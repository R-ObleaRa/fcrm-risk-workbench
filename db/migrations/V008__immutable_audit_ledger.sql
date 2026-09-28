-- =============================================================================
-- V008  Immutable audit ledger
--
-- One append-only, hash-chained event store that every component writes to:
--   * every insert, update and delete on a governed table (any table in a
--     schema registered in audit.governed_schema) is captured by trigger:
--     who, what, when, the row before and after, and the reason
--   * components record business events that are not row changes (workflow
--     transitions, AI suggestions shown, examiner exports) with
--     audit.record_event()
--   * rows that existed before this migration are recorded as a baseline, so
--     the trail is complete from the first record
--
-- Sealing
--   Captured events wait in audit.pending_event until the transaction commits.
--   A deferred trigger then appends them to audit.event in capture order. Each
--   gets the next gapless seq and event_hash = sha256 of its canonical form,
--   which includes the previous event's hash. The chain head is locked only
--   for that step, so concurrent transactions serialise at commit rather than
--   for their whole duration. A transaction that rolls back leaves no events,
--   because none of its changes happened.
--
-- Tamper evidence
--   * audit.event rejects UPDATE, DELETE and TRUNCATE, and accepts an INSERT
--     only from the sealing trigger and only if it extends the chain.
--   * audit.verify_chain() recomputes every hash and link.
--   * audit.take_anchor() records the chain head. Publish anchors outside the
--     database: a superuser who rewrites the whole chain can't also rewrite
--     copies held elsewhere.
--   * Every ledger trigger is ENABLE ALWAYS, so session_replication_role =
--     replica doesn't bypass capture or immutability.
--   * Event triggers enrol new tables in governed schemas automatically, and
--     reject DDL that would drop, disable or weaken a capture or protection
--     trigger.
--
-- Session settings read by the ledger (set with SET LOCAL per transaction):
--   fcrm.actor_id        acting principal (already required by V001)
--   fcrm.change_reason   why the change is being made
--   fcrm.correlation_id  workflow instance / request that caused the change
--   fcrm.audit_sealing   set only by audit.seal_pending while it drains pending_event
--
-- Creating event triggers requires a superuser (rds_superuser on RDS).
-- =============================================================================

select set_config('fcrm.actor_id', 'system:migration', false);

create schema if not exists audit;
comment on schema audit is 'Immutable, hash-chained audit ledger written to by every component.';

create type audit.event_kind as enum ('row_baseline', 'row_insert', 'row_update', 'row_delete', 'domain_event');
comment on type audit.event_kind is
    'row_baseline = a row that existed when the ledger was created (or when its table was enrolled); '
    'row_insert/row_update/row_delete = captured change to a governed table; '
    'domain_event = business event recorded by a component through audit.record_event().';

-- Principal for ledger housekeeping (enrolment, DDL). Business changes require
-- fcrm.actor_id; schema changes fall back to the database role running them.
create function audit.acting_principal() returns text
    language sql stable
as $$
    select coalesce(
        gov.current_actor(),
        'system:' || coalesce(nullif(trim(both '._-' from regexp_replace(lower(session_user::text), '[^a-z0-9._-]+', '-', 'g')), ''),
                              'unknown-db-role'))
$$;

-- -----------------------------------------------------------------------------
-- Scope: governed schemas, exemptions, enrolled tables
-- -----------------------------------------------------------------------------
create table audit.governed_schema (
    schema_name text primary key,
    added_at    timestamptz      not null default now(),
    added_by    gov.principal_id not null default audit.acting_principal()
);
comment on table audit.governed_schema is
    'Schemas whose tables are audited. Tables created in them are enrolled automatically. Append-only.';

create table audit.exempt_table (
    table_oid   oid primary key,
    table_name  text             not null,
    reason      text             not null check (length(trim(reason)) >= 10),
    exempted_at timestamptz      not null default now(),
    exempted_by gov.principal_id not null default audit.acting_principal()
);
comment on table audit.exempt_table is
    'Tables in governed schemas that are deliberately not audited, e.g. column templates that never hold data. Append-only. '
    'Stored as oid + name (not regclass) so a later drop does not break ledger views.';
comment on column audit.exempt_table.table_name is 'Qualified name at exemption; kept if the table is later dropped.';

create table audit.enrolled_table (
    table_oid   oid primary key,
    table_name  text             not null,
    enrolled_at timestamptz      not null default now(),
    enrolled_by gov.principal_id not null default audit.acting_principal()
);
comment on table audit.enrolled_table is
    'Tables whose changes are captured. Once enrolled, the DDL guard rejects any change that would stop capture. Append-only.';
comment on column audit.enrolled_table.table_name is 'Qualified name at enrolment; kept if the table is later dropped.';

-- -----------------------------------------------------------------------------
-- The ledger
-- -----------------------------------------------------------------------------
create table audit.chain_head (
    singleton  boolean primary key default true check (singleton),
    last_seq   bigint      not null check (last_seq >= 0),
    last_hash  text        not null check (last_hash ~ '^[0-9a-f]{64}$'),
    updated_at timestamptz not null default now()
);
comment on table audit.chain_head is 'Seq and hash of the last sealed event. Advances only when an event is sealed.';

insert into audit.chain_head (last_seq, last_hash) values (0, repeat('0', 64));

create table audit.pending_event (
    pending_seq      bigint generated always as identity primary key,
    xact_id          xid8             not null default pg_current_xact_id(),
    event_id         uuid             not null default gen_random_uuid(),
    event_kind       audit.event_kind not null,
    event_type       text             not null,
    schema_name      text,
    table_name       text,
    row_id           uuid,
    row_key          jsonb,
    row_before       jsonb,
    row_after        jsonb,
    changed_columns  text[],
    payload          jsonb,
    reason           text,
    correlation_id   uuid,
    actor_id         gov.principal_id not null,
    db_user          text             not null default session_user,
    application_name text                      default nullif(current_setting('application_name', true), ''),
    txn_started_at   timestamptz      not null default now(),
    occurred_at      timestamptz      not null default clock_timestamp()
);
comment on table audit.pending_event is
    'Events captured by the current transaction, moved into audit.event at commit. Empty outside a transaction.';

create index ix_pending_event_xact on audit.pending_event (xact_id, pending_seq);

create table audit.event (
    seq              bigint           primary key check (seq > 0),
    event_id         uuid             not null unique,
    event_kind       audit.event_kind not null,
    event_type       text             not null check (event_type ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
    schema_name      text,
    table_name       text,
    row_id           uuid,
    row_key          jsonb,
    row_before       jsonb,
    row_after        jsonb,
    changed_columns  text[],
    payload          jsonb,
    reason           text,
    correlation_id   uuid,
    actor_id         gov.principal_id not null,
    db_user          text             not null,
    application_name text,
    xact_id          xid8             not null,
    txn_started_at   timestamptz      not null,
    occurred_at      timestamptz      not null,
    sealed_at        timestamptz      not null,
    prev_hash        text             not null check (prev_hash ~ '^[0-9a-f]{64}$'),
    event_hash       text             not null unique check (event_hash ~ '^[0-9a-f]{64}$'),
    unique (seq, event_hash),
    constraint ck_event_shape check (case event_kind
        when 'domain_event' then payload is not null and jsonb_typeof(payload) = 'object'
                                 and row_before is null and row_after is null and changed_columns is null
        when 'row_update'   then schema_name is not null and table_name is not null and payload is null
                                 and row_before is not null and row_after is not null and changed_columns is not null
        when 'row_delete'   then schema_name is not null and table_name is not null and payload is null
                                 and row_before is not null and row_after is null
        else                     schema_name is not null and table_name is not null and payload is null
                                 and row_before is null and row_after is not null
    end)
);
comment on table  audit.event is 'The audit ledger: append-only, gapless, hash-chained. Never updated or deleted.';
comment on column audit.event.seq             is 'Position in the chain, gapless from 1, in commit order.';
comment on column audit.event.event_type      is '<schema>.<table>.<insert|update|delete|baseline> for row events; a dotted component code for domain events.';
comment on column audit.event.row_id          is 'The row''s uuid id column, when it has one. Domain events: the subject record.';
comment on column audit.event.row_key         is 'Primary-key columns and values of the row (null if the table has no primary key).';
comment on column audit.event.row_before      is 'Complete row before the change (update, delete).';
comment on column audit.event.row_after       is 'Complete row after the change (insert, update, baseline).';
comment on column audit.event.changed_columns is 'Columns whose value changed (update).';
comment on column audit.event.reason          is 'fcrm.change_reason, else the row''s change_reason column.';
comment on column audit.event.correlation_id  is 'fcrm.correlation_id, else the row''s correlation_id column.';
comment on column audit.event.actor_id        is 'Acting principal (fcrm.actor_id).';
comment on column audit.event.db_user         is 'Database session role that made the change; exposes direct database access.';
comment on column audit.event.occurred_at     is 'Wall-clock time the change was captured.';
comment on column audit.event.sealed_at       is 'Time the event was chained, at commit.';
comment on column audit.event.prev_hash       is 'event_hash of seq - 1; 64 zeros for seq 1.';
comment on column audit.event.event_hash      is 'sha256 of audit.canonical_text(event), hex.';

create index ix_event_row         on audit.event (schema_name, table_name, row_id, seq);
create index ix_event_correlation on audit.event (correlation_id, seq) where correlation_id is not null;
create index ix_event_actor       on audit.event (actor_id, seq);
create index ix_event_type        on audit.event (event_type, seq);

create table audit.anchor (
    id          uuid primary key default gen_random_uuid(),
    seq         bigint           not null,
    event_hash  text             not null,
    note        text,
    anchored_at timestamptz      not null default now(),
    anchored_by gov.principal_id not null default audit.acting_principal(),
    foreign key (seq, event_hash) references audit.event (seq, event_hash)
);
comment on table audit.anchor is
    'Chain-head checkpoints. Copy each one outside the database (e.g. WORM storage); verify_chain checks the chain still matches. Append-only.';

-- -----------------------------------------------------------------------------
-- Canonical form and hash
--
-- The hash covers every column except event_hash, rendered as jsonb text
-- (keys in jsonb's canonical order) with timestamps in UTC, so the result
-- doesn't depend on session settings.
-- -----------------------------------------------------------------------------
create function audit.utc_text(p_ts timestamptz) returns text
    language sql stable
as $$ select to_char(p_ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') $$;

create function audit.canonical_text(e audit.event) returns text
    language sql stable
as $$
    select jsonb_build_object(
        'format',           'fcrm-audit-v1',
        'seq',              e.seq,
        'prev_hash',        e.prev_hash,
        'event_id',         e.event_id,
        'event_kind',       e.event_kind,
        'event_type',       e.event_type,
        'schema_name',      e.schema_name,
        'table_name',       e.table_name,
        'row_id',           e.row_id,
        'row_key',          e.row_key,
        'row_before',       e.row_before,
        'row_after',        e.row_after,
        'changed_columns',  e.changed_columns,
        'payload',          e.payload,
        'reason',           e.reason,
        'correlation_id',   e.correlation_id,
        'actor_id',         e.actor_id,
        'db_user',          e.db_user,
        'application_name', e.application_name,
        'xact_id',          e.xact_id::text,
        'txn_started_at',   audit.utc_text(e.txn_started_at),
        'occurred_at',      audit.utc_text(e.occurred_at),
        'sealed_at',        audit.utc_text(e.sealed_at))::text
$$;
comment on function audit.canonical_text(audit.event) is 'Exact text that event_hash is computed over (format fcrm-audit-v1).';

create function audit.hash_event(e audit.event) returns text
    language sql stable
as $$ select encode(sha256(convert_to(audit.canonical_text(e), 'UTF8')), 'hex') $$;

-- -----------------------------------------------------------------------------
-- Capture
-- -----------------------------------------------------------------------------
create function audit.primary_key_columns(p_table regclass) returns text
    language sql stable
as $$
    select coalesce(string_agg(a.attname::text, ',' order by k.ord), '')
      from pg_index i
     cross join lateral unnest(i.indkey::int2[]) with ordinality k(attnum, ord)
      join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
     where i.indrelid = p_table and i.indisprimary
$$;

create function audit.row_key_of(p_row jsonb, p_key_columns text) returns jsonb
    language sql immutable
as $$
    select case when coalesce(p_key_columns, '') <> '' then
               (select jsonb_object_agg(k, p_row -> k) from unnest(string_to_array(p_key_columns, ',')) k)
           end
$$;

create function audit.row_id_of(p_row jsonb) returns uuid
    language sql immutable
as $$
    select case when p_row ->> 'id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                then (p_row ->> 'id')::uuid end
$$;

create function audit.setting_reason() returns text
    language sql stable
as $$ select nullif(trim(current_setting('fcrm.change_reason', true)), '') $$;

create function audit.setting_correlation_id() returns uuid
    language sql stable
as $$ select nullif(trim(current_setting('fcrm.correlation_id', true)), '')::uuid $$;

create function audit.enqueue(
    p_kind           audit.event_kind,
    p_type           text,
    p_schema         text,
    p_table          text,
    p_row_id         uuid,
    p_row_key        jsonb,
    p_before         jsonb,
    p_after          jsonb,
    p_changed        text[],
    p_payload        jsonb,
    p_reason         text,
    p_correlation_id uuid,
    p_actor          text) returns uuid
    language plpgsql security definer set search_path = pg_catalog, pg_temp
as $$
declare
    v_id uuid;
begin
    if p_actor is null then
        raise exception 'audit: % requires an identified actor (set fcrm.actor_id)', p_type;
    end if;
    if p_type !~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' then
        raise exception 'audit: event type "%" must be lower-case dotted segments, e.g. workflow.transitioned', p_type;
    end if;
    insert into audit.pending_event (event_kind, event_type, schema_name, table_name, row_id, row_key, row_before, row_after,
                                     changed_columns, payload, reason, correlation_id, actor_id)
    values (p_kind, p_type, p_schema, p_table, p_row_id, p_row_key, p_before, p_after,
            p_changed, p_payload, p_reason, p_correlation_id, p_actor)
    returning event_id into v_id;
    return v_id;
end;
$$;

-- Row-change capture (AFTER ROW, ENABLE ALWAYS).
--   TG_ARGV[0] = comma-separated primary-key columns ('' if none)
create function audit.capture_row_change() returns trigger
    language plpgsql security definer set search_path = pg_catalog, pg_temp
as $$
declare
    v_before  jsonb;
    v_after   jsonb;
    v_row     jsonb;
    v_changed text[];
    v_kind    audit.event_kind;
begin
    if tg_op = 'INSERT' then
        v_after := to_jsonb(new);
        v_kind  := 'row_insert';
    elsif tg_op = 'UPDATE' then
        v_before := to_jsonb(old);
        v_after  := to_jsonb(new);
        if v_before = v_after then
            return null;
        end if;
        select array_agg(a.key order by a.key) into v_changed
          from jsonb_each(v_after) as a(key, val)
         where a.val is distinct from v_before -> a.key;
        v_kind := 'row_update';
    else
        v_before := to_jsonb(old);
        v_kind   := 'row_delete';
    end if;
    v_row := coalesce(v_after, v_before);

    perform audit.enqueue(
        v_kind,
        format('%s.%s.%s', lower(tg_table_schema), lower(tg_table_name), lower(tg_op)),
        tg_table_schema,
        tg_table_name,
        audit.row_id_of(v_row),
        audit.row_key_of(v_row, tg_argv[0]),
        v_before,
        v_after,
        v_changed,
        null,
        coalesce(audit.setting_reason(),
                 case when tg_op <> 'DELETE' then nullif(trim(v_after ->> 'change_reason'), '') end),
        coalesce(audit.setting_correlation_id(), (v_row ->> 'correlation_id')::uuid),
        -- Updates and deletes must name the actor; an insert may carry it in created_by.
        coalesce(gov.current_actor(), case when tg_op = 'INSERT' then v_after ->> 'created_by' end));
    return null;
end;
$$;

create function audit.forbid_truncate() returns trigger
    language plpgsql
as $$
begin
    raise exception 'TRUNCATE on %.% is not permitted: the table is audited row by row', tg_table_schema, tg_table_name
        using errcode = 'P0001', hint = 'Delete rows individually so that each deletion is recorded in the audit ledger.';
end;
$$;

-- -----------------------------------------------------------------------------
-- Domain events
-- -----------------------------------------------------------------------------
create function audit.record_event(
    p_event_type    text,
    p_payload       jsonb    default '{}',
    p_subject_table regclass default null,
    p_subject_id    uuid     default null,
    p_reason        text     default null) returns uuid
    language plpgsql security definer set search_path = pg_catalog, pg_temp
as $$
declare
    v_schema text;
    v_table  text;
begin
    if p_event_type like 'audit.%' then
        raise exception 'audit.record_event: event types under "audit." are reserved for the ledger itself';
    end if;
    if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
        raise exception 'audit.record_event: payload must be a JSON object';
    end if;
    if p_subject_id is not null and p_subject_table is null then
        raise exception 'audit.record_event: a subject id needs its subject table';
    end if;
    if p_subject_table is not null then
        select n.nspname, k.relname into v_schema, v_table
          from pg_class k join pg_namespace n on n.oid = k.relnamespace
         where k.oid = p_subject_table;
    end if;
    return audit.enqueue('domain_event', p_event_type, v_schema, v_table, p_subject_id, null, null, null, null, p_payload,
                         coalesce(nullif(trim(p_reason), ''), audit.setting_reason()), audit.setting_correlation_id(),
                         gov.current_actor());
end;
$$;
comment on function audit.record_event(text, jsonb, regclass, uuid, text) is
    'Record a business event (e.g. workflow.transitioned, ai.suggestion_presented, examiner_pack.exported) in the ledger. '
    'Requires fcrm.actor_id. Sealed with the transaction.';

create function audit.emit(p_type text, p_payload jsonb) returns uuid
    language sql security definer set search_path = pg_catalog, pg_temp
as $$
    select audit.enqueue('domain_event', p_type, null, null, null, null, null, null, null, p_payload,
                         audit.setting_reason(), audit.setting_correlation_id(), audit.acting_principal())
$$;
comment on function audit.emit(text, jsonb) is 'Ledger housekeeping events (audit.*). Not for components; use audit.record_event.';

-- -----------------------------------------------------------------------------
-- Sealing and chaining
-- -----------------------------------------------------------------------------
create function audit.seal_pending() returns trigger
    language plpgsql security definer set search_path = pg_catalog, pg_temp
as $$
declare
    v_p audit.pending_event;
begin
    perform set_config('fcrm.audit_sealing', '1', true);
    for v_p in
        select * from audit.pending_event p
         where p.xact_id = pg_current_xact_id()
         order by p.pending_seq
    loop
        insert into audit.event (event_id, event_kind, event_type, schema_name, table_name, row_id, row_key,
                                 row_before, row_after, changed_columns, payload, reason, correlation_id, actor_id,
                                 db_user, application_name, xact_id, txn_started_at, occurred_at)
        values (v_p.event_id, v_p.event_kind, v_p.event_type, v_p.schema_name, v_p.table_name, v_p.row_id, v_p.row_key,
                v_p.row_before, v_p.row_after, v_p.changed_columns, v_p.payload, v_p.reason, v_p.correlation_id, v_p.actor_id,
                v_p.db_user, v_p.application_name, v_p.xact_id, v_p.txn_started_at, v_p.occurred_at);
        delete from audit.pending_event where pending_seq = v_p.pending_seq;
    end loop;
    perform set_config('fcrm.audit_sealing', '', true);
    return null;
end;
$$;

create function audit.chain_event() returns trigger
    language plpgsql
as $$
declare
    v_head audit.chain_head;
    v_hash text;
begin
    if pg_trigger_depth() < 2 then
        raise exception 'audit.event: events are appended only by sealing captured changes'
            using hint = 'Use audit.record_event() to record a business event.';
    end if;

    select * into strict v_head from audit.chain_head for update;

    if new.seq is not null and new.seq <> v_head.last_seq + 1 then
        raise exception 'audit.event: seq % does not extend the chain (next is %)', new.seq, v_head.last_seq + 1;
    end if;
    if new.prev_hash is not null and new.prev_hash <> v_head.last_hash then
        raise exception 'audit.event: prev_hash does not match the chain head';
    end if;
    new.seq       := v_head.last_seq + 1;
    new.prev_hash := v_head.last_hash;
    new.sealed_at := coalesce(new.sealed_at, clock_timestamp());

    v_hash := audit.hash_event(new);
    if new.event_hash is not null and new.event_hash <> v_hash then
        raise exception 'audit.event: event_hash does not match the event content';
    end if;
    new.event_hash := v_hash;
    return new;
end;
$$;

create function audit.advance_head() returns trigger
    language plpgsql
as $$
begin
    update audit.chain_head
       set last_seq = new.seq, last_hash = new.event_hash, updated_at = new.sealed_at
     where singleton;
    return null;
end;
$$;

create function audit.guard_chain_head() returns trigger
    language plpgsql
as $$
begin
    if tg_op <> 'UPDATE' then
        raise exception '% on audit.chain_head is not permitted', tg_op;
    end if;
    if new.last_seq <> old.last_seq + 1
       or not exists (select 1 from audit.event e
                       where e.seq = new.last_seq and e.event_hash = new.last_hash and e.prev_hash = old.last_hash) then
        raise exception 'audit.chain_head can only advance to the next sealed event';
    end if;
    return new;
end;
$$;

create function audit.guard_pending() returns trigger
    language plpgsql
as $$
begin
    if tg_op = 'UPDATE' then
        raise exception 'UPDATE on audit.pending_event is not permitted'
            using hint = 'Captured events are sealed as-is; record a new event instead of changing a pending one.';
    end if;
    if current_setting('fcrm.audit_sealing', true) is distinct from '1' then
        raise exception 'DELETE on audit.pending_event is not permitted'
            using hint = 'Pending events are removed only when they are sealed into audit.event.';
    end if;
    return old;
end;
$$;

-- -----------------------------------------------------------------------------
-- Enrolment and coverage
-- -----------------------------------------------------------------------------
create function audit.register_enrolment(p_table regclass, p_key_columns text) returns void
    language plpgsql security definer set search_path = pg_catalog, pg_temp
as $$
begin
    insert into audit.enrolled_table (table_oid, table_name) values (p_table, p_table::text)
    on conflict (table_oid) do nothing;
    if found then
        perform audit.emit('audit.table_enrolled', jsonb_build_object('table', p_table::text, 'primary_key', p_key_columns));
    end if;
end;
$$;

-- Attach (or refresh) the capture and truncate triggers on a table, then enrol it.
-- Both triggers exist before the table is enrolled, so the DDL guard never sees
-- an enrolled table half-configured. A disabled capture trigger is left alone
-- so that the guard reports it rather than it being silently re-enabled.
create function audit.enable_table(p_table regclass) returns boolean
    language plpgsql
as $$
declare
    v_keys    text := audit.primary_key_columns(p_table);
    v_capture record;
    v_enable  text[] := '{}';
begin
    if exists (select 1 from audit.exempt_table x where x.table_oid = p_table) then
        return false;
    end if;
    if not exists (select 1 from pg_class k where k.oid = p_table and k.relkind in ('r', 'p') and not k.relispartition) then
        raise exception 'audit.enable_table: % is not a table', p_table;
    end if;

    select t.tgname, t.tgenabled, regexp_replace(encode(t.tgargs, 'escape'), '\\000$', '') as args
      into v_capture
      from pg_trigger t
     where t.tgrelid = p_table and t.tgfoid = 'audit.capture_row_change()'::regprocedure
     order by t.tgname
     limit 1;

    if v_capture.tgname is null then
        execute format('create trigger trg_zz_audit after insert or update or delete on %s '
                       'for each row execute function audit.capture_row_change(%L)', p_table, v_keys);
        v_enable := v_enable || 'trg_zz_audit'::text;
    elsif v_capture.tgenabled <> 'D' and v_capture.args <> v_keys then
        execute format('create or replace trigger %I after insert or update or delete on %s '
                       'for each row execute function audit.capture_row_change(%L)', v_capture.tgname, p_table, v_keys);
        v_enable := v_enable || v_capture.tgname::text;
    end if;

    if not exists (select 1 from pg_trigger t where t.tgrelid = p_table and t.tgfoid = 'audit.forbid_truncate()'::regprocedure) then
        execute format('create trigger trg_zz_audit_no_truncate before truncate on %s '
                       'for each statement execute function audit.forbid_truncate()', p_table);
        v_enable := v_enable || 'trg_zz_audit_no_truncate'::text;
    end if;

    if cardinality(v_enable) > 0 then
        execute format('alter table %s %s', p_table,
                       (select string_agg(format('enable always trigger %I', n), ', ') from unnest(v_enable) n));
    end if;

    perform audit.register_enrolment(p_table, v_keys);
    return true;
end;
$$;
comment on function audit.enable_table(regclass) is
    'Enrol a table in the ledger. Automatic for tables created in a governed schema; call it for tables elsewhere.';

create view audit.coverage as
select k.oid::regclass                  as table_name,
       n.nspname::text                  as schema_name,
       x.table_name is not null         as exempt,
       e.table_oid is not null          as enrolled,
       audit.primary_key_columns(k.oid) as primary_key,
       cap.args                         as captured_key,
       exists (select 1 from pg_trigger t
                where t.tgrelid = k.oid and t.tgfoid = 'audit.forbid_truncate()'::regprocedure
                  and t.tgenabled <> 'D' and (t.tgtype & 35) = 34) as blocks_truncate
  from pg_class k
  join pg_namespace n on n.oid = k.relnamespace
  left join audit.exempt_table x on x.table_oid = k.oid
  left join audit.enrolled_table e on e.table_oid = k.oid
  left join lateral (
        select regexp_replace(encode(t.tgargs, 'escape'), '\\000$', '') as args
          from pg_trigger t
         where t.tgrelid = k.oid and t.tgfoid = 'audit.capture_row_change()'::regprocedure
           and t.tgenabled <> 'D' and t.tgqual is null and (t.tgtype & 95) = 29
           and cardinality(t.tgattr::int2[]) = 0
         order by t.tgname
         limit 1) cap on true
 where k.relkind in ('r', 'p') and not k.relispartition
   and (n.nspname::text in (select g.schema_name from audit.governed_schema g) or e.table_oid is not null);
comment on view audit.coverage is
    'Every table in a governed schema or enrolled in the ledger. captured_key is null unless an enabled, unconditional '
    'AFTER INSERT OR UPDATE OR DELETE row trigger calls audit.capture_row_change.';

create view audit.coverage_gap as
select c.table_name, 'not enrolled in the audit ledger'::text as problem, false as enforced
  from audit.coverage c
 where not c.exempt and not c.enrolled
union all
select c.table_name, 'row changes are not captured (capture trigger missing, disabled, conditional or column-restricted)', true
  from audit.coverage c
 where c.enrolled and c.captured_key is null
union all
select c.table_name, format('capture trigger records key (%s) but the primary key is (%s)', c.captured_key, c.primary_key), true
  from audit.coverage c
 where c.enrolled and c.captured_key <> c.primary_key
union all
select c.table_name, 'TRUNCATE is not blocked', true
  from audit.coverage c
 where c.enrolled and not c.blocks_truncate
union all
select p.table_name::regclass, format('ledger protection trigger %s is missing or not enabled always', p.trigger_name), true
  from (values ('audit.event',           'trg_a_chain'),
               ('audit.event',           'trg_b_advance_head'),
               ('audit.event',           'trg_append_only'),
               ('audit.event',           'trg_no_truncate'),
               ('audit.chain_head',      'trg_guard'),
               ('audit.chain_head',      'trg_no_truncate'),
               ('audit.pending_event',   'trg_seal_pending'),
               ('audit.pending_event',   'trg_guard'),
               ('audit.pending_event',   'trg_no_truncate'),
               ('audit.anchor',          'trg_append_only'),
               ('audit.anchor',          'trg_no_truncate'),
               ('audit.anchor',          'trg_emit'),
               ('audit.governed_schema', 'trg_append_only'),
               ('audit.governed_schema', 'trg_no_truncate'),
               ('audit.governed_schema', 'trg_enrol'),
               ('audit.exempt_table',    'trg_append_only'),
               ('audit.exempt_table',    'trg_no_truncate'),
               ('audit.exempt_table',    'trg_emit'),
               ('audit.enrolled_table',  'trg_append_only'),
               ('audit.enrolled_table',  'trg_no_truncate')) p(table_name, trigger_name)
 where not exists (select 1 from pg_trigger t
                    where t.tgrelid = p.table_name::regclass and t.tgname = p.trigger_name and t.tgenabled = 'A')
union all
select null::regclass, format('event trigger %s is missing or not enabled always', g.name), false
  from unnest(array['audit_ddl_guard', 'audit_drop_guard', 'audit_block_destructive_ddl']) g(name)
 where not exists (select 1 from pg_event_trigger e where e.evtname = g.name and e.evtenabled = 'A');
comment on view audit.coverage_gap is
    'Anything that would let a change escape the ledger. The DDL guard rejects any command that leaves an enforced gap; '
    'the rest should be empty in a correctly migrated database.';

create function audit.assert_coverage(p_include_unenforced boolean default false) returns void
    language plpgsql
as $$
declare
    v_gaps text;
begin
    select string_agg(format('%s: %s', coalesce(g.table_name::text, '(database)'), g.problem), '; '
                      order by g.table_name::text, g.problem)
      into v_gaps
      from audit.coverage_gap g
     where g.enforced or p_include_unenforced;
    if v_gaps is not null then
        raise exception 'audit ledger coverage check failed: %', v_gaps
            using hint = 'Ledger capture and protection triggers cannot be dropped, disabled or weakened. See audit.coverage_gap.';
    end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- DDL guards
-- -----------------------------------------------------------------------------
create function audit.guard_ddl() returns event_trigger
    language plpgsql
as $$
declare
    r record;
begin
    -- New tables in governed schemas are enrolled; enrolled tables that were
    -- altered have their captured key refreshed if the primary key changed.
    for r in
        select distinct k.oid::regclass as tbl
          from pg_event_trigger_ddl_commands() c
          join pg_class k on k.oid = c.objid
          left join audit.enrolled_table e on e.table_oid = k.oid
         where c.classid = 'pg_class'::regclass
           and k.relkind in ('r', 'p') and not k.relispartition
           and (e.table_oid is not null
                or (c.command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
                    and k.relnamespace::regnamespace::text in (select g.schema_name from audit.governed_schema g)))
    loop
        perform audit.enable_table(r.tbl);
    end loop;
    perform audit.assert_coverage();
end;
$$;

create function audit.guard_drop() returns event_trigger
    language plpgsql
as $$
declare
    r      record;
    v_objs text;
begin
    -- Must not query audit.* tables here until we know the ledger itself is
    -- still present: DROP SCHEMA audit CASCADE has already removed them when
    -- this trigger runs. The command-start guard should have rejected that.
    select string_agg(d.object_type || ' ' || d.object_identity, ', ') into v_objs
      from pg_event_trigger_dropped_objects() d
     where d.schema_name = 'audit'
        or (d.object_type = 'schema' and d.object_identity in ('audit', 'gov'));
    if v_objs is not null then
        raise exception 'audit ledger objects cannot be dropped: %', v_objs
            using hint = 'Change ledger functions with CREATE OR REPLACE in a new migration.';
    end if;

    for r in
        select d.object_identity
          from pg_event_trigger_dropped_objects() d
          join audit.enrolled_table e on e.table_oid = d.objid
         where d.object_type = 'table' and d.original
    loop
        perform audit.emit('audit.table_dropped', jsonb_build_object('table', r.object_identity));
    end loop;
    perform audit.assert_coverage();
end;
$$;

-- -----------------------------------------------------------------------------
-- Triggers on the ledger's own tables (all ENABLE ALWAYS)
-- -----------------------------------------------------------------------------
create function audit.enrol_schema() returns trigger
    language plpgsql
as $$
declare
    r record;
begin
    perform audit.emit('audit.schema_governed', jsonb_build_object('schema', new.schema_name));
    for r in
        select k.oid::regclass as tbl
          from pg_class k join pg_namespace n on n.oid = k.relnamespace
         where n.nspname = new.schema_name and k.relkind in ('r', 'p') and not k.relispartition
         order by k.relname
    loop
        perform audit.enable_table(r.tbl);
    end loop;
    return null;
end;
$$;

create function audit.emit_exemption() returns trigger
    language plpgsql
as $$
begin
    perform audit.emit('audit.table_exempted', jsonb_build_object('table', new.table_name, 'reason', new.reason));
    return null;
end;
$$;

create function audit.emit_anchor() returns trigger
    language plpgsql
as $$
begin
    perform audit.emit('audit.anchor_taken',
                       jsonb_build_object('anchor_id', new.id, 'seq', new.seq, 'event_hash', new.event_hash, 'note', new.note));
    return null;
end;
$$;

create trigger trg_a_chain before insert on audit.event
    for each row execute function audit.chain_event();
create trigger trg_b_advance_head after insert on audit.event
    for each row execute function audit.advance_head();
create trigger trg_append_only before update or delete on audit.event
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on audit.event
    for each statement execute function gov.forbid_mutation();

create trigger trg_guard before insert or update or delete on audit.chain_head
    for each row execute function audit.guard_chain_head();
create trigger trg_no_truncate before truncate on audit.chain_head
    for each statement execute function gov.forbid_mutation();

create constraint trigger trg_seal_pending after insert on audit.pending_event
    deferrable initially deferred
    for each row execute function audit.seal_pending();
create trigger trg_guard before update or delete on audit.pending_event
    for each row execute function audit.guard_pending();
create trigger trg_no_truncate before truncate on audit.pending_event
    for each statement execute function gov.forbid_mutation();

create trigger trg_append_only before update or delete on audit.anchor
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on audit.anchor
    for each statement execute function gov.forbid_mutation();
create trigger trg_emit after insert on audit.anchor
    for each row execute function audit.emit_anchor();

create trigger trg_append_only before update or delete on audit.governed_schema
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on audit.governed_schema
    for each statement execute function gov.forbid_mutation();
create trigger trg_enrol after insert on audit.governed_schema
    for each row execute function audit.enrol_schema();

create trigger trg_append_only before update or delete on audit.exempt_table
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on audit.exempt_table
    for each statement execute function gov.forbid_mutation();
create trigger trg_emit after insert on audit.exempt_table
    for each row execute function audit.emit_exemption();

create trigger trg_append_only before update or delete on audit.enrolled_table
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on audit.enrolled_table
    for each statement execute function gov.forbid_mutation();

alter table audit.event           enable always trigger trg_a_chain, enable always trigger trg_b_advance_head,
                                  enable always trigger trg_append_only, enable always trigger trg_no_truncate;
alter table audit.chain_head      enable always trigger trg_guard, enable always trigger trg_no_truncate;
alter table audit.pending_event   enable always trigger trg_seal_pending, enable always trigger trg_guard,
                                  enable always trigger trg_no_truncate;
alter table audit.anchor          enable always trigger trg_append_only, enable always trigger trg_no_truncate,
                                  enable always trigger trg_emit;
alter table audit.governed_schema enable always trigger trg_append_only, enable always trigger trg_no_truncate,
                                  enable always trigger trg_enrol;
alter table audit.exempt_table    enable always trigger trg_append_only, enable always trigger trg_no_truncate,
                                  enable always trigger trg_emit;
alter table audit.enrolled_table  enable always trigger trg_append_only, enable always trigger trg_no_truncate;

-- -----------------------------------------------------------------------------
-- Reading and verifying the ledger
-- -----------------------------------------------------------------------------
create function audit.row_history(p_table regclass, p_row_id uuid) returns setof audit.event
    language sql stable
as $$
    select e.*
      from audit.event e
      join pg_class k on k.oid = p_table
      join pg_namespace n on n.oid = k.relnamespace
     where e.schema_name = n.nspname and e.table_name = k.relname and e.row_id = p_row_id
     order by e.seq
$$;
comment on function audit.row_history(regclass, uuid) is 'Every sealed event for one row, oldest first.';

create function audit.events_for(p_correlation_id uuid) returns setof audit.event
    language sql stable
as $$
    select e.* from audit.event e where e.correlation_id = p_correlation_id order by e.seq
$$;
comment on function audit.events_for(uuid) is 'Every sealed event for one correlation id (workflow instance), oldest first.';

-- Returns one row per problem found; no rows means the range is intact.
create function audit.verify_chain(p_from_seq bigint default 1, p_to_seq bigint default null)
    returns table (event_seq bigint, problem text)
    language plpgsql stable
as $$
declare
    v_expected bigint := greatest(coalesce(p_from_seq, 1), 1);
    v_prev     text;
    v_last     audit.event;
    v_head     audit.chain_head;
    e          audit.event;
    a          audit.anchor;
begin
    if v_expected = 1 then
        v_prev := repeat('0', 64);
    else
        select ev.event_hash into v_prev from audit.event ev where ev.seq = v_expected - 1;
        if v_prev is null then
            event_seq := v_expected - 1; problem := 'event preceding the verified range is missing'; return next;
        end if;
    end if;

    for e in
        select * from audit.event ev
         where ev.seq >= v_expected and (p_to_seq is null or ev.seq <= p_to_seq)
         order by ev.seq
    loop
        if e.seq <> v_expected then
            event_seq := v_expected;
            problem := format('events %s to %s are missing', v_expected, e.seq - 1);
            return next;
            v_prev := null;
        end if;
        if v_prev is not null and e.prev_hash <> v_prev then
            event_seq := e.seq; problem := 'prev_hash does not match the preceding event'; return next;
        end if;
        if e.event_hash <> audit.hash_event(e) then
            event_seq := e.seq; problem := 'event_hash does not match the event content'; return next;
        end if;
        v_prev     := e.event_hash;
        v_expected := e.seq + 1;
        v_last     := e;
    end loop;

    if p_to_seq is null then
        select * into v_head from audit.chain_head;
        select * into v_last from audit.event ev order by ev.seq desc limit 1;
        if v_head.last_seq <> coalesce(v_last.seq, 0) or v_head.last_hash <> coalesce(v_last.event_hash, repeat('0', 64)) then
            event_seq := v_head.last_seq; problem := 'chain head does not match the last event'; return next;
        end if;
    end if;

    for a in
        select * from audit.anchor an
         where an.seq >= coalesce(p_from_seq, 1) and (p_to_seq is null or an.seq <= p_to_seq)
         order by an.seq
    loop
        if not exists (select 1 from audit.event ev where ev.seq = a.seq and ev.event_hash = a.event_hash) then
            event_seq := a.seq; problem := format('anchor %s no longer matches the chain', a.id); return next;
        end if;
    end loop;

    if exists (select 1 from audit.pending_event p where p.xact_id is distinct from pg_current_xact_id_if_assigned()) then
        event_seq := null; problem := 'pending events from other transactions were never sealed'; return next;
    end if;
end;
$$;
comment on function audit.verify_chain(bigint, bigint) is
    'Recompute hashes and links over a seq range (default: all), check the chain head and anchors. No rows = intact.';

create function audit.take_anchor(p_note text default null) returns audit.anchor
    language plpgsql security definer set search_path = pg_catalog, pg_temp
as $$
declare
    v audit.anchor;
begin
    if (select h.last_seq from audit.chain_head h) = 0 then
        raise exception 'audit.take_anchor: the ledger has no sealed events yet';
    end if;
    insert into audit.anchor (seq, event_hash, note)
    select h.last_seq, h.last_hash, p_note from audit.chain_head h
    returning * into v;
    return v;
end;
$$;
comment on function audit.take_anchor(text) is 'Checkpoint the chain head. Copy the result outside the database.';

create function audit.verify_anchor(p_seq bigint, p_event_hash text) returns boolean
    language sql stable
as $$ select exists (select 1 from audit.event e where e.seq = p_seq and e.event_hash = p_event_hash) $$;
comment on function audit.verify_anchor(bigint, text) is
    'Check an anchor copy held outside the database. True, together with an intact verify_chain(1, p_seq), '
    'proves that no event up to p_seq has changed since the anchor was taken.';

-- -----------------------------------------------------------------------------
-- Genesis: register scope, enrol existing tables, record the baseline
-- -----------------------------------------------------------------------------
select audit.emit('audit.ledger_initialised',
                  jsonb_build_object('format', 'fcrm-audit-v1', 'hash', 'sha256', 'genesis_prev_hash', repeat('0', 64)));

insert into audit.exempt_table (table_oid, table_name, reason) values
    ('gov.tmpl_identity'::regclass,    'gov.tmpl_identity',    'Column template for identity tables; never holds data.'),
    ('gov.tmpl_versioned'::regclass,   'gov.tmpl_versioned',   'Column template for versioned tables; never holds data.'),
    ('gov.tmpl_append_only'::regclass, 'gov.tmpl_append_only', 'Column template for append-only tables; never holds data.');

insert into audit.governed_schema (schema_name) values ('gov'), ('ref'), ('core');

do $$
declare
    r record;
begin
    for r in
        select c.table_name, c.schema_name, k.relname::text as rel, c.primary_key
          from audit.coverage c
          join pg_class k on k.oid = c.table_name
         where c.enrolled
         order by c.table_name::text
    loop
        execute format(
            'insert into audit.pending_event (event_kind, event_type, schema_name, table_name, row_id, row_key, row_after, reason, actor_id) '
            'select ''row_baseline'', %L, %L, %L, audit.row_id_of(s.j), audit.row_key_of(s.j, %L), s.j, %L, ''system:migration'' '
            '  from (select to_jsonb(t) as j from %s t) s order by s.j::text',
            format('%s.%s.baseline', lower(r.schema_name), lower(r.rel)), r.schema_name, r.rel, r.primary_key,
            'Ledger genesis: record existed before the audit ledger was created', r.table_name);
    end loop;
end;
$$;

-- sql_drop fires after the objects are gone. DROP SCHEMA audit CASCADE would
-- also drop this function and the event trigger, so the drop would succeed.
-- ddl_command_start runs first, while the ledger is still intact.
create function audit.block_destructive_ddl() returns event_trigger
    language plpgsql
as $$
declare
    q text := lower(current_query());
begin
    if tg_tag = 'DROP SCHEMA' and q ~ 'drop\s+schema\s+(if\s+exists\s+)?["'']?(audit|gov)["'']?\y' then
        raise exception 'audit ledger objects cannot be dropped: schema %',
            (regexp_match(q, 'drop\s+schema\s+(if\s+exists\s+)?["'']?(audit|gov)["'']?\y'))[2]
            using hint = 'The audit ledger and governance foundation must remain in place.';
    end if;
end;
$$;

create event trigger audit_ddl_guard on ddl_command_end
    when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE', 'CREATE TRIGGER', 'ALTER TRIGGER')
    execute function audit.guard_ddl();
create event trigger audit_drop_guard on sql_drop
    when tag in ('DROP TABLE', 'DROP TRIGGER', 'DROP SCHEMA', 'DROP FUNCTION', 'DROP OWNED', 'DROP VIEW', 'DROP TYPE')
    execute function audit.guard_drop();
create event trigger audit_block_destructive_ddl on ddl_command_start
    when tag in ('DROP SCHEMA')
    execute function audit.block_destructive_ddl();
alter event trigger audit_ddl_guard  enable always;
alter event trigger audit_drop_guard enable always;
alter event trigger audit_block_destructive_ddl enable always;

select audit.assert_coverage(true);

-- -----------------------------------------------------------------------------
-- Privileges. Capture, sealing and record_event run as the ledger owner, so
-- application roles need no privileges on the ledger tables. Read access
-- (analysts, examiners) is granted by the identity and roles module (step 3).
-- -----------------------------------------------------------------------------
revoke all on all tables in schema audit from public;
revoke execute on function audit.enqueue(audit.event_kind, text, text, text, uuid, jsonb, jsonb, jsonb, text[], jsonb, text, uuid, text),
                           audit.emit(text, jsonb),
                           audit.register_enrolment(regclass, text),
                           audit.take_anchor(text)
    from public;
grant usage on schema audit to public;

select set_config('fcrm.actor_id', '', false);
