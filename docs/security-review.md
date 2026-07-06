# MaluDB security review (S7-2)

Audit of the RLS / pgaudit / GRANT posture across the maludb_core
extension at version 0.40.0. Conducted 2026-05-13 against the live
catalog of the bench database (`maludb_bench`).

## Methodology

For every `malu$*` table the audit captured:

1. `pg_class.relrowsecurity` (RLS enabled?)
2. `pg_class.relforcerowsecurity` (RLS forced even for table owner?)
3. Count of attached `pg_policy` rows.
4. Per-role table grants from `information_schema.role_table_grants`.

Plus a check of `shared_preload_libraries` and `pgaudit.*` GUCs.

## Coverage at a glance

| Metric | Count |
|---|---:|
| Total `malu$*` tables | **87** |
| RLS enabled | **59** |
| RLS forced | **0** |
| RLS on **with at least one policy** | **59** |
| RLS on **with zero policies** (fail-closed bug) | **0** |

No table fails the basic "RLS-on but no policy" trap.

## RLS-disabled tables — by category

The 28 tables without RLS are intentional, not omissions:

| Category | Tables | Why no RLS |
|---|---|---|
| **Tier-A catalog (system seeds)** | `malu$object_type`, `malu$relationship_type`, `malu$source_type` | Globally shared roadmap rows. Read-only to `maludb_memory_{admin,executor,auditor}`. No tenant ownership concept. |
| **MC2DB catalog** | `malu$mc2db_server`, `malu$mc2db_tool` + 4 impl-kind tables, `malu$mc2db_invocation`, `malu$mc2db_prompt`, `malu$mc2db_resource` | Catalog rows are admin-managed; access mediated by the MC2DB dispatcher, not direct SQL. No memory-tier role grants on these tables. |
| **Vector substrate (R1.1)** | `malu$vector_chunk`, `malu$vector_compartment`, `malu$vector_demo`, `malu$vector_subject`, `malu$vector_verb`, `malu$ann_index`, `malu$ann_delta`, `malu$vector_tombstone` | Compartments are namespace-scoped through `search_memory_exact`. Direct table access is locked down (extension owner only for chunk/compartment/demo/subject/verb/ann_*; the LLM-tier roles have direct access only to `vector_tombstone`). |
| **System policy** | `malu$listener_config`, `malu$budget_policy`, `malu$retry_policy`, `malu$safety_policy`, `malu$partition` | Admin-only catalog rows. Not tenant-scoped. |
| **Identity & roles** | `malu$account`, `malu$account_role`, `malu$role` | Identity catalog shared across tenants. Granted to LLM-tier admin/executor/auditor for reflection. |

## RLS-enabled tables

All 59 RLS-enabled tables follow the **`tenant_owner` policy** pattern:

```sql
USING      (owner_schema = current_schema())
WITH CHECK (owner_schema = current_schema())
```

Cross-tenant visibility for Stage 2+ governed objects is mediated by
`malu$object_grant` (added in S2-5) layered via a second
**PERMISSIVE** `grant_visibility` policy that ORs additional rows
into the visible set. The two-policy pattern is verified on every
governed object table.

## Findings & recommendations

### Finding 1 — No FORCE ROW LEVEL SECURITY anywhere — **CLOSED (opt-in helper)**

**Status:** Closed by S7-2.b. `scripts/maludb-force-rls` discovers
every governed table programmatically (RLS enabled + `tenant_owner`
policy attached) and applies `ALTER TABLE … FORCE ROW LEVEL
SECURITY` to all of them. `--status` reports current state,
`--apply` enables, `--revert` rolls back. The current bench
catalog has **46 candidate tables** that get FORCE'd. Operators
keep it opt-in because FORCE breaks maintenance paths that read
across all tenants.

**Severity at time of review:** informational.
**Impact:** the extension owner (the role that ran `CREATE EXTENSION
maludb_core`) and any role with `BYPASSRLS` (incl. superuser) sees
all rows regardless of policy. This is the PostgreSQL default
behaviour for the table owner.

**Recommendation:** when a tenant truly cannot tolerate the extension
owner ever reading its rows (e.g., a multi-tenant SaaS posture),
operators MUST run the extension under a non-owner identity at
runtime. Alternatively, add `ALTER TABLE … FORCE ROW LEVEL SECURITY`
to the governed-object tables in a Stage 7 follow-up migration. For
v1 deployments this is acceptable because the extension owner IS
the operator.

### Finding 2 — `malu$mc2db_invocation` is not tenant-scoped — **CLOSED**

**Status:** Closed by S7-2.a (migration 0.40.0→0.41.0). The table
now has an `owner_schema name NOT NULL DEFAULT current_schema()`
column with a `tenant_owner` RLS policy. Existing rows backfilled
to `'maludb_core'`. Cross-tenant isolation verified by
`sql/mc2db_invocation_rls.sql`.

**Severity at time of review:** medium.
**Impact:** every MC2DB tool call lands a row here. Without RLS or
an `owner_schema` discriminator, a tenant with `SELECT` could see
other tenants' tool-call audit trail (argument hashes, result
hashes, tool definition versions). Today this is mitigated because
only the extension owner has any GRANT — but as soon as an operator
opens up read access for a self-service auditor role, leakage
becomes possible.

**Recommendation:** add an `owner_schema` column + tenant_owner
RLS in a follow-up. The mc2db dispatcher should populate
`owner_schema` from the calling session before INSERT.

### Finding 3 — `pgaudit` not preloaded by default — **CLOSED**

**Status:** Closed by S7-2.c. `scripts/maludb-bootstrap` section 3a
now uses `pg_conftool` to add `pgaudit` to
`shared_preload_libraries` and set
`pgaudit.log='write, ddl, role'`, then restarts
`postgresql@17-main`. Idempotent — skips if already configured.
`scripts/maludb-validate` section 3a checks both GUCs after install.

*Revised 2026-07-06: the original default was
`'read, write, ddl, role, function'`. `read` SESSION-logs every
SELECT; on the artfin deployment a 30-second e2e monitoring loop plus
test runs grew `postgresql-17-main.log` to 19GB and filled the disk
(weekly logrotate with `copytruncate` could no longer copy the file
once the disk was full, so rotation stopped entirely). The default is
now `'write, ddl, role'`, the same class set as the extension's
`pgaudit_recommended_settings()`. Deployments that need read or
function auditing for compliance should re-add those classes together
with a logrotate `maxsize` policy (e.g. `maxsize 500M`).*

**Severity at time of review:** medium.
**Impact:** `shared_preload_libraries` is empty in the audited
cluster. Per requirements.md §3.11/§6, MaluDB ships pgaudit as a
required dependency; the install scripts pull the package but don't
edit `postgresql.conf`. So pgaudit logs nothing until an operator
opts in.

**Recommendation:** `scripts/maludb-bootstrap` should, on first
install, run:

```bash
sudo -u postgres pg_conftool 17 main set \
  shared_preload_libraries 'pgaudit'
sudo -u postgres pg_conftool 17 main set \
  pgaudit.log 'read, write, ddl, role, function'
sudo systemctl restart postgresql@17-main
```

Acceptance: `SHOW pgaudit.log` returns non-empty after restart, and
a `CREATE TABLE` in any tenant schema logs an AUDIT line in
`/var/log/postgresql/postgresql-17-main.log`.

### Finding 4 — No `SECURITY DEFINER` privileged paths to audit

**Severity:** informational.
**Impact:** every helper that needs cross-tenant visibility (`graph_walk`,
`text_search`, `execute_retrieval`, `replay_episode`, `negotiate_local_model`)
runs `SECURITY INVOKER`. This is the correct posture — RLS handles
the per-tenant gating without privilege elevation — and it means
there's no `SECURITY DEFINER` attack surface to review.

### Finding 5 — Semantic-slice grants are uniform

The Stage 2+ governed-object grant pattern is consistent:

```sql
GRANT SELECT                  ON malu$<table> TO maludb_memory_{admin,executor,auditor};
GRANT INSERT, UPDATE, DELETE  ON malu$<table> TO maludb_memory_{admin,executor};
GRANT USAGE, SELECT ON SEQUENCE malu$<table>_<pk>_seq
                              TO maludb_memory_{admin,executor};
```

Auditor role is read-only across all governed tables. Admin and
executor can write. Tier-A catalog tables grant SELECT only — no
INSERT/UPDATE/DELETE to memory_* roles. The MC2DB dispatcher and
the model gateway use the LLM-tier role family (`maludb_llm_*`),
which is intentionally disjoint from memory_*.

No surprises in the grant matrix. The "semantic slice" doctrine
(roles named for their *capability* rather than their schema) is
holding.

## What was not in scope

- Live penetration testing.
- Network-layer hardening (TLS, listener policies).
- pg_hba.conf review.
- Backup encryption.
- The mc2dbd / maludb-modeld service-level authz.

Those belong to a deployment-time security review and are out of
scope for the in-DB audit.

## Follow-up tickets (proposed)

- **S7-2.a** — ✅ Closed by migration 0.40.0→0.41.0.
- **S7-2.b** — ✅ Closed by `scripts/maludb-force-rls` (opt-in helper
  with `--status`, `--apply`, `--revert` modes; idempotent;
  discovers tables programmatically via `tenant_owner` policy
  presence).
- **S7-2.c** — ✅ Closed; bootstrap and validate scripts updated.

These can land before public alpha; the current posture is acceptable
for early-adopter use as long as deployments install pgaudit manually.
