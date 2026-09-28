# Team handoff

Governed FCRM Risk Assessment Workbench. Foundations first, then UI. There is no web UI or API yet.

## Done

| Step | To-do | What shipped |
|---|---|---|
| 1 | `data-model` | Versioned domain model, taxonomies, lineage (`V001`–`V006`) |
| 1b | (in `V007`) | Human challenge, consequences, committee gates |
| 2 | `audit` | Append-only, hash-chained ledger (`V008`). Every later component writes here. |

## Next (in this order)

| Step | To-do | What to build |
|---|---|---|
| 3 | `config-rbac` | Roles (Product Owner, FCRM Analyst, Committee Member, Examiner) and versioned maker-checker config for scoring weights, questionnaires, and workflow rules. **First API.** |
| 4 | `workflow` | Dynamic intake form and state machine (Draft → Submitted → Triage → In Assessment → Analyst Review → Committee → Decided). **First web UI.** |
| 5 | `scoring` | Deterministic inherent / residual engine with explanation trace. AI must not produce the score. |
| 6 | `corpus` | Versioned policies and submitted documents, split into citable clauses and indexed for retrieval. |
| 7 | `ai-assist` | Extract, retrieve, draft — suggestions only; human accept / edit / reject is logged to the ledger. |
| 8 | `committee` | Pack, vote, quorum, conditions. Only humans may move a request to Decided. |
| 9 | `examiner` | One-click examiner pack and cycle-time / override / AI-acceptance dashboards. |

Release 1 is steps 1–5 (usable workbench, no AI). Release 2 is 6–7. Release 3 is 8–9.

## Continue in Cursor

This chat and the original Cursor plan stay on the author's machine. The repo is the shared source of truth.

1. Clone [fcrm-risk-workbench](https://github.com/R-ObleaRa/fcrm-risk-workbench) (you need collaborator access).
2. **File → Open Folder** on that clone.
3. Open **Agent** chat (`Ctrl+L`). Attach this file with `@HANDOFF.md`.
4. Paste the prompt below. Change only the to-do id if you are not on the next pending step.

```
Read HANDOFF.md and db/README.md. Implement the next to-do: config-rbac — roles (Product Owner, FCRM Analyst, Committee Member, Examiner) and versioned maker-checker configuration for scoring weights, questionnaires, and workflow rules. Follow the existing PostgreSQL migration style (next unused V###). Do not skip ahead to workflow or AI. After you finish, update the Done / Next tables in HANDOFF.md.
```

5. When the step is done: commit, push, and leave `HANDOFF.md` updated so the next person can repeat from step 3.

There is no web UI or `npm start` until `workflow` (step 4). Until then, verify with the `psql` commands below.

## How to run the database

PostgreSQL 16. `V008` needs a superuser (`rds_superuser` on RDS) because it creates event triggers.

```powershell
createdb fcrm
Get-ChildItem db\migrations\V*.sql | Sort-Object Name | ForEach-Object {
  psql -d fcrm -v ON_ERROR_STOP=1 -1 -f $_.FullName
}
psql -d fcrm -v ON_ERROR_STOP=1 -f db\tests\test_data_model.sql
psql -d fcrm -v ON_ERROR_STOP=1 -f db\tests\test_audit_ledger.sql
```

Set these in every write transaction:

```sql
set local fcrm.actor_id        = 'user:analyst.alice@fcrm.example';
set local fcrm.change_reason   = 'Why this change is being made';
set local fcrm.correlation_id  = '11111111-1111-1111-1111-111111111111';
```

Row changes in `gov`, `ref`, and `core` are captured automatically. Non-row facts use `audit.record_event()`.

## Integration notes for step 3

- `config_version_id` and `intake_form_version_id` are placeholders; add foreign keys when the config store exists.
- `gov.principal_id` is a synthetic identity domain; step 3 can add FKs to a user table.
- Ledger read grants for analysts and examiners belong in the identity module.
- New tables in `gov`, `ref`, or `core` are enrolled in the ledger automatically.
