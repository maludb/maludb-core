# Subsystem: Lifecycle, salience, decay, legal hold, retention, verbatim archive

Open when grilling reveals retention/compliance needs, aging data, or immutable
evidence. Confirm signatures against `maludb_core--0.73.0.sql`.

## Lifecycle / salience / decay
Memory objects have a lifecycle state and a salience that decays over time.
Match: "data ages out", "stale memories", "rank by recency", "decay".
- `apply_lifecycle_state(...)` — transition an object's state.
- `set_lifecycle_policy(...)` — configure decay/retention behavior.
- `compute_salience(...)` — rank by recency + usage + decay.
- `propagate_staleness(p_source_type, p_source_id, p_reason)` → count — when a source is superseded/retracted, flag downstream dependents stale (one hop). Often paired with `correct_fact`/`retract_fact`.
- Predicates: `is_currently_valid(...)`, `is_valid_at(...)`, `is_under_legal_hold(...)`.

## Legal hold + retention + prune
Compliance controls. Match: "legal hold", "can't delete during litigation",
"retention policy", "GDPR", "prune old data".
- `legal_hold_apply(...)` / `legal_hold_release(...)` — pin objects against pruning.
- `set_retention(...)` (retention class on objects/sources).
- `prune_*` — remove only what policy allows (tombstoned, never silently).

## Verbatim source archive — immutable sealed evidence
Seal a source package so its content can't be tampered with; verify by hash;
re-extract under new models without source drift. Match: "tamper-proof",
"immutable evidence", "audit-grade source retention", "re-extract under a new
model", "prove what the original said".
- `seal_source_package(p_source_package_id, p_placement_tier, p_external_uri, p_note)` → archive_id. After sealing, a trigger blocks content edits. tiers: inline|external|legal_hold.
- `unseal_source_package(p_source_package_id, p_reason)` — admin-only; supersedes prior archive rows.
- `verify_source_hash(p_source_package_id, p_context_label)` → (matched, verification_id).
- `reingest_source_package(p_source_package_id, p_verify)` → content (re-parse after parser/model updates).
- Also: `archive_source_package`, `tombstone_source_package` (soft-delete with audit).

## When to recommend
These are mostly relevant to compliance-heavy domains (finance, healthcare, legal).
For a simple app, the user likely doesn't need lifecycle/legal-hold — don't push
it. Surface it when they mention regulation, retention, or audit-grade evidence.