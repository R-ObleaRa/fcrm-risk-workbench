-- =============================================================================
-- V001  Governance foundation
--
-- Shared building blocks used by every governed table:
--   * lifecycle / origin / classification enums
--   * column templates for the three record kinds (identity, versioned, append-only)
--   * trigger functions that enforce immutability, versioning and lineage
--   * a generic lineage edge table for derivations that have no typed FK
--
-- Record kinds
--   IDENTITY     Stable logical identity of a business object (e.g. a change
--                request). Insert-only; never updated or deleted.
--   VERSIONED    Content of an identity at a point in time. Editable only while
--                DRAFT. Once ACTIVE the content is frozen; the only permitted
--                changes are ACTIVE -> SUPERSEDED / RETIRED.
--   APPEND-ONLY  Facts that are true once recorded (ratings, votes, reviews,
--                extracted fields). Never updated or deleted.
-- =============================================================================

create schema if not exists gov;
comment on schema gov is 'Governance infrastructure: lifecycle enums, column templates, immutability and lineage.';

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
create type gov.record_status as enum ('draft', 'active', 'superseded', 'retired');
comment on type gov.record_status is
    'Lifecycle of a versioned row. draft = editable; active = frozen and in force; '
    'superseded = replaced by a later version; retired = withdrawn with no replacement.';

create type gov.record_origin as enum (
    'user_entry',
    'system_derived',
    'document_extraction',
    'ai_suggestion_accepted',
    'synthetic_generation',
    'reference_data_seed'
);
comment on type gov.record_origin is
    'How a row came into existence; the first hop of its lineage. There is deliberately no origin for '
    'imports from operational systems: the workbench holds synthetic data only.';

create type gov.data_classification as enum ('internal', 'confidential', 'restricted');

-- -----------------------------------------------------------------------------
-- Synthetic-data-only guard rails
--
-- The workbench must never hold real customer, employee or system data, and
-- must not be wired to real systems. The database enforces this where it can:
--   * gov.principal_id only accepts service/role accounts or users on reserved
--     documentation domains (RFC 2606 / RFC 6761: .example, .test, .invalid)
--   * source_system only accepts the workbench itself or a synthetic generator
--   * document storage URIs must use the synthetic:// scheme
-- Public reference material (country codes, published supervisory frameworks)
-- is not customer or system data and is allowed.
-- -----------------------------------------------------------------------------
create domain gov.principal_id as text
    constraint ck_synthetic_principal check (
        value ~ '^(system|role|svc):[a-z0-9][a-z0-9._-]*$'
        or value ~ '^user:[a-z0-9][a-z0-9._-]*@([a-z0-9-]+\.)*(example|test|invalid)$'
    );
comment on domain gov.principal_id is
    'Synthetic principal: system:/role:/svc: accounts, or user:<name>@<host>.example|.test|.invalid.';

-- -----------------------------------------------------------------------------
-- Acting principal
--
-- The application sets fcrm.actor_id per transaction (SET LOCAL fcrm.actor_id = '...').
-- Audit columns default to it, so an unidentified write fails the NOT NULL check.
-- -----------------------------------------------------------------------------
create function gov.current_actor() returns text
    language sql stable
as $$ select nullif(current_setting('fcrm.actor_id', true), '') $$;

-- -----------------------------------------------------------------------------
-- Column templates (used via CREATE TABLE ... (LIKE gov.tmpl_x INCLUDING ALL))
-- These tables never hold data.
-- -----------------------------------------------------------------------------
create table gov.tmpl_identity (
    created_at  timestamptz      not null default now(),
    created_by  gov.principal_id not null default gov.current_actor()
);

create table gov.tmpl_versioned (
    version_no          integer                 not null check (version_no > 0),
    record_status       gov.record_status       not null default 'draft',
    status_changed_at   timestamptz,
    status_changed_by   gov.principal_id,
    owner_id            gov.principal_id        not null default gov.current_actor(),
    data_classification gov.data_classification not null default 'confidential',
    origin              gov.record_origin       not null default 'user_entry',
    source_system       text                    not null default 'fcrm-workbench',
    source_ref          text,
    supersedes_id       uuid,
    correlation_id      uuid,
    change_reason       text,
    created_at          timestamptz             not null default now(),
    created_by          gov.principal_id        not null default gov.current_actor(),
    updated_at          timestamptz,
    updated_by          gov.principal_id,
    constraint ck_status_change_recorded
        check (record_status = 'draft' or (status_changed_at is not null and status_changed_by is not null)),
    constraint ck_synthetic_source_system
        check (source_system ~ '^(fcrm-workbench|synthetic-[a-z0-9-]+)$')
);

create table gov.tmpl_append_only (
    seq                 bigint                  generated always as identity,
    data_classification gov.data_classification not null default 'confidential',
    origin              gov.record_origin       not null default 'user_entry',
    source_system       text                    not null default 'fcrm-workbench',
    source_ref          text,
    correlation_id      uuid,
    created_at          timestamptz             not null default now(),
    created_by          gov.principal_id        not null default gov.current_actor(),
    constraint ck_synthetic_source_system
        check (source_system ~ '^(fcrm-workbench|synthetic-[a-z0-9-]+)$')
);

comment on column gov.tmpl_versioned.version_no      is 'Sequential per logical entity, assigned on insert.';
comment on column gov.tmpl_versioned.owner_id        is 'Accountable owner (data steward) of this version.';
comment on column gov.tmpl_versioned.supersedes_id   is 'Previous version of the same entity; assigned on insert.';
comment on column gov.tmpl_versioned.correlation_id  is 'Links the row to the workflow instance / audit events that produced it.';
comment on column gov.tmpl_versioned.source_ref      is 'Identifier of the record in the originating (synthetic) generator, if not created in the workbench.';
comment on column gov.tmpl_append_only.seq           is 'Insertion order. created_at is the transaction time and is shared by rows written together.';

revoke all on gov.tmpl_identity, gov.tmpl_versioned, gov.tmpl_append_only from public;

-- -----------------------------------------------------------------------------
-- Append-only enforcement
-- -----------------------------------------------------------------------------
create function gov.forbid_mutation() returns trigger
    language plpgsql
as $$
begin
    raise exception '% on %.% is not permitted: table is append-only',
        tg_op, tg_table_schema, tg_table_name
        using errcode = 'P0001', hint = 'Record a new fact instead of changing an existing one.';
end;
$$;

-- Usage:
--   create trigger trg_append_only before update or delete on x
--       for each row execute function gov.forbid_mutation();
--   create trigger trg_no_truncate before truncate on x
--       for each statement execute function gov.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Version assignment (BEFORE INSERT)
--   TG_ARGV[0] = column holding the logical entity id
-- Assigns version_no = max + 1 and supersedes_id = previous latest version.
-- An advisory lock per entity serialises concurrent version creation.
-- -----------------------------------------------------------------------------
create function gov.assign_version() returns trigger
    language plpgsql
as $$
declare
    v_entity_col text := tg_argv[0];
    v_entity_id  text;
    v_prev_id    uuid;
    v_prev_no    integer;
begin
    v_entity_id := to_jsonb(new) ->> v_entity_col;
    if v_entity_id is null then
        raise exception '%.%: % must not be null', tg_table_schema, tg_table_name, v_entity_col;
    end if;

    perform pg_advisory_xact_lock(hashtextextended(tg_table_schema || '.' || tg_table_name || ':' || v_entity_id, 0));

    execute format(
        'select id, version_no from %I.%I where %I::text = $1 order by version_no desc limit 1',
        tg_table_schema, tg_table_name, v_entity_col)
        into v_prev_id, v_prev_no
        using v_entity_id;

    if new.version_no is null then
        new.version_no := coalesce(v_prev_no, 0) + 1;
    elsif new.version_no <> coalesce(v_prev_no, 0) + 1 then
        raise exception '%.%: version_no % is not the next version (expected %)',
            tg_table_schema, tg_table_name, new.version_no, coalesce(v_prev_no, 0) + 1;
    end if;

    if new.supersedes_id is null then
        new.supersedes_id := v_prev_id;
    elsif new.supersedes_id is distinct from v_prev_id then
        raise exception '%.%: supersedes_id must reference the latest version of the entity',
            tg_table_schema, tg_table_name;
    end if;

    return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Versioned-row guard (BEFORE INSERT OR UPDATE OR DELETE)
-- -----------------------------------------------------------------------------
create function gov.guard_versioned_row() returns trigger
    language plpgsql
as $$
declare
    c_mutable_when_frozen constant text[] := array['record_status', 'status_changed_at', 'status_changed_by', 'updated_at', 'updated_by'];
    c_immutable_always    constant text[] := array['id', 'version_no', 'supersedes_id', 'created_at', 'created_by', 'origin', 'source_system'];
    v_col text;
begin
    if tg_op = 'INSERT' then
        if new.record_status not in ('draft', 'active') then
            raise exception '%.%: new versions must start as draft or active, not %',
                tg_table_schema, tg_table_name, new.record_status;
        end if;
        if new.record_status = 'active' then
            new.status_changed_at := coalesce(new.status_changed_at, now());
            new.status_changed_by := coalesce(new.status_changed_by, gov.current_actor(), new.created_by);
        end if;
        return new;
    end if;

    if tg_op = 'DELETE' then
        if old.record_status <> 'draft' then
            raise exception '%.%: % version % cannot be deleted',
                tg_table_schema, tg_table_name, old.record_status, old.id
                using hint = 'Retire or supersede it instead.';
        end if;
        return old;
    end if;

    -- UPDATE
    foreach v_col in array c_immutable_always loop
        if (to_jsonb(new) -> v_col) is distinct from (to_jsonb(old) -> v_col) then
            raise exception '%.%: column % cannot be changed', tg_table_schema, tg_table_name, v_col;
        end if;
    end loop;

    if old.record_status = 'draft' then
        if new.record_status not in ('draft', 'active', 'retired') then
            raise exception '%.%: invalid transition draft -> %', tg_table_schema, tg_table_name, new.record_status;
        end if;
    else
        if not (old.record_status = 'active' and new.record_status in ('superseded', 'retired')) then
            raise exception '%.%: version % is % and its content is frozen (attempted % -> %)',
                tg_table_schema, tg_table_name, old.id, old.record_status, old.record_status, new.record_status
                using hint = 'Create a new version instead.';
        end if;
        if (to_jsonb(new) - c_mutable_when_frozen) <> (to_jsonb(old) - c_mutable_when_frozen) then
            raise exception '%.%: version % is % and its content is frozen',
                tg_table_schema, tg_table_name, old.id, old.record_status
                using hint = 'Only the lifecycle status may change. Create a new version instead.';
        end if;
    end if;

    new.updated_at := now();
    new.updated_by := coalesce(gov.current_actor(), new.updated_by);
    if new.updated_by is null then
        raise exception '%.%: updates require an identified actor (set fcrm.actor_id)', tg_table_schema, tg_table_name;
    end if;

    if new.record_status is distinct from old.record_status then
        new.status_changed_at := now();
        new.status_changed_by := new.updated_by;
    end if;

    return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Children of a versioned row may only be written while that row is DRAFT.
--   TG_ARGV[0] = parent table (schema-qualified), TG_ARGV[1] = FK column in child
-- -----------------------------------------------------------------------------
create function gov.guard_child_of_draft() returns trigger
    language plpgsql
as $$
declare
    v_parent_table text := tg_argv[0];
    v_fk_col       text := tg_argv[1];
    v_parent_id    text;
    v_status       gov.record_status;
    v_rec          jsonb;
begin
    foreach v_rec in array
        case tg_op
            when 'INSERT' then array[to_jsonb(new)]
            when 'DELETE' then array[to_jsonb(old)]
            else array[to_jsonb(old), to_jsonb(new)]
        end
    loop
        v_parent_id := v_rec ->> v_fk_col;
        execute format('select record_status from %s where id::text = $1', v_parent_table)
            into v_status using v_parent_id;
        if v_status is distinct from 'draft' then
            raise exception '%.%: cannot % rows of % % because it is %',
                tg_table_schema, tg_table_name, lower(tg_op), v_parent_table, v_parent_id, coalesce(v_status::text, 'missing')
                using hint = 'Create a new draft version of the parent instead.';
        end if;
    end loop;

    return case tg_op when 'DELETE' then old else new end;
end;
$$;

-- -----------------------------------------------------------------------------
-- A governed record may only point at a frozen (ACTIVE) version, so that what it
-- references can never change underneath it.
--   TG_ARGV[0] = referenced table, TG_ARGV[1] = FK column, TG_ARGV[2] = optional
--   comma-separated list of allowed statuses (default 'active')
-- Checked on INSERT, and on UPDATE when the FK column changes.
-- -----------------------------------------------------------------------------
create function gov.require_frozen_reference() returns trigger
    language plpgsql
as $$
declare
    v_ref_table text   := tg_argv[0];
    v_fk_col    text   := tg_argv[1];
    v_allowed   text[] := string_to_array(coalesce(nullif(tg_argv[2], ''), 'active'), ',');
    v_ref_id    text;
    v_status    gov.record_status;
begin
    v_ref_id := to_jsonb(new) ->> v_fk_col;
    if v_ref_id is null then
        return new;
    end if;
    if tg_op = 'UPDATE' and v_ref_id is not distinct from (to_jsonb(old) ->> v_fk_col) then
        return new;
    end if;

    execute format('select record_status from %s where id::text = $1', v_ref_table)
        into v_status using v_ref_id;
    if v_status is null or not (v_status::text = any (v_allowed)) then
        raise exception '%.%: % must reference a % version of %, but % is %',
            tg_table_schema, tg_table_name, v_fk_col, array_to_string(v_allowed, '/'), v_ref_table,
            v_ref_id, coalesce(v_status::text, 'missing');
    end if;
    return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Generic lineage graph for derivations that have no typed foreign key
-- (e.g. a risk-factor answer derived from an extracted document field).
-- -----------------------------------------------------------------------------
create type gov.lineage_relation as enum (
    'derived_from',
    'extracted_from',
    'evidenced_by',
    'cites',
    'generated_by',
    'copied_from'
);

create table gov.lineage_edge (
    id          uuid primary key default gen_random_uuid(),
    from_table  regclass             not null,
    from_id     uuid                 not null,
    relation    gov.lineage_relation not null,
    to_table    regclass             not null,
    to_id       uuid                 not null,
    attributes  jsonb                not null default '{}',
    like gov.tmpl_append_only including all,
    unique (from_table, from_id, relation, to_table, to_id)
);
comment on table gov.lineage_edge is
    'Directed lineage graph: from_table/from_id <relation> to_table/to_id. Append-only.';

create index ix_lineage_edge_from on gov.lineage_edge (from_table, from_id);
create index ix_lineage_edge_to   on gov.lineage_edge (to_table, to_id);

create trigger trg_append_only before update or delete on gov.lineage_edge
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on gov.lineage_edge
    for each statement execute function gov.forbid_mutation();
