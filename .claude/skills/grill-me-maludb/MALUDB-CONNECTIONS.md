# MaluDB Connection Points — the always-loaded map

This is the skill's internal knowledge of MaluDB. It is **not** user-facing. It
is what the grilling questions are derived from. Keep it always loaded.

MaluDB is a memory database built as a PostgreSQL extension. Its job is to
remember **what was believed, when, from where, and how that belief changed** —
the things a normal database throws away. A "connection point" is a place in an
application where one of MaluDB's functions belongs.

This skill grills toward the **SQL functions** — the true, complete, universal
surface. Every driver, REST, CLI, and `psql` bottoms out here. It recommends SQL
calls, which the user wires through whatever surface their app uses.

> **THE GOLDEN RULE OF FIT.** MaluDB belongs where *history, provenance, or
> changed-our-mind* matters. If a moment is just current-state lookup with no
> "who said it / why / did it change," it is **NOT** a MaluDB connection point —
> recommend a normal table instead. A skill that can only say "yes" is a
> salesman. The "NOT this if" lines are what make this a sales engineer. Saying
> "don't use MaluDB here" is a correct, valuable answer.

---

## How this knowledge is structured (read this)

There are ~331 callable functions in MaluDB. You do not have all of them
memorised, and you do not need to. Knowledge is tiered:

1. **THE CORE PATH (below, in full).** The spine of MaluDB. Most integrations are
   some subset of these. Grill hardest here. You know these cold.
2. **THE CAPABILITY INDEX (below).** A one-line entry for *every* capability area
   MaluDB has — so you NEVER miss a fit. When grilling reveals one of these
   matters, open its detailed file in `subsystems/` (listed per entry).
3. **READ THE REPO'S CANONICAL SQL.** This skill ships inside the MaluDB repo at
   `.claude/skills/grill-me-maludb/`, so MaluDB's own source of truth is two
   levels up at `../../sql/extension/maludb_core--<version>.sql` relative to this
   file. Grep that file for exact signatures: search for `CREATE FUNCTION <name>`
   to get the precise parameter list. NEVER hand a user a signature you haven't
   confirmed against this file or a subsystem doc — the canonical SQL is
   authoritative and stays in sync with whatever MaluDB version the repo is on.
   If the skill is being run outside the MaluDB repo (e.g. copied into another
   project), look for the same file in that project's MaluDB checkout, or ask the
   user where it lives.

The matching rules in the core path and the index are how you grill: listen for
the trigger words, map the app-moment to the connection point, confirm with the
distinction tell, then write the entry into the user's `INTEGRATION-MAP.md`.

---

## THE CORE PATH (detailed — you know these cold)

```
register_source_package → register_claim → register_fact → correct_fact / retract_fact
   (raw evidence)          (stated)         (verified)       (changed our mind, kept history)
                                └── or gated: propose_pending_claim → accept/reject_pending_claim
```

### SOURCE — `register_source_package`
- **Meaning:** raw material preserved verbatim — a doc, log, message, event. The
  sealed evidence bag everything points back to.
- **Matching rule (trigger words):** *"ingested", "we got a document/log/message",
  "the webhook fired", "uploaded", "raw payload", "came in from".* Raw input a
  belief will be built from → register it first.
- **NOT this if:** the raw input has no lasting value and nothing will cite it
  (skip MaluDB); or you only have the interpretation (go straight to claim).
- **Call:** `register_source_package(p_source_type, p_content_text|p_content_jsonb|p_content_bytes, p_origin_jsonb, p_sensitivity)` → `source_package_id`. Only `p_source_type` required.
- **Distinction tell:** one required param + three content slots. Content is hashed for dedup.
- **Pairs with:** a `register_claim` next; `ingest_claim_atomic` does both at once.

### CLAIM — `register_claim`
- **Meaning:** something *stated* — a reason, observation, assertion — attributed
  to a source but **not yet verified**. A quote with a source stapled on.
- **Matching rule (trigger words):** *"noted", "logged", "the user said", "we
  observed", "flagged", "the model output", "their reasoning was", "the analyst
  entered".* Attributable + nobody has confirmed it → claim.
- **Worked example:** analyst types a buy-reason and clicks Confirm → that reason
  is a claim → `register_claim(p_statement_text => the reason, p_source_package_id => :src)`.
- **NOT this if:** already verified/approved (→ fact); or just current-state data
  with no "who said it / why" (→ normal table, not MaluDB).
- **Call:** `register_claim(p_subject, p_verb, p_object_value, p_statement_text, p_source_package_id, p_sensitivity)` → `claim_id`.
- **Distinction tell:** takes `p_source_package_id`, has **no** verification param. The absence is the signal.
- **Pairs with:** a source before it; a fact that promotes it later.

### FACT — `register_fact`
- **Meaning:** a claim (or several) **verified and now believed**. The graduation
  from "someone said" to "we hold true." Carries who/how verified + a lifecycle.
- **Matching rule (trigger words):** *"verified", "approved", "confirmed", "signed
  off", "the review passed", "we accepted", "promoted", "validated".*
- **Worked example:** a risk officer approves the analyst's claim →
  `register_fact(p_claim_ids => ARRAY[:claim], p_verification_method => 'risk_review')`.
- **NOT this if:** nothing actually verifies it — relabeling a claim as a fact for
  no reason (keep it a claim). Worth it only when a real verification step exists,
  OR you are the authority and want it on record that you vouched.
- **Call:** `register_fact(p_claim_ids[REQUIRED], p_subject, p_verb, p_object_value, p_statement_text, p_verification_scope, p_verification_method)` → `fact_id`.
- **Distinction tell:** requires `p_claim_ids` (built from claims, not a source) + carries verification params.
- **Pairs with:** the claims it promotes; later a `correct_fact`. Atomic shortcut: `promote_claim_to_fact_atomic`.
- **On "do I need an authority?":** the claim→fact line is OPTIONAL. Three valid
  stances: store only claims; let an automated rule / the AI be the verifier;
  require a human sign-off (the pending-claim queue). Recommend a fact step only
  when someone *later* must tell "verified" from "merely stated."

### CORRECTION — `correct_fact`  ⭐ the reason MaluDB exists
- **Meaning:** changed our mind **without erasing the past**. Closes the old fact,
  creates a successor, links them with the *reason*. Afterward both "what's true
  now?" and "what did we believe before?" answer honestly.
- **Matching rule (trigger words):** *"turns out", "we were wrong", "actually it
  was", "corrected", "revised", "the real cause was", "updated our view",
  "re-classified", "changed our mind".* Anywhere a value would normally be
  *overwritten* but the old value has historical worth.
- **Worked example:** team realizes the trade thesis was a glitch →
  `correct_fact(p_fact_id => :f, p_new_object_value => 'false_signal', p_reason => 'low-volume glitch')`.
- **NOT this if:** no replacement belief (→ `retract_fact`); or throwaway
  current-state nobody will care about historically (→ a normal UPDATE is fine).
- **Call:** `correct_fact(p_fact_id[REQUIRED], p_new_object_value, p_new_statement, p_reason, p_supersession_kind)` → NEW `fact_id`.
- **Distinction tell:** old fact_id in, reason preserved, new fact_id out. Unique shape.
- **Pairs with:** `propagate_staleness` if others depended on the old belief; `replay_episode` to see the change in history.

### RETRACTION — `retract_fact`
- **Meaning:** "this was wrong and we have **nothing** to replace it." Retires the
  fact, records why, no successor.
- **Matching rule (trigger words):** *"withdraw", "retract", "simply false", "no
  longer holds", "void".*
- **NOT this if:** you have a replacement belief (→ `correct_fact`).
- **Call:** `retract_fact(p_fact_id[REQUIRED], p_reason[REQUIRED])`.
- **Distinction tell:** required reason, no new-value param. Absence of a successor is the signal.

### READING IT BACK (the payoff)
- **`execute_retrieval(envelope, hint_name, limit)`** — canonical "what do I know
  about X?": authorization-aware, multi-strategy, audited. Match: a search box, an
  AI recall step, a "related context" panel. Envelope is
  `malu$retrieval_envelope_t` = (cue_text, object_types[], valid_as_of,
  transaction_as_of, confidence_floor, hints) — **fields in that order**.
- **`text_search(query, object_types[], limit)`** — quick keyword hits, no authz/
  planning. Match: lightweight "find mentions of." NOT this if permissions/
  confidence matter (→ execute_retrieval).
- **`replay_episode(episode_id, mode, as_of)`** — "show me this situation as it
  was." `mode`: `current_valid` (now), `historical` (as of a date),
  `full_bitemporal` (everything incl. superseded + later changes). Match:
  "timeline", "history of", "as of last March", "what changed since." This is
  where never-overwrite pays off visibly.
- More read paths (graph walk, vector search, fuzzy subject, `*_as_of`) are in
  `subsystems/retrieval.md`.

---

## THE CAPABILITY INDEX (every area — so you never miss a fit)

One line each. When grilling reveals an area matters, open its detailed file in
`subsystems/`. For functions not in a subsystem file, read the canonical SQL live.

### Memory & provenance
- **Memory / episode / detail / edge** — standalone knowledge, multi-step
  narratives, graph links. `register_memory`, `register_episode`,
  `register_memory_detail`, `register_relationship_edge`. → `subsystems/memory-model.md`
- **Derivation ledger** — provenance record of HOW an object was made
  (`record_derivation`); mostly automatic. → `subsystems/memory-model.md`
- **MAUT confidence** — multi-criteria confidence scoring on facts (`set_maut_score`,
  `apply_default_weights`, `record_reinforcement`, `maut_aggregate_confidence`).
  Match: "how sure are we", "confidence", "trust score". → `subsystems/confidence-and-time.md`
- **Bitemporal time** — valid-time vs transaction-time; point-in-time reads
  (`fact_as_of`, `memory_as_of`, `episode_as_of`). Match: "as of", "what was true
  when", "point in time". → `subsystems/confidence-and-time.md`
- **Lifecycle / salience / decay / legal-hold / retention / prune** — objects age,
  decay in salience, can be held for compliance or pruned. `apply_lifecycle_state`,
  `compute_salience`, `legal_hold_apply/release`, `set_retention`, `prune_*`. Match:
  "retention", "expire", "legal hold", "compliance", "decay". → `subsystems/lifecycle.md`
- **SVPOR registries** — canonical subject/verb/predicate tokens
  (`register_svpor_*`, `resolve_svpor_*`). Mostly resolved automatically on insert.
  → `subsystems/memory-model.md`

### Intake & review
- **Pending-claim review queue** — candidate → human review → real claim.
  `propose_pending_claim`, `accept_pending_claim`, `reject_pending_claim`,
  `list_pending_claims`. Match: "review queue", "needs approval", "human in the
  loop", "moderation". → `subsystems/intake.md`
- **Ingestion connectors** — recurring sync from external feeds with cursors.
  `register_connector`, `advance_checkpoint`. Match: "poll", "sync from", "since
  last run", "incremental import". → `subsystems/intake.md`
- **Active memory pools** — a scratch workspace that accumulates observations,
  some promoted to claims/facts. `create_active_memory_pool`, `pool_add_observation`,
  `pool_add_reference`, `pool_promote_to_claim/fact`, `pool_seal/archive/tombstone`,
  `pool_search`. Match: "working set", "investigation thread", "gather then
  commit", "session context". → `subsystems/pools.md`

### Authorization & multi-tenancy
- **Object grants / 3-point authz** — cross-schema access, RLS-aware retrieval.
  `grant_object_access`, `revoke_object_grant`, `authorize_object_types`. Match:
  "share between teams", "who can see", "cross-tenant". → `subsystems/authz.md`
- **Schema-local memory (multi-tenancy)** — a tenant opts in and gets facade views
  in their own schema. `enable_memory_schema`. Match: "per-customer isolation",
  "SaaS tenants", "each team their own". → `subsystems/multitenancy.md`
- **Sensitivity** — every object carries a sensitivity tier (param on most
  register_* calls). Match: "classification", "confidential vs internal". → `subsystems/authz.md`

### AI / workflow / skills
- **Skill runtime** — a governed state machine for an AI following a procedure.
  `register_skill`, `add_skill_state`, `add_skill_transition`,
  `begin/step/abort_skill_execution`, `skill_emit_claim`. Match: "the agent
  follows defined steps", "allowed transitions", "runbook". → `subsystems/skills.md`
- **Workflow extraction** — learn procedures from episode traces; candidates
  DON'T auto-promote. `extract_workflow_trace`, `cluster_workflow_traces`,
  `propose_workflow_candidate`, `review_workflow_candidate`. Match: "learn from
  what we did", "auto-generate runbooks". → `subsystems/skills.md`
- **Skill discovery + fork** — searchable skill catalog, cross-tenant forking.
  `find_skill`, `get_skill`, `fork_skill`. Match: "skill marketplace", "reuse a
  skill", "search for a procedure". → `subsystems/skills.md`

### Documents & conversations (V4)
- **PageIndex** — parse a document into a navigable tree for structured Q&A.
  `source_package_promote_to_page_index`, `page_index_tree_*`, `page_index_record_*`,
  `tree_descent_retrieve`. Match: "document Q&A", "navigate a PDF", "outline".
  → `subsystems/pageindex.md`
- **ChatIndex** — structure a conversation into nested topics + messages.
  `chat_index_tree_*`, `chat_index_record_*`, `chat_index_append_messages`. Match:
  "conversation recall", "long chat history". → `subsystems/pageindex.md`
- **Verbatim source archive** — immutable sealed storage + hash verification.
  `seal_source_package`, `unseal_source_package`, `verify_source_hash`,
  `reingest_source_package`. Match: "tamper-proof", "immutable evidence",
  "re-extract under a new model". → `subsystems/lifecycle.md`

### Models & prompts
- **Model registry / blue-green / adapters** — version embedding models, roll out
  with traffic split, bridge embedding spaces. `register_model_provider/alias`,
  `register_embedding_space`, `advance_model_rollout`, `propose_index_migration`,
  `route_query`, `register_embedding_adapter`, `negotiate_*`. Match: "upgrade the
  embedding model", "A/B a model", "zero-downtime cutover". → `subsystems/models.md`
- **Prompts** — template → render → approve → bind → call, with response
  accessors, idempotency, budget. `register_prompt_template`, `declare_prompt_variable`,
  `render_prompt`, `approve_prompt`, `bind_prompt`, `call`, `submit_render`,
  `response_text/json/cost/tokens/error`, `check_budget`. Match: "manage prompts",
  "prompt versioning", "call an LLM through the DB", "token budget". → `subsystems/models.md`
- **Vector / embedding / ANN** — embeddings organised by SVPOR compartment;
  exact + ANN search. `register_embedding_space/adapter`, `search_memory_exact`,
  `vector_search_by_tags`, `explain_vector_search`, `embedding_enqueue`. Match:
  "semantic search", "vector similarity". → `subsystems/retrieval.md`

### Sync
- **Local node sync** — edge nodes propose; server applies under governance
  (nodes never authoritative). `register_local_node`, `node_submit`,
  `node_accept/reject`, `node_record_conflict`, `revoke_local_node`. Match:
  "offline-first", "edge devices", "local clients that sync up". → `subsystems/node-sync.md`

### Platform / operational (V3)
- **Secrets** — encrypted credential storage + rotation + external refs.
  `secret_set`, `secret_set_external`, `secret_revoke`, `secret_get_metadata`,
  `__secret_resolve`. Match: "API keys", "credentials", "rotate secrets". → `subsystems/platform.md`
- **Auth tokens / JWT** — bearer tokens, scopes, CIDR, JWT verify.
  `auth_token_create/verify/revoke`, `jwt_verify`. Match: "authenticate clients",
  "bearer token", "scopes". → `subsystems/platform.md`
- **Durable queue** — work-stealing async jobs + retry + DLQ. `queue_register`,
  `queue_enqueue`, `queue_lease`, `queue_ack/nack`, `queue_stats`. Match:
  "background jobs", "async processing", "worker pool". → `subsystems/platform.md`
- **Cron / schedules** — periodic jobs (cron syntax). `schedule_create`,
  `schedule_tick`, `schedule_run_now`, `schedule_enable/disable/list`. Match:
  "scheduled task", "nightly", "recurring". → `subsystems/platform.md`
- **Realtime events / presence** — pub/sub with cursor replay + online presence.
  `emit_event`, `event_subscribe`, `event_fetch_batch`, `event_ack`, `presence_*`.
  Match: "live updates", "SSE", "notifications", "who's online". → `subsystems/platform.md`
- **REST endpoint registry** — catalog-driven REST gateway. `rest_register_endpoint`,
  `rest_list_endpoints`, `rest_openapi_spec`, `rest_log_invocation`. Match: "expose
  a REST API", "OpenAPI". → `subsystems/platform.md`
- **MC2DB tool registry + r10_ wrappers** — expose DB ops as MCP tools for AI
  agents. `mc2db.create_server`, `mc2db.register_tool/prompt/resource`, and the
  `r10_*` tool handlers (skill/sessions/prompts/models/memory/context/catalog/
  health). Match: "expose tools to Claude", "MCP", "AI agent calls our DB". → `subsystems/platform.md`
- **Log drains** — export audit/events to HTTP/S3/file/OTLP. `log_drain_set`,
  `log_drain_enable/disable/list`, `log_drain_record_run`. Match: "ship logs to
  SIEM", "export audit". → `subsystems/platform.md`
- **Metrics** — Prometheus scrape. `metrics_prometheus_scrape`. Match:
  "Prometheus", "Grafana", "monitoring". → `subsystems/platform.md`
- **Backup / PITR** — backup manifests + verification. `backup_manifest_record`,
  `backup_verification_record`, `backup_manifest_latest`. Match: "backups",
  "recovery". → `subsystems/platform.md`
- **Preview environments** — sandbox seeding + promotion gates. `preview_env_create`,
  `preview_env_record_seed`, `preview_env_promote_check`. Match: "staging", "demo
  env", "anonymized test data". → `subsystems/platform.md`
- **Idempotency + budget** — duplicate suppression + token quotas. Built into
  `call`/`submit_render` (idempotency_key) + `check_budget`. Match: "exactly once",
  "rate limit", "cost cap". → `subsystems/models.md`
- **Governance audit** — every operation emits a `malu$audit_event`. `audit_event`,
  `audit_status`. Match: "audit trail", "who did what", "compliance log". → `subsystems/platform.md`

### `advanced_*` family (27 functions)
Framework-integration variants of the core register/read calls, taking richer
jsonb args. When a user needs one, **read its exact signature live** from the
canonical SQL (`grep "CREATE FUNCTION advanced_"`). Don't memorise them; know
they exist as "the power-user version of the core calls."

---

## ITERATION NOTE

v2 of this file. Areas are complete (every capability is named above, so you never
miss a fit). Depth is concentrated in the core path; subsystem files hold the next
layer; the canonical SQL is the source of truth for everything else. Deepen a
subsystem file only when a real grilling session shows it's needed.