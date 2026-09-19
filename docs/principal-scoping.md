# Principals and scopes (0.106.0)

One tenant, many agents and people. Before 0.106.0 the engine isolated tenants
(`owner_schema`) and nothing inside one: whoever held the tenant's login read
everything, and the host application was the only thing keeping an agent out of
another department's memory. From 0.106.0 the engine can be told **who is
asking** and enforces that principal's reach itself.

## The model

| Thing | What it is |
|---|---|
| **Scope** | A namespace string — `agent:44`, `dept:3`, `org`. The same strings the vector layer has always used as `namespace`. A row with no scope reads as `default`. |
| **Principal** | A row in `maludb_principal`: `principal_ref` (the host's name for an agent or a person), kind, `home_scope` (where its own writes land when it names none), `max_sensitivity`, `enabled`. |
| **Grant** | `maludb_principal_scope`: a principal may `read` or `write` a scope. Write implies read. A principal always holds write on its `home_scope`. |
| **Session** | Three settings, normally `SET LOCAL` per request by the service in front of the engine. |

```sql
SELECT maludb_principal_upsert('agent:44', 'agent', 'Sasha', 'agent:44');
SELECT maludb_principal_grant_scope('agent:44', 'dept:3', 'read');

BEGIN;
SET LOCAL maludb_core.principal_ref = 'agent:44';
-- optional: narrow (never widen) what the grants allow, for this request only
SET LOCAL maludb_core.principal_scopes = '["agent:44", "dept:3"]';
-- optional: refuse every scoped write
SET LOCAL maludb_core.principal_readonly = 'on';
SELECT maludb_principal_whoami();   -- what this session is actually allowed
COMMIT;
```

**No principal set = unrestricted**, exactly the behaviour before 0.106.0 —
maintenance jobs, ingest pipelines and existing clients need no change. A
principal that is set but unknown or disabled gets nothing.

## What is enforced, and how

| Surface | Read | Write |
|---|---|---|
| `maludb_document`, `maludb_episode`, `maludb_chat_session` (+ messages), `maludb_memory_pool` (+ members, presence) | RESTRICTIVE row policy `principal_scope` | trigger |
| `maludb_memory`, `maludb_source_package` (views the extension owns; row security does not reach them) | the same predicate in the view | trigger |
| `maludb_memory_search`, `maludb_vector_search` | the namespace must be readable, else `insufficient_privilege`; hits whose source is above the ceiling are dropped | — |
| `maludb_memory_ingest_edge`, `maludb_memory_ingest_extraction`, `maludb_memory_request_extraction` | — | the namespace must be writable |
| `maludb_note_search` | document scope + source sensitivity | — |
| `maludb_semantic_search` | the card of a document / episode / memory / source the session cannot read is left out; an event subject stands for its episode | — |
| `maludb_principal_*`, skill principal grants | — | refused in any principal-bound session |

`sensitivity` (`public` < `internal` < `restricted` < `prohibited`) is compared
with the principal's `max_sensitivity`. A document takes its sensitivity from its
source package.

A row written by a principal-bound session is stamped with that principal
(`principal_ref`) whatever the caller supplies, and lands in its `home_scope`
unless it names a scope it may write.

### A document lives in the namespace of its first edge

`maludb_upload_document()` takes no scope. The first
`maludb_memory_ingest_edge(..., p_namespace => 'dept:3', p_document_id => …)`
gives the document (and its source package) the scope `dept:3` — if it has none,
or if its own author has just uploaded it and nothing is embedded yet. Anything
else keeps its scope; `maludb_set_scope(kind, id, scope)` moves a `document`,
`source_package`, `memory`, `episode`, `chat_session` or `pool` deliberately
(write on both the old and the new scope). The upgrade backfills documents whose
chunks all live in one namespace.

## Forgetting

```sql
SELECT maludb_forget_document(42);
-- {"chunks": 1, "statements": 1, "source_package": "deleted"}
SELECT maludb_forget_chunk(7);
```

The document, its vector chunks, the edges that carry its words and its source
package go (a source under legal hold refuses; one something else still cites is
kept and reported). Tombstoned chunks are filtered on all three search paths.

## Skills

`review_state` is separate from `enabled`; a skill resolves only when it is
enabled **and** approved. `maludb_skill_review(skill_id, 'approved' | 'rejected'
| 'proposed', reviewer, note)`; an author cannot review their own proposal.
`maludb_skill_grant_principal(skill_id, 'agent:44')` reserves a skill for named
principals (bound sessions only — the tenant still sees its own skills).
`maludb_skill_record_load(skill_id, run_ref, principal_ref)` →
`maludb_skill_load_event`.

## Pools

`maludb_presence_update(pool_name, kind, ref, role, declared_task, cursor, ttl)`
joins, heartbeats and moves the cursor in one call; `maludb_presence_leave`;
`maludb_presence_list(pool_name, include_left)` returns the cursor and TTL. A
principal is present as itself; a pool outside its scopes is not there.

## What this is not

- **Not a defence against the tenant's own login.** A client that connects as the
  tenant role can set the settings itself. They bind callers behind a service
  that sets them per request — the model `maludb_core.current_account_id` uses.
- **Not per-scope vocabulary.** Subjects, verbs and statements are shared across
  a tenant, so a bound principal can learn that a *name* exists.
- The role-based `maludb_memory_pool_access` table is still not consulted by
  anything; principals use scopes.

## Upgrading

```sql
ALTER EXTENSION maludb_core UPDATE TO '0.106.0';
SELECT * FROM maludb_core.enable_memory_schema('<tenant>');   -- every tenant: 165 -> 194 objects
```

Install the new shared library with the scripts (`make install`). Until
`enable_memory_schema` is re-run a tenant keeps its 0.105.3 facades, which keep
working.
