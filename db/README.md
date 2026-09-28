# FCRM Workbench: governed data model

PostgreSQL 16 schema for the FCRM Risk Assessment Workbench. The migrations use Flyway naming (`V###__name.sql`) and are plain SQL, so any migration runner can apply them in order.

| Migration | Contents |
|---|---|
| `V001__governance_foundation.sql` | Lifecycle enums, synthetic-data guards, column templates, immutability/versioning triggers, lineage graph |
| `V002__reference_taxonomies.sql` | Framework register, versioned taxonomies, term grounding and validation |
| `V003__core_change_requests_and_assessments.sql` | Change requests, assessments, risk factors, control library |
| `V004__policies_documents_and_evidence.sql` | Documents, extracted fields and reviews, policy corpus, evidence links |
| `V005__ratings_and_decisions.sql` | Ratings with explanation trace and mitigation rules, committee reviews, votes, decisions, conditions |
| `V006__seed_reference_taxonomies.sql` | Published frameworks and version 1 of the thirteen reference taxonomies |
| `V007__human_challenge_and_consequences.sql` | Human challenge of system outputs, consequence tracking, committee gates |
| `V008__immutable_audit_ledger.sql` | Append-only, hash-chained audit event ledger used by every component |

## Design constraints and how they are enforced

### 1. Risk decomposition is grounded in published frameworks

Every risk-related taxonomy term cites the provision it comes from. The sources were checked against the published text.

| Framework | Kind | Used for |
|---|---|---|
| FATF Recommendations (2012, updated June 2025) | International standard | Change types (R.15 "new products, business practices, delivery mechanisms, technologies"); typologies (R.3, R.5, R.6, R.7, INR.1); the 21 money-laundering predicate offences (Glossary: designated categories of offences) |
| EBA/GL/2021/02 ML/TF Risk Factors Guidelines | Supervisory guideline | Risk-factor categories and sub-factors (paragraph 1.22 and the Guideline 2 sections on customer, geography, products/services/transactions and delivery channel) |
| Wolfsberg Risk Assessment FAQs (2015) | Industry guidance | The inherent, control and residual method (section 6); the "other qualitative" factors (6.1.5); control categories and the satisfactory / needs improvement / deficient scale (6.2); override approval (6.2.1); the Low / Moderate / High scale and the rule that High inherent risk never becomes Low residual risk (6.3) |

- `ref.framework` and `ref.framework_provision` hold the sources. `ref.taxonomy_term_basis` links each term to its provisions, with a relationship of `defined_by`, `derived_from` or `aligned_with`.
- Taxonomies flagged `requires_framework_basis` can't be activated while any term lacks a citation. This applies to change types, risk-factor categories, typologies, control categories, control effectiveness and rating levels.
- `ref.active_term_grounding` shows every active term with its citations.
- Provisions inside EBA Guideline 2 are cited by section heading. The paragraph numbers within Guideline 2 couldn't be verified from the published text, so they aren't asserted.
- Transaction risk sits under "products, services and transactions", as it does in both EBA and Wolfsberg.

### 2. Controls mitigate risk and never eliminate it

These rules are enforced on `core.rating` for calculated ratings and human overrides alike:

- A residual rating must be based on the inherent rating currently in effect, and a final rating on the residual rating currently in effect.
- `control_mitigation`, the share of inherent risk offset by controls, must be at least 0 and strictly less than 1.
- Scores are strictly positive. A calculated residual score can't exceed its inherent score.
- A residual level can't be higher than the inherent level, or lower than that level's `min_residual_ordinal`. With the seeded scale, High inherent risk can be reduced to Moderate at most.
- A control evaluation can only be rated better than `DEFICIENT` if it has a test date in the past. A planned remediation doesn't count as mitigation (Wolfsberg 6.2).

To lower residual risk, a human has to challenge the inherent rating or the control evidence. The mitigation limits can't be bypassed.

### 3. A human can disagree with any system output, record why, and have the consequences handled

1. **Challenge.** `core.challenge` records the human's disagreement with any row in a table registered in `core.challengeable_table`: ratings, rating inputs, risk factors, control evaluations, evidence links and extracted fields. It needs a reason of at least 20 characters and must come from a human (`origin = user_entry`).
2. **Consequences.** `core.challenge_consequence` is generated automatically. It covers the subject itself, the ratings in effect that were derived from it (through rating inputs and basis chains), evidence built on it, records derived from it in the lineage graph, and any decision already taken on an affected assessment.
3. **Resolution.** `core.challenge_resolution` upholds or dismisses the challenge. It must be made by someone other than the challenger (four-eyes, Wolfsberg 6.2.1).
4. **Disposition.** `core.consequence_disposition` closes each consequence. If the challenge is dismissed, everything closes as `no_change_required`. If it's upheld, the challenged record must be corrected in the way `core.challengeable_table.correction_method` sets for its table:

   | Method | Tables | Accepted corrections |
   |---|---|---|
   | `new_record` | ratings, rating inputs | `superseded_by_new_record`, meaning a later rating of the same kind |
   | `review_record` | extracted fields | `corrected_by_review`, meaning the field's latest review, which corrects or rejects it; or `superseded_by_new_record` by a re-extraction |
   | `draft_amendment` | risk factors, control evaluations, evidence links | `amended_in_draft` or `withdrawn_in_draft` while the assessment version is draft; or `superseded_by_new_record`, e.g. in a new assessment version |

   Every correction is checked. A superseding record must be in the registered table and created after the challenge. A corrective review must review the challenged row. An amendment must differ from `target_snapshot`, the copy of the row taken when the consequence was raised. A withdrawal requires that the row is gone.
5. **Gates.** While `core.open_challenge_item` has rows for an assessment version, it can't go to committee or be decided. The committee also requires that the residual rating in effect is derived from the inherent rating in effect, so it can't be stale.

A rating override must cite an upheld challenge of the rating it replaces.

### 4. Synthetic data only; no connection to any real system

- **Principal ids.** `gov.principal_id` only accepts `system:`, `role:` and `svc:` accounts, or `user:<name>@<host>` on the reserved `.example`, `.test` or `.invalid` domains (RFC 2606 and RFC 6761). It's used for every person column.
- **Source systems.** `source_system` must be `fcrm-workbench` or `synthetic-<name>`. There is no origin value for imports from operational systems.
- **Document storage.** Storage URIs must use the `synthetic://` scheme.
- **Public reference material.** ISO country codes and published framework citations (including their public URLs) aren't customer or system data. The database only stores the URLs and never connects to them.

### 5. Every change is an append-only, hash-chained audit event

`audit.event` is the ledger every later component writes to. Updates and deletes of business data become new events; nothing in the ledger is changed in place.

- **Row changes.** Every insert, update and delete on a table in a governed schema (`gov`, `ref`, `core`) is captured by trigger: actor, database role, time, the row before and after, the changed columns, the reason and the correlation id. Tables created later in those schemas are enrolled automatically. Column templates (`gov.tmpl_*`) are exempt.
- **Domain events.** Components record facts that are not row changes with `audit.record_event('workflow.transitioned', '{"from":"draft","to":"submitted"}', 'core.change_request', id, 'reason')`. Event types under `audit.` are reserved for the ledger itself.
- **Sealing.** Captured events wait in `audit.pending_event` until the transaction commits. A deferred trigger then appends them to `audit.event` in capture order, each with the next gapless `seq` and `event_hash = sha256` of its canonical form (`fcrm-audit-v1`), which includes the previous event's hash. A rolled-back transaction leaves no events.
- **Tamper evidence.** `audit.event` rejects `UPDATE`, `DELETE` and `TRUNCATE`, and accepts an `INSERT` only from the sealer. `audit.verify_chain()` recomputes every hash and link. `audit.take_anchor()` records the chain head; copy the result outside the database so a rewrite of the whole chain is still detectable. Ledger triggers are `ENABLE ALWAYS`, so `session_replication_role = replica` does not bypass capture or immutability. Event triggers enrol new tables and reject DDL that would drop, disable or weaken capture or protection.
- **Coverage.** `audit.coverage` lists every governed or enrolled table. `audit.coverage_gap` and `audit.assert_coverage()` report anything that would let a change escape the ledger. Rows that existed before V008 are recorded as `row_baseline` events so the trail is complete from the first record.
- **Read path.** `audit.row_history(table, id)` and `audit.events_for(correlation_id)` return sealed events oldest-first. Application roles need no write privileges on ledger tables: capture, sealing and `record_event` run as the ledger owner. Read grants for analysts and examiners come with the identity module (step 3).

## Schemas

- `gov`: governance infrastructure shared by every table
- `ref`: frameworks and controlled reference taxonomies
- `core`: FCRM domain data
- `audit`: immutable hash-chained event ledger written to by every component

## Record kinds

Every table is one of three kinds, and triggers enforce the rules.

- **Identity** tables (`core.change_request`, `core.assessment`, `core.control`, `core.policy`, `core.document`, `ref.taxonomy`, `ref.framework`) hold the stable identity of a business object. They are insert-only.
- **Versioned** tables (`*_version`) hold an object's content at a point in time.
  - `version_no` and `supersedes_id` are assigned automatically on insert.
  - A version can be edited or deleted only while it is `draft`.
  - Once `active`, its content is frozen. The only allowed changes are `active -> superseded` and `active -> retired`.
  - At most one version per object is `active`.
  - Child rows (risk factors, clauses, terms, term citations, scope) can be written only while their parent version is `draft`.
- **Append-only** tables (ratings, rating inputs, challenges and their consequences, resolutions and dispositions, votes, decisions, conditions and their events, document versions, extracted fields and reviews, lineage edges) are never updated or deleted. `TRUNCATE` is blocked too. Their `seq` column gives the insertion order, since `created_at` is shared by rows written in the same transaction.

## Standard governance columns

Versioned tables include `gov.tmpl_versioned`:

| Column | Meaning |
|---|---|
| `version_no`, `supersedes_id` | Version sequence and link to the previous version |
| `record_status`, `status_changed_at`, `status_changed_by` | Lifecycle state and who changed it, and when |
| `owner_id` | Accountable data owner |
| `data_classification` | `internal` / `confidential` / `restricted` |
| `origin` | How the row came to exist, e.g. `user_entry`, `system_derived`, `document_extraction`, `ai_suggestion_accepted`, `synthetic_generation` |
| `source_system`, `source_ref` | Originating (synthetic) system and its record id |
| `correlation_id` | Workflow instance or audit event that produced the row |
| `change_reason` | Why this version was created |
| `created_at/by`, `updated_at/by` | Who created the row, and who last edited it while it was a draft |

Append-only tables include the subset in `gov.tmpl_append_only`.

### Acting principal

Audit columns default to the session setting `fcrm.actor_id`. The application must set it in every transaction:

```sql
begin;
set local fcrm.actor_id = 'user:analyst.alice@fcrm.example';
-- writes ...
commit;
```

If it isn't set, writes fail the `NOT NULL` check on `created_by`. A non-synthetic identity fails `ck_synthetic_principal`.

Optional session settings consumed by the audit ledger (also `SET LOCAL` per transaction):

```sql
set local fcrm.change_reason  = 'Product owner submitted the request';
set local fcrm.correlation_id = '11111111-1111-1111-1111-111111111111';
```

## Traceability rules enforced in the database

- **Reference by exact version.** Business rows point at a specific taxonomy term row, so the taxonomy version in force is pinned. `ref.check_term_refs` verifies that each term belongs to the expected taxonomy and to its active version.
- **Consistent cross-object links.** Composite foreign keys make sure, for example, that an assessment version assesses a version of its own change request, and that rating inputs and evidence come from the same assessment version.
- **Ratings run only on frozen inputs.** A rating can only be inserted for an `active` assessment version, and it must carry that version's `config_version_id`.
- **Calculated ratings are reproducible.** They need `score`, `engine_version`, `inputs_sha256` and an `explanation` trace, and their inputs are listed in `core.rating_input`.
- **Overrides go through a challenge.** An override is a new rating of the same kind as the one it replaces. It must be entered by a human, carry a justification of at least 20 characters, and cite an upheld challenge. The overridden rating is kept.
- **Extracted fields need human review.** They can't be used until a human review confirms or corrects them (`core.extracted_field_current.is_usable`).
- **Humans decide.** Votes and decisions must have origin `user_entry`, and a vote can only be cast by the voter. A decision requires the quorum of recorded votes. `approve_with_conditions` requires at least one condition, checked at commit. No votes are accepted after a decision.
- **Citations are stable.** A citation references a clause row, which is frozen once its policy version is active.
- **Generic lineage.** `gov.lineage_edge` records derivations that have no typed foreign key. Challenges follow it to find affected records.

## Reference taxonomies

Seeded as active version 1:

- **Grounded** (every term cites a provision): `CHANGE_REQUEST_TYPE`, `RISK_FACTOR_CATEGORY`, `RISK_TYPOLOGY`, `CONTROL_CATEGORY`, `CONTROL_EFFECTIVENESS`, `RATING_LEVEL`
- **Internal classifications:** `GEOGRAPHY`, `CUSTOMER_SEGMENT`, `CHANNEL`, `PRODUCT_CATEGORY`, `CONTROL_TYPE`, `CONTROL_NATURE`, `DOCUMENT_TYPE`

`GEOGRAPHY` has the region hierarchy and a starter set of countries. The full ISO 3166-1 list should be loaded as version 2.

Scores and thresholds (for example country risk, or how much "needs improvement" offsets) are not held in taxonomies. They belong to the versioned scoring configuration (step 3), which must keep every mitigation factor below 100%.

To revise a taxonomy:

1. Insert a new draft `ref.taxonomy_version`.
2. Add its terms with their `ref.taxonomy_term_basis` citations, setting `supersedes_term_id` to the equivalent term in the previous version.
3. In one transaction, mark the old version `superseded`, then mark the new one `active`.

Enums are used only for values that application logic depends on: vote choices, decision outcomes, rating kinds and methods, challenge outcomes and condition statuses.

## Integration points for later steps

- `config_version_id` (on `core.assessment_version` and `core.rating`) and `intake_form_version_id` (on `core.change_request_version`) will reference the configuration store from step 3. That migration adds the foreign keys.
- Principal ids are synthetic identities in the `gov.principal_id` domain. Step 3 can add foreign keys to its user table.
- AI suggestions (step 7) should register their table in `core.challengeable_table` so humans can challenge them.
- `correlation_id` on a row and on `audit.event` is the same workflow instance. Set `fcrm.correlation_id` in the session so every captured change and `audit.record_event()` call in the transaction carries it. Look up with `audit.events_for(correlation_id)` and `audit.row_history(table, id)`.
- Later components record non-row facts (workflow transitions, AI suggestions, examiner exports) with `audit.record_event()`. Row changes in `gov`, `ref` and `core` are captured automatically.

## Running locally

```powershell
createdb fcrm
Get-ChildItem db\migrations\V*.sql | Sort-Object Name | ForEach-Object { psql -d fcrm -v ON_ERROR_STOP=1 -1 -f $_.FullName }
psql -d fcrm -v ON_ERROR_STOP=1 -f db\tests\test_data_model.sql
psql -d fcrm -v ON_ERROR_STOP=1 -f db\tests\test_audit_ledger.sql
```

The test scripts run inside a transaction that is rolled back, so they leave no data behind. `V008` creates event triggers and must be applied by a superuser (`rds_superuser` on RDS).
