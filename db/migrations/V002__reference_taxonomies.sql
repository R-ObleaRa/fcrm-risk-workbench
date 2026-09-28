-- =============================================================================
-- V002  Controlled reference taxonomies
--
--   ref.taxonomy          identity of a code list (e.g. RISK_TYPOLOGY)
--   ref.taxonomy_version  published, effective-dated version of that list
--   ref.taxonomy_term     terms within one version (optionally hierarchical)
--
-- Business records reference a specific term row, which pins the exact taxonomy
-- version that was in force. term_code is stable across versions, and
-- supersedes_term_id maps a term to its predecessor, so data can be traced and
-- re-mapped when a taxonomy is revised.
--
-- Values that application logic depends on (workflow states, vote choices,
-- decision outcomes) are enums. Classifications that the risk function tunes
-- are taxonomies.
-- =============================================================================

create schema if not exists ref;
comment on schema ref is 'Controlled, versioned reference taxonomies.';

-- -----------------------------------------------------------------------------
-- Published frameworks the risk decomposition is grounded in
-- -----------------------------------------------------------------------------
create type ref.framework_kind as enum (
    'international_standard',
    'supervisory_guideline',
    'industry_guidance'
);

create table ref.framework (
    code           text primary key check (code ~ '^[A-Z][A-Z0-9_]*$'),
    title          text not null,
    issuer         text not null,
    framework_kind ref.framework_kind not null,
    edition        text not null,
    published_on   date not null,
    publication_url text not null check (publication_url ~ '^https://'),
    like gov.tmpl_identity including all
);
comment on table  ref.framework is
    'A published standard, supervisory guideline or industry guidance cited as the basis of a taxonomy. '
    'Insert-only; a new edition is a new row.';
comment on column ref.framework.publication_url is 'Public location of the published text (citation only; nothing connects to it).';

create trigger trg_append_only before update or delete on ref.framework
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on ref.framework
    for each statement execute function gov.forbid_mutation();

create table ref.framework_provision (
    id             uuid primary key default gen_random_uuid(),
    framework_code text not null references ref.framework (code),
    provision_ref  text not null,
    heading        text not null,
    summary        text not null,
    like gov.tmpl_identity including all,
    unique (framework_code, provision_ref)
);
comment on table  ref.framework_provision is 'A citable provision (recommendation, guideline section, paragraph) of a framework. Insert-only.';
comment on column ref.framework_provision.provision_ref is 'Reference as used by the issuer, e.g. "R.15", "Guideline 2: Customer risk factors", "6.3".';
comment on column ref.framework_provision.summary       is 'Short paraphrase of what the provision says, sufficient to justify the terms grounded in it.';

create trigger trg_append_only before update or delete on ref.framework_provision
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on ref.framework_provision
    for each statement execute function gov.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Taxonomies
-- -----------------------------------------------------------------------------
create table ref.taxonomy (
    code                     text primary key check (code ~ '^[A-Z][A-Z0-9_]*$'),
    name                     text    not null,
    description              text    not null,
    is_hierarchical          boolean not null default false,
    requires_framework_basis boolean not null default false,
    like gov.tmpl_identity including all
);
comment on table  ref.taxonomy is 'Identity of a controlled code list. Insert-only.';
comment on column ref.taxonomy.requires_framework_basis is
    'When true, a version can only be activated if every term cites at least one framework provision.';

create trigger trg_append_only before update or delete on ref.taxonomy
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on ref.taxonomy
    for each statement execute function gov.forbid_mutation();

create table ref.taxonomy_version (
    id              uuid primary key default gen_random_uuid(),
    taxonomy_code   text not null references ref.taxonomy (code),
    effective_from  date not null default current_date,
    effective_to    date,
    like gov.tmpl_versioned including all,
    unique (taxonomy_code, version_no),
    foreign key (supersedes_id) references ref.taxonomy_version (id),
    check (effective_to is null or effective_to > effective_from)
);
comment on table ref.taxonomy_version is
    'Published version of a taxonomy. Terms are editable only while the version is draft.';

create unique index ux_taxonomy_version_one_active
    on ref.taxonomy_version (taxonomy_code) where record_status = 'active';

create trigger trg_a_assign_version before insert on ref.taxonomy_version
    for each row execute function gov.assign_version('taxonomy_code');
create trigger trg_b_guard_version before insert or update or delete on ref.taxonomy_version
    for each row execute function gov.guard_versioned_row();

create table ref.taxonomy_term (
    id                  uuid primary key default gen_random_uuid(),
    taxonomy_version_id uuid    not null references ref.taxonomy_version (id),
    term_code           text    not null check (term_code ~ '^[A-Z0-9][A-Z0-9_\-]*$'),
    label               text    not null,
    description         text,
    parent_term_id      uuid,
    sort_order          integer not null default 0,
    external_scheme     text,
    external_code       text,
    attributes          jsonb   not null default '{}' check (jsonb_typeof(attributes) = 'object'),
    supersedes_term_id  uuid references ref.taxonomy_term (id),
    like gov.tmpl_identity including all,
    unique (taxonomy_version_id, term_code),
    unique (taxonomy_version_id, id),
    foreign key (taxonomy_version_id, parent_term_id) references ref.taxonomy_term (taxonomy_version_id, id),
    check (parent_term_id is distinct from id),
    check ((external_scheme is null) = (external_code is null))
);
comment on table  ref.taxonomy_term is 'A term within one taxonomy version.';
comment on column ref.taxonomy_term.term_code          is 'Stable business key, unchanged across taxonomy versions.';
comment on column ref.taxonomy_term.external_scheme    is 'External standard the term maps to, e.g. ISO3166-1-A2.';
comment on column ref.taxonomy_term.supersedes_term_id is 'Equivalent term in the previous taxonomy version (cross-version lineage).';

create index ix_taxonomy_term_parent on ref.taxonomy_term (parent_term_id);

create trigger trg_guard_child before insert or update or delete on ref.taxonomy_term
    for each row execute function gov.guard_child_of_draft('ref.taxonomy_version', 'taxonomy_version_id');

-- -----------------------------------------------------------------------------
-- Grounding: which framework provisions each term is taken from
-- -----------------------------------------------------------------------------
create type ref.basis_relationship as enum ('defined_by', 'derived_from', 'aligned_with');
comment on type ref.basis_relationship is
    'defined_by = the term is named/defined in the provision; derived_from = the term decomposes what the '
    'provision describes; aligned_with = the term is an internal classification consistent with the provision.';

create table ref.taxonomy_term_basis (
    taxonomy_version_id    uuid not null,
    taxonomy_term_id       uuid not null,
    framework_provision_id uuid not null references ref.framework_provision (id),
    relationship           ref.basis_relationship not null,
    note                   text,
    like gov.tmpl_identity including all,
    primary key (taxonomy_term_id, framework_provision_id),
    foreign key (taxonomy_version_id, taxonomy_term_id) references ref.taxonomy_term (taxonomy_version_id, id)
);
comment on table ref.taxonomy_term_basis is 'Citation of the published provision(s) a taxonomy term is grounded in.';

create trigger trg_guard_child before insert or update or delete on ref.taxonomy_term_basis
    for each row execute function gov.guard_child_of_draft('ref.taxonomy_version', 'taxonomy_version_id');

create function ref.check_taxonomy_grounding() returns trigger
    language plpgsql
as $$
declare
    v_required boolean;
    v_missing  text;
begin
    if new.record_status <> 'active' or (tg_op = 'UPDATE' and old.record_status = 'active') then
        return new;
    end if;

    select requires_framework_basis into v_required from ref.taxonomy where code = new.taxonomy_code;
    if not v_required then
        return new;
    end if;

    if tg_op = 'INSERT' then
        raise exception 'ref.taxonomy_version: % requires framework grounding; create the version as draft, add grounded terms, then activate',
            new.taxonomy_code;
    end if;

    select string_agg(t.term_code, ', ' order by t.sort_order) into v_missing
      from ref.taxonomy_term t
     where t.taxonomy_version_id = new.id
       and not exists (select 1 from ref.taxonomy_term_basis b where b.taxonomy_term_id = t.id);

    if v_missing is not null then
        raise exception 'ref.taxonomy_version: cannot activate % version %: terms without a framework basis: %',
            new.taxonomy_code, new.version_no, v_missing;
    end if;
    if not exists (select 1 from ref.taxonomy_term t where t.taxonomy_version_id = new.id) then
        raise exception 'ref.taxonomy_version: cannot activate % version % with no terms', new.taxonomy_code, new.version_no;
    end if;
    return new;
end;
$$;

create trigger trg_c_grounding before insert or update on ref.taxonomy_version
    for each row execute function ref.check_taxonomy_grounding();

-- -----------------------------------------------------------------------------
-- Term reference validation for business tables.
--   TG_ARGV = pairs of (column_name, allowed taxonomy codes separated by '|')
-- On INSERT, and on UPDATE when the column changes, the referenced term must
-- belong to one of the allowed taxonomies and to its ACTIVE version.
-- -----------------------------------------------------------------------------
create function ref.check_term_refs() returns trigger
    language plpgsql
as $$
declare
    i           integer := 0;
    v_col       text;
    v_allowed   text[];
    v_term_id   text;
    v_taxonomy  text;
    v_status    gov.record_status;
begin
    while i < tg_nargs loop
        v_col     := tg_argv[i];
        v_allowed := string_to_array(tg_argv[i + 1], '|');
        i := i + 2;

        v_term_id := to_jsonb(new) ->> v_col;
        continue when v_term_id is null;
        continue when tg_op = 'UPDATE' and v_term_id is not distinct from (to_jsonb(old) ->> v_col);

        select tv.taxonomy_code, tv.record_status
          into v_taxonomy, v_status
          from ref.taxonomy_term t
          join ref.taxonomy_version tv on tv.id = t.taxonomy_version_id
         where t.id = v_term_id::uuid;

        if v_taxonomy is null then
            raise exception '%.%: % references unknown term %', tg_table_schema, tg_table_name, v_col, v_term_id;
        elsif not (v_taxonomy = any (v_allowed)) then
            raise exception '%.%: % must be a term of %, but % belongs to %',
                tg_table_schema, tg_table_name, v_col, array_to_string(v_allowed, ' or '), v_term_id, v_taxonomy;
        elsif v_status <> 'active' then
            raise exception '%.%: % references term % from a % version of %',
                tg_table_schema, tg_table_name, v_col, v_term_id, v_status, v_taxonomy
                using hint = 'Use a term from the active taxonomy version.';
        end if;
    end loop;
    return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Convenience lookups
-- -----------------------------------------------------------------------------
create view ref.active_term as
select tv.taxonomy_code,
       tv.id            as taxonomy_version_id,
       tv.version_no    as taxonomy_version_no,
       t.id             as term_id,
       t.term_code,
       t.label,
       t.description,
       p.term_code      as parent_term_code,
       t.sort_order,
       t.external_scheme,
       t.external_code,
       t.attributes
  from ref.taxonomy_term t
  join ref.taxonomy_version tv on tv.id = t.taxonomy_version_id
  left join ref.taxonomy_term p on p.id = t.parent_term_id
 where tv.record_status = 'active'
   and tv.effective_from <= current_date
   and (tv.effective_to is null or tv.effective_to > current_date);
comment on view ref.active_term is 'Terms of every taxonomy version currently active and in effect.';

create function ref.term_id(p_taxonomy_code text, p_term_code text) returns uuid
    language sql stable
as $$
    select t.id
      from ref.taxonomy_term t
      join ref.taxonomy_version tv on tv.id = t.taxonomy_version_id
     where tv.taxonomy_code = p_taxonomy_code
       and tv.record_status = 'active'
       and t.term_code = p_term_code
$$;
comment on function ref.term_id(text, text) is 'Id of a term in the active version of a taxonomy, or null.';

create view ref.active_term_grounding as
select a.taxonomy_code,
       a.term_code,
       a.label,
       b.relationship,
       f.code           as framework_code,
       f.framework_kind,
       f.title          as framework_title,
       f.edition,
       p.provision_ref,
       p.heading        as provision_heading,
       p.summary        as provision_summary,
       b.note,
       f.publication_url
  from ref.active_term a
  join ref.taxonomy_term_basis b on b.taxonomy_term_id = a.term_id
  join ref.framework_provision p on p.id = b.framework_provision_id
  join ref.framework f on f.code = p.framework_code;
comment on view ref.active_term_grounding is 'Each active term with the published provisions it is grounded in.';
