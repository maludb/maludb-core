# Subsystem: Model registry, prompts, vectors, idempotency, budget

The model/LLM-plumbing side. Open when grilling reveals managing embedding models,
prompt templates, or calling an LLM through the DB. Confirm signatures against
`maludb_core--0.73.0.sql`.

## Model registry + blue-green + adapters
Version embedding models and roll them out with zero-downtime traffic splits;
bridge incompatible embedding spaces with adapters. Match: "upgrade the embedding
model", "A/B a model", "zero-downtime cutover", "migrate the index".
- `register_model_provider(name, kind, adapter_name, secret_ref, data_sensitivity)`; `register_model_alias(alias, provider, model_identifier, ...)`.
- `register_embedding_space(p_space_name, p_dimensions, p_distance_metric, p_model_alias_id)` → space_id.
- `register_model_in_registry(p_model_kind, p_model_alias_id, p_embedding_space_id, ...)` → registry_id.
- `advance_model_rollout(p_registry_id, p_new_state)` — proposed → canary → active (auto-demotes prior active; one active per kind).
- `propose_index_migration(source_space, target_space, index_type)`; `advance_index_migration(migration_id, new_state, traffic_pct)` — shadow_building → dual_serve(traffic%) → cutover → cleanup → done.
- `route_query(p_model_kind)` → routing strategy (active | dual_serve{traffic_pct} | target_only).
- `register_embedding_adapter(name, source_space, target_space, kind, params, evaluation)`; `attach_adapter_to_migration(...)`; `negotiate_*` (capability negotiation — read live).

## Prompts — template → render → approve → bind → call
Manage prompts with typed variables, an approval workflow, and submit them to a
model through the DB. Match: "manage prompts", "prompt versioning", "approval gate
for prompts", "call an LLM via the database".
- `register_prompt_template(p_name, p_body, p_variables, ...)` → template_id (upsert by name; versioned).
- `declare_prompt_variable(p_template_name, p_variable_name, p_variable_type, p_required, p_default_value, p_max_length, p_validation_rule, p_enum_values[])` → variable_id.
- `render_prompt(p_session_id, p_template_name, p_template_version, p_variables)` → render_id (deterministic prompt_hash); `preview_prompt(name, variables)` → text (no row).
- `approve_prompt(p_template_name, p_safety_policy, p_approver_account)`; `deprecate_prompt(...)`; `request_review(...)`.
- `bind_prompt(p_template_name, p_variables, p_session_id, ...)` → bound prompt (validates variables: type, required, enum, regex, length).
- `call(p_bound_prompt_id, p_model_alias_id, p_generation_params, p_timeout_ms, p_cache_mode, p_idempotency_key)` → request_id; or `submit_render(p_render_id, p_alias_name, ...)`.
- Read the result: `response_text(request_id)`, `response_json(...)`, `response_tokens(...)`, `response_cost(...)`, `response_error(...)`. Poll `request_status(request_id)`.

## Idempotency + budget
- Idempotency: pass `p_idempotency_key` to `call`/`submit_render` — a repeat with the same key returns the prior request_id (no re-run). Match: "exactly once", "don't double-charge".
- Budget: `check_budget(p_account_id, p_template_id)` enforces token/request quotas (account|prompt|role|global scope) before a request is created. Match: "rate limit", "cost cap", "per-tenant quota".

## Vector setup
The write side of vector search (read side in retrieval.md): embeddings are
organised by SVPOR compartment. `embedding_enqueue(...)` schedules async embedding
generation; `embedding_record_output(...)` is how a worker records the result.
Match: "generate embeddings", "index for semantic search".