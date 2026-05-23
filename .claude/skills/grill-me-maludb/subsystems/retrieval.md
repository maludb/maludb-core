# Subsystem: Retrieval, search, replay, graph, vector

The read side. Open when grilling reveals a "get data out" need. Confirm exact
signatures against `maludb_core--0.73.0.sql`.

## Canonical retrieval — `execute_retrieval`
The full authorization-aware, multi-strategy, audited path. Match: a search box,
an AI recall step, "what do we know about X", a "related context" panel.
- `execute_retrieval(p_envelope malu$retrieval_envelope_t, p_hint_name, p_limit)` → SETOF malu$retrieval_hit.
- Envelope = `(cue_text, object_types[], valid_as_of, transaction_as_of, confidence_floor, hints)` — fields in THAT order. Build with `ROW(...)::malu$retrieval_envelope_t`.
- Hit = `(object_type, object_id, title, snippet, rank, strategy, metadata)`.
- Runs intent classification → strategies (fts, fuzzy_subject, temporal_as_of, source_filter, +vector/graph) → RLS + lifecycle + confidence gating → audit.
- `plan_retrieval(envelope)` returns the plan without executing; `authorize_object_types(envelope)` returns the readable subset.

## Quick search — `text_search`
Plain FTS, no authz/planning. Match: "just search the text", "find mentions".
- `text_search(p_query, p_object_types[], p_limit)` → (object_type, object_id, title_or_subject, snippet, rank).
- NOT this if permissions/confidence matter → use execute_retrieval.
- `fuzzy_subject_match(p_needle, p_threshold, p_object_types[], p_limit)` — typo-tolerant subject lookup (pg_trgm). Match: autocomplete.

## Replay — `replay_episode`
Reconstruct an episode (steps + supporting evidence) at a point in time. Match:
"timeline", "history of", "as of last March", "what changed since", "show the
whole story". THIS is where never-overwrite pays off visibly.
- `replay_episode(p_episode_id, p_mode, p_as_of)` → jsonb envelope (steps, supporting_evidence, source_packages_inspected, included_object_ids, later_changes, prior_belief, hidden_by_policy_count).
- modes: `current_valid` (now), `historical` (valid at p_as_of), `as_of_transaction_time` (what we KNEW at p_as_of — requires p_as_of), `full_bitemporal` (everything incl. superseded + later changes).

## Graph traversal
Walk relationship edges. Match: "what depends on this", "trace the connections",
"impact analysis".
- `graph_neighbors(p_object_type, p_object_id, p_direction, p_relationship_filter[])` → direct neighbors. direction ∈ out|in|both.
- `graph_walk(p_object_type, p_object_id, p_max_depth, p_direction, p_relationship_filter[], p_mode)` → multi-hop (bfs|dfs, cycle-safe).
- `graph_path(source, target, p_max_depth, p_direction)` → shortest path.

## Vector / semantic search
Embeddings organised by SVPOR compartment (namespace + subject + verb). Match:
"semantic search", "vector similarity", "find similar".
- `search_memory_exact(p_namespace, p_subject, p_verb, p_query bytea, p_limit, p_metric)` → ranked chunks. Ergonomic SVPOR-tagged search.
- `search_memory_filter(..., p_metadata_filter jsonb, ...)` — vector search + jsonb metadata filter.
- `vector_search_by_tags(p_namespace, p_subject, p_verb, p_query_embedding, p_limit, p_metric)` — across multiple compartments.
- `explain_vector_search(namespace, subject, verb)` — compartment config + index health (debug).
- Setup: `register_embedding_space`, vector compartments, `embedding_enqueue` (async embed). See models.md.

## Bitemporal point reads
- `fact_as_of(p_at)`, `memory_as_of(p_at)`, `episode_as_of(p_at)` → SETOF the object, valid at that instant. Match: "what was true on <date>".

## Query hints
- `register_query_hint(p_hint_name, p_hint_jsonb, p_description)` → hint_id. Directives: force_path, suppress_path, intent_override, confidence_floor_override, time_constraint_override. Pass p_hint_name to execute_retrieval. Match: "tune retrieval", "always prefer vector for this".