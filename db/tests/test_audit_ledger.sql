-- =============================================================================
-- Audit ledger behaviour tests. Run against a freshly migrated database as a
-- superuser (the tamper tests switch off the guards to simulate an attacker):
--   psql -v ON_ERROR_STOP=1 -f db/tests/test_audit_ledger.sql
-- Everything runs in one transaction that is rolled back. All data is synthetic.
-- =============================================================================
\set ON_ERROR_STOP on
begin;

create function pg_temp.expect_error(p_sql text, p_fragment text) returns void
    language plpgsql
as $$
begin
    begin
        execute p_sql;
    exception when others then
        if position(p_fragment in sqlerrm) = 0 then
            raise exception 'expected error containing "%", got "%"', p_fragment, sqlerrm;
        end if;
        raise notice 'PASS rejected: %', p_fragment;
        return;
    end;
    raise exception 'expected error containing "%" but statement succeeded: %', p_fragment, p_sql;
end;
$$;

create function pg_temp.assert(p_condition boolean, p_message text) returns void
    language plpgsql
as $$
begin
    if p_condition is not true then
        raise exception 'FAIL: %', p_message;
    end if;
    raise notice 'PASS: %', p_message;
end;
$$;

-- -----------------------------------------------------------------------------
-- Genesis and coverage
-- -----------------------------------------------------------------------------
select pg_temp.assert((select count(*) = 0 from audit.coverage_gap), 'no coverage gaps after migration');
select pg_temp.assert(
    (select bool_and(enrolled) from audit.coverage where not exempt)
    and (select count(*) from audit.coverage where not exempt) >= 30,
    'every non-template table in gov, ref and core is enrolled');
select pg_temp.assert((select count(*) = 0 from audit.verify_chain()), 'genesis chain verifies');
select pg_temp.assert(
    (select event_type = 'audit.ledger_initialised' and prev_hash = repeat('0', 64) from audit.event where seq = 1),
    'chain starts with the ledger_initialised event on a zero hash');
select pg_temp.assert(
    (select count(*) from audit.event where event_kind = 'row_baseline' and schema_name = 'ref' and table_name = 'taxonomy_term')
    = (select count(*) from ref.taxonomy_term),
    'every seeded taxonomy term has a baseline event');
select pg_temp.assert(
    (select count(*) from audit.event where event_kind = 'row_baseline' and table_name = 'challengeable_table')
    = (select count(*) from core.challengeable_table),
    'rows seeded before the ledger existed are in the baseline');
select pg_temp.assert(
    (select count(*) = 0 from audit.event where event_kind = 'row_baseline' and schema_name = 'gov' and table_name like 'tmpl_%'),
    'column templates are exempt');

do $$
declare
    v_corr      uuid := gen_random_uuid();
    v_head      audit.chain_head;
    v_cr        uuid;
    v_crv1      uuid;
    v_crv2      uuid;
    v_evt       uuid;
    v_count     bigint;
    v_anchor    audit.anchor;
    v_seq       bigint;
    v_e         audit.event;
    v_probe     uuid;
begin
    ---------------------------------------------------------------------------
    -- Sealing happens at commit (deferred), in one gapless chain
    ---------------------------------------------------------------------------
    perform set_config('fcrm.actor_id', 'user:po.priya@fcrm.example', true);
    perform set_config('fcrm.change_reason', 'New cross-border product intake', true);
    perform set_config('fcrm.correlation_id', v_corr::text, true);
    select * into v_head from audit.chain_head;

    insert into core.change_request default values returning id into v_cr;
    perform pg_temp.assert(
        not exists (select 1 from audit.event where row_id = v_cr)
        and exists (select 1 from audit.pending_event where row_id = v_cr),
        'captured change waits in pending_event until commit');
    perform pg_temp.expect_error('update audit.pending_event set reason = ''rewritten''', 'not permitted');
    perform pg_temp.expect_error('delete from audit.pending_event', 'not permitted');

    set constraints audit.trg_seal_pending immediate;
    perform pg_temp.assert(not exists (select 1 from audit.pending_event), 'sealing drains pending_event');

    select * into v_e from audit.event where row_id = v_cr;
    perform pg_temp.assert(
        v_e.seq = v_head.last_seq + 1 and v_e.prev_hash = v_head.last_hash
        and v_e.event_hash = (select last_hash from audit.chain_head),
        'sealed event extends the chain head');
    perform pg_temp.assert(
        v_e.event_kind = 'row_insert' and v_e.event_type = 'core.change_request.insert'
        and v_e.actor_id = 'user:po.priya@fcrm.example' and v_e.db_user = session_user
        and v_e.reason = 'New cross-border product intake' and v_e.correlation_id = v_corr
        and v_e.row_after ->> 'reference_no' = (select reference_no from core.change_request where id = v_cr)
        and v_e.row_key = jsonb_build_object('id', v_cr) and v_e.row_before is null
        and exists (select 1 from audit.events_for(v_corr) f where f.event_id = v_e.event_id),
        'insert records who, what, when, the new row, the reason and the correlation id');

    ---------------------------------------------------------------------------
    -- Updates record before and after; failed statements record nothing
    ---------------------------------------------------------------------------
    perform set_config('fcrm.change_reason', '', true);
    insert into core.change_request_version (change_request_id, change_type_term_id, title, sponsor_id, change_reason)
    values (v_cr, ref.term_id('CHANGE_REQUEST_TYPE', 'PRODUCT'), 'Cross-border instant payments', 'user:po.priya@fcrm.example',
            'Initial intake')
    returning id into v_crv1;
    perform pg_temp.assert(
        (select reason = 'Initial intake' from audit.event where row_id = v_crv1 and event_kind = 'row_insert'),
        'reason falls back to the row''s change_reason');

    perform set_config('fcrm.change_reason', 'Sponsor clarified the launch corridors', true);
    update core.change_request_version set summary = 'SG and HK corridors' where id = v_crv1;
    select * into v_e from audit.event where row_id = v_crv1 and event_kind = 'row_update';
    perform pg_temp.assert(
        v_e.row_before ->> 'summary' is null and v_e.row_after ->> 'summary' = 'SG and HK corridors'
        and 'summary' = any (v_e.changed_columns) and not ('title' = any (v_e.changed_columns))
        and v_e.reason = 'Sponsor clarified the launch corridors',
        'update records the before and after row and the changed columns');

    update core.change_request_version set summary = 'SG and HK corridors' where id = v_crv1 and false;
    update core.change_request_version set record_status = 'active' where id = v_crv1;

    select count(*) into v_count from audit.event;
    perform pg_temp.expect_error(format('update core.change_request_version set title = ''changed'' where id = %L', v_crv1),
        'content is frozen');
    perform pg_temp.assert((select count(*) from audit.event) = v_count, 'a rejected change leaves no event');

    perform pg_temp.assert(
        (select array_agg(event_kind::text order by seq) = array['row_insert', 'row_update', 'row_update']
           from audit.row_history('core.change_request_version', v_crv1)),
        'row_history returns the lifecycle of a record in order');

    ---------------------------------------------------------------------------
    -- Deletes record the removed row, and need an identified actor
    ---------------------------------------------------------------------------
    insert into core.change_request_version (change_request_id, change_type_term_id, title, sponsor_id)
    values (v_cr, ref.term_id('CHANGE_REQUEST_TYPE', 'PRODUCT'), 'Draft to discard', 'user:po.priya@fcrm.example')
    returning id into v_crv2;

    perform set_config('fcrm.actor_id', '', true);
    perform pg_temp.expect_error(format('delete from core.change_request_version where id = %L', v_crv2),
        'requires an identified actor');
    perform set_config('fcrm.actor_id', 'user:po.priya@fcrm.example', true);

    delete from core.change_request_version where id = v_crv2;
    perform pg_temp.assert(
        (select row_before ->> 'title' = 'Draft to discard' and row_after is null
           from audit.event where row_id = v_crv2 and event_kind = 'row_delete'),
        'delete records the removed row');

    perform pg_temp.expect_error('truncate core.change_request_scope', 'audited row by row');

    ---------------------------------------------------------------------------
    -- Domain events from components
    ---------------------------------------------------------------------------
    v_evt := audit.record_event('workflow.transitioned', '{"from": "draft", "to": "submitted"}',
                                'core.change_request', v_cr, 'Product owner submitted the request');
    perform pg_temp.assert(
        (select event_kind = 'domain_event' and table_name = 'change_request' and row_id = v_cr
                and payload ->> 'to' = 'submitted' and correlation_id = v_corr
                and reason = 'Product owner submitted the request'
           from audit.event where event_id = v_evt),
        'record_event logs a business event against its subject');

    perform pg_temp.expect_error('select audit.record_event(''Workflow Moved'')', 'must be lower-case dotted segments');
    perform pg_temp.expect_error('select audit.record_event(''audit.anchor_taken'')', 'reserved for the ledger');
    perform pg_temp.expect_error('select audit.record_event(''ai.suggestion_presented'', ''[]'')', 'must be a JSON object');
    perform set_config('fcrm.actor_id', '', true);
    perform pg_temp.expect_error('select audit.record_event(''ai.suggestion_presented'')', 'requires an identified actor');
    perform set_config('fcrm.actor_id', 'user:po.priya@fcrm.example', true);

    ---------------------------------------------------------------------------
    -- The ledger itself is immutable
    ---------------------------------------------------------------------------
    perform pg_temp.expect_error('update audit.event set reason = ''rewritten'' where seq = 1', 'append-only');
    perform pg_temp.expect_error('delete from audit.event where seq = 1', 'append-only');
    perform pg_temp.expect_error('truncate audit.event cascade', 'append-only');
    perform pg_temp.expect_error(
        'insert into audit.event (event_id, event_kind, event_type, payload, actor_id, db_user, xact_id, txn_started_at, occurred_at) '
        || 'values (gen_random_uuid(), ''domain_event'', ''forged.event'', ''{}'', ''system:forger'', ''x'', ''1'', now(), now())',
        'appended only by sealing');
    perform pg_temp.expect_error('update audit.chain_head set last_seq = 1', 'can only advance');
    perform pg_temp.expect_error('delete from audit.chain_head', 'not permitted');
    perform pg_temp.expect_error('truncate audit.pending_event', 'append-only');
    perform pg_temp.expect_error('delete from audit.governed_schema', 'append-only');

    -- Replication mode does not switch capture or immutability off.
    set local session_replication_role = replica;
    insert into core.change_request default values returning id into v_probe;
    perform pg_temp.expect_error('delete from audit.event where seq = 1', 'append-only');
    set local session_replication_role = origin;
    perform pg_temp.assert(exists (select 1 from audit.event where row_id = v_probe), 'changes are captured in replica mode');

    ---------------------------------------------------------------------------
    -- DDL guards
    ---------------------------------------------------------------------------
    perform pg_temp.expect_error('alter table core.rating disable trigger trg_zz_audit', 'coverage check failed');
    perform pg_temp.expect_error('alter table core.rating disable trigger all', 'coverage check failed');
    perform pg_temp.expect_error('drop trigger trg_zz_audit on core.rating', 'coverage check failed');
    perform pg_temp.expect_error('drop trigger trg_zz_audit_no_truncate on core.vote', 'TRUNCATE is not blocked');
    perform pg_temp.expect_error(
        'create or replace trigger trg_zz_audit after insert on core.rating for each row execute function audit.capture_row_change(''id'')',
        'row changes are not captured');
    perform pg_temp.expect_error('alter table audit.event disable trigger trg_append_only', 'ledger protection trigger');
    perform pg_temp.expect_error('drop trigger trg_seal_pending on audit.pending_event', 'ledger objects cannot be dropped');
    perform pg_temp.expect_error('drop function audit.capture_row_change() cascade', 'ledger objects cannot be dropped');
    perform pg_temp.expect_error('drop view audit.coverage cascade', 'ledger objects cannot be dropped');
    perform pg_temp.expect_error('drop schema audit cascade', 'ledger objects cannot be dropped');

    -- New tables in governed schemas are enrolled automatically.
    create table core.audit_probe (id uuid primary key default gen_random_uuid(), note text);
    perform pg_temp.assert(
        (select enrolled and captured_key = 'id' and blocks_truncate from audit.coverage where table_name = 'core.audit_probe'::regclass),
        'a table created in a governed schema is enrolled with its primary key');
    insert into core.audit_probe (note) values ('probe') returning id into v_probe;
    perform pg_temp.assert(
        (select event_type = 'core.audit_probe.insert' from audit.event where row_id = v_probe)
        and exists (select 1 from audit.event where event_type = 'audit.table_enrolled' and payload ->> 'table' = 'core.audit_probe'),
        'changes to a newly created table are captured, and its enrolment is recorded');

    create table core.audit_probe_nokey (note text);
    insert into core.audit_probe_nokey values ('no key');
    perform pg_temp.assert(
        (select row_key is null and row_after ->> 'note' = 'no key' from audit.event where table_name = 'audit_probe_nokey'),
        'a table without a primary key is still captured, by full row');
    alter table core.audit_probe_nokey add column id uuid primary key default gen_random_uuid();
    perform pg_temp.assert(
        (select captured_key = 'id' from audit.coverage where table_name = 'core.audit_probe_nokey'::regclass),
        'adding a primary key refreshes the captured key');

    drop table core.audit_probe;
    perform pg_temp.assert(
        exists (select 1 from audit.event where event_type = 'audit.table_dropped' and payload ->> 'table' = 'core.audit_probe'),
        'dropping an enrolled table is recorded; its history stays in the ledger');
    perform pg_temp.assert(exists (select 1 from audit.event where row_id = v_probe), 'history of a dropped table is kept');

    ---------------------------------------------------------------------------
    -- Anchors and verification
    ---------------------------------------------------------------------------
    perform set_config('fcrm.actor_id', 'user:mlro.maria@fcrm.example', true);
    v_anchor := audit.take_anchor('Daily checkpoint (synthetic)');
    perform pg_temp.assert(v_anchor.seq > 0 and v_anchor.event_hash = (select event_hash from audit.event where seq = v_anchor.seq),
        'anchor records the chain head');
    perform pg_temp.assert(audit.verify_anchor(v_anchor.seq, v_anchor.event_hash),
        'verify_anchor accepts a matching copy held outside the database');
    perform pg_temp.assert(
        exists (select 1 from audit.event where event_type = 'audit.anchor_taken' and actor_id = 'user:mlro.maria@fcrm.example'),
        'taking an anchor is itself recorded');
    perform pg_temp.assert((select count(*) = 0 from audit.verify_chain()), 'chain verifies after all activity');
    perform pg_temp.assert((select count(*) = 0 from audit.verify_chain(v_anchor.seq - 5, v_anchor.seq)),
        'a sub-range verifies');

    ---------------------------------------------------------------------------
    -- Tampering by someone who can bypass the guards is detected
    -- (each block runs in a subtransaction that is rolled back)
    ---------------------------------------------------------------------------
    select seq into v_seq from audit.event where row_id = v_crv1 and event_kind = 'row_update';

    begin
        alter event trigger audit_ddl_guard disable;
        alter table audit.event disable trigger trg_append_only;
        update audit.event set row_after = jsonb_set(row_after, '{summary}', '"rewritten"') where seq = v_seq;
        perform pg_temp.assert(
            (select array_agg(problem) = array['event_hash does not match the event content']
               from audit.verify_chain() where event_seq = v_seq),
            'editing an event''s content is detected');
        raise exception 'rollback_tamper';
    exception when raise_exception then
        if sqlerrm <> 'rollback_tamper' then raise; end if;
    end;

    begin
        alter event trigger audit_ddl_guard disable;
        alter table audit.event disable trigger trg_append_only;
        update audit.event e set row_after = jsonb_set(e.row_after, '{summary}', '"rewritten"') where e.seq = v_seq;
        update audit.event e set event_hash = audit.hash_event(e) where e.seq = v_seq;
        perform pg_temp.assert(
            exists (select 1 from audit.verify_chain() where event_seq = v_seq + 1 and problem like 'prev_hash%'),
            'rehashing an edited event breaks the link to the next one');
        raise exception 'rollback_tamper';
    exception when raise_exception then
        if sqlerrm <> 'rollback_tamper' then raise; end if;
    end;

    begin
        alter event trigger audit_ddl_guard disable;
        alter table audit.event disable trigger trg_append_only;
        delete from audit.event where seq = v_seq;
        perform pg_temp.assert(
            exists (select 1 from audit.verify_chain() where event_seq = v_seq and problem like 'events % to % are missing'),
            'deleting an event is detected');
        raise exception 'rollback_tamper';
    exception when raise_exception then
        if sqlerrm <> 'rollback_tamper' then raise; end if;
    end;

    begin
        alter event trigger audit_ddl_guard disable;
        alter table audit.event disable trigger trg_append_only;
        alter table audit.anchor disable trigger trg_append_only;
        alter table audit.chain_head disable trigger trg_guard;
        -- A superuser removes the internal anchors and rewrites the chain after the edit.
        delete from audit.anchor;
        update audit.event e set row_after = jsonb_set(e.row_after, '{summary}', '"rewritten"') where e.seq = v_seq;
        declare
            v_prev text := (select event_hash from audit.event where seq = v_seq - 1);
            r      audit.event;
        begin
            for r in select * from audit.event where seq >= v_seq order by seq loop
                r.prev_hash := v_prev;
                v_prev := audit.hash_event(r);
                update audit.event set prev_hash = r.prev_hash, event_hash = v_prev where seq = r.seq;
            end loop;
            update audit.chain_head set last_hash = v_prev;
        end;
        perform pg_temp.assert((select count(*) = 0 from audit.verify_chain()),
            'a full rewrite that also removes internal anchors passes the internal checks');
        perform pg_temp.assert(not audit.verify_anchor(v_anchor.seq, v_anchor.event_hash),
            'but it is detected by the anchor copy held outside the database');
        raise exception 'rollback_tamper';
    exception when raise_exception then
        if sqlerrm <> 'rollback_tamper' then raise; end if;
    end;

    begin
        alter event trigger audit_ddl_guard disable;
        alter table audit.event disable trigger all;
        update audit.event set event_hash = repeat('e', 64) where seq = v_anchor.seq;
        perform pg_temp.assert(
            exists (select 1 from audit.verify_chain() where problem = format('anchor %s no longer matches the chain', v_anchor.id)),
            'verify_chain reports an internal anchor that no longer matches');
        raise exception 'rollback_tamper';
    exception when raise_exception then
        if sqlerrm <> 'rollback_tamper' then raise; end if;
    end;

    perform pg_temp.assert((select count(*) = 0 from audit.verify_chain()), 'chain intact again after tamper rollbacks');
    perform pg_temp.assert((select count(*) = 0 from audit.coverage_gap), 'guards intact again after tamper rollbacks');
end;
$$;

rollback;
\echo 'All audit ledger tests passed.'
