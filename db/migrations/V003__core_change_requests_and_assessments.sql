-- =============================================================================
-- V003  Core domain: change requests, assessments, risk factors, controls
--
-- Each business object is split into an insert-only identity table and a
-- versioned content table. Cross-object consistency (for example "this
-- assessment version assesses a version of *its own* change request") is
-- enforced declaratively with composite foreign keys.
--
-- config_version_id columns reference the versioned configuration store that
-- the identity/configuration module (step 3) creates; that migration adds the
-- foreign keys.
-- =============================================================================

create schema if not exists core;
comment on schema core is 'Governed FCRM domain data.';

-- -----------------------------------------------------------------------------
-- Change request
-- -----------------------------------------------------------------------------
create sequence core.change_request_ref_seq;

create table core.change_request (
    id           uuid primary key default gen_random_uuid(),
    reference_no text not null unique
                 default ('CR-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('core.change_request_ref_seq')::text, 6, '0')),
    like gov.tmpl_identity including all
);
comment on table core.change_request is 'Identity of a proposed change (product, feature, process, vendor, geography or segment). Insert-only.';

create trigger trg_append_only before update or delete on core.change_request
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.change_request
    for each statement execute function gov.forbid_mutation();

create table core.change_request_version (
    id                     uuid primary key default gen_random_uuid(),
    change_request_id      uuid not null references core.change_request (id),
    change_type_term_id    uuid not null references ref.taxonomy_term (id),
    title                  text not null check (length(trim(title)) > 0),
    summary                text,
    sponsor_id             gov.principal_id not null,
    business_unit          text,
    target_launch_date     date,
    intake_form_version_id uuid,
    intake_answers         jsonb not null default '{}' check (jsonb_typeof(intake_answers) = 'object'),
    like gov.tmpl_versioned including all,
    unique (change_request_id, version_no),
    unique (change_request_id, id),
    foreign key (supersedes_id) references core.change_request_version (id)
);
comment on table  core.change_request_version is 'Content of a change request at a point in time. The active version is the submitted one.';
comment on column core.change_request_version.sponsor_id             is 'Product Owner accountable for the change.';
comment on column core.change_request_version.intake_form_version_id is 'Configuration version of the intake questionnaire that produced intake_answers.';
comment on column core.change_request_version.intake_answers         is 'Answers to the configured intake questionnaire, keyed by question code.';

create unique index ux_change_request_version_one_active
    on core.change_request_version (change_request_id) where record_status = 'active';

create trigger trg_a_assign_version before insert on core.change_request_version
    for each row execute function gov.assign_version('change_request_id');
create trigger trg_b_guard_version before insert or update or delete on core.change_request_version
    for each row execute function gov.guard_versioned_row();
create trigger trg_c_term_refs before insert or update on core.change_request_version
    for each row execute function ref.check_term_refs('change_type_term_id', 'CHANGE_REQUEST_TYPE');

-- Scope of the change: geographies, customer segments, channels, product categories.
create table core.change_request_scope (
    change_request_version_id uuid not null references core.change_request_version (id),
    taxonomy_term_id          uuid not null references ref.taxonomy_term (id),
    like gov.tmpl_identity including all,
    primary key (change_request_version_id, taxonomy_term_id)
);
comment on table core.change_request_scope is 'Geographies, segments, channels and product categories in scope of a change request version.';

create index ix_change_request_scope_term on core.change_request_scope (taxonomy_term_id);

create trigger trg_guard_child before insert or update or delete on core.change_request_scope
    for each row execute function gov.guard_child_of_draft('core.change_request_version', 'change_request_version_id');
create trigger trg_term_refs before insert or update on core.change_request_scope
    for each row execute function ref.check_term_refs('taxonomy_term_id', 'GEOGRAPHY|CUSTOMER_SEGMENT|CHANNEL|PRODUCT_CATEGORY');

-- -----------------------------------------------------------------------------
-- Assessment
-- -----------------------------------------------------------------------------
create type core.assessment_kind as enum ('initial', 'reassessment', 'periodic_review');

create table core.assessment (
    id                uuid primary key default gen_random_uuid(),
    change_request_id uuid not null references core.change_request (id),
    assessment_kind   core.assessment_kind not null default 'initial',
    like gov.tmpl_identity including all,
    unique (id, change_request_id)
);
comment on table core.assessment is 'Identity of an FCRM risk assessment of a change request. Insert-only.';

create index ix_assessment_change_request on core.assessment (change_request_id);

create trigger trg_append_only before update or delete on core.assessment
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.assessment
    for each statement execute function gov.forbid_mutation();

create table core.assessment_version (
    id                        uuid primary key default gen_random_uuid(),
    assessment_id             uuid not null,
    change_request_id         uuid not null,
    change_request_version_id uuid not null,
    analyst_id                gov.principal_id,
    config_version_id         uuid,
    narrative                 text,
    like gov.tmpl_versioned including all,
    unique (assessment_id, version_no),
    unique (change_request_id, id),
    foreign key (assessment_id, change_request_id) references core.assessment (id, change_request_id),
    foreign key (change_request_id, change_request_version_id) references core.change_request_version (change_request_id, id),
    foreign key (supersedes_id) references core.assessment_version (id),
    check (record_status = 'draft' or (config_version_id is not null and analyst_id is not null))
);
comment on table  core.assessment_version is
    'Content of an assessment at a point in time. Activating a version freezes its factors and control '
    'evaluations so a rating can be calculated against it.';
comment on column core.assessment_version.change_request_version_id is 'Exact (submitted) change request version that was assessed.';
comment on column core.assessment_version.config_version_id         is 'Configuration version (questionnaire, weights, thresholds) the assessment was performed under.';

create unique index ux_assessment_version_one_active
    on core.assessment_version (assessment_id) where record_status = 'active';

create trigger trg_a_assign_version before insert on core.assessment_version
    for each row execute function gov.assign_version('assessment_id');
create trigger trg_b_guard_version before insert or update or delete on core.assessment_version
    for each row execute function gov.guard_versioned_row();
create trigger trg_c_frozen_ref before insert or update on core.assessment_version
    for each row execute function gov.require_frozen_reference('core.change_request_version', 'change_request_version_id', 'active,superseded');

-- -----------------------------------------------------------------------------
-- Risk factor: an assessed factor (customer, product, channel, geography,
-- transaction) within one assessment version.
-- -----------------------------------------------------------------------------
create table core.risk_factor (
    id                    uuid primary key default gen_random_uuid(),
    assessment_version_id uuid not null references core.assessment_version (id),
    category_term_id      uuid not null references ref.taxonomy_term (id),
    typology_term_id      uuid references ref.taxonomy_term (id),
    factor_code           text not null,
    response              jsonb not null check (jsonb_typeof(response) in ('object', 'array', 'string', 'number', 'boolean')),
    factor_score          numeric(8, 4),
    rationale             text,
    like gov.tmpl_append_only including all,
    unique (assessment_version_id, factor_code),
    unique (assessment_version_id, id)
);
comment on table  core.risk_factor is 'Response to one configured risk-factor question within an assessment version.';
comment on column core.risk_factor.factor_code  is 'Question code from the configured risk-factor questionnaire.';
comment on column core.risk_factor.factor_score is 'Score mapped from the response by the configured questionnaire; weighting happens in the rating.';

create trigger trg_guard_child before insert or update or delete on core.risk_factor
    for each row execute function gov.guard_child_of_draft('core.assessment_version', 'assessment_version_id');
create trigger trg_term_refs before insert or update on core.risk_factor
    for each row execute function ref.check_term_refs(
        'category_term_id', 'RISK_FACTOR_CATEGORY',
        'typology_term_id', 'RISK_TYPOLOGY');

-- -----------------------------------------------------------------------------
-- Control library
-- -----------------------------------------------------------------------------
create table core.control (
    id           uuid primary key default gen_random_uuid(),
    control_code text not null unique check (control_code ~ '^[A-Z0-9][A-Z0-9_\-]*$'),
    like gov.tmpl_identity including all
);
comment on table core.control is 'Identity of a financial-crime control in the control library. Insert-only.';

create trigger trg_append_only before update or delete on core.control
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.control
    for each statement execute function gov.forbid_mutation();

create table core.control_version (
    id                     uuid primary key default gen_random_uuid(),
    control_id             uuid not null references core.control (id),
    name                     text not null,
    description              text not null,
    control_category_term_id uuid not null references ref.taxonomy_term (id),
    control_type_term_id     uuid not null references ref.taxonomy_term (id),
    control_nature_term_id   uuid not null references ref.taxonomy_term (id),
    frequency                text,
    control_owner_id         gov.principal_id not null,
    like gov.tmpl_versioned including all,
    unique (control_id, version_no),
    foreign key (supersedes_id) references core.control_version (id)
);
comment on table core.control_version is 'Definition of a control at a point in time.';

create unique index ux_control_version_one_active
    on core.control_version (control_id) where record_status = 'active';

create trigger trg_a_assign_version before insert on core.control_version
    for each row execute function gov.assign_version('control_id');
create trigger trg_b_guard_version before insert or update or delete on core.control_version
    for each row execute function gov.guard_versioned_row();
create trigger trg_c_term_refs before insert or update on core.control_version
    for each row execute function ref.check_term_refs(
        'control_category_term_id', 'CONTROL_CATEGORY',
        'control_type_term_id', 'CONTROL_TYPE',
        'control_nature_term_id', 'CONTROL_NATURE');

create table core.control_version_typology (
    control_version_id uuid not null references core.control_version (id),
    typology_term_id   uuid not null references ref.taxonomy_term (id),
    like gov.tmpl_identity including all,
    primary key (control_version_id, typology_term_id)
);
comment on table core.control_version_typology is 'Risk typologies a control version is designed to mitigate.';

create trigger trg_guard_child before insert or update or delete on core.control_version_typology
    for each row execute function gov.guard_child_of_draft('core.control_version', 'control_version_id');
create trigger trg_term_refs before insert or update on core.control_version_typology
    for each row execute function ref.check_term_refs('typology_term_id', 'RISK_TYPOLOGY');

-- Evaluation of a library control within an assessment version.
create table core.assessment_control (
    id                              uuid primary key default gen_random_uuid(),
    assessment_version_id           uuid not null references core.assessment_version (id),
    control_version_id              uuid not null references core.control_version (id),
    risk_factor_id                  uuid,
    design_effectiveness_term_id    uuid not null references ref.taxonomy_term (id),
    operating_effectiveness_term_id uuid not null references ref.taxonomy_term (id),
    last_tested_on                  date,
    rationale                       text,
    like gov.tmpl_append_only including all,
    unique (assessment_version_id, id),
    unique nulls not distinct (assessment_version_id, control_version_id, risk_factor_id),
    foreign key (assessment_version_id, risk_factor_id) references core.risk_factor (assessment_version_id, id)
);
comment on table  core.assessment_control is 'Effectiveness of a control, as relied upon in one assessment version.';
comment on column core.assessment_control.risk_factor_id is 'Risk factor the control mitigates; null when it applies to the assessment as a whole.';
comment on column core.assessment_control.last_tested_on is
    'Date operating effectiveness was last tested. Required for any rating better than DEFICIENT: a planned '
    'or in-flight remediation is not a mitigating factor (Wolfsberg Risk Assessment FAQs 2015, 6.2).';

create function core.check_control_evidence() returns trigger
    language plpgsql
as $$
declare
    v_operating text;
begin
    select term_code into v_operating from ref.taxonomy_term where id = new.operating_effectiveness_term_id;
    if v_operating <> 'DEFICIENT' and (new.last_tested_on is null or new.last_tested_on > current_date) then
        raise exception 'core.assessment_control: operating effectiveness % requires a past test date (last_tested_on)', v_operating
            using hint = 'Untested or planned controls must be rated DEFICIENT; remediation in progress does not mitigate risk.';
    end if;
    return new;
end;
$$;

create trigger trg_guard_child before insert or update or delete on core.assessment_control
    for each row execute function gov.guard_child_of_draft('core.assessment_version', 'assessment_version_id');
create trigger trg_frozen_ref before insert or update on core.assessment_control
    for each row execute function gov.require_frozen_reference('core.control_version', 'control_version_id');
create trigger trg_term_refs before insert or update on core.assessment_control
    for each row execute function ref.check_term_refs(
        'design_effectiveness_term_id', 'CONTROL_EFFECTIVENESS',
        'operating_effectiveness_term_id', 'CONTROL_EFFECTIVENESS');
create trigger trg_zz_control_evidence before insert or update on core.assessment_control
    for each row execute function core.check_control_evidence();

-- -----------------------------------------------------------------------------
-- Current-state views
-- -----------------------------------------------------------------------------
create view core.change_request_latest as
select distinct on (cr.id)
       cr.id as change_request_id,
       cr.reference_no,
       v.id  as change_request_version_id,
       v.version_no,
       v.record_status,
       ct.term_code as change_type,
       v.title,
       v.sponsor_id,
       v.owner_id,
       cr.created_at,
       v.created_at as version_created_at
  from core.change_request cr
  join core.change_request_version v on v.change_request_id = cr.id
  join ref.taxonomy_term ct on ct.id = v.change_type_term_id
 order by cr.id, v.version_no desc;
comment on view core.change_request_latest is 'Latest version of each change request, whatever its status.';

create view core.control_active as
select c.control_code, v.*
  from core.control c
  join core.control_version v on v.control_id = c.id and v.record_status = 'active';
