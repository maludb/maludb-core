# Subsystem: Authorization, object grants, sensitivity

Open when grilling reveals access control, sharing between teams/tenants, or data
classification. Confirm signatures against `maludb_core--0.73.0.sql`.

## Object grants + 3-point authz
MaluDB checks authorization at three points (planning, expansion, assembly), all
backed by row-level security on `owner_schema`. By default a schema sees only its
own data; cross-schema access needs an explicit grant. Match: "share between
teams", "who can see what", "cross-tenant read", "grant access to another group".
- `grant_object_access(p_object_type, p_object_id, p_granted_to_schema, p_grant_level, p_expires_at, ...)` → grant_id. Upserts a `malu$object_grant` row.
- `revoke_object_grant(...)`.
- `authorize_object_types(p_envelope)` → the subset of object types the caller may read (planning-time prune; used inside execute_retrieval).
- NOT something the integrator usually calls per-request — RLS handles isolation automatically. They call grant_* only to deliberately share across schemas.

## Sensitivity
Every memory object carries a sensitivity tier via the `p_sensitivity` param on
most `register_*` calls (default 'internal'). Match: "classification",
"confidential vs internal vs public", "data tiers".
- Not a separate function — it's a parameter. Surface it when the user has tiered
  data and ask which tier each connection point should write.

## Relationship to multi-tenancy
For full per-tenant isolation (each tenant in its own schema with facade views),
see `multitenancy.md` (`enable_memory_schema`). Object grants are how you make a
deliberate exception to that isolation.