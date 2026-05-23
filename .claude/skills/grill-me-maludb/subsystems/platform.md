# Subsystem: Platform / Operational (V3)

Open when grilling reveals an operational need: secrets, auth, async jobs,
scheduling, realtime, REST exposure, MCP tools, log export, metrics, backup,
preview envs, audit. Confirm exact signatures against the repo's canonical SQL
at `../../../sql/extension/maludb_core--<version>.sql` (from this subsystems/
directory, that's three levels up to the repo root).

## Secrets
Encrypted credential storage + rotation. Use when the app needs to hold API keys/
tokens for external services. Match: "API keys", "rotate credentials", "vault".
- `secret_set(p_name, p_kind, p_value, p_description, p_rotation_policy_days)` → (secret_id, version) — inline secret; auto-retires prior version. kind ∈ provider|tool|broker|storage|log_drain|backup|other.
- `secret_set_external(p_name, p_kind, p_external_ref, ...)` — value lives at file:// or https://.
- `secret_revoke(p_name, p_reason)`; `secret_get_metadata(p_name)` (no plaintext); `__secret_resolve(p_name)` → plaintext (needs maludb_secret_consumer role).

## Auth tokens / JWT
Bearer tokens with scopes + CIDR, or HS256 JWT. Use to authenticate REST/CLI/
service callers. Match: "authenticate clients", "bearer token", "scopes".
- `auth_token_create(p_account_id, p_kind, p_label, p_scopes[], p_allowed_cidrs[], p_expires_at)` → (token_id, plaintext_token). Plaintext shown ONCE. kind ∈ personal|service.
- `auth_token_verify(p_plaintext, p_source_ip)` → (token_id, account_id, kind, scopes). Empty on failure. Enforces expiry/revocation/CIDR; audits every attempt.
- `auth_token_revoke(p_token_id, p_reason)`; `jwt_verify(p_jwt)` → claims (HS256 only; RS256/ES256 not yet supported).
- How REST uses it: gateway pulls Bearer token → `auth_token_verify` → checks scopes vs endpoint required_scopes → sets tenant GUC.

## Durable queue
Work-stealing async jobs with retry + dead-letter. Use for background work
(index builds, exports, anything slow). Match: "background jobs", "worker pool".
- `queue_register(p_name, p_default_visibility_ms, p_max_retries, p_dlq_name, p_description)` → queue_id.
- `queue_enqueue(p_queue_name, p_payload, p_idempotency_key, p_priority, p_visible_at, p_account_id)` → job_id (idempotency_key dedups).
- `queue_lease(p_queue_name, p_worker_id, p_batch, p_visibility_ms)` → jobs (FOR UPDATE SKIP LOCKED — concurrent-safe).
- `queue_ack(p_job_id)`; `queue_nack(p_job_id, p_error_text)` (promotes to DLQ at max_retries); `queue_reap_expired_leases()`; `queue_stats()`.

## Cron / schedules
Periodic jobs via cron syntax (5-field or @daily etc). Match: "nightly",
"recurring task". Two action kinds: `enqueue` (push to a queue) or `sql`.
- `schedule_create(p_name, p_cron_expr, p_action_kind, p_action_payload, p_description, p_enabled)` → schedule_id.
- `schedule_tick()` fires all due schedules (call every 1-5 min); `schedule_run_now(p_name)`; `schedule_enable/disable/list`.

## Realtime events + presence
Pub/sub with durable cursor (at-least-once replay) + online presence. Match:
"live updates", "SSE", "notifications", "who's online".
- `emit_event(p_event_kind, p_payload, p_account_id, p_partition, ...)` → event_id. Fires NOTIFY 'maludb_event'.
- `event_subscribe(p_name, p_account_id, p_kinds[], p_partitions[], ..., p_start_cursor)` → subscription_id.
- `event_fetch_batch(p_subscription_id, p_limit)` → events (does NOT advance cursor); `event_ack(p_subscription_id, p_through_event_id)` advances it; `event_list_subscriptions`.
- `presence_*` (4 functions — read live for exact signatures): online/heartbeat state.

## REST endpoint registry
Catalog-driven REST gateway: register a function as an HTTP endpoint; the daemon
reads the catalog at dispatch. Match: "expose a REST API", "OpenAPI".
- `rest_register_endpoint(p_method, p_path, p_handler regprocedure, p_required_scopes[], p_risk_class, p_openapi_spec, p_auth_required, p_timeout_ms, ...)` → endpoint_id.
- `rest_list_endpoints`; `rest_openapi_spec()` → full OpenAPI 3.1 doc; `rest_disable_endpoint`; `rest_log_invocation(...)` (gateway audits each call).

## MC2DB tool registry + r10_ wrappers
Expose DB operations as MCP tools for AI agents (Claude). Match: "expose tools to
Claude", "MCP", "let an agent call our DB".
- `mc2db.create_server(name, title, description)` → server_id.
- `mc2db.register_tool(server_name, tool_name, description, implementation_type, input_schema, ...)` — type ∈ sql_function|external_exec|mcp_proxy|http_endpoint.
- `mc2db.register_prompt(...)`, `mc2db.register_resource(...)`.
- The `r10_*` functions are the built-in MCP tool handlers: `r10_skill_find/get/fork`, `r10_sessions_create/get`, `r10_prompts_render/list`, `r10_models_submit/list`, `r10_memory_search_exact`, `r10_context_read/append`, `r10_catalog_describe`, `r10_health`. These are the ready-made tools the listener exposes.

## Log drains
Export audit/events to HTTP/S3/file/OTLP with redaction + batching. Match: "ship
to SIEM", "export audit logs".
- `log_drain_set(p_name, p_kind, p_destination, p_source_streams[], p_destination_secret_ref, p_redaction_rules, p_batch_size, p_flush_interval_ms)` → drain_id. kind ∈ http|file|s3|otlp_http.
- `log_drain_enable/disable/list`; `log_drain_record_run(...)`.

## Metrics
- `metrics_prometheus_scrape()` → Prometheus exposition text. Match: "Prometheus", "Grafana".

## Backup / PITR
- `backup_manifest_record(p_label, p_postgres_state_kind, p_postgres_state_uri, p_hash_summary, ...)` → manifest_id; `backup_verification_record(p_manifest_id, p_status, ...)`; `backup_manifest_latest()`.

## Preview environments
Sandbox clones with promotion gates (no production data). Match: "staging env",
"demo data", "anonymized test set".
- `preview_env_create(p_name, p_base_migration, p_seed_policy, p_anonymizer_ref, ...)` (seed_policy must have production_data=false); `preview_env_record_seed(...)`; `preview_env_promote_check(p_env_id)` → gate results; `preview_env_list`.

## Governance audit
Every operation emits a `malu$audit_event` row (append-only). Match: "audit
trail", "who did what", "compliance log".
- `audit_event(p_event_kind, p_target_object_type, p_target_object_id, p_event_jsonb, p_error_text)` → event_id (mostly called internally; app can add custom events).
- `audit_status()` reports pgaudit/pg_stat_statements availability.
- Query `malu$audit_event` directly for forensics (event_kind, target_object_type/id, event_jsonb, created_at).