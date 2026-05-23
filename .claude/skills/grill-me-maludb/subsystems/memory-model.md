# Subsystem: Memory model, provenance, SVPOR

The objects beyond the core path. Open when grilling reveals standalone knowledge,
multi-step narratives, or graph links. Exact signatures: confirm against
`maludb_core--0.73.0.sql`.

## Memory — `register_memory`
A standalone reusable knowledge unit (a lesson, a pattern, a principle), NOT tied
to a claim or fact. Match: "we learned a general rule", "a reusable principle",
"a lesson worth keeping".
- `register_memory(p_memory_kind[REQUIRED], p_title, p_summary, p_payload_jsonb, p_occurred_at, p_occurred_until, p_sensitivity)` → memory_id.
- Distinction tell: NOT built from claims (unlike a fact). Standalone. Carries temporal bounds for bitemporal queries.

## Episode + details — `register_episode`, `register_memory_detail`
An episode is a container for a multi-step narrative (an incident, a deployment,
a session). Details are its ordered steps. Match: "the whole sequence of what
happened", "the steps we took", "the timeline of the incident".
- `register_episode(p_episode_kind[REQUIRED], p_title[REQUIRED], p_summary, p_payload_jsonb, p_occurred_at, p_occurred_until, p_sensitivity)` → episode_id.
- `register_memory_detail(p_detail_kind[REQUIRED], p_parent_mdo_id|p_memory_id|p_episode_id (one required), p_ordinal, p_title, p_body_text, p_body_jsonb, p_sensitivity)` → mdo_id. detail_kind='step' for episode steps; supports nesting via parent_mdo_id.
- Episodes are the anchor for `replay_episode` — see `retrieval.md`.

## Relationship edges — `register_relationship_edge`
A polymorphic link between any two memory objects (fact→memory, claim→episode).
Match: "this relates to that", "build a knowledge graph", "X supports Y".
- `register_relationship_edge(p_source_object_type, p_source_object_id, p_target_object_type, p_target_object_id, p_relationship_type, p_label, p_edge_jsonb, p_confidence)` → edge_id.
- Edges power `graph_neighbors`/`graph_walk` (retrieval.md) and `propagate_staleness`.

## Derivation ledger — `record_derivation`
Provenance: HOW an object was made (parser, model, verifier, input hashes).
Doctrine: every derived object MUST have a ledger entry. Match: "track how this
was generated", "provenance", "lineage".
- `record_derivation(p_derived_object_type, p_derived_object_id, p_parser_name, p_model_alias_id, p_prompt_template_id, p_policy_name, p_verifier_name, p_model_request_id, p_inputs_jsonb)` → derivation_id.
- Mostly written AUTOMATICALLY by `ingest_claim_atomic`, `promote_claim_to_fact_atomic`, `accept_pending_claim`, the PageIndex builders, etc. Rarely called by hand. If the user uses the atomic/accept paths, provenance is handled for them.

## SVPOR registries
Canonical Subject/Verb/Predicate/Object/Relation tokens — deduplicated vocabulary
that claims and facts resolve against. Match: "canonical entity names",
"normalize subjects", "controlled vocabulary".
- `register_svpor_subject(p_canonical_name, p_aliases)` → subject_id (upsert); same for `register_svpor_verb`, `register_svpor_predicate`.
- `resolve_svpor_subject/verb/predicate(text)` → id.
- Usually resolved AUTOMATICALLY by a trigger when you insert a claim/fact with a
  text subject. A developer rarely registers these by hand — mention only if they
  want an explicit controlled vocabulary.

## advanced_* variants
For most register_* calls there is an `advanced_write_*` / `advanced_*` variant
taking richer jsonb arguments (for framework integration). 27 in total. Read the
exact signature live when one is needed; otherwise prefer the plain register_* call.