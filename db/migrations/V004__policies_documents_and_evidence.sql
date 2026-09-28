-- =============================================================================
-- V004  Policy corpus, submitted documents, extracted fields, evidence links
--
-- Policies are versioned and split into citable clauses. A clause row belongs
-- to exactly one policy version and is frozen once that version is active, so a
-- citation (clause id) always resolves to the exact wording that was cited.
--
-- Documents are stored by reference (storage_uri) with a content hash. Every
-- upload is a new immutable document_version.
--
-- Extracted fields are machine output. They take effect only after a human
-- review is recorded in extracted_field_review.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Documents
-- -----------------------------------------------------------------------------
create table core.document (
    id                    uuid primary key default gen_random_uuid(),
    document_type_term_id uuid not null references ref.taxonomy_term (id),
    title                 text not null,
    change_request_id     uuid references core.change_request (id),
    like gov.tmpl_identity including all
);
comment on table  core.document is 'Identity of a document (submission artefact or policy source). Insert-only.';
comment on column core.document.change_request_id is 'Change request the document was submitted for; null for corpus documents.';

create index ix_document_change_request on core.document (change_request_id);

create trigger trg_append_only before update or delete on core.document
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.document
    for each statement execute function gov.forbid_mutation();
create trigger trg_term_refs before insert on core.document
    for each row execute function ref.check_term_refs('document_type_term_id', 'DOCUMENT_TYPE');

create table core.document_version (
    id             uuid primary key default gen_random_uuid(),
    document_id    uuid    not null references core.document (id),
    version_no     integer not null check (version_no > 0),
    supersedes_id  uuid references core.document_version (id),
    file_name      text    not null,
    mime_type      text    not null,
    size_bytes     bigint  not null check (size_bytes >= 0),
    storage_uri    text    not null constraint ck_synthetic_storage check (storage_uri ~ '^synthetic://[A-Za-z0-9._~/-]+$'),
    content_sha256 text    not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
    like gov.tmpl_append_only including all,
    unique (document_id, version_no)
);
comment on table  core.document_version is 'Immutable upload of a document. created_by/created_at record who uploaded it and when.';
comment on column core.document_version.storage_uri is 'Location in the synthetic document store (synthetic:// scheme only; no real storage systems).';
comment on column core.document_version.content_sha256 is 'SHA-256 of the stored bytes; used to prove the file has not changed.';

create index ix_document_version_hash on core.document_version (content_sha256);

create trigger trg_a_assign_version before insert on core.document_version
    for each row execute function gov.assign_version('document_id');
create trigger trg_append_only before update or delete on core.document_version
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.document_version
    for each statement execute function gov.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Extracted fields (document extraction output) and their human review
-- -----------------------------------------------------------------------------
create table core.extracted_field (
    id                  uuid primary key default gen_random_uuid(),
    document_version_id uuid    not null references core.document_version (id),
    field_key           text    not null,
    value_text          text,
    value_json          jsonb,
    confidence          numeric(5, 4) not null check (confidence between 0 and 1),
    source_locator      jsonb   not null check (jsonb_typeof(source_locator) = 'object'),
    extractor_name      text    not null,
    extractor_version   text    not null,
    like gov.tmpl_append_only including all,
    check (value_text is not null or value_json is not null)
);
alter table core.extracted_field alter column origin set default 'document_extraction';

comment on table  core.extracted_field is 'Field proposed by document extraction. Not usable until confirmed or corrected by a reviewer.';
comment on column core.extracted_field.source_locator is 'Where in the document the value was found, e.g. {"page": 3, "char_start": 120, "char_end": 164}.';
comment on column core.extracted_field.correlation_id is 'Audit ledger id of the AI suggestion event that produced the field.';

create index ix_extracted_field_document on core.extracted_field (document_version_id, field_key);

create trigger trg_append_only before update or delete on core.extracted_field
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.extracted_field
    for each statement execute function gov.forbid_mutation();

create type core.review_outcome as enum ('confirmed', 'corrected', 'rejected');

create table core.extracted_field_review (
    id                   uuid primary key default gen_random_uuid(),
    extracted_field_id   uuid not null references core.extracted_field (id),
    outcome              core.review_outcome not null,
    corrected_value_text text,
    corrected_value_json jsonb,
    comment              text,
    like gov.tmpl_append_only including all,
    constraint ck_review_correction_has_value
        check (outcome <> 'corrected' or corrected_value_text is not null or corrected_value_json is not null),
    constraint ck_review_value_only_when_corrected
        check (outcome = 'corrected' or (corrected_value_text is null and corrected_value_json is null)),
    constraint ck_review_by_human check (origin = 'user_entry')
);
comment on table core.extracted_field_review is 'Human decision on an extracted field. The latest review wins. created_by is the reviewer.';

create index ix_extracted_field_review_field on core.extracted_field_review (extracted_field_id, seq desc);

create trigger trg_append_only before update or delete on core.extracted_field_review
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.extracted_field_review
    for each statement execute function gov.forbid_mutation();

create view core.extracted_field_current as
select f.id as extracted_field_id,
       f.document_version_id,
       f.field_key,
       f.confidence,
       coalesce(r.outcome::text, 'pending')                                  as review_status,
       case r.outcome when 'corrected' then r.corrected_value_text else f.value_text end as effective_value_text,
       case r.outcome when 'corrected' then r.corrected_value_json else f.value_json end as effective_value_json,
       r.created_by                                                          as reviewed_by,
       r.created_at                                                          as reviewed_at,
       coalesce(r.outcome in ('confirmed', 'corrected'), false)              as is_usable
  from core.extracted_field f
  left join lateral (
        select * from core.extracted_field_review rv
         where rv.extracted_field_id = f.id
         order by rv.seq desc
         limit 1) r on true;
comment on view core.extracted_field_current is 'Each extracted field with its latest human review; is_usable is true only after confirmation or correction.';

-- -----------------------------------------------------------------------------
-- Policy corpus
-- -----------------------------------------------------------------------------
create type core.policy_kind as enum ('internal_policy', 'procedure', 'standard', 'regulation', 'regulatory_guidance');

create table core.policy (
    id            uuid primary key default gen_random_uuid(),
    policy_code   text not null unique check (policy_code ~ '^[A-Z0-9][A-Z0-9_\-\.]*$'),
    policy_kind   core.policy_kind not null,
    issuing_body  text not null,
    like gov.tmpl_identity including all
);
comment on table core.policy is 'Identity of an internal policy, procedure or external regulatory source. Insert-only.';

create trigger trg_append_only before update or delete on core.policy
    for each row execute function gov.forbid_mutation();
create trigger trg_no_truncate before truncate on core.policy
    for each statement execute function gov.forbid_mutation();

create table core.policy_version (
    id                         uuid primary key default gen_random_uuid(),
    policy_id                  uuid not null references core.policy (id),
    title                      text not null,
    version_label              text not null,
    effective_from             date not null,
    effective_to               date,
    source_document_version_id uuid references core.document_version (id),
    approved_by                gov.principal_id,
    like gov.tmpl_versioned including all,
    unique (policy_id, version_no),
    unique (policy_id, version_label),
    foreign key (supersedes_id) references core.policy_version (id),
    check (effective_to is null or effective_to > effective_from),
    constraint ck_policy_version_approved check (record_status = 'draft' or approved_by is not null)
);
comment on table  core.policy_version is 'A version of a policy or regulation. Clauses are frozen once active.';
comment on column core.policy_version.version_label is 'Version label used by the issuer, e.g. "3.1" or "2026-04".';
comment on column core.policy_version.approved_by   is 'Who approved the policy version for use in the workbench.';

create unique index ux_policy_version_one_active
    on core.policy_version (policy_id) where record_status = 'active';

create trigger trg_a_assign_version before insert on core.policy_version
    for each row execute function gov.assign_version('policy_id');
create trigger trg_b_guard_version before insert or update or delete on core.policy_version
    for each row execute function gov.guard_versioned_row();

create table core.policy_clause (
    id                   uuid primary key default gen_random_uuid(),
    policy_version_id    uuid    not null references core.policy_version (id),
    clause_ref           text    not null,
    heading              text,
    clause_text          text    not null check (length(trim(clause_text)) > 0),
    parent_clause_id     uuid,
    ordinal              integer not null default 0,
    supersedes_clause_id uuid references core.policy_clause (id),
    like gov.tmpl_identity including all,
    unique (policy_version_id, clause_ref),
    unique (policy_version_id, id),
    foreign key (policy_version_id, parent_clause_id) references core.policy_clause (policy_version_id, id),
    check (parent_clause_id is distinct from id)
);
comment on table  core.policy_clause is 'Citable unit of a policy version.';
comment on column core.policy_clause.clause_ref           is 'Issuer''s clause number, e.g. "4.2.1".';
comment on column core.policy_clause.supersedes_clause_id is 'Equivalent clause in the previous policy version.';

create trigger trg_guard_child before insert or update or delete on core.policy_clause
    for each row execute function gov.guard_child_of_draft('core.policy_version', 'policy_version_id');

create table core.policy_clause_tag (
    policy_version_id uuid not null,
    policy_clause_id  uuid not null,
    taxonomy_term_id  uuid not null references ref.taxonomy_term (id),
    like gov.tmpl_identity including all,
    primary key (policy_clause_id, taxonomy_term_id),
    foreign key (policy_version_id, policy_clause_id) references core.policy_clause (policy_version_id, id)
);
comment on table core.policy_clause_tag is 'Classifies clauses by typology, risk-factor category, geography etc. for retrieval.';

create index ix_policy_clause_tag_term on core.policy_clause_tag (taxonomy_term_id);

create trigger trg_guard_child before insert or update or delete on core.policy_clause_tag
    for each row execute function gov.guard_child_of_draft('core.policy_version', 'policy_version_id');
create trigger trg_term_refs before insert or update on core.policy_clause_tag
    for each row execute function ref.check_term_refs(
        'taxonomy_term_id', 'RISK_TYPOLOGY|RISK_FACTOR_CATEGORY|GEOGRAPHY|CUSTOMER_SEGMENT|CHANNEL|PRODUCT_CATEGORY|CHANGE_REQUEST_TYPE');

create view core.policy_clause_active as
select p.policy_code,
       p.policy_kind,
       p.issuing_body,
       pv.id            as policy_version_id,
       pv.version_label,
       pv.title         as policy_title,
       pv.effective_from,
       pv.effective_to,
       c.id             as policy_clause_id,
       c.clause_ref,
       c.heading,
       c.clause_text,
       c.ordinal
  from core.policy p
  join core.policy_version pv on pv.policy_id = p.id and pv.record_status = 'active'
  join core.policy_clause c   on c.policy_version_id = pv.id;
comment on view core.policy_clause_active is 'Clauses of every active policy version: the governed retrieval corpus.';

-- -----------------------------------------------------------------------------
-- Evidence supporting a risk factor or control evaluation
-- -----------------------------------------------------------------------------
create table core.evidence_link (
    id                    uuid primary key default gen_random_uuid(),
    assessment_version_id uuid not null references core.assessment_version (id),
    risk_factor_id        uuid,
    assessment_control_id uuid,
    document_version_id   uuid not null references core.document_version (id),
    extracted_field_id    uuid references core.extracted_field (id),
    locator               jsonb check (locator is null or jsonb_typeof(locator) = 'object'),
    note                  text,
    like gov.tmpl_append_only including all,
    foreign key (assessment_version_id, risk_factor_id)        references core.risk_factor (assessment_version_id, id),
    foreign key (assessment_version_id, assessment_control_id) references core.assessment_control (assessment_version_id, id),
    check (num_nonnulls(risk_factor_id, assessment_control_id) <= 1)
);
comment on table core.evidence_link is
    'Document evidence for a risk factor, a control evaluation, or (when both are null) the assessment version as a whole.';

create index ix_evidence_link_assessment on core.evidence_link (assessment_version_id);

create function core.check_evidence_field_document() returns trigger
    language plpgsql
as $$
begin
    if new.extracted_field_id is not null and not exists (
        select 1 from core.extracted_field f
         where f.id = new.extracted_field_id and f.document_version_id = new.document_version_id) then
        raise exception 'core.evidence_link: extracted field % does not belong to document version %',
            new.extracted_field_id, new.document_version_id;
    end if;
    return new;
end;
$$;

create trigger trg_guard_child before insert or update or delete on core.evidence_link
    for each row execute function gov.guard_child_of_draft('core.assessment_version', 'assessment_version_id');
create trigger trg_field_document before insert or update on core.evidence_link
    for each row execute function core.check_evidence_field_document();
