# MaluDB User Manual

This manual is the user-facing guide for the current MaluDB repository. It is
written for operators, database users, model-session users, MC2DB tool authors,
and developers who need to install, run, and exercise the Release 1.x system.

The white papers remain the conceptual source material. This manual describes
the product surface that exists in this repository.

## 1. Current Scope

MaluDB is a memory DBMS built on PostgreSQL 17. It is delivered as:

- `maludb_core`, a PostgreSQL extension containing C code, SQL objects,
  PL/pgSQL APIs, catalog tables, vector helpers, Session Context, the memory
  object model (sources, claims, facts, episodes, memories, MDOs,
  relationships), bitemporal truth, the Temporal Supersession Engine, the
  Derivation Ledger, SVPOR registries, MAUT confidence/precision scoring,
  lifecycle/decay/legal hold, the retrieval planner, hybrid search,
  authorization-aware retrieval, the Workflow Extraction Engine, the Skill
  Runtime, Active Memory Pools, Episode replay, Local Node sync, the Model
  Registry, and MC2DB catalog objects.
- `maludb_modeld`, a companion model gateway daemon that polls PostgreSQL for
  pending model requests and runs configured local model backends.
- `maludb_mc2dbd`, a companion MC2DB listener that exposes database-governed
  tools through MCP-shaped JSON-RPC over HTTP or HTTPS.
- `mcp-broker`, a stdlib-only Python reference broker for external (non-database)
  MCP tools.
- C, Python, Node.js, and PHP SDKs.
- Bootstrap, validation, field-test, packaging, and systemd assets for Ubuntu
  24.04 LTS.

### 1.1 Current Version

| | |
|---|---|
| Extension `default_version` | **0.105.3** (0.105.3: text comparisons in functions called with a `name` argument use their indexes — the per-statement dirty-queue purge and memory search no longer scan a schema's rows; 0.105.2: foreign-key indexes for the extension's bulk deletes — source packages, community replacement, ANN-indexed compartments; 0.105.1: `malu_vector` text output reads back exactly, so dumps and copies keep embeddings bit for bit; 0.105.0: `pg_dump` carries MaluDB's data — data tables registered with `pg_extension_config_dump`, installed rows and per-database secrets excluded; 0.101.0–0.104.0: unified-graph path finding, graph communities and analytics, in-core graph import, and the relational data-model graph — see CHANGELOG; on 0.100.0 document/note reindex protocol: a background worker re-derives a document's/note's SVPOR graph footprint against the current graph via `maludb_memory_reindex_claim` → `maludb_memory_reindex_apply` (replace the `$source`-anchored statement footprint, re-ingest idempotently with the document section stripped; shared subjects/verbs merge; embeddings refresh via the 0.95.0 dirty-queue triggers), with `last_indexed`/`last_indexed_model` watermarks on `malu$document` — the documents/notes analogue of the 0.99.0 skill reindex; core never calls a model — on 0.99.0 skill reindex protocol: a background worker re-derives a skill's discovery tags against the current graph via `maludb_skill_reindex_claim` → `maludb_skill_reindex_apply` (replace-`extracted`, preserves curator `manual` tags), with `last_indexed`/`last_indexed_model` watermarks on `malu$skill_package`; core never calls a model — a `claim → apply` contract an external worker drives — on 0.98.0 note retrieval by subject/verb: one-call `maludb_note_search` over extracted SVO edges — subject patterns against both statement endpoints, verb-exact/verb-like bidirectional containment, both statement→document rails, one row per note with matched edges aggregated — plus deterministic `maludb_note_query_parse` free-text parsing against the tenant verb catalog — on 0.97.0 agent-skill distribution, 0.96.0 event kinds as first-class subject types, and the 0.95.0 semantic spine; earlier: episodes-as-subjects, memory-model episodes/attributes, vector compartments, in-database model gateway, link helpers, one-call extraction ingest; V4 acceptance artefacts remain `scripts/maludb-fieldtest-v4`, `bench/v4/run-bench`, and `docs/v4/acceptance-matrix.md`) |
| Last release tag | **`v4.5.0`** at extension `0.100.0` (skill + document/note reindex protocols, agent-skill distribution, note retrieval; 2026-06-17) |
| Supported PostgreSQL majors | 16, 17, 18 (PG 17 is the blocking CI target) |
| Test suite | 91 `pg_regress` targets on PG 17 + restd / realtimed / CLI / libmaludb v0.2 / pageindexd parser smoke |
| Shipped services | `maludb_modeld`, `maludb_mc2dbd`, `mcp-broker`, `maludb-restd`, `maludb-realtimed`, `maludb-pageindexd` |
| Shipped SDKs | C (`libmaludb` v0.2.0 — pool/skill/node wrappers), Python, Node.js, PHP (`maludb/client` via Composer) |
| Shipped CLI | `maludb` v0.1.0 (V3-CLI-01) |
| Roadmap status | `requirements.md` §9 Stages 1–16+ shipped through V4 GA — see [`version4-pageindex-plan.md`](../version4-pageindex-plan.md) |

For day-to-day operations the version that matters is the **extension migration
chain version** (`maludb_core.control`'s `default_version`), the **latest release
tag** (`v4.1.0`), and the **supported PG majors**. These values are checked
across `maludb_core.control`, [`README.md`](../README.md),
[`CHANGELOG.md`](../CHANGELOG.md), and this manual by
`scripts/maludb-check-doc-consistency`.

### 1.2 Shipped Memory Surface (Stages 1–7)

These memory-DBMS surfaces are user-facing today, not roadmap:

- Source Packages, Claims, Facts, Episode Objects, Memories, Memory Detail
  Objects, and typed Relationship Edges (Stage 2).
- Bitemporal valid-time / transaction-time, the Temporal Supersession Engine
  (corrections never overwrite history), SVPOR registries, MAUT-based
  confidence/precision scoring, lifecycle + decay + legal hold (Stage 3).
- Retrieval planner, hybrid search (FTS + pg_trgm + graph + vector), query
  hints, three-stage authorization-aware retrieval (Stage 4).
- Workflow Extraction Engine, Skill Runtime as a governed state machine,
  manual subject / verb / keyword skill discovery, public skills, find/get/fork
  skill APIs, Active Memory Pool manager, Episode replay (Stage 5).
- User-facing onboarding roles: `maludb_read`, `maludb_user`, `maludb_admin`,
  plus a guarded short `maludb` alias where that role name is not already used
  by an existing operator login.
- Local Node sync protocol, Model Registry blue-green + dual-space routing,
  embedding adapters with capability negotiation, advanced MC2DB tools, and
  the external MCP broker reference implementation (Stage 6).
- Hardening: performance baselines, security review (RLS / pgaudit /
  semantic-slice grants), packaging, public-alpha tag (Stage 7).

### 1.3 What's NOT in 2.0.0-alpha

Version 3 is the platform-ergonomics track scoped in §1.5 and §9 of
[`requirements.md`](../requirements.md). The following are V3 surfaces (not
shipped today): first-party API tokens/JWT, governed secret store, curated REST
gateway, durable queue, scheduler, verbatim source archive v1 with object
storage adapters, memory event stream + presence, vector metadata filters and
multilevel HNSW / pgvector HNSW, embedding job pipeline, public retrieval
endpoint, `maludb` CLI, expanded metrics, log drains, backup/PITR manifests,
self-hosted preview environments, read-replica posture.

## 2. Architecture

MaluDB keeps PostgreSQL as the durable authority.

| Component | Role |
|---|---|
| PostgreSQL 17 | Base database engine, MVCC, WAL, SQL, roles, extensions. |
| `maludb_core` | Extension schema, catalog tables, C helpers, SQL APIs, regression-tested behavior. |
| `pgvector` | Required dependency for the base vector smoke table and exact compartment search. |
| `maludb_modeld` | Out-of-backend model execution daemon for local runtime requests. |
| `maludb_mc2dbd` | MCP-compatible listener and tool dispatcher. |
| `mcp-broker` | Reference broker for external (non-database) MCP tools (Stage 6). |
| `mc2db` schema | Response-context procedures used by database-backed tools. |
| SDKs | C (`libmaludb`), Python, Node.js, PHP (`maludb/client` via Composer) — all four validated against the live extension. |

Ordinary PostgreSQL backends do not run model inference and do not shell out.
External model execution and external tool execution happen in sidecar
processes so PostgreSQL remains the system of record rather than the process
isolation boundary.

## 3. Requirements

This section assumes Ubuntu 24.04 LTS is already installed. The bootstrap in
section 4 installs the normal operator requirements automatically; use the
commands below when preparing a host manually or debugging a dependency issue.
Do not run every command in section 3 and then repeat section 4.1 as a single
linear script; choose the manual path or the bootstrap path for the same host.

### 3.1 Base Utilities

```bash
sudo apt-get update
sudo apt-get install -y git curl ca-certificates jq openssl
```

### 3.2 PostgreSQL 17 From PGDG

MaluDB targets PostgreSQL 17 from the PostgreSQL Global Development Group apt
repository, not the older PostgreSQL packages from the stock Ubuntu repo.

```bash
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt noble-pgdg main" | \
  sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt-get update
sudo apt-get install -y \
  postgresql-17 postgresql-client-17 \
  postgresql-server-dev-17 postgresql-server-dev-all
```

Verify:

```bash
/usr/lib/postgresql/17/bin/pg_config --version
psql -V
pg_lsclusters
```

### 3.3 Required PostgreSQL Extensions

```bash
sudo apt-get install -y \
  postgresql-17-pgvector \
  postgresql-17-pgaudit \
  postgresql-17-partman
```

`pgvector` is a hard dependency of `maludb_core`. `pgaudit` and `pg_partman`
are part of the planned operator bundle and hardening posture.

### 3.4 Build Toolchain

Minimum build dependencies:

```bash
sudo apt-get install -y \
  build-essential pkg-config cmake \
  bison flex \
  libicu-dev libssl-dev libreadline-dev zlib1g-dev \
  liblz4-dev libzstd-dev libxml2-dev
```

Developer and static-analysis tools:

```bash
sudo apt-get install -y \
  clang-18 clang-tools-18 clang-tidy-18 llvm-18-dev \
  lcov gcovr cppcheck
```

### 3.5 MC2DB Listener Libraries

The `maludb_mc2dbd` listener links against libpq, libmicrohttpd, jansson,
GnuTLS, and libcurl.

```bash
sudo apt-get install -y \
  libpq-dev libmicrohttpd-dev libjansson-dev \
  libgnutls28-dev libcurl4-openssl-dev
```

### 3.6 Local Model Runtime Requirements

For local model execution, first check out the MaluDB repository, then build
the vendored `llama.cpp` runtime from the repository root:

```bash
git clone <maludb-core-url> ~/maludb-core
cd ~/maludb-core
git submodule update --init --recursive
make -C runtime
```

CUDA-capable hosts can build the CUDA variant:

```bash
make -C runtime cuda
```

Install a model runtime binary and model files somewhere readable by the
`maludb_modeld` service user. If you have not run `scripts/maludb-bootstrap`
yet, create the MaluDB service group and users first:

```bash
sudo getent group maludb >/dev/null || sudo groupadd --system maludb
id maludb_modeld >/dev/null 2>&1 || \
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin \
    --gid maludb maludb_modeld
id maludb_mc2dbd >/dev/null 2>&1 || \
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin \
    --gid maludb maludb_mc2dbd

sudo install -d -o maludb_modeld -g maludb /var/lib/maludb/models
sudo install -m 0755 third_party/llama.cpp/build/bin/llama-cli /usr/local/bin/llama-cli
sudo install -m 0644 third_party/llama.cpp/build/bin/lib*.so /usr/local/lib/
sudo ldconfig
```

Place GGUF model files under `/var/lib/maludb/models/`, owned by
`maludb_modeld:maludb`. Do not use a model path under `/home`; the systemd unit
uses `ProtectHome=true`.

### 3.7 Hardware Readiness Checks

CPU-only hosts are valid for development and R1.0 acceptance with small
Q4-quantized models. GPU hosts are preferred for larger local models.

```bash
./scripts/maludb-gpu-check
./scripts/maludb-model-runtime-check --mode=stub
```

For a small CPU-friendly smoke-test model, download Qwen 2.5 0.5B Instruct in
Q4_K_M GGUF format:

```bash
sudo install -d -o maludb_modeld -g maludb /var/lib/maludb/models
sudo curl -fL \
  -o /var/lib/maludb/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
sudo chown maludb_modeld:maludb /var/lib/maludb/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
sudo chmod 0640 /var/lib/maludb/models/qwen2.5-0.5b-instruct-q4_k_m.gguf
```

Then run the local runtime check:

```bash
./scripts/maludb-model-runtime-check \
  --mode=local \
  --model=/var/lib/maludb/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  --prompt="Say hello from MaluDB in one sentence." \
  --max-tokens=32
```

## 4. Installation

### 4.1 Fresh Ubuntu Bootstrap

From a clean Ubuntu 24.04 host:

```bash
git clone <maludb-core-url> ~/maludb-core
cd ~/maludb-core
git submodule update --init --recursive

./scripts/maludb-bootstrap --dry-run
sudo ./scripts/maludb-bootstrap
```

If you already cloned the repository while following section 3.6, do not clone
it again. Start from:

```bash
cd ~/maludb-core
./scripts/maludb-bootstrap --dry-run
sudo ./scripts/maludb-bootstrap
```

The bootstrap installs PostgreSQL 17, required PostgreSQL extensions, build
dependencies, `maludb_core`, service users, config files, service binaries, and
systemd units.

Equivalent make target:

```bash
sudo make bootstrap
```

### 4.2 Manual Extension Build

For development on a host that already has PostgreSQL 17 and pgvector:

```bash
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
sudo make install PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

Create the extension in a database:

```sql
CREATE EXTENSION maludb_core CASCADE;
```

`CASCADE` allows PostgreSQL to install the required `vector` extension when it
is not already present.

### 4.3 Build the Local Model Runtime

The PostgreSQL extension build is separate from the model runtime build.

```bash
# CPU build
make -C runtime

# CUDA build, when the NVIDIA toolchain is available
make -C runtime cuda
```

The runtime build produces `llama-cli` under:

```text
third_party/llama.cpp/build/bin/llama-cli
```

For service use, install the binary and model files under system paths readable
by `maludb_modeld`, for example:

```bash
sudo install -d -o maludb_modeld -g maludb /var/lib/maludb/models
sudo install -m 0755 third_party/llama.cpp/build/bin/llama-cli /usr/local/bin/llama-cli
sudo install -m 0644 third_party/llama.cpp/build/bin/lib*.so /usr/local/lib/
sudo ldconfig
```

Do not store production model files under `/home`. The systemd unit uses
`ProtectHome=true`.

## 5. Validation and Tests

Operator validation:

```bash
./scripts/maludb-validate
```

Field-test automation:

```bash
./scripts/maludb-fieldtest
```

PostgreSQL regression suite:

```bash
sudo --preserve-env make installcheck \
  PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

MC2DB listener service tests:

```bash
make -C mc2dbd test
```

A healthy development run should have no `FAIL` lines. Warnings are expected on
CPU-only hosts when no GPU is present, and when the listener or model daemon has
not yet been started.

## 6. Database Basics

Use the extension schema explicitly or set the search path:

```sql
SET search_path = maludb_core, public;
```

Private MaluDB catalog tables use the `malu$` prefix. Stable public operations
are exposed through SQL functions, views, and MC2DB tools. Prefer the functions
documented here over direct DML against private tables.

Core schemas:

- `maludb_core`: extension-owned tables, views, and SQL functions.
- `mc2db`: MC2DB response-context functions and procedures.

Version check:

```sql
SELECT maludb_core.maludb_core_version();
SELECT maludb_core.maludb_core_release();
```

Stage-boundary check:

```sql
SELECT * FROM maludb_core.stage_boundary_violations();
```

An empty result means no later-stage memory object tables have been installed.

## 7. Accounts and Roles

Accounts are stored in `malu$account`. An account represents a human, service,
agent, application, MCP client, MC2DB client, local node, or admin.

Create a basic human account:

```sql
INSERT INTO malu$account(account_name, account_kind, description)
VALUES ('alice', 'human', 'Example user');
```

Generic roles and account-role bindings live in:

- `malu$role`
- `malu$account_role`

R1.1 also adds LLM-specific PostgreSQL group roles:

- `maludb_llm_admin`
- `maludb_llm_prompt_author`
- `maludb_llm_prompt_approver`
- `maludb_llm_model_admin`
- `maludb_llm_executor`
- `maludb_llm_auditor`

LLM row-level security uses `maludb_core.current_account_id()`. The helper first
reads the `maludb_core.current_account_id` GUC, then falls back to matching
`session_user` against `malu$account.account_name`.

Example tenant binding:

```sql
SET maludb_core.current_account_id = '1';
SELECT maludb_core.current_account_id();
```

Admin and auditor roles bypass RLS by design. Grant them only to trusted service
or audit roles.

## 8. Schema Memory Enablement

MaluDB keeps shared storage in `maludb_core`, but ordinary PostgreSQL schemas
can opt in to schema-local memory views. The enablement step is explicit;
creating a schema by itself does not add memory objects.

```sql
CREATE USER app;
GRANT maludb_user TO app;
CREATE SCHEMA app AUTHORIZATION app;

SET ROLE app;
SET search_path TO app, maludb_core, public;
SELECT * FROM maludb_core.enable_memory_schema();
```

Use standard PostgreSQL role grants for day-to-day onboarding:

```sql
GRANT maludb_read TO reporting_user;     -- schema-local read access
GRANT maludb_user TO app_user;           -- normal read/write use
GRANT maludb_admin TO trusted_operator;  -- admin delegation
```

On fresh installs where `maludb` is not already an operator login, the extension
also creates a guarded short alias:

```sql
GRANT maludb TO app_user;
```

Existing installs that already have a login or superuser named `maludb` leave
that role untouched; use `maludb_user` or the helper script instead:

```bash
psql -d maludb -v role=app_user -v access=write -f sql/grant-memory-access.sql
```

Operators can also run the wrapper script from `psql`:

```bash
psql -d maludb -v schema=app -f sql/enable-memory-schema.sql
```

After enablement, tenant users query familiar schema-local names while rows stay
owner-scoped in extension tables:

```sql
INSERT INTO app.maludb_project(subject_type, canonical_name)
VALUES ('project', 'app migration');

SELECT *
FROM app.maludb_subject;
```

Documents, raw ingest, embeddings, and pools use the same schema-local surface:

```sql
SELECT *
FROM app.maludb_unapplied_ingest;

SELECT app.maludb_upload_document(
    p_title => 'Cutover notes',
    p_content_text => 'Deploy window notes and operator comments',
    p_source_type => 'document',
    p_projects => ARRAY['app migration']
);

SELECT *
FROM app.maludb_vector_search(
    p_subject => 'app migration',
    p_query_embedding => maludb_core.vector_from_real_array('{1,0,0,0}'::real[])
);

INSERT INTO app.maludb_memory_pool(pool_name, task_objective)
VALUES ('app-coding-agent', 'Focused memory for coding agents');

SELECT *
FROM app.maludb_pool_search('app-coding-agent', 'schema views', 20, false);
```

The generated facades include subjects, verbs, source packages, claims, facts,
memories, documents, raw ingest, vector search, memory pools, prompt/model
session objects, skills, workflow objects, and MCP catalog views.

Skills can be made discoverable with manual subjects, verbs, and keywords:

```sql
INSERT INTO maludb_skill(skill_name, version, description, packaging_kind)
VALUES ('meeting_action_item_extractor', '1.0.0',
        'Extract action items from meeting transcripts.', 'markdown');

INSERT INTO maludb_skill_keyword(skill_id, keyword)
SELECT skill_id, 'action items'
FROM maludb_skill
WHERE skill_name = 'meeting_action_item_extractor';

INSERT INTO maludb_skill_subject(skill_id, subject_name)
SELECT skill_id, 'meeting transcript'
FROM maludb_skill
WHERE skill_name = 'meeting_action_item_extractor';

INSERT INTO maludb_skill_verb(skill_id, verb_name)
SELECT skill_id, 'extract'
FROM maludb_skill
WHERE skill_name = 'meeting_action_item_extractor';

SELECT skill_name, owner_schema, match_reasons
FROM maludb_skill_search(
    p_query => 'extract action items',
    p_subject => 'meeting transcript',
    p_verb => 'extract'
);

SELECT payload
FROM maludb_skill_get('maludb_public', 42);
```

Curated public skills live in the `maludb_public` schema with
`visibility = 'public'`. Tenant schemas include them in `maludb_skill_search`
by default, and can fork public or explicitly fork-granted skills with
`maludb_skill_fork`. MC2DB clients use the matching `skill.find`, `skill.get`,
and `skill.fork` tools. MC2DB calls must include the tenant schema explicitly:
`skill.find` and `skill.get` require `requesting_schema`, and `skill.fork`
requires `target_owner_schema`.

## 9. Model Providers and Aliases

Model providers describe where model execution happens. Model aliases describe
which model a user or session should request.

Supported provider kinds:

| Provider kind | Meaning |
|---|---|
| `stub` | Deterministic in-database test adapter. |
| `local_runtime` | Local runtime such as `llama-cli`. |
| `local_http` | Local HTTP inference service. |
| `local_socket` | Local socket inference service. |
| `cloud_api` | Cloud provider metadata. Dispatch is not yet production-wired in `maludb_modeld`. |
| `shell_adapter` | Reserved catalog value. |

Register a deterministic stub provider:

```sql
SELECT register_model_provider(
    'stub-provider',
    'stub',
    'stub',
    NULL,
    'internal');

SELECT register_model_alias(
    'stub-small',
    'stub-provider',
    'stub-model-1');
```

Register a local llama model:

```sql
SELECT register_model_provider(
    'local-llama',
    'local_runtime',
    'llama-cli',
    NULL,
    'internal');

SELECT register_model_alias(
    'tiny',
    'local-llama',
    'qwen2.5-0.5b-instruct',
    '/var/lib/maludb/models/qwen2.5-0.5b.q4_k_m.gguf',
    NULL,
    'Q4_K_M',
    32768,
    '{"temperature":0,"max_tokens":256}'::jsonb);
```

Provider secrets are references, not literal credentials. Normal callers should
read provider metadata through public views that omit `secret_ref`.

## 10. Prompt Templates

Prompt templates are versioned. A template can use either the legacy `body`
field or channel fields:

- `system_template`
- `developer_template`
- `user_template`

When any channel column is set, channel rendering is canonical. If no channel
columns are set, `body` is used.

Variables can be written in either form:

- `{{name}}`
- `:name`

Both resolve from the same JSONB variables object.

Create a prompt template:

```sql
SELECT register_prompt_template(
    p_name => 'greet',
    p_body => 'fallback',
    p_owner_account => 'alice',
    p_variables => NULL,
    p_version => NULL,
    p_system_template => 'You are concise.',
    p_developer_template => 'Prefer operational detail.',
    p_user_template => 'Say hello to :name about {{topic}}.');
```

Preview a prompt without writing a render row:

```sql
SELECT *
FROM preview_prompt(
    1,
    'greet',
    NULL,
    '{"name":"world","topic":"MaluDB"}'::jsonb);
```

Render a prompt and store an audit artifact:

```sql
SELECT render_prompt(
    1,
    'greet',
    NULL,
    '{"name":"world","topic":"MaluDB"}'::jsonb);
```

## 11. Sessions and Session Context

Session Context is short-term context for model sessions. It is not long-term
memory, not a fact, not a claim, and not a source package.

Create a session:

```sql
SELECT start_session(
    'alice',
    'stub-small',
    'greet',
    NULL,
    4096);
```

Append ordered context blocks:

```sql
SELECT append_context(
    p_session_id => 1,
    p_role => 'system',
    p_content_text => 'Be terse.',
    p_source_label => 'manual',
    p_sensitivity => 'internal');

SELECT append_context(
    p_session_id => 1,
    p_role => 'user',
    p_content_jsonb => '{"task":"summarize install state"}'::jsonb,
    p_source_label => 'manual',
    p_sensitivity => 'internal');
```

Read context:

```sql
SELECT * FROM read_context(1);
```

Clear context:

```sql
SELECT clear_context(1);
```

Close a session:

```sql
SELECT close_session(1, 'closed');
```

Every context block stores a content hash. Rendered prompts store prompt hashes,
context hashes, and context block counts so prompt assembly can be audited.

## 12. Model Requests and Responses

The preferred path is:

1. Start a session.
2. Append context.
3. Render a prompt.
4. Submit the render to a model alias.
5. Read the response.

Submit a stored render:

```sql
SELECT submit_render(
    p_render_id => 1,
    p_alias_name => 'stub-small',
    p_account_name => 'alice',
    p_generation_params => '{"temperature":0}'::jsonb,
    p_timeout_ms => 30000);
```

For stub providers, process synchronously:

```sql
SELECT mc_stub_process(1);
SELECT * FROM get_response(1);
```

One-call convenience path:

```sql
SELECT *
FROM run_session_step(
    p_session_id => 1,
    p_template_name => 'greet',
    p_alias_name => 'stub-small',
    p_variables => '{"name":"world","topic":"MaluDB"}'::jsonb,
    p_account_name => 'alice');
```

For non-stub providers, `maludb_modeld` picks up pending rows from
`malu$model_request` and writes a row to `malu$model_response`.

Start the model daemon:

```bash
sudo systemctl enable --now maludb-modeld
systemctl status maludb-modeld --no-pager
```

Model run audit view:

```sql
SELECT *
FROM model_run_audit
ORDER BY rendered_at DESC
LIMIT 20;
```

## 13. Vector Search

MaluDB has two vector surfaces:

- `malu$vector_demo`, a pgvector smoke-test table proving the dependency is
  installed.
- Stage 1.7 vector compartments, which store little-endian float32 embeddings
  as `bytea` and perform compartment-first exact search.

The compartment model is:

```text
namespace + subject + verb -> vector compartment -> vector chunks
```

Register a compartment and insert chunks from `psql`:

```sql
SELECT register_vector_compartment(
    'manual',
    'installation',
    'explains',
    3,
    'demo-3d',
    'cosine') AS compartment_id \gset

SELECT register_vector_chunk(
    :compartment_id,
    'Install MaluDB with scripts/maludb-bootstrap.',
    vector_from_real_array(ARRAY[1.0, 0.0, 0.0]::real[]),
    'demo-3d');

SELECT register_vector_chunk(
    :compartment_id,
    'Run scripts/maludb-validate after installation.',
    vector_from_real_array(ARRAY[0.9, 0.1, 0.0]::real[]),
    'demo-3d');
```

Search directly:

```sql
SELECT *
FROM search_memory_exact(
    'manual',
    'installation',
    'explains',
    vector_from_real_array(ARRAY[1.0, 0.0, 0.0]::real[]),
    5,
    'cosine');
```

Explain the compartment:

```sql
SELECT *
FROM explain_vector_search('manual', 'installation', 'explains');
```

### 12.1 Search modes

`maludb_core` ships two search modes for vector compartments. The public entry
point `search_memory_exact(namespace, subject, verb, query, limit, metric)`
dispatches between them based on the compartment's `search_mode` column — the
function name predates ANN support and is preserved for backward compatibility;
it auto-routes today:

- **`search_mode = 'exact'`** (default for a new compartment) — the dispatcher
  scans the compartment row set and returns the K closest chunks under the
  configured distance metric. This is the ground truth for benchmarking and
  tests.
- **`search_mode = 'local_ann'`** (after `ann_build(...)`) — the dispatcher
  routes through `maludb_ann_search_c` over the single-layer **Navigable
  Small-World (NSW)** graph stored in `malu$ann_index`, merges with chunks
  added since the last build (`malu$ann_delta`), and filters out tombstoned
  chunks (`malu$vector_tombstone`).

This is **single-layer NSW**, not multilevel HNSW. Functionally similar at
small-to-medium compartment sizes; multilevel HNSW is a deferred upgrade. The
V3-VEC-01 ticket decides
whether v3 upgrades the local graph to multilevel HNSW or delegates large-
compartment ANN to `pgvector` HNSW with exact search preserved for tests.

```sql
-- Build a local NSW index for a compartment (flips search_mode to 'local_ann').
SELECT ann_build(:compartment_id, 16, 200, 'cosine');

-- Inspect the index.
SELECT * FROM ann_status(:compartment_id);

-- search_memory_exact(...) now auto-routes through the NSW graph + delta.
SELECT * FROM search_memory_exact(
    'manual', 'installation', 'explains',
    vector_from_real_array(ARRAY[1.0, 0.0, 0.0]::real[]),
    5,
    'cosine');

-- Drain delta + clear tombstones when the compartment churns.
SELECT ann_rebuild(:compartment_id);
```

## 14. MC2DB Listener

`maludb_mc2dbd` exposes MaluDB as an MCP-compatible JSON-RPC listener. Default
development binding is:

```text
http://127.0.0.1:5329
```

Start the listener:

```bash
sudo systemctl enable --now maludb-mc2dbd
sudo systemctl status maludb-mc2dbd --no-pager | head -15
```

Health probe:

```bash
curl -fsS http://127.0.0.1:5329/healthz
```

Initialize:

```bash
curl -fsS -X POST http://127.0.0.1:5329/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
```

List tools:

```bash
curl -fsS -X POST http://127.0.0.1:5329/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

Call `maludb.health`:

```bash
curl -fsS -X POST http://127.0.0.1:5329/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"maludb.health","arguments":{}}}'
```

### 13.1 Seeded Tools

The `maludb.r10` server profile currently advertises 17 tools:

| Tool | Implementation |
|---|---|
| `maludb.health` | `sql_function` |
| `maludb.catalog.describe` | `sql_function` |
| `maludb.models.list` | `sql_function` |
| `maludb.prompts.list` | `sql_function` |
| `maludb.sessions.create` | `sql_function` |
| `maludb.sessions.get` | `sql_function` |
| `maludb.context.append` | `sql_function` |
| `maludb.context.read` | `sql_function` |
| `maludb.prompts.render` | `sql_function` |
| `maludb.models.submit` | `sql_function` |
| `maludb.responses.get` | `sql_function` |
| `maludb.memory.search.exact` | `sql_function` |
| `skill.find` | `sql_function` |
| `skill.get` | `sql_function` |
| `skill.fork` | `sql_function` |
| `maludb.r10.external_exec_demo` | `external_exec` exemplar |
| `maludb.r10.mcp_proxy_demo` | `mcp_proxy` exemplar |

Tool calls always write audit rows to `malu$mc2db_invocation`.

### 13.2 MC2DB Tool Errors

Protocol errors appear in the JSON-RPC top-level `error` object. Tool errors are
successful JSON-RPC responses with:

```json
{
  "result": {
    "isError": true,
    "_meta": {
      "error_code": "TOOL_EXECUTION_ERROR"
    }
  }
}
```

This distinction matters for clients. A missing tool, bad input, permission
problem, timeout, or upstream failure is a tool result, not a JSON-RPC protocol
failure.

## 15. Registering MC2DB Tools

Tools are catalog rows. Each row has an `implementation_type`:

- `sql_function`
- `external_exec`
- `mcp_proxy`
- `http_endpoint`

Register tools through `mc2db.register_tool`.

### 14.1 SQL Function Tool

Tool functions take exactly two arguments:

```sql
CREATE FUNCTION app.my_tool(args jsonb, context jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $body$
BEGIN
    CALL mc2db.put_object(jsonb_build_object(
        'content', jsonb_build_array(
            jsonb_build_object('type','text','text','hello')),
        'structuredContent', jsonb_build_object('ok', true),
        'isError', false));
END;
$body$;
```

Register it:

```sql
SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name => 'app.my_tool',
    description => 'Example SQL-backed tool.',
    implementation_type => 'sql_function',
    input_schema => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object(
        'function_signature', 'app.my_tool(jsonb, jsonb)',
        'pinned_search_path', 'app, maludb_core, pg_catalog'));
```

Use `mc2db.put_error(message, details)` for expected tool failures.

### 14.2 External Exec Tool

`external_exec` runs an absolute executable path from the listener process. The
child receives one JSON object on stdin:

```json
{
  "tool_name": "app.echo",
  "call_id": "...",
  "arguments": {},
  "context": {}
}
```

The child must write one JSON object to stdout:

```json
{"ok":true,"result":{"structuredContent":{"ok":true}}}
```

or:

```json
{"ok":false,"error":{"code":"BAD_INPUT","message":"missing value"}}
```

Register an executable:

```sql
SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name => 'app.echo_external',
    description => 'Example external executable.',
    implementation_type => 'external_exec',
    input_schema => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    timeout_ms => 1000,
    max_output_bytes => 1048576,
    impl_metadata => jsonb_build_object(
        'command_path', '/usr/local/maludb/tools/echo_tool',
        'argv_template', '[]'::jsonb,
        'environment', '{}'::jsonb));
```

Security notes:

- `command_path` must be absolute.
- Environment is scrubbed by the listener.
- Output size and timeout are enforced.
- Treat external tools as privileged integration points.

### 14.3 MCP Proxy Tool

`mcp_proxy` forwards a tool call to another MCP server while keeping MaluDB as
the registry and audit authority.

Register an HTTP proxy target:

```sql
SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name => 'app.remote_tool',
    description => 'Proxy to a remote MCP tool.',
    implementation_type => 'mcp_proxy',
    input_schema => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object(
        'remote_server_name', 'remote',
        'remote_tool_name', 'echo',
        'transport_type', 'http',
        'endpoint_url', 'http://127.0.0.1:9000/'));
```

The listener also supports stdio proxy transport with `command_path` and `argv`.

### 14.4 HTTP Endpoint Tool

`http_endpoint` dispatches a tool call to a generic HTTP endpoint.

```sql
SELECT mc2db.register_tool(
    server_name => 'maludb.r10',
    tool_name => 'app.http_echo',
    description => 'POST arguments to an HTTP endpoint.',
    implementation_type => 'http_endpoint',
    input_schema => '{"type":"object"}'::jsonb,
    output_schema => '{"type":"object"}'::jsonb,
    impl_metadata => jsonb_build_object(
        'endpoint_url', 'http://127.0.0.1:9001/echo',
        'http_method', 'POST',
        'static_headers', '{"X-App":"maludb"}'::jsonb,
        'auth_type', 'none'));
```

JSON responses are returned as structured content. Non-JSON responses are
returned as text content. Transport failures and non-2xx HTTP status codes
surface as `UPSTREAM_ERROR`.

## 16. MC2DB Security

Before exposing MC2DB beyond localhost:

1. Enable bearer-token authentication.
2. Enable native TLS or place the listener behind a TLS-terminating reverse
   proxy.
3. Bind only to trusted interfaces.
4. Restrict firewall access.
5. Review all non-`sql_function` tools.
6. Verify the listener PostgreSQL role is not a superuser.

The listener can require:

```bash
Authorization: Bearer <token>
```

The binary accepts `--bearer-token`, `BEARER_TOKEN`, or the legacy
`MALUDB_MC2DBD_TOKEN` environment variable.

## 17. Monitoring

The listener exposes Prometheus metrics:

```bash
curl -fsS http://127.0.0.1:5329/metrics
```

Metric families:

- `maludb_mc2dbd_up`
- `maludb_mc2dbd_invocations_total`
- `maludb_mc2dbd_invocation_duration_ms_sum`
- `maludb_model_request_count`

For PostgreSQL internals, run a standard PostgreSQL exporter in addition to the
MC2DB listener metrics.

## 18. Logs and Audit

System logs:

```bash
journalctl -u maludb-mc2dbd -n 100 --no-pager
journalctl -u maludb-modeld -n 100 --no-pager
```

PostgreSQL logs:

```text
/var/log/postgresql/postgresql-17-main.log
```

MC2DB audit:

```sql
SELECT tool_name, implementation_type, request_user, success,
       error_code, started_at, duration_ms
FROM malu$mc2db_invocation
ORDER BY started_at DESC
LIMIT 50;
```

Model audit:

```sql
SELECT account_name, template_name, alias_name, provider_kind,
       request_status, response_status, adapter_name, rendered_at
FROM model_run_audit
ORDER BY rendered_at DESC
LIMIT 50;
```

## 19. Backups

MaluDB R1.x uses ordinary PostgreSQL backup tools.

Minimum backup:

```bash
pg_dump -Fc maludb > maludb-$(date +%F).dump
```

Also back up:

- `/etc/maludb/`
- TLS certificates and keys, if the listener terminates TLS.
- Any model files under `/var/lib/maludb/models/`.
- Any external executables registered as MC2DB tools.

Test restores regularly.

## 20. Troubleshooting

### `CREATE EXTENSION maludb_core` fails because `vector` is missing

Install pgvector for PostgreSQL 17:

```bash
sudo apt-get install -y postgresql-17-pgvector
```

Then retry:

```sql
CREATE EXTENSION maludb_core CASCADE;
```

### `scripts/maludb-validate` warns that no GPU is detected

This is acceptable for CPU-only development and CPU acceptance. Use a small
Q4-quantized model for local runtime tests.

### `maludb_modeld` cannot read the model

Check path, ownership, and systemd hardening:

```bash
sudo ls -l /var/lib/maludb/models
journalctl -u maludb-modeld -n 50 --no-pager
```

Model files should be readable by `maludb_modeld:maludb` and should not live
under `/home`.

### MC2DB returns `TOOL_NOT_FOUND`

Check the catalog:

```sql
SELECT tool_name, enabled, implementation_type
FROM malu$mc2db_tool
ORDER BY tool_name;
```

### MC2DB returns `UPSTREAM_ERROR`

The listener reached an external implementation path but the upstream failed.
Check:

- `endpoint_url` for `http_endpoint` or HTTP `mcp_proxy`.
- `command_path` and executable bit for stdio `mcp_proxy`.
- Network reachability from the listener host.
- `journalctl -u maludb-mc2dbd`.

### RLS hides expected rows

Confirm the current account binding:

```sql
SHOW maludb_core.current_account_id;
SELECT maludb_core.current_account_id();
```

Confirm the connected PostgreSQL role has the required LLM group role.

## 21. Version 3 Preview

Version 3 is the post-`v2.0.0-alpha` **platform-ergonomics** track. It does
not revise the memory model, provenance, bitemporal discipline, three-stage
authorization, or atomic multi-model writes documented in the rest of this
manual; it adds the developer and operator surfaces that a self-hosted memory
DBMS needs (identity, REST gateway, CLI, durable queue, scheduler, storage
adapters, realtime, metrics, log drains, backups, preview environments).

Authoritative V3 documents:

- [`requirements.md`](../requirements.md) §1.5 and §9 Stages 8–15.

V3 stage map:

| Stage | Tickets | What it adds |
|---|---|---|
| **Stage 8** ✅ | V3-DOC-01, V3-DOC-02 | Doc reconciliation, V3 vs V2 boundaries, `scripts/maludb-check-doc-consistency`. *(this section is part of Stage 8.)* |
| **Stage 9** | V3-AUTH-01, V3-SECRET-01 | Personal/service tokens + JWT; governed secret store. |
| **Stage 10** | V3-API-01, V3-CLI-01, V3-SDK-01 | Curated REST gateway with OpenAPI; first-party `maludb` CLI; SDK parity + generated types. |
| **Stage 11** | V3-QUEUE-01, V3-CRON-01 | Durable job queue (DLQ, lease, idempotency); scheduler. |
| **Stage 12** | V3-STOR-01 | Verbatim source archive v1 (local FS + S3 adapters, signed URLs, retention/legal hold). |
| **Stage 13** | V3-REALTIME-01, V3-PRESENCE-01 | Memory event stream (SSE/WebSocket); active pool presence. |
| **Stage 14** | V3-VEC-01, V3-EMBED-01, V3-RET-01 | Vector metadata filters; multilevel HNSW decision; embedding job pipeline; public retrieval endpoint. |
| **Stage 15** | V3-OBS-01, V3-LOG-01, V3-BACKUP-01, V3-ENV-01, V3-REPL-01 | Expanded metrics; log drains; backup/PITR manifest; self-hosted preview environments; read-replica posture. |

V3 explicitly does NOT scope: a full email/password/OAuth/SSO/MFA identity
provider, a global edge function network, CDN-backed public asset hosting and
image transformations, a Supabase Studio equivalent, billing/orgs/spend caps,
a generic GraphQL API over all MaluDB tables, an extension marketplace, or
active-active replication.

While V3 is in progress, the doc-consistency CI gate (Stage 8) enforces that
the version, release tag, supported PG majors, and shipped services/SDKs do
not drift between `maludb_core.control`, [`README.md`](../README.md),
[`CHANGELOG.md`](../CHANGELOG.md), and this manual.

## 22. Further Reading

- [Install Guide](install.md)
- [Field Test Playbook](field-test.md)
- [Runtime Guide](runtime.md)
- [MC2DB Contract](maludb-mc2dbd-contract.md)
- [Model Gateway Contract](maludb-modeld-contract.md)
- [Post-Install Hardening](post-install-hardening.md)
- [Monitoring](monitoring.md)
- [Full Roadmap Requirements](../requirements.md)
