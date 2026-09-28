-- =============================================================================
-- V007  Human challenge of system outputs, and handling of the consequences
--
-- A human can disagree with any system output (rating, factor score, control
-- evaluation, extracted field, evidence link, and any table later registered
-- in core.challengeable_table), record why, and have the consequences handled:
--
--   1. core.challenge          a human records the disagreement and the reason
--   2. core.challenge_consequence
--                              generated automatically: the subject itself
--                              plus every downstream record that depends on it
--                              (derived ratings, evidence, lineage, decisions)
--   3. core.challenge_resolution
--                              a different human upholds or dismisses it
--                              (four-eyes; Wolfsberg Risk Assessment FAQs 6.2.1)
--   4. core.consequence_disposition
--                              each consequence is closed by the correction that
--                              suits the affected table (a superseding record, a
--                              corrective human review, or an amendment/withdrawal
--                              while its assessment version is still draft) or as
--                              "no change required"
--
-- While any challenge or consequence on an assessment version is open, that
-- version cannot go to committee or be decided. A rating override must cite an
-- upheld challenge of the rating it overrides.
-- =============================================================================

create type core.challenge_outcome   as enum ('upheld', 'partially_upheld', 'dismissed');
create type core.consequence_kind    as enum ('correct_subject', 'recalculate_dependent', 'review_dependent', 'revisit_decision');
create type core.consequence_action  as enum ('superseded_by_new_record', 'corrected_by_review', 'amended_in_draft',
                                              'withdrawn_in_draft', 'no_change_required');
create type core.correction_method   as enum ('new_record', 'review_record', 'draft_amendment');

-- -----------------------------------------------------------------------------
-- Registry of tables whose rows can be challenged
-- -----------------------------------------------------------------------------
create table core.challengeable_table (
    table_name                   regclass primary key,
    assessment_version_column    text,
    correction_method            core.correction_method not null,
    superseded_by                regclass not null,
    review_table                 regclass,
    review_link_column           text,
    description                  text not null,
    like gov.tmpl_identity including all,
    constraint ck_review_correction check (
        (correction_method = 'review_record') = (review_table is not null and review_link_column is not null))
);
comment on table  core.challengeable_table is 'Tables whose rows a human may challenge. Later modules (e.g. AI suggestions) register here.';
comment on column core.challengeable_table.assessment_version_column is 'Column locating the row''s assessment version, used to block progression while challenges are open.';
comment on column core.challengeable_table.correction_method is
    'How an upheld challenge is corrected. new_record: only by a superseding record (fully append-only rows). '
    'review_record: by a human review row, or a superseding record. draft_amendment: by amending or withdrawing '
    'the row while its assessment version is draft, or by a superseding record (e.g. in a new assessment version).';
comment on column core.challengeable_table.superseded_by is 'Table a superseding record must be in.';
comment on column core.challengeable_table.review_link_column is 'Column of review_table that references the reviewed row.';

insert into core.challengeable_table (table_name, assessment_version_column, correction_method, superseded_by,
                                      review_table, review_link_column, description, created_by) values
    ('core.rating',             'assessment_version_id', 'new_record',      'core.rating',             null, null,
     'Inherent, residual or final rating',             'system:migration'),
    ('core.rating_input',       'assessment_version_id', 'new_record',      'core.rating',             null, null,
     'Weight or contribution of an input to a rating', 'system:migration'),
    ('core.risk_factor',        'assessment_version_id', 'draft_amendment', 'core.risk_factor',        null, null,
     'Risk-factor response and mapped score',          'system:migration'),
    ('core.assessment_control', 'assessment_version_id', 'draft_amendment', 'core.assessment_control', null, null,
     'Control effectiveness relied upon',              'system:migration'),
    ('core.evidence_link',      'assessment_version_id', 'draft_amendment', 'core.evidence_link',      null, null,
     'Evidence supporting a factor or control',        'system:migration'),
    ('core.extracted_field',    null,                    'review_record',   'core.extracted_field',
     'core.extracted_field_review', 'extracted_field_id',
     'Field produced by document extraction',          'system:migration');

create trigger trg_append_only before update or delete on core.challengeable_table
    for each row execute function gov.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Challenge
-- -----------------------------------------------------------------------------
create table core.challenge (
    id                    uuid primary key default gen_random_uuid(),
    subject_table         regclass not null references core.challengeable_table (table_name),
    subject_id            uuid     not null,
    assessment_version_id uuid references core.assessment_version (id),
    challenged_aspect     text     not null check (length(trim(challenged_aspect)) > 0),
    reason                text     not null check (length(trim(reason)) >= 20),
    proposed_value        jsonb,
    like gov.tmpl_append_only including all,
    constraint ck_challenge_by_human check (origin = 'user_entry')
);
comment on table  core.challenge is 'A human''s recorded disagreement with a system output. Append-only.';
comment on column core.challenge.challenged_aspect is 'What is disputed, e.g. "rating_level", "factor_score", "operating_effectiveness", "value".';
comment on column core.challenge.proposed_value    is 'What the challenger believes the value should be, if applicable.';

create index ix_challenge_subject on core.challenge (subject_table, subject_id);
create index ix_challenge_assessment on core.challenge (assessment_version_id);

create function core.prepare_challenge() returns trigger
    language plpgsql
as $$
declare
    v_av_col text;
    v_av     uuid;
    v_exists boolean;
begin
    select assessment_version_column into v_av_col from core.challengeable_table where table_name = new.subject_table;
    if not found then
        raise exception 'core.challenge: % is not a challengeable table', new.subject_table
            using hint = 'Register it in core.challengeable_table.';
    end if;

    execute format('select true%s from %s where id = $1',
                   case when v_av_col is null then ', null::uuid' else format(', %I', v_av_col) end,
                   new.subject_table)
        into v_exists, v_av using new.subject_id;

    if v_exists is null then
        raise exception 'core.challenge: % % does not exist', new.subject_table, new.subject_id;
    end if;
    if new.assessment_version_id is not null and v_av is not null and new.assessment_version_id <> v_av then
        raise exception 'core.challenge: subject belongs to assessment version %, not %', v_av, new.assessment_version_id;
    end if;
    new.assessment_version_id := coalesce(new.assessment_version_id, v_av);
    return new;
end;
$$;

create trigger trg_prepare before insert on core.challenge
    for each row execute function core.prepare_challenge();
create trigger trg_append_only before update or delete on core.challenge
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.challenge
    for each statement execute function gov.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Consequences
-- -----------------------------------------------------------------------------
create table core.challenge_consequence (
    id                    uuid primary key default gen_random_uuid(),
    challenge_id          uuid not null references core.challenge (id),
    consequence_kind      core.consequence_kind not null,
    target_table          regclass not null,
    target_id             uuid not null,
    assessment_version_id uuid references core.assessment_version (id),
    target_snapshot       jsonb,
    like gov.tmpl_append_only including all,
    unique (challenge_id, target_table, target_id)
);
comment on table core.challenge_consequence is
    'A record affected by a challenge that must be dispositioned: the subject itself, or a dependent record. '
    'Generated automatically on challenge; humans may add more.';
comment on column core.challenge_consequence.target_snapshot is
    'Target row as it stood when the consequence was raised (null if it no longer existed). Set by trigger; '
    'preserves the disputed state and proves an amended_in_draft disposition actually changed the row.';

create index ix_challenge_consequence_assessment on core.challenge_consequence (assessment_version_id);

create function core.capture_consequence_target() returns trigger
    language plpgsql
as $$
begin
    execute format('select to_jsonb(t) from %s t where t.id = $1', new.target_table)
        into new.target_snapshot using new.target_id;
    return new;
end;
$$;

create trigger trg_capture_target before insert on core.challenge_consequence
    for each row execute function core.capture_consequence_target();

create trigger trg_append_only before update or delete on core.challenge_consequence
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.challenge_consequence
    for each statement execute function gov.forbid_mutation();

-- Effective ratings that depend (directly or through basis chains) on the given ratings.
create function core.dependent_effective_ratings(p_rating_ids uuid[]) returns table (rating_id uuid, assessment_version_id uuid)
    language sql stable
as $$
    with recursive dep as (
        select r.id, r.assessment_version_id, r.rating_kind
          from core.rating r
         where r.basis_rating_id = any (p_rating_ids)
        union
        select r.id, r.assessment_version_id, r.rating_kind
          from core.rating r
          join dep d on r.basis_rating_id = d.id
    )
    select d.id, d.assessment_version_id
      from dep d
     where d.id = core.effective_rating_id(d.assessment_version_id, d.rating_kind)
$$;

create function core.generate_challenge_consequences() returns trigger
    language plpgsql
as $$
declare
    v_seed_ratings uuid[];
begin
    insert into core.challenge_consequence (challenge_id, consequence_kind, target_table, target_id, assessment_version_id, origin, created_by)
    values (new.id, 'correct_subject', new.subject_table, new.subject_id, new.assessment_version_id, 'system_derived', new.created_by);

    -- Ratings computed from the challenged record.
    if new.subject_table = 'core.rating'::regclass then
        v_seed_ratings := array[new.subject_id];
    elsif new.subject_table = 'core.rating_input'::regclass then
        select array_agg(ri.rating_id) into v_seed_ratings from core.rating_input ri where ri.id = new.subject_id;
    elsif new.subject_table in ('core.risk_factor'::regclass, 'core.assessment_control'::regclass) then
        select array_agg(distinct ri.rating_id) into v_seed_ratings
          from core.rating_input ri
          join core.rating r on r.id = ri.rating_id
         where (ri.risk_factor_id = new.subject_id or ri.assessment_control_id = new.subject_id)
           and r.id = core.effective_rating_id(r.assessment_version_id, r.rating_kind);
    end if;

    if new.subject_table <> 'core.rating'::regclass and v_seed_ratings is not null then
        insert into core.challenge_consequence (challenge_id, consequence_kind, target_table, target_id, assessment_version_id, origin, created_by)
        select new.id, 'recalculate_dependent', 'core.rating', r.id, r.assessment_version_id, 'system_derived', new.created_by
          from core.rating r where r.id = any (v_seed_ratings)
        on conflict do nothing;
    end if;

    if v_seed_ratings is not null then
        insert into core.challenge_consequence (challenge_id, consequence_kind, target_table, target_id, assessment_version_id, origin, created_by)
        select new.id, 'recalculate_dependent', 'core.rating', d.rating_id, d.assessment_version_id, 'system_derived', new.created_by
          from core.dependent_effective_ratings(v_seed_ratings) d
        on conflict do nothing;
    end if;

    -- Evidence built on a challenged extracted field.
    if new.subject_table = 'core.extracted_field'::regclass then
        insert into core.challenge_consequence (challenge_id, consequence_kind, target_table, target_id, assessment_version_id, origin, created_by)
        select new.id, 'review_dependent', 'core.evidence_link', e.id, e.assessment_version_id, 'system_derived', new.created_by
          from core.evidence_link e where e.extracted_field_id = new.subject_id
        on conflict do nothing;
    end if;

    -- Anything recorded in the lineage graph as derived from the subject.
    insert into core.challenge_consequence (challenge_id, consequence_kind, target_table, target_id, assessment_version_id, origin, created_by)
    select new.id, 'review_dependent', l.from_table, l.from_id, null, 'system_derived', new.created_by
      from gov.lineage_edge l
     where l.to_table = new.subject_table and l.to_id = new.subject_id
       and l.relation in ('derived_from', 'extracted_from', 'evidenced_by', 'copied_from')
    on conflict do nothing;

    -- Decisions already taken on any affected assessment version.
    insert into core.challenge_consequence (challenge_id, consequence_kind, target_table, target_id, assessment_version_id, origin, created_by)
    select distinct new.id, 'revisit_decision'::core.consequence_kind, 'core.decision'::regclass, d.id, cr.assessment_version_id, 'system_derived'::gov.record_origin, new.created_by
      from core.challenge_consequence c
      join core.committee_review cr on cr.assessment_version_id = c.assessment_version_id
      join core.decision d on d.committee_review_id = cr.id
     where c.challenge_id = new.id
    on conflict do nothing;

    return null;
end;
$$;

create trigger trg_generate_consequences after insert on core.challenge
    for each row execute function core.generate_challenge_consequences();

-- -----------------------------------------------------------------------------
-- Resolution (four-eyes)
-- -----------------------------------------------------------------------------
create table core.challenge_resolution (
    id           uuid primary key default gen_random_uuid(),
    challenge_id uuid not null unique references core.challenge (id),
    outcome      core.challenge_outcome not null,
    rationale    text not null check (length(trim(rationale)) >= 20),
    like gov.tmpl_append_only including all,
    constraint ck_resolution_by_human check (origin = 'user_entry')
);
comment on table core.challenge_resolution is 'Decision on a challenge by someone other than the challenger. Append-only.';

create function core.check_resolution_four_eyes() returns trigger
    language plpgsql
as $$
begin
    if exists (select 1 from core.challenge c where c.id = new.challenge_id and c.created_by = new.created_by) then
        raise exception 'core.challenge_resolution: a challenge must be resolved by someone other than the challenger'
            using hint = 'Four-eyes principle: overrides need approval by someone with appropriate authority.';
    end if;
    return new;
end;
$$;

create trigger trg_four_eyes before insert on core.challenge_resolution
    for each row execute function core.check_resolution_four_eyes();
create trigger trg_append_only before update or delete on core.challenge_resolution
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.challenge_resolution
    for each statement execute function gov.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Disposition of each consequence
-- -----------------------------------------------------------------------------
create table core.consequence_disposition (
    id              uuid primary key default gen_random_uuid(),
    consequence_id  uuid not null unique references core.challenge_consequence (id),
    action          core.consequence_action not null,
    resulting_table regclass,
    resulting_id    uuid,
    note            text not null check (length(trim(note)) >= 10),
    like gov.tmpl_append_only including all,
    constraint ck_disposition_by_human check (origin = 'user_entry'),
    constraint ck_disposition_result check (
        (action in ('superseded_by_new_record', 'corrected_by_review')) = (resulting_table is not null and resulting_id is not null))
);
comment on table core.consequence_disposition is 'How a consequence was handled. Append-only.';

create function core.check_consequence_disposition() returns trigger
    language plpgsql
as $$
declare
    v_cons     core.challenge_consequence;
    v_reg      core.challengeable_table;
    v_outcome  core.challenge_outcome;
    v_chal_at  timestamptz;
    v_res_at   timestamptz;
    v_current  jsonb;
    v_target   core.rating;
    v_result   core.rating;
    v_review   core.extracted_field_review;
begin
    select * into v_cons from core.challenge_consequence where id = new.consequence_id;
    select * into v_reg from core.challengeable_table where table_name = v_cons.target_table;
    select r.outcome, c.created_at into v_outcome, v_chal_at
      from core.challenge c left join core.challenge_resolution r on r.challenge_id = c.id
     where c.id = v_cons.challenge_id;

    if v_outcome is null then
        raise exception 'core.consequence_disposition: challenge % must be resolved first', v_cons.challenge_id;
    end if;
    if v_outcome = 'dismissed' and new.action <> 'no_change_required' then
        raise exception 'core.consequence_disposition: challenge was dismissed; consequences close as no_change_required';
    end if;
    if new.action = 'corrected_by_review' and v_reg.correction_method is distinct from 'review_record' then
        raise exception 'core.consequence_disposition: % rows are not corrected by review', v_cons.target_table;
    end if;
    if new.action in ('amended_in_draft', 'withdrawn_in_draft') and v_reg.correction_method is distinct from 'draft_amendment' then
        raise exception 'core.consequence_disposition: % rows cannot be amended or withdrawn in a draft', v_cons.target_table
            using hint = 'Supersede the record with a new one.';
    end if;
    if v_outcome <> 'dismissed' and v_cons.consequence_kind = 'correct_subject' and new.action = 'no_change_required' then
        raise exception 'core.consequence_disposition: challenge was %; the challenged record must be corrected (%)', v_outcome,
            case v_reg.correction_method
                when 'new_record'    then 'superseded_by_new_record'
                when 'review_record' then 'corrected_by_review or superseded_by_new_record'
                else 'amended_in_draft, withdrawn_in_draft or superseded_by_new_record'
            end;
    end if;

    if new.action = 'superseded_by_new_record' then
        if v_reg.superseded_by is not null and new.resulting_table <> v_reg.superseded_by then
            raise exception 'core.consequence_disposition: % rows are superseded by a % row, not %',
                v_cons.target_table, v_reg.superseded_by, new.resulting_table;
        end if;
        execute format('select created_at from %s where id = $1', new.resulting_table) into v_res_at using new.resulting_id;
        if v_res_at is null then
            raise exception 'core.consequence_disposition: % % does not exist', new.resulting_table, new.resulting_id;
        end if;
        if v_res_at < v_chal_at then
            raise exception 'core.consequence_disposition: resulting record predates the challenge';
        end if;

        -- A rating input is corrected by a later rating of the kind it fed.
        if v_cons.target_table in ('core.rating'::regclass, 'core.rating_input'::regclass) then
            select r.* into v_target
              from core.rating r
             where r.id = case when v_cons.target_table = 'core.rating'::regclass then v_cons.target_id
                               else (select ri.rating_id from core.rating_input ri where ri.id = v_cons.target_id) end;
            select * into v_result from core.rating where id = new.resulting_id;
            if v_result.rating_kind <> v_target.rating_kind or v_result.seq <= v_target.seq then
                raise exception 'core.consequence_disposition: resulting rating must be a later % rating', v_target.rating_kind;
            end if;
        end if;

    elsif new.action = 'corrected_by_review' then
        if new.resulting_table <> v_reg.review_table then
            raise exception 'core.consequence_disposition: % rows are corrected by a % row, not %',
                v_cons.target_table, v_reg.review_table, new.resulting_table;
        end if;
        execute format('select created_at from %s where id = $1 and %I = $2', new.resulting_table, v_reg.review_link_column)
            into v_res_at using new.resulting_id, v_cons.target_id;
        if v_res_at is null then
            raise exception 'core.consequence_disposition: % % is not a review of % %',
                new.resulting_table, new.resulting_id, v_cons.target_table, v_cons.target_id;
        end if;
        if v_res_at < v_chal_at then
            raise exception 'core.consequence_disposition: resulting review predates the challenge';
        end if;

        if new.resulting_table = 'core.extracted_field_review'::regclass then
            select * into v_review from core.extracted_field_review where id = new.resulting_id;
            if v_review.outcome = 'confirmed' then
                raise exception 'core.consequence_disposition: a review confirming the challenged value does not correct it';
            end if;
            if exists (select 1 from core.extracted_field_review rv
                        where rv.extracted_field_id = v_review.extracted_field_id and rv.seq > v_review.seq) then
                raise exception 'core.consequence_disposition: review % is no longer the latest review of the field', v_review.id;
            end if;
        end if;

    elsif new.action in ('amended_in_draft', 'withdrawn_in_draft') then
        execute format('select to_jsonb(t) from %s t where t.id = $1', v_cons.target_table)
            into v_current using v_cons.target_id;
        if new.action = 'withdrawn_in_draft' and v_current is not null then
            raise exception 'core.consequence_disposition: % % still exists; remove it from the draft first',
                v_cons.target_table, v_cons.target_id;
        end if;
        if new.action = 'amended_in_draft' and v_current is null then
            raise exception 'core.consequence_disposition: % % no longer exists; disposition it as withdrawn_in_draft',
                v_cons.target_table, v_cons.target_id;
        end if;
        if new.action = 'amended_in_draft' and v_current is not distinct from v_cons.target_snapshot then
            raise exception 'core.consequence_disposition: % % has not been amended since the challenge',
                v_cons.target_table, v_cons.target_id;
        end if;
    end if;
    return new;
end;
$$;

create trigger trg_check before insert on core.consequence_disposition
    for each row execute function core.check_consequence_disposition();
create trigger trg_append_only before update or delete on core.consequence_disposition
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.consequence_disposition
    for each statement execute function gov.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Open items and progression gates
-- -----------------------------------------------------------------------------
create view core.open_challenge_item as
select c.id as challenge_id, null::uuid as consequence_id, 'challenge_unresolved' as item,
       c.assessment_version_id, c.subject_table as target_table, c.subject_id as target_id, c.created_at
  from core.challenge c
 where not exists (select 1 from core.challenge_resolution r where r.challenge_id = c.id)
union all
select k.challenge_id, k.id, 'consequence_' || k.consequence_kind::text,
       k.assessment_version_id, k.target_table, k.target_id, k.created_at
  from core.challenge_consequence k
 where not exists (select 1 from core.consequence_disposition d where d.consequence_id = k.id);
comment on view core.open_challenge_item is 'Unresolved challenges and undispositioned consequences. Any row for an assessment version blocks committee and decision.';

create function core.assert_ready_for_committee(p_assessment_version_id uuid, p_context text) returns void
    language plpgsql
as $$
declare
    v_open      integer;
    v_inherent  uuid := core.effective_rating_id(p_assessment_version_id, 'inherent');
    v_residual  uuid := core.effective_rating_id(p_assessment_version_id, 'residual');
begin
    select count(*) into v_open from core.open_challenge_item where assessment_version_id = p_assessment_version_id;
    if v_open > 0 then
        raise exception '%: assessment version % has % open challenge item(s)', p_context, p_assessment_version_id, v_open
            using hint = 'Resolve challenges and disposition their consequences first (see core.open_challenge_item).';
    end if;
    if v_inherent is null or v_residual is null then
        raise exception '%: assessment version % needs an inherent and a residual rating', p_context, p_assessment_version_id;
    end if;
    if (select basis_rating_id from core.rating where id = v_residual) <> v_inherent then
        raise exception '%: the residual rating in effect is stale; it is not derived from the inherent rating in effect', p_context;
    end if;
end;
$$;

create function core.gate_committee_review() returns trigger
    language plpgsql
as $$
begin
    perform core.assert_ready_for_committee(new.assessment_version_id, 'core.committee_review');
    return new;
end;
$$;

create function core.gate_decision() returns trigger
    language plpgsql
as $$
begin
    perform core.assert_ready_for_committee(
        (select assessment_version_id from core.committee_review where id = new.committee_review_id), 'core.decision');
    return new;
end;
$$;

create trigger trg_gate before insert on core.committee_review
    for each row execute function core.gate_committee_review();
create trigger trg_gate before insert on core.decision
    for each row execute function core.gate_decision();

-- -----------------------------------------------------------------------------
-- Overrides are the correction of an upheld challenge
-- -----------------------------------------------------------------------------
alter table core.rating add column challenge_id uuid references core.challenge (id);
alter table core.rating add constraint ck_override_via_challenge check (method <> 'override' or challenge_id is not null);
comment on column core.rating.challenge_id is 'Upheld challenge this override corrects.';

create function core.check_override_challenge() returns trigger
    language plpgsql
as $$
begin
    if new.method <> 'override' or new.challenge_id is null then
        return new;
    end if;
    if not exists (
        select 1
          from core.challenge c
          join core.challenge_resolution r on r.challenge_id = c.id
         where c.id = new.challenge_id
           and c.subject_table = 'core.rating'::regclass
           and c.subject_id = new.overrides_rating_id
           and r.outcome in ('upheld', 'partially_upheld')) then
        raise exception 'core.rating: an override must cite an upheld challenge of rating %', new.overrides_rating_id;
    end if;
    return new;
end;
$$;

create trigger trg_zz_override_challenge before insert on core.rating
    for each row execute function core.check_override_challenge();
