# Subsystem: PageIndex / ChatIndex (V4)

Tree-structured memory over documents and conversations. Open when grilling
reveals document Q&A or long-conversation recall. Confirm signatures against
`maludb_core--0.73.0.sql`.

## PageIndex — document → navigable tree
Parse a document (PDF, markdown, …) into an outline tree (internal nodes) + leaf
content, for structured Q&A. The structure pass is deterministic + model-free; a
separate summarization pass uses the model. Match: "document Q&A", "navigate a
PDF", "outline of a doc", "structured retrieval over a manual".
- `source_package_promote_to_page_index(p_source_package_id, p_parser_kind, p_model_alias_id, p_prompt_template_id, p_builder_options)` → tree_id. **The one-call entry point** — registers the tree and enqueues the async build job.
- Lower-level (usually the builder daemon's job, not the integrator's):
  `page_index_tree_register`, `page_index_tree_mark_building/ready/failed`,
  `page_index_record_structure_pass(...)`, `page_index_record_node(...)`,
  `page_index_tree_supersede(p_prior_tree_id, p_new_tree_id)`.
- Build status: `pending → building → ready|failed`.

## ChatIndex — conversation → nested topics + messages
Structure a conversation into a topic tree with messages as leaves, appended
incrementally. Match: "conversation recall", "long chat history", "remember a
multi-session dialogue".
- `chat_index_tree_register(p_source_package_id, p_model_alias_id, p_prompt_template_id, p_max_children)` → tree_id.
- `chat_index_append_messages(p_tree_id, p_messages jsonb)` → (message_index, mdo_id, idempotent_hit). **The main entry point** — append an array of messages; idempotent by message_index; auto-opens a root topic; supports topic branching via `p_messages[].topic_branch`.
- Lower-level: `chat_index_tree_mark_building/ready`, `chat_index_record_topic(...)`, `chat_index_record_message(...)`.

## Reading the trees
- `tree_descent_retrieve(p_tree_id, p_cue_text, ...)` → matching leaf + descent audit trail (tree must be 'ready'). Walks internal → leaf.
- `classify_intent` admits 'structured_doc_qa' (PageIndex) and 'long_chat_recall' (ChatIndex) so `execute_retrieval` can route to them.

## Key concepts
- Both build on the **verbatim source archive** (lifecycle.md) — the tree is a
  derived view over preserved source bytes, re-buildable under a new model.
- Tree supersession works like fact correction: a new tree supersedes the prior,
  linked by a relationship edge — history kept.
- Nodes are `malu$memory_detail_object` rows (node_kind internal|leaf), with a
  derivation ledger entry each.