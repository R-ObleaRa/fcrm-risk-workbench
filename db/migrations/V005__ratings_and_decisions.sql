-- =============================================================================
-- V005  Ratings (with explanation trace), committee reviews, votes, decisions,
--       conditions
--
-- Traceability rules enforced here:
--   * a rating can only be calculated against an ACTIVE (frozen) assessment
--     version, and must carry the configuration version of that assessment
--   * every rating input points at a factor / control of the same assessment
--     version
--   * an override is a new rating that points at the rating it overrides, is of
--     the same kind, is entered by a human and carries a justification
--   * controls mitigate risk but never eliminate it (see "Mitigation rules")
--   * votes and decisions can only be recorded by humans (origin = user_entry)
--   * a decision requires the quorum of votes; approve_with_conditions requires
--     at least one condition (checked at commit)
--
-- Mitigation rules (Wolfsberg Risk Assessment FAQs 2015, 6.3; FATF R.15 "manage
-- and mitigate"):
--   * a residual rating is always derived from the inherent rating currently in
--     effect, and a final rating from the residual rating currently in effect
--   * control_mitigation, the proportion of inherent risk the controls offset,
--     is in [0, 1): controls can never offset all of it
--   * scores are strictly positive, and a calculated residual score never
--     exceeds its inherent score
--   * a residual level is never above the inherent level, and never below the
--     floor the inherent level allows (RATING_LEVEL attribute
--     min_residual_ordinal; e.g. High inherent can never become Low residual)
--   * a final rating may be raised, but never below that same floor
-- These apply to human overrides too: to lower residual risk further, a human
-- must challenge the inherent rating or the control evidence, not the arithmetic.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Ratings
-- -----------------------------------------------------------------------------
create type core.rating_kind   as enum ('inherent', 'residual', 'final');
create type core.rating_method as enum ('calculated', 'override');

alter table core.assessment_version add unique (id, config_version_id);

create table core.rating (
    id                     uuid primary key default gen_random_uuid(),
    assessment_version_id  uuid not null references core.assessment_version (id),
    rating_kind            core.rating_kind   not null,
    method                 core.rating_method not null,
    score                  numeric(10, 4) check (score > 0),
    rating_level_term_id   uuid not null references ref.taxonomy_term (id),
    config_version_id      uuid not null,
    engine_version         text,
    inputs_sha256          text check (inputs_sha256 ~ '^[0-9a-f]{64}$'),
    explanation            jsonb not null default '{}' check (jsonb_typeof(explanation) = 'object'),
    basis_rating_id        uuid,
    control_mitigation     numeric(5, 4),
    overrides_rating_id    uuid,
    override_justification text,
    like gov.tmpl_append_only including all,
    unique (assessment_version_id, id),
    unique (assessment_version_id, id, rating_kind),
    constraint fk_rating_assessment_config foreign key (assessment_version_id, config_version_id)
        references core.assessment_version (id, config_version_id),
    constraint fk_rating_overrides_same_kind foreign key (assessment_version_id, overrides_rating_id, rating_kind)
        references core.rating (assessment_version_id, id, rating_kind),
    constraint fk_rating_basis foreign key (assessment_version_id, basis_rating_id)
        references core.rating (assessment_version_id, id),
    constraint ck_rating_basis check ((rating_kind = 'inherent') = (basis_rating_id is null)),
    constraint ck_mitigation_never_eliminates check (
        control_mitigation is null or (control_mitigation >= 0 and control_mitigation < 1)),
    constraint ck_mitigation_recorded check (
        (rating_kind = 'residual' and method = 'calculated') = (control_mitigation is not null)),
    constraint ck_rating_method check (
        (method = 'calculated'
            and score is not null
            and engine_version is not null
            and inputs_sha256 is not null
            and overrides_rating_id is null
            and override_justification is null)
        or
        (method = 'override'
            and overrides_rating_id is not null
            and length(trim(coalesce(override_justification, ''))) >= 20
            and origin = 'user_entry')
    )
);
comment on table  core.rating is 'Inherent, residual or final rating of an assessment version, with its full explanation trace. Append-only.';
comment on column core.rating.config_version_id      is 'Configuration version (weights, thresholds) that produced the rating.';
comment on column core.rating.engine_version         is 'Version of the scoring engine code that calculated the rating.';
comment on column core.rating.inputs_sha256          is 'Hash of the canonical input set, so a recalculation can be proven identical.';
comment on column core.rating.explanation            is 'Human-readable calculation trace: formula, intermediate values, thresholds applied.';
comment on column core.rating.overrides_rating_id    is 'Rating this analyst override replaces. The overridden rating is kept.';
comment on column core.rating.override_justification is 'Mandatory justification for an override (at least 20 characters).';
comment on column core.rating.basis_rating_id        is 'Rating this one is derived from: inherent for a residual rating, residual for a final rating.';
comment on column core.rating.control_mitigation     is 'Proportion of inherent risk offset by controls, in [0, 1). Never 1: controls do not eliminate risk.';

create index ix_rating_assessment_version on core.rating (assessment_version_id, rating_kind, seq);

create function core.effective_rating_id(p_assessment_version_id uuid, p_kind core.rating_kind) returns uuid
    language sql stable
as $$
    select r.id from core.rating r
     where r.assessment_version_id = p_assessment_version_id and r.rating_kind = p_kind
     order by r.seq desc
     limit 1
$$;
comment on function core.effective_rating_id(uuid, core.rating_kind) is 'Latest rating of a kind for an assessment version (overrides replace calculations).';

create function core.level_attr(p_term_id uuid, p_attr text) returns integer
    language plpgsql stable
as $$
declare
    v_value integer;
begin
    select (attributes ->> p_attr)::integer into v_value from ref.taxonomy_term where id = p_term_id;
    if v_value is null then
        raise exception 'RATING_LEVEL term % has no % attribute', p_term_id, p_attr;
    end if;
    return v_value;
end;
$$;

create function core.check_rating_rules() returns trigger
    language plpgsql
as $$
declare
    v_basis          core.rating;
    v_inherent       core.rating;
    v_expected_basis core.rating_kind;
    v_ord            integer;
    v_floor          integer;
begin
    if new.rating_kind = 'inherent' or new.basis_rating_id is null then
        return new;
    end if;

    v_expected_basis := case new.rating_kind when 'residual' then 'inherent'::core.rating_kind else 'residual'::core.rating_kind end;

    select * into v_basis from core.rating where id = new.basis_rating_id;
    if v_basis.rating_kind <> v_expected_basis then
        raise exception 'core.rating: a % rating must be based on a % rating, not %', new.rating_kind, v_expected_basis, v_basis.rating_kind;
    end if;
    if v_basis.id is distinct from core.effective_rating_id(new.assessment_version_id, v_expected_basis) then
        raise exception 'core.rating: basis rating % is not the % rating currently in effect', v_basis.id, v_expected_basis
            using hint = 'It has been overridden; derive from the rating in effect.';
    end if;

    if new.rating_kind = 'residual' then
        v_inherent := v_basis;
    else
        select * into v_inherent from core.rating where id = v_basis.basis_rating_id;
    end if;

    v_ord   := core.level_attr(new.rating_level_term_id, 'ordinal');
    v_floor := core.level_attr(v_inherent.rating_level_term_id, 'min_residual_ordinal');

    if v_ord < v_floor then
        raise exception 'core.rating: % level (ordinal %) is below the floor (ordinal %) allowed for the inherent level; controls mitigate risk but never eliminate it',
            new.rating_kind, v_ord, v_floor;
    end if;

    if new.rating_kind = 'residual' then
        if v_ord > core.level_attr(v_inherent.rating_level_term_id, 'ordinal') then
            raise exception 'core.rating: residual level cannot be higher than the inherent level';
        end if;
        if new.method = 'calculated' and v_inherent.score is not null and new.score > v_inherent.score then
            raise exception 'core.rating: residual score % exceeds inherent score %', new.score, v_inherent.score;
        end if;
    end if;

    return new;
end;
$$;

create trigger trg_append_only before update or delete on core.rating
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.rating
    for each statement execute function gov.forbid_mutation();
create trigger trg_frozen_ref before insert on core.rating
    for each row execute function gov.require_frozen_reference('core.assessment_version', 'assessment_version_id');
create trigger trg_term_refs before insert on core.rating
    for each row execute function ref.check_term_refs('rating_level_term_id', 'RATING_LEVEL');
create trigger trg_zz_rating_rules before insert on core.rating
    for each row execute function core.check_rating_rules();

create type core.rating_input_kind as enum ('risk_factor', 'control', 'parameter');

create table core.rating_input (
    id                    uuid primary key default gen_random_uuid(),
    rating_id             uuid not null,
    assessment_version_id uuid not null,
    input_kind            core.rating_input_kind not null,
    risk_factor_id        uuid,
    assessment_control_id uuid,
    parameter_key         text,
    input_value           jsonb not null,
    weight                numeric(12, 6),
    contribution          numeric(14, 6),
    like gov.tmpl_append_only including all,
    foreign key (assessment_version_id, rating_id)             references core.rating (assessment_version_id, id),
    foreign key (assessment_version_id, risk_factor_id)        references core.risk_factor (assessment_version_id, id),
    foreign key (assessment_version_id, assessment_control_id) references core.assessment_control (assessment_version_id, id),
    constraint ck_rating_input_kind check (
        (input_kind = 'risk_factor') = (risk_factor_id is not null)
        and (input_kind = 'control') = (assessment_control_id is not null)
        and (input_kind = 'parameter') = (parameter_key is not null))
);
comment on table  core.rating_input is 'One input to a rating: a weighted factor, a control effectiveness, or a configuration parameter.';
comment on column core.rating_input.contribution is 'Amount this input contributed to the rating score.';

create index ix_rating_input_rating on core.rating_input (rating_id);

create trigger trg_append_only before update or delete on core.rating_input
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.rating_input
    for each statement execute function gov.forbid_mutation();

create view core.rating_effective as
select distinct on (r.assessment_version_id, r.rating_kind)
       r.*
  from core.rating r
 order by r.assessment_version_id, r.rating_kind, r.seq desc;
comment on view core.rating_effective is 'Latest rating of each kind per assessment version (an override replaces the calculated rating).';

-- -----------------------------------------------------------------------------
-- Committee review, votes, decision
-- -----------------------------------------------------------------------------
create table core.committee_review (
    id                       uuid primary key default gen_random_uuid(),
    change_request_id        uuid    not null,
    assessment_version_id    uuid    not null,
    quorum_required          integer not null check (quorum_required > 0),
    meeting_ref              text,
    pack_document_version_id uuid references core.document_version (id),
    like gov.tmpl_append_only including all,
    foreign key (change_request_id, assessment_version_id) references core.assessment_version (change_request_id, id)
);
comment on table  core.committee_review is 'Committee consideration of a finalised assessment version. Append-only.';
comment on column core.committee_review.pack_document_version_id is 'Committee pack presented to members.';

create index ix_committee_review_change_request on core.committee_review (change_request_id);

create trigger trg_append_only before update or delete on core.committee_review
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.committee_review
    for each statement execute function gov.forbid_mutation();
create trigger trg_frozen_ref before insert on core.committee_review
    for each row execute function gov.require_frozen_reference('core.assessment_version', 'assessment_version_id');

create type core.vote_choice      as enum ('approve', 'reject', 'defer', 'approve_with_conditions', 'abstain');
create type core.decision_outcome as enum ('approve', 'reject', 'defer', 'approve_with_conditions');

create table core.vote (
    id                  uuid primary key default gen_random_uuid(),
    committee_review_id uuid not null references core.committee_review (id),
    voter_id            gov.principal_id not null,
    choice              core.vote_choice not null,
    rationale           text not null check (length(trim(rationale)) > 0),
    like gov.tmpl_append_only including all,
    unique (committee_review_id, voter_id),
    constraint ck_vote_by_human check (origin = 'user_entry'),
    constraint ck_vote_cast_by_voter check (voter_id = created_by)
);
comment on table core.vote is 'A committee member''s vote with recorded rationale. Only the voter can cast it. Append-only.';

create table core.decision (
    id                  uuid primary key default gen_random_uuid(),
    committee_review_id uuid not null unique references core.committee_review (id),
    outcome             core.decision_outcome not null,
    rationale           text not null check (length(trim(rationale)) > 0),
    like gov.tmpl_append_only including all,
    constraint ck_decision_by_human check (origin = 'user_entry')
);
comment on table core.decision is 'Committee decision. Requires a quorum of human votes. Append-only.';

create function core.check_vote_open() returns trigger
    language plpgsql
as $$
begin
    if exists (select 1 from core.decision d where d.committee_review_id = new.committee_review_id) then
        raise exception 'core.vote: committee review % is already decided', new.committee_review_id;
    end if;
    return new;
end;
$$;

create function core.check_decision_quorum() returns trigger
    language plpgsql
as $$
declare
    v_required integer;
    v_cast     integer;
begin
    select cr.quorum_required into v_required
      from core.committee_review cr where cr.id = new.committee_review_id
       for update;

    select count(*) into v_cast
      from core.vote v where v.committee_review_id = new.committee_review_id;

    if v_cast < v_required then
        raise exception 'core.decision: quorum not met for committee review % (% of % votes recorded)',
            new.committee_review_id, v_cast, v_required;
    end if;
    return new;
end;
$$;

create function core.check_conditions_present() returns trigger
    language plpgsql
as $$
begin
    if new.outcome = 'approve_with_conditions'
       and not exists (select 1 from core.condition c where c.decision_id = new.id) then
        raise exception 'core.decision: % is approve_with_conditions but has no conditions', new.id;
    end if;
    return null;
end;
$$;

create trigger trg_append_only before update or delete on core.vote
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.vote
    for each statement execute function gov.forbid_mutation();
create trigger trg_vote_open before insert on core.vote
    for each row execute function core.check_vote_open();

create trigger trg_append_only before update or delete on core.decision
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.decision
    for each statement execute function gov.forbid_mutation();
create trigger trg_quorum before insert on core.decision
    for each row execute function core.check_decision_quorum();

-- -----------------------------------------------------------------------------
-- Conditions and their progress to closure
-- -----------------------------------------------------------------------------
create table core.condition (
    id             uuid primary key default gen_random_uuid(),
    decision_id    uuid not null references core.decision (id),
    condition_text text not null check (length(trim(condition_text)) > 0),
    owner_id       gov.principal_id not null,
    due_date       date,
    like gov.tmpl_append_only including all
);
comment on table core.condition is 'Condition attached to an approve_with_conditions decision. Status is tracked in condition_status_event.';

create index ix_condition_decision on core.condition (decision_id);

create function core.check_condition_decision() returns trigger
    language plpgsql
as $$
begin
    if not exists (select 1 from core.decision d where d.id = new.decision_id and d.outcome = 'approve_with_conditions') then
        raise exception 'core.condition: decision % is not approve_with_conditions', new.decision_id;
    end if;
    return new;
end;
$$;

create trigger trg_append_only before update or delete on core.condition
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.condition
    for each statement execute function gov.forbid_mutation();
create trigger trg_condition_decision before insert on core.condition
    for each row execute function core.check_condition_decision();

create constraint trigger trg_conditions_present after insert on core.decision
    deferrable initially deferred
    for each row execute function core.check_conditions_present();

create type core.condition_status as enum ('open', 'in_progress', 'evidence_submitted', 'closed', 'waived');

create table core.condition_status_event (
    id                           uuid primary key default gen_random_uuid(),
    condition_id                 uuid not null references core.condition (id),
    status                       core.condition_status not null,
    note                         text,
    evidence_document_version_id uuid references core.document_version (id),
    like gov.tmpl_append_only including all,
    check (status not in ('closed', 'waived') or length(trim(coalesce(note, ''))) > 0)
);
comment on table core.condition_status_event is 'Status history of a condition. A condition with no events is open.';

create index ix_condition_status_event_condition on core.condition_status_event (condition_id, seq desc);

create trigger trg_append_only before update or delete on core.condition_status_event
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.condition_status_event
    for each statement execute function gov.forbid_mutation();

create view core.condition_current as
select c.*,
       coalesce(e.status, 'open') as current_status,
       e.created_at               as status_since,
       e.created_by               as status_set_by
  from core.condition c
  left join lateral (
        select * from core.condition_status_event ev
         where ev.condition_id = c.id
         order by ev.seq desc
         limit 1) e on true;
