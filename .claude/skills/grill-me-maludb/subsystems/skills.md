# Subsystem: Skill runtime, workflow extraction, skill discovery

The AI-procedure side. Open when grilling reveals an agent following defined steps,
learning procedures from history, or a skill catalog. Confirm signatures against
`maludb_core--0.73.0.sql`.

## Skill runtime — governed state machine
Model a repeatable procedure as states + transitions; run it as a tracked
execution. Match: "the agent follows defined steps", "allowed transitions",
"runbook with branches", "guard what the agent can do next".
- `register_skill(p_skill_name, p_version, p_description, p_packaging_kind, p_applicability_jsonb, p_precondition_jsonb)` → skill_id (upsert by name+version).
- `add_skill_state(p_skill_id, p_state_name, p_state_kind, p_step_jsonb, p_validation_jsonb)` → state_id. kinds: start (exactly one)|step|validation|exception_handler|terminal.
- `add_skill_transition(p_skill_id, p_from_state, p_to_state, p_on_outcome, p_guard_jsonb)` → transition_id. on_outcome: literal (e.g. 'success') or wildcard 'exception:*'.
- `begin_skill_execution(p_skill_id, p_environment, p_technology_stack[], p_task_objective, ..., p_active_pool_id, p_source_context_id)` → execution_id. Applicability mismatch is rejected.
- `step_skill_execution(p_execution_id, p_outcome, p_observation_jsonb)` → next_state_name (matches literal → exception:* → default).
- `abort_skill_execution(p_execution_id, p_reason)`; `skill_emit_claim(p_execution_id, p_claim_id)` (a skill produces a claim).

## Workflow extraction — candidates DON'T auto-promote
Learn procedure templates from observed episode traces. Doctrine: a candidate is
a proposal; approving it flips a status — it never auto-creates a procedural
memory. Match: "learn from what we did", "auto-generate runbooks from history",
"cluster similar procedures".
- `extract_workflow_trace(p_episode_id, p_outcome, p_environment, p_security_domain, p_subject_class, p_action_class)` → trace_id (parses episode steps, keeps positive/negative evidence + causation).
- `cluster_workflow_traces(p_subject_class, p_action_class, p_outcome, p_environment, p_tool_stack[], p_exception_pattern)` → cluster_id (groups by signature; tracks positive_member_count vs negative_member_count).
- `propose_workflow_candidate(p_cluster_id, p_name, p_description, p_step_template)` → candidate_id (status 'proposed'; creates NOTHING else).
- `review_workflow_candidate(p_candidate_id, p_status, p_notes)` — flip to approved/rejected (immutable after).

## Skill discovery + fork
Searchable, RLS-protected skill catalog with cross-tenant forking. Match: "skill
marketplace", "reuse a skill", "search for a procedure", "clone and customize".
- `find_skill(p_query, p_subject, p_verb, p_query_embedding, p_owner_schema, p_limit, p_include_public)` → ranked skills (scores subject+verb+keyword+embedding+fuzzy-name).
- `get_skill(p_owner_schema, p_skill_id, p_requesting_schema)` → full definition jsonb (RLS-checked).
- `fork_skill(p_source_owner_schema, p_source_skill_id, p_target_owner_schema, p_new_skill_name, p_new_version)` → new skill_id (re-parents subjects/verbs/keywords/embeddings).
- Public skills live in a public schema; access levels read|execute|admin (execute/admin hide from discovery). The `r10_skill_find/get/fork` MCP wrappers expose this to AI agents (see platform.md).