# Subsystem: Schema-local memory (multi-tenancy)

Open when grilling reveals per-customer/per-team isolation. Confirm signatures
against `maludb_core--0.73.0.sql`.

## enable_memory_schema — the opt-in
A tenant calls this once and gets facade views (`maludb_subject`, `maludb_claim`,
`maludb_fact`, `maludb_memory`, `maludb_skill`, etc.) created inside their own
schema, auto-filtered to their data by RLS. They then use the plain view names
instead of the `maludb_core.*` functions. Match: "SaaS tenants", "per-customer
isolation", "each team their own memory", "multi-tenant".
- `enable_memory_schema(p_schema)` → (schema_name, enabled_version, object_count). Idempotent — re-running refreshes the views. Creates ~54+ objects (views + helper functions + RLS).
- After enabling, the tenant sets `search_path` to their schema + `maludb_core` and works through the facade (e.g. `SELECT * FROM maludb_subject`, `maludb_upload_document(...)`, `maludb_skill_search(...)`).

## How it relates to the integration
This is an architecture-level decision, not a per-moment connection point. If the
user's app is multi-tenant, recommend `enable_memory_schema` per tenant as the
setup step, then the per-moment connection points (claim/fact/correction) operate
through that tenant's facade and RLS keeps tenants apart automatically.

- Cross-tenant sharing, when deliberately needed, goes through object grants (authz.md).
- The README quickstart shows the opt-in pattern:
  `GRANT maludb_memory_executor TO <user>; ... SELECT maludb_core.enable_memory_schema();`