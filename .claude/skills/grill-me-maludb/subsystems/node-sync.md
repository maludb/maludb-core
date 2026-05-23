# Subsystem: Local node sync

Open when grilling reveals offline-first / edge clients that sync up. Confirm
signatures against `maludb_core--0.73.0.sql`.

## Nodes-never-authoritative model
Edge nodes (laptops, mobile, field devices) work offline and SUBMIT proposals;
the server reviews and applies them under governance. A node never writes a memory
table directly. Match: "offline-first", "edge devices", "local clients that sync
up", "field app that works without connection".

## Functions
- `register_local_node(p_node_name, p_fingerprint, p_uri, p_description)` → node_id (upsert by name; fingerprint mismatch rejected).
- `node_submit(p_node_id, p_submission_kind, p_payload_jsonb, p_local_id, p_local_hash)` → submission_id. Status 'pending'. submission_kind e.g. 'claim_new'. Idempotent by (node_id, local_id, kind).
- `node_accept(p_submission_id, p_reason)` → decision jsonb. For a claim_new submission, invokes `register_claim` server-side and links applied_object_id.
- `node_reject(p_submission_id, p_reason)`; `node_record_conflict(p_submission_id, p_conflict_reason)` → conflict_id; `revoke_local_node(p_node_id, p_reason)`.

## When to recommend
Only for genuinely distributed/offline architectures. For a normal server-side
app, this is overkill — the app just calls `register_claim` directly. Surface it
when the user describes clients that operate disconnected and reconcile later.