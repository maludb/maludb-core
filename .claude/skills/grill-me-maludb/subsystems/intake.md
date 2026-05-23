# Subsystem: Intake — review queue, connectors

Open when grilling reveals a "review before it counts" step or a recurring feed.
Confirm signatures against `maludb_core--0.73.0.sql`.

## Pending-claim review queue
The built-in "candidate → human review → real claim" gate. This is MaluDB's
structured answer to the claim→fact authority question. Match: "review queue",
"needs approval", "human in the loop", "moderation", "an inbox of suggestions to
approve/reject".
- `propose_pending_claim(p_connector_id, p_source_package_id, p_subject, p_verb, p_object_value, p_statement_text, p_confidence, p_proposed_by, ...)` → pending_claim_id. NOT yet a real claim — sits in `malu$pending_claim`, state 'pending'.
- `accept_pending_claim(p_pending_claim_id[REQUIRED], p_reviewer, p_review_note, p_parser_name, p_verifier_name, ...)` → real claim_id (+ writes the derivation ledger automatically).
- `reject_pending_claim(p_pending_claim_id[REQUIRED], p_reviewer, p_review_note, p_final_state)` — non-destructive; final_state ∈ rejected|duplicate|superseded; row kept for audit.
- `list_pending_claims(p_connector_id, p_limit)` → the review queue (pending only).
- NOT this if items are trusted on arrival → `register_claim` directly, skip the queue.

## Ingestion connectors
For recurring sync from external feeds (Slack, GitHub, log tails) with resumable
cursors. Match: "poll", "sync from <system>", "cursor", "since last run",
"incremental import", "scheduled pull".
- `register_connector(p_connector_name, p_connector_kind, p_source_type, p_config_jsonb, p_sensitivity)` → connector_id (upsert by name).
- `advance_checkpoint(p_connector_id, p_cursor_name, p_cursor_value, p_cursor_format, p_mode, p_items_added, p_last_error)` → checkpoint_id. Tracks "where did I leave off". Formats: timestamp|opaque|message_id|offset|jsonb. Modes: retrospective|continuous|paused.
- NOT this if writes are one-off / user-driven → just write sources/claims directly, no connector.