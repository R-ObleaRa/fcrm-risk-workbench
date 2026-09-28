-- =============================================================================
-- Data model behaviour tests. Run against a freshly migrated database:
--   psql -v ON_ERROR_STOP=1 -f db/tests/test_data_model.sql
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
-- Reference data and grounding
-- -----------------------------------------------------------------------------
select pg_temp.assert((select count(*) from ref.taxonomy) = 13, 'thirteen taxonomies seeded');
select pg_temp.assert(
    (select count(*) from ref.taxonomy_version where record_status = 'active') = 13,
    'each seeded taxonomy has an active version');
select pg_temp.assert((select count(*) from ref.framework) = 3, 'three published frameworks registered');
select pg_temp.assert(
    (select count(*) from ref.active_term a join ref.taxonomy t on t.code = a.taxonomy_code
      where t.requires_framework_basis
        and not exists (select 1 from ref.taxonomy_term_basis b where b.taxonomy_term_id = a.term_id)) = 0,
    'every term of a grounded taxonomy cites a framework provision');
select pg_temp.assert(
    (select count(*) from ref.active_term where taxonomy_code = 'RISK_TYPOLOGY' and parent_term_code = 'ML') = 21,
    'money-laundering predicates are the 21 FATF designated categories of offences');
select pg_temp.assert(
    (select count(distinct term_code) from ref.active_term_grounding
      where taxonomy_code = 'RISK_FACTOR_CATEGORY' and framework_code = 'EBA_GL_2021_02') >= 4,
    'risk factor categories are grounded in EBA/GL/2021/02');
select pg_temp.assert(
    (select parent_term_code from ref.active_term where taxonomy_code = 'GEOGRAPHY' and term_code = 'SG') = 'REGION_ASIA',
    'geography hierarchy resolves');

-- -----------------------------------------------------------------------------
-- Synthetic data only
-- -----------------------------------------------------------------------------
set local fcrm.actor_id = 'user:jane.doe@realbank.com';
select pg_temp.expect_error('insert into core.change_request default values', 'ck_synthetic_principal');
set local fcrm.actor_id = '';
select pg_temp.expect_error('insert into core.change_request default values', 'null value in column "created_by"');
set local fcrm.actor_id = 'user:po.priya@fcrm.example';

select pg_temp.expect_error(
    'insert into gov.lineage_edge (from_table, from_id, relation, to_table, to_id, source_system) '
    || 'values (''core.rating'', gen_random_uuid(), ''cites'', ''core.rating'', gen_random_uuid(), ''core-banking-prod'')',
    'ck_synthetic_source_system');
select pg_temp.expect_error(
    'insert into gov.lineage_edge (from_table, from_id, relation, to_table, to_id, origin) '
    || 'values (''core.rating'', gen_random_uuid(), ''cites'', ''core.rating'', gen_random_uuid(), ''bulk_import'')',
    'invalid input value for enum gov.record_origin');

do $$
declare
    v_cr      uuid;
    v_crv1    uuid;
    v_crv2    uuid;
    v_asmt    uuid;
    v_av1     uuid;
    v_rf1     uuid;
    v_rf2     uuid;
    v_ctl     uuid;
    v_ctlv    uuid;
    v_ac      uuid;
    v_inh     uuid;
    v_res     uuid;
    v_inh2    uuid;
    v_res2    uuid;
    v_doc     uuid;
    v_docv    uuid;
    v_field   uuid;
    v_pol     uuid;
    v_polv    uuid;
    v_clause  uuid;
    v_chal    uuid;
    v_chal2   uuid;
    v_cons    uuid;
    v_rev     uuid;
    v_av2     uuid;
    v_rf3     uuid;
    v_ev2     uuid;
    v_review  uuid;
    v_dec     uuid;
    v_cfg     uuid := gen_random_uuid();
    v_tax_v2  uuid;
    v_c       record;
begin
    ---------------------------------------------------------------------------
    -- Taxonomy governance
    ---------------------------------------------------------------------------
    perform pg_temp.expect_error(format(
        'insert into ref.taxonomy_term (taxonomy_version_id, term_code, label) values (%L, ''NEW'', ''New'')',
        (select id from ref.taxonomy_version where taxonomy_code = 'CHANNEL' and record_status = 'active')),
        'because it is active');

    insert into ref.taxonomy_version (taxonomy_code, change_reason)
    values ('CHANNEL', 'Add partner-branch channel') returning id into v_tax_v2;
    perform pg_temp.assert((select version_no = 2 and supersedes_id is not null
                              from ref.taxonomy_version where id = v_tax_v2),
        'new taxonomy version gets version_no 2 and supersedes v1');
    perform pg_temp.expect_error(format(
        'update ref.taxonomy_version set record_status = ''active'' where id = %L', v_tax_v2),
        'ux_taxonomy_version_one_active');

    insert into ref.taxonomy_version (taxonomy_code, change_reason)
    values ('RISK_TYPOLOGY', 'Attempt to add an ungrounded typology') returning id into v_tax_v2;
    insert into ref.taxonomy_term (taxonomy_version_id, term_code, label) values (v_tax_v2, 'INVENTED_TYPOLOGY', 'Invented');
    perform pg_temp.expect_error(format(
        'update ref.taxonomy_version set record_status = ''active'' where id = %L', v_tax_v2),
        'terms without a framework basis: INVENTED_TYPOLOGY');
    perform pg_temp.expect_error(
        'insert into ref.taxonomy_version (taxonomy_code, record_status) values (''RATING_LEVEL'', ''active'')',
        'requires framework grounding');

    ---------------------------------------------------------------------------
    -- Change request versioning
    ---------------------------------------------------------------------------
    insert into core.change_request default values returning id into v_cr;
    perform pg_temp.assert((select reference_no ~ '^CR-\d{4}-\d{6}$' from core.change_request where id = v_cr),
        'change request reference number generated');
    perform pg_temp.expect_error(format('update core.change_request set reference_no = ''X'' where id = %L', v_cr),
        'append-only');
    perform pg_temp.expect_error(format('delete from core.change_request where id = %L', v_cr),
        'append-only');

    perform pg_temp.expect_error(format(
        'insert into core.change_request_version (change_request_id, change_type_term_id, title, sponsor_id) values (%L, %L, ''x'', ''user:po.priya@fcrm.example'')',
        v_cr, ref.term_id('RISK_TYPOLOGY', 'ML')),
        'must be a term of CHANGE_REQUEST_TYPE');
    perform pg_temp.expect_error(format(
        'insert into core.change_request_version (change_request_id, change_type_term_id, title, sponsor_id) values (%L, %L, ''x'', ''priya.sharma'')',
        v_cr, ref.term_id('CHANGE_REQUEST_TYPE', 'PRODUCT')),
        'ck_synthetic_principal');

    insert into core.change_request_version (change_request_id, change_type_term_id, title, sponsor_id)
    values (v_cr, ref.term_id('CHANGE_REQUEST_TYPE', 'PRODUCT'), 'Cross-border instant payments', 'user:po.priya@fcrm.example')
    returning id into v_crv1;

    insert into core.change_request_scope (change_request_version_id, taxonomy_term_id)
    values (v_crv1, ref.term_id('GEOGRAPHY', 'SG')),
           (v_crv1, ref.term_id('CHANNEL', 'MOBILE')),
           (v_crv1, ref.term_id('PRODUCT_CATEGORY', 'PAYMENTS_CROSS_BORDER'));
    perform pg_temp.expect_error(format(
        'insert into core.change_request_scope values (%L, %L)', v_crv1, ref.term_id('RATING_LEVEL', 'LOW')),
        'must be a term of GEOGRAPHY or CUSTOMER_SEGMENT');

    update core.change_request_version set summary = 'Draft edit allowed' where id = v_crv1;
    perform pg_temp.assert((select updated_by = 'user:po.priya@fcrm.example' from core.change_request_version where id = v_crv1),
        'draft edit records updated_by');

    update core.change_request_version set record_status = 'active' where id = v_crv1;
    perform pg_temp.assert((select status_changed_by = 'user:po.priya@fcrm.example' and status_changed_at is not null
                              from core.change_request_version where id = v_crv1),
        'activation records who and when');
    perform pg_temp.expect_error(format('update core.change_request_version set title = ''changed'' where id = %L', v_crv1),
        'content is frozen');
    perform pg_temp.expect_error(format('delete from core.change_request_version where id = %L', v_crv1),
        'cannot be deleted');
    perform pg_temp.expect_error(format(
        'insert into core.change_request_scope values (%L, %L)', v_crv1, ref.term_id('GEOGRAPHY', 'HK')),
        'because it is active');
    perform pg_temp.expect_error(format(
        'update core.change_request_version set record_status = ''draft'' where id = %L', v_crv1),
        'attempted active -> draft');

    insert into core.change_request_version (change_request_id, change_type_term_id, title, sponsor_id)
    values (v_cr, ref.term_id('CHANGE_REQUEST_TYPE', 'PRODUCT'), 'Cross-border instant payments (rev)', 'user:po.priya@fcrm.example')
    returning id into v_crv2;
    perform pg_temp.assert((select version_no = 2 and supersedes_id = v_crv1 from core.change_request_version where id = v_crv2),
        'second change request version links to the first');

    ---------------------------------------------------------------------------
    -- Assessment, risk factors, controls
    ---------------------------------------------------------------------------
    perform set_config('fcrm.actor_id', 'user:analyst.alice@fcrm.example', true);

    insert into core.assessment (change_request_id) values (v_cr) returning id into v_asmt;

    perform pg_temp.expect_error(format(
        'insert into core.assessment_version (assessment_id, change_request_id, change_request_version_id) values (%L, %L, %L)',
        v_asmt, v_cr, v_crv2),
        'must reference a active/superseded version');

    insert into core.assessment_version (assessment_id, change_request_id, change_request_version_id, analyst_id, config_version_id)
    values (v_asmt, v_cr, v_crv1, 'user:analyst.alice@fcrm.example', v_cfg)
    returning id into v_av1;

    insert into core.risk_factor (assessment_version_id, category_term_id, typology_term_id, factor_code, response, factor_score, origin)
    values (v_av1, ref.term_id('RISK_FACTOR_CATEGORY', 'GEO_TF_SANCTIONS'), ref.term_id('RISK_TYPOLOGY', 'TFS_TERRORISM'),
            'GEO_CORRIDORS', '["SG","HK"]', 3.0, 'system_derived')
    returning id into v_rf1;
    insert into core.risk_factor (assessment_version_id, category_term_id, factor_code, response, factor_score, origin)
    values (v_av1, ref.term_id('RISK_FACTOR_CATEGORY', 'CHANNEL_NON_FACE_TO_FACE'), 'NON_FACE_TO_FACE', 'true', 2.0, 'system_derived')
    returning id into v_rf2;

    insert into core.control (control_code) values ('CTL-SANCTIONS-SCREENING') returning id into v_ctl;
    insert into core.control_version (control_id, name, description, control_category_term_id, control_type_term_id,
                                      control_nature_term_id, control_owner_id)
    values (v_ctl, 'Real-time payment sanctions screening', 'Screens parties against sanctions lists before release.',
            ref.term_id('CONTROL_CATEGORY', 'MONITORING_CONTROLS'), ref.term_id('CONTROL_TYPE', 'PREVENTIVE'),
            ref.term_id('CONTROL_NATURE', 'AUTOMATED'), 'user:ops.omar@fcrm.example')
    returning id into v_ctlv;
    insert into core.control_version_typology values (v_ctlv, ref.term_id('RISK_TYPOLOGY', 'TFS_TERRORISM'));
    update core.control_version set record_status = 'active' where id = v_ctlv;

    perform pg_temp.expect_error(format(
        'insert into core.assessment_control (assessment_version_id, control_version_id, risk_factor_id, design_effectiveness_term_id, operating_effectiveness_term_id) values (%L, %L, %L, %L, %L)',
        v_av1, v_ctlv, v_rf1, ref.term_id('CONTROL_EFFECTIVENESS', 'SATISFACTORY'), ref.term_id('CONTROL_EFFECTIVENESS', 'SATISFACTORY')),
        'requires a past test date');
    perform pg_temp.expect_error(format(
        'insert into core.assessment_control (assessment_version_id, control_version_id, risk_factor_id, design_effectiveness_term_id, operating_effectiveness_term_id, last_tested_on) values (%L, %L, %L, %L, %L, current_date + 30)',
        v_av1, v_ctlv, v_rf1, ref.term_id('CONTROL_EFFECTIVENESS', 'SATISFACTORY'), ref.term_id('CONTROL_EFFECTIVENESS', 'SATISFACTORY')),
        'requires a past test date');

    insert into core.assessment_control (assessment_version_id, control_version_id, risk_factor_id,
                                         design_effectiveness_term_id, operating_effectiveness_term_id, last_tested_on)
    values (v_av1, v_ctlv, v_rf1, ref.term_id('CONTROL_EFFECTIVENESS', 'SATISFACTORY'),
            ref.term_id('CONTROL_EFFECTIVENESS', 'NEEDS_IMPROVEMENT'), current_date - 45)
    returning id into v_ac;

    ---------------------------------------------------------------------------
    -- Documents, extraction, evidence (synthetic store only)
    ---------------------------------------------------------------------------
    insert into core.document (document_type_term_id, title, change_request_id)
    values (ref.term_id('DOCUMENT_TYPE', 'PRODUCT_SPECIFICATION'), 'Instant payments spec (synthetic)', v_cr) returning id into v_doc;
    perform pg_temp.expect_error(format(
        'insert into core.document_version (document_id, file_name, mime_type, size_bytes, storage_uri, content_sha256) values (%L, ''spec.pdf'', ''application/pdf'', 1, ''s3://prod-bucket/spec.pdf'', %L)',
        v_doc, repeat('a', 64)),
        'ck_synthetic_storage');
    insert into core.document_version (document_id, file_name, mime_type, size_bytes, storage_uri, content_sha256)
    values (v_doc, 'spec.pdf', 'application/pdf', 1024, 'synthetic://fcrm-docs/spec-v1.pdf', repeat('a', 64)) returning id into v_docv;

    insert into core.extracted_field (document_version_id, field_key, value_text, confidence, source_locator,
                                      extractor_name, extractor_version)
    values (v_docv, 'target_corridors', 'SG, HK', 0.91, '{"page": 2}', 'doc-extractor', '1.0.0')
    returning id into v_field;
    perform pg_temp.assert((select review_status = 'pending' and not is_usable from core.extracted_field_current where extracted_field_id = v_field),
        'extracted field is unusable until reviewed');
    insert into core.extracted_field_review (extracted_field_id, outcome) values (v_field, 'confirmed');

    insert into core.evidence_link (assessment_version_id, risk_factor_id, document_version_id, extracted_field_id)
    values (v_av1, v_rf1, v_docv, v_field);
    insert into gov.lineage_edge (from_table, from_id, relation, to_table, to_id)
    values ('core.risk_factor', v_rf1, 'derived_from', 'core.extracted_field', v_field);

    ---------------------------------------------------------------------------
    -- Ratings: controls mitigate, never eliminate
    ---------------------------------------------------------------------------
    update core.assessment_version set record_status = 'active' where id = v_av1;
    perform set_config('fcrm.actor_id', 'svc:scoring-engine', true);

    insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id,
                             config_version_id, engine_version, inputs_sha256, origin)
    values (v_av1, 'inherent', 'calculated', 3.0, ref.term_id('RATING_LEVEL', 'HIGH'),
            v_cfg, '1.0.0', repeat('b', 64), 'system_derived')
    returning id into v_inh;
    insert into core.rating_input (rating_id, assessment_version_id, input_kind, risk_factor_id, input_value, weight, contribution, origin)
    values (v_inh, v_av1, 'risk_factor', v_rf1, '3.0', 0.6, 1.8, 'system_derived'),
           (v_inh, v_av1, 'risk_factor', v_rf2, '2.0', 0.6, 1.2, 'system_derived');

    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, control_mitigation) values (%L, ''residual'', ''calculated'', 2.0, %L, %L, ''1.0.0'', %L, 0.3)',
        v_av1, ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg, repeat('c', 64)),
        'ck_rating_basis');
    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, basis_rating_id, control_mitigation) values (%L, ''residual'', ''calculated'', 0.0001, %L, %L, ''1.0.0'', %L, %L, 1.0)',
        v_av1, ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg, repeat('c', 64), v_inh),
        'ck_mitigation_never_eliminates');
    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, basis_rating_id) values (%L, ''residual'', ''calculated'', 2.0, %L, %L, ''1.0.0'', %L, %L)',
        v_av1, ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg, repeat('c', 64), v_inh),
        'ck_mitigation_recorded');
    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, basis_rating_id, control_mitigation) values (%L, ''residual'', ''calculated'', 0, %L, %L, ''1.0.0'', %L, %L, 0.5)',
        v_av1, ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg, repeat('c', 64), v_inh),
        'rating_score_check');
    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, basis_rating_id, control_mitigation) values (%L, ''residual'', ''calculated'', 0.9, %L, %L, ''1.0.0'', %L, %L, 0.7)',
        v_av1, ref.term_id('RATING_LEVEL', 'LOW'), v_cfg, repeat('c', 64), v_inh),
        'below the floor');
    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, basis_rating_id, control_mitigation) values (%L, ''residual'', ''calculated'', 3.5, %L, %L, ''1.0.0'', %L, %L, 0.1)',
        v_av1, ref.term_id('RATING_LEVEL', 'HIGH'), v_cfg, repeat('c', 64), v_inh),
        'exceeds inherent score');
    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, basis_rating_id) values (%L, ''final'', ''calculated'', 2.0, %L, %L, ''1.0.0'', %L, %L)',
        v_av1, ref.term_id('RATING_LEVEL', 'HIGH'), v_cfg, repeat('c', 64), v_inh),
        'must be based on a residual');

    insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id,
                             engine_version, inputs_sha256, basis_rating_id, control_mitigation, origin)
    values (v_av1, 'residual', 'calculated', 1.8, ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg,
            '1.0.0', repeat('c', 64), v_inh, 0.4, 'system_derived')
    returning id into v_res;
    insert into core.rating_input (rating_id, assessment_version_id, input_kind, assessment_control_id, input_value, origin)
    values (v_res, v_av1, 'control', v_ac, '"NEEDS_IMPROVEMENT"', 'system_derived');
    perform pg_temp.assert(true, 'residual MODERATE from HIGH inherent with 40% mitigation accepted');

    ---------------------------------------------------------------------------
    -- Human challenge of a system output, with consequences
    ---------------------------------------------------------------------------
    perform set_config('fcrm.actor_id', 'user:analyst.alice@fcrm.example', true);

    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, rating_level_term_id, config_version_id, overrides_rating_id, override_justification) values (%L, ''inherent'', ''override'', %L, %L, %L, %L)',
        v_av1, ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg, v_inh, 'Corridor volumes are far below the questionnaire assumption.'),
        'ck_override_via_challenge');
    perform pg_temp.expect_error(format(
        'insert into core.challenge (subject_table, subject_id, challenged_aspect, reason, origin) values (''core.rating'', %L, ''rating_level'', ''Automated reviewer disagrees with the rating'', ''system_derived'')',
        v_inh),
        'ck_challenge_by_human');
    perform pg_temp.expect_error(format(
        'insert into core.challenge (subject_table, subject_id, challenged_aspect, reason) values (''core.rating'', %L, ''rating_level'', ''too high'')',
        v_inh),
        'challenge_reason_check');
    perform pg_temp.expect_error(format(
        'insert into core.challenge (subject_table, subject_id, challenged_aspect, reason) values (''core.policy'', %L, ''x'', ''Policies are not system outputs to challenge'')',
        gen_random_uuid()),
        'is not a challengeable table');

    insert into core.challenge (subject_table, subject_id, challenged_aspect, reason, proposed_value)
    values ('core.rating', v_inh, 'rating_level',
            'Synthetic corridor volumes are capped at a low value; the questionnaire overstates transaction exposure.',
            '{"rating_level": "MODERATE"}')
    returning id into v_chal;

    perform pg_temp.assert((select assessment_version_id = v_av1 from core.challenge where id = v_chal),
        'challenge located on its assessment version');
    perform pg_temp.assert(
        (select count(*) = 2
            and bool_or(consequence_kind = 'correct_subject' and target_id = v_inh)
            and bool_or(consequence_kind = 'recalculate_dependent' and target_id = v_res)
           from core.challenge_consequence where challenge_id = v_chal),
        'challenging the inherent rating flags it and the residual derived from it');

    perform pg_temp.expect_error(format(
        'insert into core.committee_review (change_request_id, assessment_version_id, quorum_required) values (%L, %L, 2)', v_cr, v_av1),
        'open challenge item');
    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, rating_level_term_id, config_version_id, overrides_rating_id, override_justification, challenge_id) values (%L, ''inherent'', ''override'', %L, %L, %L, %L, %L)',
        v_av1, ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg, v_inh, 'Corridor volumes are far below the questionnaire assumption.', v_chal),
        'must cite an upheld challenge');
    perform pg_temp.expect_error(format(
        'insert into core.challenge_resolution (challenge_id, outcome, rationale) values (%L, ''upheld'', ''I agree with myself on this one'')', v_chal),
        'someone other than the challenger');

    perform set_config('fcrm.actor_id', 'user:mlro.maria@fcrm.example', true);
    insert into core.challenge_resolution (challenge_id, outcome, rationale)
    values (v_chal, 'upheld', 'Volume caps are a hard product limit documented in the specification.');

    perform set_config('fcrm.actor_id', 'user:analyst.alice@fcrm.example', true);
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, note) values (%L, ''no_change_required'', ''Nothing to change here'')',
        (select id from core.challenge_consequence where challenge_id = v_chal and consequence_kind = 'correct_subject')),
        'must be corrected (superseded_by_new_record)');
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, note) values (%L, ''amended_in_draft'', ''Edited the rating in place'')',
        (select id from core.challenge_consequence where challenge_id = v_chal and consequence_kind = 'correct_subject')),
        'cannot be amended or withdrawn in a draft');

    insert into core.rating (assessment_version_id, rating_kind, method, rating_level_term_id, config_version_id,
                             overrides_rating_id, override_justification, challenge_id)
    values (v_av1, 'inherent', 'override', ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg, v_inh,
            'Upheld challenge: product volume caps reduce transaction exposure.', v_chal)
    returning id into v_inh2;

    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, basis_rating_id, control_mitigation) values (%L, ''residual'', ''calculated'', 1.5, %L, %L, ''1.0.0'', %L, %L, 0.4)',
        v_av1, ref.term_id('RATING_LEVEL', 'MODERATE'), v_cfg, repeat('d', 64), v_inh),
        'not the inherent rating currently in effect');
    perform pg_temp.expect_error(format(
        'insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id, engine_version, inputs_sha256, basis_rating_id, control_mitigation) values (%L, ''residual'', ''calculated'', 1.5, %L, %L, ''1.0.0'', %L, %L, 0.4)',
        v_av1, ref.term_id('RATING_LEVEL', 'HIGH'), v_cfg, repeat('d', 64), v_inh2),
        'cannot be higher than the inherent level');

    perform set_config('fcrm.actor_id', 'svc:scoring-engine', true);
    insert into core.rating (assessment_version_id, rating_kind, method, score, rating_level_term_id, config_version_id,
                             engine_version, inputs_sha256, basis_rating_id, control_mitigation, origin)
    values (v_av1, 'residual', 'calculated', 1.2, ref.term_id('RATING_LEVEL', 'LOW'), v_cfg,
            '1.0.0', repeat('d', 64), v_inh2, 0.4, 'system_derived')
    returning id into v_res2;
    insert into core.rating_input (rating_id, assessment_version_id, input_kind, assessment_control_id, input_value, origin)
    values (v_res2, v_av1, 'control', v_ac, '"NEEDS_IMPROVEMENT"', 'system_derived');

    perform set_config('fcrm.actor_id', 'user:analyst.alice@fcrm.example', true);
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, resulting_table, resulting_id, note) values (%L, ''superseded_by_new_record'', ''core.rating'', %L, ''Recalculated after override'')',
        (select id from core.challenge_consequence where challenge_id = v_chal and consequence_kind = 'recalculate_dependent'), v_inh2),
        'must be a later residual rating');

    insert into core.consequence_disposition (consequence_id, action, resulting_table, resulting_id, note)
    select id, 'superseded_by_new_record', 'core.rating',
           case consequence_kind when 'correct_subject' then v_inh2 else v_res2 end,
           'Handled by override and recalculation'
      from core.challenge_consequence where challenge_id = v_chal;

    -- Challenge of an extracted field: evidence and lineage are flagged; dismissed.
    insert into core.challenge (subject_table, subject_id, challenged_aspect, reason)
    values ('core.extracted_field', v_field, 'value', 'Extractor may have missed a third corridor listed in the annex.')
    returning id into v_chal2;
    perform pg_temp.assert(
        (select count(*) = 3
            and bool_or(target_table = 'core.evidence_link'::regclass)
            and bool_or(target_table = 'core.risk_factor'::regclass)
           from core.challenge_consequence where challenge_id = v_chal2),
        'challenging an extracted field flags the evidence and the factor derived from it');

    perform set_config('fcrm.actor_id', 'user:mlro.maria@fcrm.example', true);
    insert into core.challenge_resolution (challenge_id, outcome, rationale)
    values (v_chal2, 'dismissed', 'The annex lists a prospective corridor that is out of scope for launch.');
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, resulting_table, resulting_id, note) values (%L, ''superseded_by_new_record'', ''core.rating'', %L, ''Should not be allowed'')',
        (select id from core.challenge_consequence where challenge_id = v_chal2 and consequence_kind = 'correct_subject'), v_res2),
        'close as no_change_required');
    insert into core.consequence_disposition (consequence_id, action, note)
    select id, 'no_change_required', 'Challenge dismissed; field stands'
      from core.challenge_consequence where challenge_id = v_chal2;

    -- Upheld challenge of an extracted field: corrected by a human review, not a superseding record.
    perform set_config('fcrm.actor_id', 'user:analyst.alice@fcrm.example', true);
    insert into core.challenge (subject_table, subject_id, challenged_aspect, reason, proposed_value)
    values ('core.extracted_field', v_field, 'value', 'Specification v1 page 2 also lists MY as a launch corridor.', '{"value": "SG, HK, MY"}')
    returning id into v_chal2;
    perform set_config('fcrm.actor_id', 'user:mlro.maria@fcrm.example', true);
    insert into core.challenge_resolution (challenge_id, outcome, rationale)
    values (v_chal2, 'upheld', 'MY is listed as a launch corridor in the synthetic specification.');

    perform set_config('fcrm.actor_id', 'user:analyst.alice@fcrm.example', true);
    select id into v_cons from core.challenge_consequence where challenge_id = v_chal2 and consequence_kind = 'correct_subject';
    perform pg_temp.assert((select target_snapshot ->> 'value_text' = 'SG, HK' from core.challenge_consequence where id = v_cons),
        'consequence preserves the disputed state of its target');
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, note) values (%L, ''no_change_required'', ''Nothing to change here'')', v_cons),
        'corrected_by_review or superseded_by_new_record');
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, resulting_table, resulting_id, note) values (%L, ''superseded_by_new_record'', ''core.rating'', %L, ''Wrong kind of record'')',
        v_cons, v_res2),
        'superseded by a core.extracted_field row');
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, note) values (%L, ''withdrawn_in_draft'', ''Cannot withdraw'')', v_cons),
        'cannot be amended or withdrawn in a draft');

    insert into core.extracted_field_review (extracted_field_id, outcome) values (v_field, 'confirmed') returning id into v_rev;
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, resulting_table, resulting_id, note) values (%L, ''corrected_by_review'', ''core.extracted_field_review'', %L, ''Reconfirmed value'')',
        v_cons, v_rev),
        'does not correct it');
    insert into core.extracted_field_review (extracted_field_id, outcome, corrected_value_text)
    values (v_field, 'corrected', 'SG, HK, MY') returning id into v_rev;
    insert into core.consequence_disposition (consequence_id, action, resulting_table, resulting_id, note)
    values (v_cons, 'corrected_by_review', 'core.extracted_field_review', v_rev, 'Reviewer corrected the corridor list');
    perform pg_temp.assert(
        (select effective_value_text = 'SG, HK, MY' from core.extracted_field_current where extracted_field_id = v_field),
        'upheld extracted-field challenge closed by a corrective review');
    -- Dependents are on the active assessment version; a reassessment would carry the corridor change.
    insert into core.consequence_disposition (consequence_id, action, note)
    select id, 'no_change_required', 'Carried into the next assessment version'
      from core.challenge_consequence where challenge_id = v_chal2 and consequence_kind <> 'correct_subject';

    perform pg_temp.assert(
        (select count(*) = 0 from core.open_challenge_item where assessment_version_id = v_av1),
        'all challenge items on the assessment are closed');

    ---------------------------------------------------------------------------
    -- Policy corpus
    ---------------------------------------------------------------------------
    insert into core.policy (policy_code, policy_kind, issuing_body) values ('FCP-SANCTIONS', 'internal_policy', 'Synthetic Bank Financial Crime')
    returning id into v_pol;
    insert into core.policy_version (policy_id, title, version_label, effective_from)
    values (v_pol, 'Sanctions Policy (synthetic)', '4.0', date '2026-01-01') returning id into v_polv;
    insert into core.policy_clause (policy_version_id, clause_ref, heading, clause_text)
    values (v_polv, '5.1', 'Payment screening', 'All outbound cross-border payments must be screened before release.')
    returning id into v_clause;
    insert into core.policy_clause_tag values (v_polv, v_clause, ref.term_id('RISK_TYPOLOGY', 'TFS_TERRORISM'));
    perform pg_temp.expect_error(format('update core.policy_version set record_status = ''active'' where id = %L', v_polv),
        'ck_policy_version_approved');
    update core.policy_version set record_status = 'active', approved_by = 'user:mlro.maria@fcrm.example' where id = v_polv;
    perform pg_temp.expect_error(format('update core.policy_clause set clause_text = ''softened'' where id = %L', v_clause),
        'because it is active');

    ---------------------------------------------------------------------------
    -- Committee: votes and decision
    ---------------------------------------------------------------------------
    insert into core.committee_review (change_request_id, assessment_version_id, quorum_required)
    values (v_cr, v_av1, 2) returning id into v_review;

    perform set_config('fcrm.actor_id', 'user:member.a@fcrm.example', true);
    perform pg_temp.expect_error(format(
        'insert into core.vote (committee_review_id, voter_id, choice, rationale, origin) values (%L, ''user:member.a@fcrm.example'', ''approve'', ''ok'', ''ai_suggestion_accepted'')',
        v_review),
        'ck_vote_by_human');
    perform pg_temp.expect_error(format(
        'insert into core.vote (committee_review_id, voter_id, choice, rationale) values (%L, ''user:member.b@fcrm.example'', ''approve'', ''ok'')',
        v_review),
        'ck_vote_cast_by_voter');
    insert into core.vote (committee_review_id, voter_id, choice, rationale)
    values (v_review, 'user:member.a@fcrm.example', 'approve_with_conditions', 'Acceptable once screening is tuned.');

    perform pg_temp.expect_error(format(
        'insert into core.decision (committee_review_id, outcome, rationale) values (%L, ''approve'', ''x'')', v_review),
        'quorum not met');

    perform set_config('fcrm.actor_id', 'user:member.b@fcrm.example', true);
    insert into core.vote (committee_review_id, voter_id, choice, rationale)
    values (v_review, 'user:member.b@fcrm.example', 'approve_with_conditions', 'Agree, subject to screening tuning.');

    set constraints core.trg_conditions_present immediate;
    perform pg_temp.expect_error(format(
        'insert into core.decision (committee_review_id, outcome, rationale) values (%L, ''approve_with_conditions'', ''Approved subject to conditions'')',
        v_review),
        'has no conditions');
    set constraints core.trg_conditions_present deferred;

    insert into core.decision (committee_review_id, outcome, rationale)
    values (v_review, 'approve_with_conditions', 'Approved subject to conditions')
    returning id into v_dec;
    insert into core.condition (decision_id, condition_text, owner_id, due_date)
    values (v_dec, 'Tune sanctions screening fuzzy-match threshold for new corridors.', 'user:ops.omar@fcrm.example', date '2026-12-31');
    set constraints core.trg_conditions_present immediate;
    perform pg_temp.assert(true, 'approve_with_conditions decision with a condition passes the commit-time check');

    perform pg_temp.expect_error(format(
        'insert into core.vote (committee_review_id, voter_id, choice, rationale) values (%L, ''user:member.b@fcrm.example'', ''reject'', ''late'')',
        v_review),
        'already decided');

    -- A challenge after the decision flags the decision for revisiting.
    perform set_config('fcrm.actor_id', 'user:analyst.alice@fcrm.example', true);
    insert into core.challenge (subject_table, subject_id, challenged_aspect, reason)
    values ('core.assessment_control', v_ac, 'operating_effectiveness', 'Post-decision testing found the screening control was mis-tuned.')
    returning id into v_chal;
    perform pg_temp.assert(
        (select bool_or(consequence_kind = 'revisit_decision' and target_id = v_dec)
            and bool_or(consequence_kind = 'recalculate_dependent' and target_id = v_res2)
           from core.challenge_consequence where challenge_id = v_chal),
        'post-decision challenge flags the dependent residual and the decision');

    -- Upheld challenges of rows in a draft assessment version: amended or withdrawn in place.
    insert into core.assessment_version (assessment_id, change_request_id, change_request_version_id, analyst_id, config_version_id)
    values (v_asmt, v_cr, v_crv1, 'user:analyst.alice@fcrm.example', v_cfg)
    returning id into v_av2;
    insert into core.risk_factor (assessment_version_id, category_term_id, factor_code, response, factor_score, origin)
    values (v_av2, ref.term_id('RISK_FACTOR_CATEGORY', 'CHANNEL_NON_FACE_TO_FACE'), 'NON_FACE_TO_FACE', 'true', 2.0, 'system_derived')
    returning id into v_rf3;
    insert into core.evidence_link (assessment_version_id, risk_factor_id, document_version_id, note)
    values (v_av2, v_rf3, v_docv, 'Onboarding flow screenshots') returning id into v_ev2;

    insert into core.challenge (subject_table, subject_id, challenged_aspect, reason)
    values ('core.risk_factor', v_rf3, 'factor_score', 'Onboarding uses certified digital identity, which mitigates non-face-to-face risk.')
    returning id into v_chal;
    insert into core.challenge (subject_table, subject_id, challenged_aspect, reason)
    values ('core.evidence_link', v_ev2, 'relevance', 'The screenshots show the legacy flow, not the channel being launched.')
    returning id into v_chal2;
    perform set_config('fcrm.actor_id', 'user:mlro.maria@fcrm.example', true);
    insert into core.challenge_resolution (challenge_id, outcome, rationale)
    values (v_chal, 'partially_upheld', 'Digital identity is certified; the score should drop but not to the minimum.'),
           (v_chal2, 'upheld', 'The evidence is for the wrong flow and does not support the factor.');

    perform set_config('fcrm.actor_id', 'user:analyst.alice@fcrm.example', true);
    select id into v_cons from core.challenge_consequence where challenge_id = v_chal and consequence_kind = 'correct_subject';
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, note) values (%L, ''no_change_required'', ''Nothing to change here'')', v_cons),
        'amended_in_draft, withdrawn_in_draft or superseded_by_new_record');
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, note) values (%L, ''amended_in_draft'', ''Claimed but not done'')', v_cons),
        'has not been amended since the challenge');
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, note) values (%L, ''withdrawn_in_draft'', ''Claimed but not done'')', v_cons),
        'still exists');
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, resulting_table, resulting_id, note) values (%L, ''corrected_by_review'', ''core.extracted_field_review'', %L, ''Wrong mechanism'')',
        v_cons, v_rev),
        'are not corrected by review');

    update core.risk_factor set factor_score = 1.5, rationale = 'Certified digital identity at onboarding' where id = v_rf3;
    insert into core.consequence_disposition (consequence_id, action, note)
    values (v_cons, 'amended_in_draft', 'Score lowered in the draft assessment');

    select id into v_cons from core.challenge_consequence where challenge_id = v_chal2 and consequence_kind = 'correct_subject';
    delete from core.evidence_link where id = v_ev2;
    perform pg_temp.expect_error(format(
        'insert into core.consequence_disposition (consequence_id, action, note) values (%L, ''amended_in_draft'', ''Not amended, removed'')', v_cons),
        'disposition it as withdrawn_in_draft');
    insert into core.consequence_disposition (consequence_id, action, note)
    values (v_cons, 'withdrawn_in_draft', 'Irrelevant evidence removed from the draft');
    perform pg_temp.assert(
        (select count(*) = 0 from core.open_challenge_item where assessment_version_id = v_av2),
        'upheld challenges of draft rows closed by amendment and withdrawal');

    ---------------------------------------------------------------------------
    -- Lineage
    ---------------------------------------------------------------------------
    perform pg_temp.expect_error('truncate gov.lineage_edge', 'append-only');
end;
$$;

rollback;
\echo 'All data model tests passed.'
