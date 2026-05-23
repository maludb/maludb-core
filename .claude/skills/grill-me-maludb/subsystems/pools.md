# Subsystem: Active memory pools

A transient working-set: accumulate observations during a task, promote the good
ones to claims/facts, then seal. Open when grilling reveals a "scratch workspace"
or "investigation thread" pattern. Confirm signatures against `maludb_core--0.73.0.sql`.

Match: "working set", "investigation thread", "session context", "gather then
commit", "collect findings before deciding", "incident workspace".

NOT this if data is committed directly without a gathering phase → just write
claims/facts.

## Lifecycle
`live → sealed → archived → tombstoned` (only sealing rejects new writes).

## Functions
- `create_active_memory_pool(p_pool_name, p_creation_kind, p_task_objective, p_authorized_partitions[], p_confidence_floor, p_max_member_count)` → pool_id (idempotent on name).
- `pool_add_observation(p_pool_id, p_payload_jsonb, p_confidence, p_provenance, p_access_label, p_account_id)` → member_id. A free-form working signal (no object_id).
- `pool_add_reference(p_pool_id, p_member_kind, p_member_object_type, p_member_object_id, p_confidence)` → member_id. Link an EXISTING memory object (memory|claim|fact) into the pool.
- `pool_promote_to_claim(p_member_id, p_subject, p_verb, p_object_value, p_statement_text, p_sensitivity)` → claim_id. Elevate an observation to a (pending) claim. Records promoted_from_member_id.
- `pool_promote_to_fact(p_member_id, p_subject, p_verb, p_object_value, p_statement_text, p_verification_scope, p_verification_method)` → fact_id.
- `pool_seal(p_pool_id, p_reason)` — freeze (no more writes); `pool_archive(...)`; `pool_tombstone(...)`.
- `pool_search(p_pool_name, p_query_text, p_limit, p_allow_fallback)` — search WITHIN a pool (scopes text_search to members). Match: "search just my current session's context".

## Why it matters for integration
A pool is the natural home for an AI agent's or an incident responder's
in-progress reasoning: collect observations, then commit the conclusions as
durable claims/facts. The promote_* calls are the bridge from scratch to permanent.