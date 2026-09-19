\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.106.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.106.0  --  the engine learns who is asking
--
-- Until now a tenant had one axis of isolation, `owner_schema`, and nothing
-- inside it: no principal, no scope, and a `sensitivity` column that was
-- stored on four tables and filtered on none. A host running many agents and
-- people against one tenant (one namespace per agent, per department, one for
-- the organisation) was the only thing keeping them apart.
--
-- This release gives the engine the same picture:
--
--   1. `malu$principal` + `malu$principal_scope` -- tenant-scoped (the
--      cluster-wide `malu$account` / `malu$partition` would show one tenant's
--      staff to every other). A scope is a namespace string, the unit the
--      vector layer has always used.
--   2. Three transaction-local settings say who is asking:
--      `maludb_core.principal_ref`, `maludb_core.principal_scopes` (narrows,
--      never widens), `maludb_core.principal_readonly`. Unset = unrestricted:
--      every existing caller behaves exactly as before. A principal that is
--      set but unknown or disabled reads nothing.
--   3. `principal_ref` + `scope` on source packages, documents, memories,
--      episodes, chat sessions and pools; a RESTRICTIVE policy for reads, a
--      trigger for writes, explicit checks in the SECURITY DEFINER search and
--      ingest workers (which bypass row security), and `sensitivity` enforced
--      against the principal's ceiling.
--   4. Forgetting works: tombstones are honoured on the exact and
--      exact_parallel search paths (they were only on local_ann), a deleted
--      document takes its chunks with it, and `maludb_forget_document()` /
--      `maludb_forget_chunk()` exist.
--   5. Skills: `review_state` apart from `enabled`, principal grants, and
--      `malu$skill_load_event`.
--   6. Pools: tenant facades for presence, and a roster that returns the cursor.
--   7. `maludb_memory_ingest_extraction(..., p_namespace)`.
--
-- The trust boundary is unchanged and worth stating: a client that holds the
-- tenant's Postgres login can set these settings itself -- it IS the tenant.
-- They bind callers who reach the engine through a service that sets them per
-- request, the way `maludb_core.current_account_id` already works.
--
-- After upgrading, re-run `maludb_core.enable_memory_schema('<tenant>')` for
-- every tenant. The shared library changes too (the exact scan's tombstone
-- filter); the new query needs `malu$vector_tombstone`, which every database since 0.14.0 has.
--
-- Regress: principal_scoping, vector_forget, skill_review_load,
-- pool_presence_facade.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Principals, their scopes, and the session that names one.
-- ---------------------------------------------------------------------

CREATE TABLE maludb_core.malu$principal (
    principal_id    bigserial PRIMARY KEY,
    owner_schema    name NOT NULL DEFAULT current_schema(),
    principal_ref   text NOT NULL
        CHECK (principal_ref ~ '^[A-Za-z0-9][A-Za-z0-9:_.@-]{0,119}$'),
    principal_kind  text NOT NULL DEFAULT 'agent'
        CHECK (principal_kind IN ('human','agent','service')),
    display_name    text,
    home_scope      text CHECK (home_scope IS NULL OR home_scope <> ''),
    max_sensitivity text NOT NULL DEFAULT 'internal'
        CHECK (max_sensitivity IN ('public','internal','restricted','prohibited')),
    enabled         boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, principal_ref),
    UNIQUE (owner_schema, principal_id)
);

CREATE TABLE maludb_core.malu$principal_scope (
    principal_scope_id bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    principal_id       bigint NOT NULL,
    scope              text NOT NULL CHECK (scope <> ''),
    access_level       text NOT NULL DEFAULT 'read'
        CHECK (access_level IN ('read','write')),
    granted_by         name NOT NULL DEFAULT session_user,
    granted_at         timestamptz NOT NULL DEFAULT now(),
    revoked_at         timestamptz,
    FOREIGN KEY (owner_schema, principal_id)
        REFERENCES maludb_core.malu$principal(owner_schema, principal_id) ON DELETE CASCADE
);
-- One live grant per (principal, scope); its level is changed in place.
CREATE UNIQUE INDEX malu$principal_scope_live_uq
    ON maludb_core.malu$principal_scope(owner_schema, principal_id, scope)
    WHERE revoked_at IS NULL;
CREATE INDEX malu$principal_scope_principal_idx
    ON maludb_core.malu$principal_scope(principal_id);

ALTER TABLE maludb_core.malu$principal       ENABLE ROW LEVEL SECURITY;
ALTER TABLE maludb_core.malu$principal_scope ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$principal
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON maludb_core.malu$principal_scope
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$principal, maludb_core.malu$principal_scope
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$principal, maludb_core.malu$principal_scope
    TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE ON SEQUENCE maludb_core.malu$principal_principal_id_seq,
                        maludb_core.malu$principal_scope_principal_scope_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- Who is asking. Unset or empty = unrestricted: the tenant itself, as before.
CREATE FUNCTION maludb_core.current_principal_ref() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE
AS $body$
    SELECT NULLIF(pg_catalog.btrim(pg_catalog.current_setting('maludb_core.principal_ref', true)), '')
$body$;

CREATE FUNCTION maludb_core._sensitivity_rank(p_sensitivity text) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $body$
    SELECT CASE p_sensitivity
               WHEN 'public'     THEN 0
               WHEN 'internal'   THEN 1
               WHEN 'restricted' THEN 2
               WHEN 'prohibited' THEN 3
               ELSE CASE WHEN p_sensitivity IS NULL THEN 1 ELSE 3 END
           END
$body$;

-- The scopes the session's principal may read (or write) in p_schema.
--   NULL  = no principal is set: unrestricted.
--   '{}'  = a principal is set but unknown, disabled, read-only (for write),
--           or asking about a schema the session cannot use: nothing.
-- Stored grants are the authority; the session's own list can only narrow them.
CREATE FUNCTION maludb_core._principal_scopes_for_schema(p_schema name, p_level text DEFAULT 'read')
RETURNS text[]
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_ref     text := maludb_core.current_principal_ref();
    v_level   text := lower(COALESCE(p_level, 'read'));
    v_p       record;
    v_scopes  text[];
    v_raw     text;
    v_session text[];
BEGIN
    IF v_ref IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_level NOT IN ('read','write') THEN
        RAISE EXCEPTION 'principal scopes: level must be read or write'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_schema IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.nspname = p_schema)
       OR NOT pg_catalog.has_schema_privilege(session_user, p_schema, 'USAGE') THEN
        RETURN ARRAY[]::text[];
    END IF;

    SELECT p.principal_id, p.home_scope, p.enabled INTO v_p
      FROM maludb_core.malu$principal p
     WHERE p.owner_schema = p_schema
       AND p.principal_ref = v_ref COLLATE "default";
    IF NOT FOUND OR NOT v_p.enabled THEN
        RETURN ARRAY[]::text[];
    END IF;
    IF v_level = 'write'
       AND lower(COALESCE(pg_catalog.current_setting('maludb_core.principal_readonly', true), ''))
           IN ('on','true','1','yes') THEN
        RETURN ARRAY[]::text[];
    END IF;

    SELECT COALESCE(array_agg(DISTINCT g.scope), ARRAY[]::text[]) INTO v_scopes
      FROM maludb_core.malu$principal_scope g
     WHERE g.owner_schema = p_schema
       AND g.principal_id = v_p.principal_id
       AND g.revoked_at IS NULL
       AND (v_level = 'read' OR g.access_level = 'write');
    IF v_p.home_scope IS NOT NULL AND NOT (v_p.home_scope = ANY (v_scopes)) THEN
        v_scopes := v_scopes || v_p.home_scope;
    END IF;

    v_raw := NULLIF(pg_catalog.btrim(pg_catalog.current_setting('maludb_core.principal_scopes', true)), '');
    IF v_raw IS NOT NULL THEN
        BEGIN
            SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_session
              FROM pg_catalog.jsonb_array_elements_text(v_raw::jsonb) AS t(x);
        EXCEPTION WHEN OTHERS THEN
            RETURN ARRAY[]::text[];        -- unreadable narrowing list: fail closed
        END;
        SELECT COALESCE(array_agg(s), ARRAY[]::text[]) INTO v_scopes
          FROM unnest(v_scopes) AS u(s)
         WHERE s = ANY (v_session);
    END IF;

    RETURN v_scopes;
END;
$body$;

-- The most sensitive class the session's principal may read, as a rank.
-- NULL = unrestricted; -1 = a principal that may read nothing.
CREATE FUNCTION maludb_core._principal_ceiling_for_schema(p_schema name) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_ref text := maludb_core.current_principal_ref();
    v_max text;
BEGIN
    IF v_ref IS NULL THEN
        RETURN NULL;
    END IF;
    IF p_schema IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.nspname = p_schema)
       OR NOT pg_catalog.has_schema_privilege(session_user, p_schema, 'USAGE') THEN
        RETURN -1;
    END IF;
    SELECT p.max_sensitivity INTO v_max
      FROM maludb_core.malu$principal p
     WHERE p.owner_schema = p_schema
       AND p.principal_ref = v_ref COLLATE "default"
       AND p.enabled;
    IF NOT FOUND THEN
        RETURN -1;
    END IF;
    RETURN maludb_core._sensitivity_rank(v_max);
END;
$body$;

-- The forms the row policies use: the caller's own schema.
CREATE FUNCTION maludb_core.principal_scopes(p_level text DEFAULT 'read') RETURNS text[]
LANGUAGE sql STABLE
AS $body$
    SELECT maludb_core._principal_scopes_for_schema(pg_catalog.current_schema(), p_level)
$body$;

CREATE FUNCTION maludb_core.principal_sensitivity_ceiling() RETURNS integer
LANGUAGE sql STABLE
AS $body$
    SELECT maludb_core._principal_ceiling_for_schema(pg_catalog.current_schema())
$body$;

-- A policy on every scoped table calls these as whatever role is reading, so
-- they are PUBLIC. They answer only about the session's own declared principal
-- and only for a schema the session can already use.
GRANT EXECUTE ON FUNCTION maludb_core.current_principal_ref(),
                          maludb_core._sensitivity_rank(text),
                          maludb_core._principal_scopes_for_schema(name, text),
                          maludb_core._principal_ceiling_for_schema(name),
                          maludb_core.principal_scopes(text),
                          maludb_core.principal_sensitivity_ceiling()
    TO PUBLIC;

-- Raise unless the session may use p_scope at p_level in p_schema.
CREATE FUNCTION maludb_core._principal_assert_scope(p_schema name, p_scope text, p_level text, p_what text)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_scopes text[] := maludb_core._principal_scopes_for_schema(p_schema, p_level);
BEGIN
    IF v_scopes IS NULL THEN
        RETURN;
    END IF;
    IF NOT (COALESCE(p_scope, 'default') = ANY (v_scopes)) THEN
        RAISE EXCEPTION '%: principal % may not % scope %',
            p_what, maludb_core.current_principal_ref(), p_level, COALESCE(p_scope, 'default')
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._principal_assert_scope(name, text, text, text) FROM PUBLIC;

-- A session bound to a principal administers no principals, its own included.
CREATE FUNCTION maludb_core._principal_admin_guard_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
BEGIN
    IF maludb_core.current_principal_ref() IS NOT NULL THEN
        RAISE EXCEPTION 'a session bound to principal % cannot change %',
            maludb_core.current_principal_ref(), TG_TABLE_NAME
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$body$;
CREATE TRIGGER malu$principal_admin_guard
    BEFORE INSERT OR UPDATE OR DELETE ON maludb_core.malu$principal
    FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_admin_guard_tg();
CREATE TRIGGER malu$principal_scope_admin_guard
    BEFORE INSERT OR UPDATE OR DELETE ON maludb_core.malu$principal_scope
    FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_admin_guard_tg();

-- Management workers behind the tenant facades.
CREATE FUNCTION maludb_core._principal_upsert_for_schema(
    p_schema          name,
    p_principal_ref   text,
    p_principal_kind  text    DEFAULT 'agent',
    p_display_name    text    DEFAULT NULL,
    p_home_scope      text    DEFAULT NULL,
    p_max_sensitivity text    DEFAULT NULL,
    p_enabled         boolean DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_ref text := btrim(COALESCE(p_principal_ref, ''));
    v_id  bigint;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    IF v_ref = '' THEN
        RAISE EXCEPTION 'principal_upsert: principal_ref is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO maludb_core.malu$principal AS p
        (owner_schema, principal_ref, principal_kind, display_name, home_scope, max_sensitivity, enabled)
    VALUES (p_schema, v_ref, COALESCE(p_principal_kind, 'agent'), p_display_name,
            NULLIF(btrim(COALESCE(p_home_scope, '')), ''),
            COALESCE(p_max_sensitivity, 'internal'), COALESCE(p_enabled, true))
    ON CONFLICT (owner_schema, principal_ref) DO UPDATE
       SET principal_kind  = COALESCE(p_principal_kind, p.principal_kind),
           display_name    = COALESCE(p_display_name, p.display_name),
           home_scope      = COALESCE(NULLIF(btrim(COALESCE(p_home_scope, '')), ''), p.home_scope),
           max_sensitivity = COALESCE(p_max_sensitivity, p.max_sensitivity),
           enabled         = COALESCE(p_enabled, p.enabled),
           updated_at      = now()
    RETURNING p.principal_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION maludb_core._principal_grant_scope_for_schema(
    p_schema        name,
    p_principal_ref text,
    p_scope         text,
    p_access_level  text DEFAULT 'read'
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_pid   bigint;
    v_scope text := btrim(COALESCE(p_scope, ''));
    v_level text := lower(COALESCE(p_access_level, 'read'));
    v_id    bigint;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    IF v_scope = '' THEN
        RAISE EXCEPTION 'principal_grant_scope: scope is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT p.principal_id INTO v_pid
      FROM maludb_core.malu$principal p
     WHERE p.owner_schema = p_schema
       AND p.principal_ref = p_principal_ref COLLATE "default";
    IF v_pid IS NULL THEN
        RAISE EXCEPTION 'principal_grant_scope: unknown principal %', p_principal_ref
            USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE maludb_core.malu$principal_scope g
       SET access_level = v_level
     WHERE g.owner_schema = p_schema
       AND g.principal_id = v_pid
       AND g.scope = v_scope COLLATE "default"
       AND g.revoked_at IS NULL
    RETURNING g.principal_scope_id INTO v_id;
    IF v_id IS NULL THEN
        INSERT INTO maludb_core.malu$principal_scope (owner_schema, principal_id, scope, access_level)
        VALUES (p_schema, v_pid, v_scope, v_level)
        RETURNING principal_scope_id INTO v_id;
    END IF;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION maludb_core._principal_revoke_scope_for_schema(
    p_schema        name,
    p_principal_ref text,
    p_scope         text
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_n integer;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    UPDATE maludb_core.malu$principal_scope g
       SET revoked_at = now()
      FROM maludb_core.malu$principal p
     WHERE p.owner_schema = p_schema
       AND p.principal_ref = p_principal_ref COLLATE "default"
       AND g.owner_schema = p_schema
       AND g.principal_id = p.principal_id
       AND g.scope = p_scope COLLATE "default"
       AND g.revoked_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END;
$body$;

-- What the session is actually allowed: for a host's own verification.
CREATE FUNCTION maludb_core._principal_whoami_for_schema(p_schema name) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_ref   text := maludb_core.current_principal_ref();
    v_p     record;
    v_known boolean;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    IF v_ref IS NULL THEN
        RETURN jsonb_build_object('restricted', false);
    END IF;
    SELECT p.principal_kind, p.display_name, p.home_scope, p.max_sensitivity, p.enabled INTO v_p
      FROM maludb_core.malu$principal p
     WHERE p.owner_schema = p_schema
       AND p.principal_ref = v_ref COLLATE "default";
    v_known := FOUND;
    RETURN jsonb_build_object(
        'restricted',      true,
        'principal_ref',   v_ref,
        'known',           v_known,
        'enabled',         COALESCE(v_p.enabled, false),
        'principal_kind',  v_p.principal_kind,
        'home_scope',      v_p.home_scope,
        'max_sensitivity', v_p.max_sensitivity,
        'read_scopes',     to_jsonb(maludb_core._principal_scopes_for_schema(p_schema, 'read')),
        'write_scopes',    to_jsonb(maludb_core._principal_scopes_for_schema(p_schema, 'write')));
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._principal_upsert_for_schema(name, text, text, text, text, text, boolean),
                       maludb_core._principal_grant_scope_for_schema(name, text, text, text),
                       maludb_core._principal_revoke_scope_for_schema(name, text, text),
                       maludb_core._principal_whoami_for_schema(name)
    FROM PUBLIC;
-- ---------------------------------------------------------------------
-- 2. Every scoped row says whose it is and which scope it lives in.
--    NULL scope reads as 'default' -- every row written before 0.106.0.
-- ---------------------------------------------------------------------

ALTER TABLE maludb_core.malu$source_package     ADD COLUMN principal_ref text, ADD COLUMN scope text;
ALTER TABLE maludb_core.malu$document           ADD COLUMN principal_ref text, ADD COLUMN scope text;
ALTER TABLE maludb_core.malu$memory             ADD COLUMN principal_ref text, ADD COLUMN scope text;
ALTER TABLE maludb_core.malu$episode_object     ADD COLUMN principal_ref text, ADD COLUMN scope text;
ALTER TABLE maludb_core.malu$chat_session       ADD COLUMN principal_ref text, ADD COLUMN scope text;
ALTER TABLE maludb_core.malu$active_memory_pool ADD COLUMN principal_ref text, ADD COLUMN scope text;

CREATE INDEX malu$source_package_scope_idx ON maludb_core.malu$source_package(owner_schema, scope) WHERE scope IS NOT NULL;
CREATE INDEX malu$document_scope_idx       ON maludb_core.malu$document(owner_schema, scope)       WHERE scope IS NOT NULL;
CREATE INDEX malu$memory_scope_idx         ON maludb_core.malu$memory(owner_schema, scope)         WHERE scope IS NOT NULL;
CREATE INDEX malu$episode_scope_idx        ON maludb_core.malu$episode_object(owner_schema, scope) WHERE scope IS NOT NULL;
CREATE INDEX malu$chat_session_scope_idx   ON maludb_core.malu$chat_session(owner_schema, scope)   WHERE scope IS NOT NULL;

-- A document whose chunks all live in one namespace was written there: that is
-- its scope. (The platform has scoped memory by namespace since 0.88; this is
-- what makes those documents, and not only their chunks, private.)
WITH doc_ns AS (
    SELECT vc.document_id, c.owner_schema, min(c.namespace) AS namespace
      FROM maludb_core.malu$vector_chunk vc
      JOIN maludb_core.malu$vector_compartment c ON c.compartment_id = vc.compartment_id
     WHERE vc.document_id IS NOT NULL
     GROUP BY vc.document_id, c.owner_schema
    HAVING count(DISTINCT c.namespace) = 1
), docs AS (
    UPDATE maludb_core.malu$document d
       SET scope = n.namespace
      FROM doc_ns n
     WHERE d.document_id = n.document_id
       AND d.owner_schema = n.owner_schema
       AND n.namespace <> 'default'
    RETURNING d.owner_schema, d.source_package_id, d.scope
)
UPDATE maludb_core.malu$source_package sp
   SET scope = docs.scope
  FROM docs
 WHERE sp.source_package_id = docs.source_package_id
   AND sp.owner_schema = docs.owner_schema;

-- Writes: enforced by trigger, so they hold on every path -- a view owned by
-- the extension, a SECURITY DEFINER worker and a plain INSERT alike.
CREATE FUNCTION maludb_core._principal_stamp_tg() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_ref    text := maludb_core.current_principal_ref();
    v_scopes text[];
    v_home   text;
BEGIN
    IF v_ref IS NULL THEN
        IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    END IF;

    v_scopes := maludb_core._principal_scopes_for_schema(
        CASE WHEN TG_OP = 'DELETE' THEN OLD.owner_schema ELSE NEW.owner_schema END, 'write');

    IF TG_OP IN ('UPDATE','DELETE') AND NOT (COALESCE(OLD.scope, 'default') = ANY (v_scopes)) THEN
        RAISE EXCEPTION 'principal % may not change % rows in scope %',
            v_ref, TG_TABLE_NAME, COALESCE(OLD.scope, 'default')
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.principal_ref := v_ref;                 -- never the caller's word for it
        IF NEW.scope IS NULL THEN
            SELECT p.home_scope INTO v_home
              FROM maludb_core.malu$principal p
             WHERE p.owner_schema = NEW.owner_schema
               AND p.principal_ref = v_ref COLLATE "default";
            NEW.scope := v_home;
        END IF;
    ELSE
        NEW.principal_ref := OLD.principal_ref;
    END IF;

    IF NOT (COALESCE(NEW.scope, 'default') = ANY (v_scopes)) THEN
        RAISE EXCEPTION 'principal % may not write % rows in scope %',
            v_ref, TG_TABLE_NAME, COALESCE(NEW.scope, 'default')
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._principal_stamp_tg() FROM PUBLIC;

CREATE TRIGGER malu$source_package_principal_stamp BEFORE INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$source_package FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_stamp_tg();
CREATE TRIGGER malu$document_principal_stamp BEFORE INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$document FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_stamp_tg();
CREATE TRIGGER malu$memory_principal_stamp BEFORE INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$memory FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_stamp_tg();
CREATE TRIGGER malu$episode_object_principal_stamp BEFORE INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$episode_object FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_stamp_tg();
CREATE TRIGGER malu$chat_session_principal_stamp BEFORE INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$chat_session FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_stamp_tg();
CREATE TRIGGER malu$active_memory_pool_principal_stamp BEFORE INSERT OR UPDATE OR DELETE
    ON maludb_core.malu$active_memory_pool FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_stamp_tg();

-- Reads: a RESTRICTIVE policy beside tenant_owner (a second permissive policy
-- would widen access, not narrow it). tenant_owner itself is untouched --
-- scripts/maludb-force-rls finds its tables by that name. The scope list and
-- the ceiling sit in scalar subqueries so they are computed once per statement.
CREATE POLICY principal_scope ON maludb_core.malu$source_package AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR (COALESCE(scope, 'default') = ANY ((SELECT maludb_core.principal_scopes('read'))::text[])
               AND maludb_core._sensitivity_rank(sensitivity) <= (SELECT maludb_core.principal_sensitivity_ceiling())));
CREATE POLICY principal_scope ON maludb_core.malu$memory AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR (COALESCE(scope, 'default') = ANY ((SELECT maludb_core.principal_scopes('read'))::text[])
               AND maludb_core._sensitivity_rank(sensitivity) <= (SELECT maludb_core.principal_sensitivity_ceiling())));
CREATE POLICY principal_scope ON maludb_core.malu$episode_object AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR (COALESCE(scope, 'default') = ANY ((SELECT maludb_core.principal_scopes('read'))::text[])
               AND maludb_core._sensitivity_rank(sensitivity) <= (SELECT maludb_core.principal_sensitivity_ceiling())));
-- A document has no sensitivity of its own: it is as readable as its source package.
CREATE POLICY principal_scope ON maludb_core.malu$document AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR (COALESCE(scope, 'default') = ANY ((SELECT maludb_core.principal_scopes('read'))::text[])
               AND (source_package_id IS NULL
                    OR EXISTS (SELECT 1 FROM maludb_core.malu$source_package sp
                                WHERE sp.source_package_id = malu$document.source_package_id))));
CREATE POLICY principal_scope ON maludb_core.malu$chat_session AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR COALESCE(scope, 'default') = ANY ((SELECT maludb_core.principal_scopes('read'))::text[]));
CREATE POLICY principal_scope ON maludb_core.malu$chat_message AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR (maludb_core._sensitivity_rank(sensitivity) <= (SELECT maludb_core.principal_sensitivity_ceiling())
               AND EXISTS (SELECT 1 FROM maludb_core.malu$chat_session s
                            WHERE s.chat_session_id = malu$chat_message.chat_session_id)));
CREATE POLICY principal_scope ON maludb_core.malu$active_memory_pool AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR COALESCE(scope, 'default') = ANY ((SELECT maludb_core.principal_scopes('read'))::text[]));
CREATE POLICY principal_scope ON maludb_core.malu$active_memory_pool_member AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR EXISTS (SELECT 1 FROM maludb_core.malu$active_memory_pool p
                       WHERE p.pool_id = malu$active_memory_pool_member.pool_id));
CREATE POLICY principal_scope ON maludb_core.malu$pool_presence AS RESTRICTIVE
    USING (maludb_core.current_principal_ref() IS NULL
           OR EXISTS (SELECT 1 FROM maludb_core.malu$active_memory_pool p
                       WHERE p.pool_id = malu$pool_presence.pool_id));
-- ---------------------------------------------------------------------
-- 3. Forgetting. A tombstoned chunk is gone from every search path, and a
--    deleted document takes its chunks with it.
--
--    Before 0.106.0 only the local_ann branch of exact_vector_search_sql()
--    filtered malu$vector_tombstone; the default 'exact' branch (the C scan,
--    fixed in src/maludb_search.c in this release) and 'exact_parallel' (below)
--    returned tombstoned chunks for ever. Nothing deleted a document's chunks
--    either -- malu$vector_chunk.document_id is a soft reference -- so a
--    deleted memory stayed recallable.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION maludb_core.exact_vector_search_parallel_c(
    p_compartment_id bigint,
    p_query          maludb_core.malu_vector,
    p_limit          integer DEFAULT 10,
    p_metric         text    DEFAULT NULL
) RETURNS TABLE (
    chunk_id     bigint,
    source_text  text,
    distance     double precision,
    similarity   double precision,
    rank_no      integer
) LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_compart  maludb_core.malu$vector_compartment%ROWTYPE;
    v_metric   text;
    v_qnorm    maludb_core.malu_vector;
BEGIN
    SELECT * INTO v_compart FROM maludb_core.malu$vector_compartment
     WHERE compartment_id = p_compartment_id;
    IF v_compart.compartment_id IS NULL THEN
        RAISE EXCEPTION 'unknown compartment_id: %', p_compartment_id
            USING ERRCODE = 'no_data_found';
    END IF;
    IF maludb_core.vector_dims(p_query) <> v_compart.embedding_dim THEN
        RAISE EXCEPTION 'query dim % does not match compartment dim %',
            maludb_core.vector_dims(p_query), v_compart.embedding_dim
            USING ERRCODE = 'check_violation';
    END IF;
    v_metric := COALESCE(p_metric, v_compart.distance_metric);
    v_qnorm  := maludb_core.vector_normalize(p_query);

    RETURN QUERY
        WITH agg AS (
            SELECT maludb_core.topk_vector_search(
                       c.embedding, c.chunk_id, c.source_text,
                       v_qnorm, p_limit, v_metric) AS j
            FROM maludb_core.malu$vector_chunk c
            WHERE c.compartment_id = p_compartment_id
              AND NOT EXISTS (SELECT 1 FROM maludb_core.malu$vector_tombstone t
                               WHERE t.chunk_id = c.chunk_id)
        ),
        rows AS (
            SELECT e
            FROM   agg, jsonb_array_elements(agg.j) e
        )
        SELECT (e->>'chunk_id')::bigint,
               e->>'source_text',
               (e->>'distance')::double precision,
               (e->>'similarity')::double precision,
               (e->>'rank_no')::integer
        FROM   rows
        ORDER BY (e->>'rank_no')::integer;
END;
$body$;

-- Remove chunk rows for good: keep each compartment's count true and mark an
-- ANN index stale (its graph still names the chunks; the search joins them away
-- until ann_rebuild()). malu$ann_delta and malu$vector_tombstone cascade.
CREATE FUNCTION maludb_core._vector_chunks_delete(p_chunk_ids bigint[]) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_n integer := 0;
BEGIN
    IF p_chunk_ids IS NULL OR cardinality(p_chunk_ids) = 0 THEN
        RETURN 0;
    END IF;

    WITH gone AS (
        DELETE FROM maludb_core.malu$vector_chunk c
         WHERE c.chunk_id = ANY (p_chunk_ids)
        RETURNING c.compartment_id
    ), per AS (
        SELECT compartment_id, count(*) AS n FROM gone GROUP BY compartment_id
    ), upd AS (
        UPDATE maludb_core.malu$vector_compartment vc
           SET vector_count = GREATEST(vc.vector_count - per.n, 0),
               ann_index_status = CASE
                   WHEN EXISTS (SELECT 1 FROM maludb_core.malu$ann_index ai
                                 WHERE ai.compartment_id = vc.compartment_id)
                   THEN 'stale' ELSE vc.ann_index_status END,
               updated_at = now()
          FROM per
         WHERE vc.compartment_id = per.compartment_id
        RETURNING per.n
    )
    SELECT COALESCE(sum(n), 0)::integer INTO v_n FROM upd;
    RETURN v_n;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._vector_chunks_delete(bigint[]) FROM PUBLIC;

-- However a document row goes, its chunks go with it.
CREATE FUNCTION maludb_core._document_chunks_cleanup_tg() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
BEGIN
    PERFORM maludb_core._vector_chunks_delete(
        ARRAY(SELECT c.chunk_id FROM maludb_core.malu$vector_chunk c
               WHERE c.document_id = OLD.document_id));
    RETURN OLD;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._document_chunks_cleanup_tg() FROM PUBLIC;
CREATE TRIGGER malu$document_chunks_cleanup
    AFTER DELETE ON maludb_core.malu$document
    FOR EACH ROW EXECUTE FUNCTION maludb_core._document_chunks_cleanup_tg();

CREATE FUNCTION maludb_core._forget_document_for_schema(p_schema name, p_document_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_doc        record;
    v_hold       boolean;
    v_stmt_ids   bigint[];
    v_chunks     integer;
    v_statements integer := 0;
    v_package    text := 'none';
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT d.document_id, d.source_package_id, d.scope INTO v_doc
      FROM maludb_core.malu$document d
     WHERE d.owner_schema = p_schema AND d.document_id = p_document_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'forget_document: no document % in %', p_document_id, p_schema
            USING ERRCODE = 'no_data_found';
    END IF;
    PERFORM maludb_core._principal_assert_scope(p_schema, v_doc.scope, 'write', 'forget_document');

    IF v_doc.source_package_id IS NOT NULL THEN
        SELECT sp.legal_hold INTO v_hold
          FROM maludb_core.malu$source_package sp
         WHERE sp.owner_schema = p_schema AND sp.source_package_id = v_doc.source_package_id;
        IF COALESCE(v_hold, false) THEN
            RAISE EXCEPTION 'forget_document: document % is under legal hold', p_document_id
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
    END IF;

    -- the edges this document is an endpoint of carry its words (source_span)
    SELECT COALESCE(array_agg(st.statement_id), ARRAY[]::bigint[]) INTO v_stmt_ids
      FROM maludb_core.malu$svpor_statement st
     WHERE st.owner_schema = p_schema
       AND ((st.subject_kind = 'document' AND st.subject_id = p_document_id)
         OR (st.object_kind  = 'document' AND st.object_id  = p_document_id));

    v_chunks := maludb_core._vector_chunks_delete(
        ARRAY(SELECT c.chunk_id
                FROM maludb_core.malu$vector_chunk c
                JOIN maludb_core.malu$vector_compartment vc ON vc.compartment_id = c.compartment_id
               WHERE vc.owner_schema = p_schema
                 AND (c.document_id = p_document_id OR c.statement_id = ANY (v_stmt_ids))));

    DELETE FROM maludb_core.malu$svpor_attribute a
     WHERE a.owner_schema = p_schema
       AND ((a.target_kind = 'svpor_statement' AND a.target_id = ANY (v_stmt_ids))
         OR (a.target_kind = 'document' AND a.target_id = p_document_id));
    DELETE FROM maludb_core.malu$svpor_statement st
     WHERE st.owner_schema = p_schema AND st.statement_id = ANY (v_stmt_ids);
    GET DIAGNOSTICS v_statements = ROW_COUNT;
    DELETE FROM maludb_core.malu$object_embedding oe
     WHERE oe.owner_schema = p_schema AND oe.object_kind = 'document' AND oe.object_id = p_document_id;

    DELETE FROM maludb_core.malu$document d
     WHERE d.owner_schema = p_schema AND d.document_id = p_document_id;

    IF v_doc.source_package_id IS NOT NULL THEN
        BEGIN
            DELETE FROM maludb_core.malu$source_package sp
             WHERE sp.owner_schema = p_schema AND sp.source_package_id = v_doc.source_package_id;
            v_package := 'deleted';
        EXCEPTION WHEN foreign_key_violation THEN
            v_package := 'kept_referenced';      -- something else still cites the source
        END;
    END IF;

    RETURN jsonb_build_object(
        'document_id',    p_document_id,
        'chunks',         v_chunks,
        'statements',     v_statements,
        'source_package', v_package);
END;
$body$;

CREATE FUNCTION maludb_core._forget_chunk_for_schema(p_schema name, p_chunk_id bigint)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_namespace text;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    SELECT vc.namespace INTO v_namespace
      FROM maludb_core.malu$vector_chunk c
      JOIN maludb_core.malu$vector_compartment vc ON vc.compartment_id = c.compartment_id
     WHERE c.chunk_id = p_chunk_id AND vc.owner_schema = p_schema;
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    PERFORM maludb_core._principal_assert_scope(p_schema, v_namespace, 'write', 'forget_chunk');
    RETURN maludb_core._vector_chunks_delete(ARRAY[p_chunk_id]) > 0;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._forget_document_for_schema(name, bigint),
                       maludb_core._forget_chunk_for_schema(name, bigint)
    FROM PUBLIC;

-- ---------------------------------------------------------------------
-- A document lives in the namespace of its first edge. A document with no
-- scope adopts it; so does one its own author has just uploaded -- still in
-- the author's home scope, nothing embedded yet -- which is what "remember
-- this in dept:3" looks like from a principal-bound session. Anything else
-- keeps the scope it has: maludb_set_scope() moves a document deliberately.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._document_adopt_scope(p_schema name, p_document_id bigint, p_namespace text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_ns   text := COALESCE(NULLIF(btrim(COALESCE(p_namespace, '')), ''), 'default');
    v_ref  text := maludb_core.current_principal_ref();
    v_doc  record;
    v_home text;
BEGIN
    IF p_document_id IS NULL OR v_ns = 'default' THEN
        RETURN;
    END IF;
    SELECT d.scope, d.principal_ref, d.source_package_id INTO v_doc
      FROM maludb_core.malu$document d
     WHERE d.owner_schema = p_schema AND d.document_id = p_document_id;
    IF NOT FOUND OR v_doc.scope IS NOT DISTINCT FROM v_ns THEN
        RETURN;
    END IF;

    IF v_doc.scope IS NOT NULL THEN
        IF v_ref IS NULL OR v_doc.principal_ref IS DISTINCT FROM v_ref THEN
            RETURN;
        END IF;
        SELECT p.home_scope INTO v_home
          FROM maludb_core.malu$principal p
         WHERE p.owner_schema = p_schema AND p.principal_ref = v_ref COLLATE "default";
        IF v_doc.scope IS DISTINCT FROM v_home
           OR EXISTS (SELECT 1 FROM maludb_core.malu$vector_chunk c WHERE c.document_id = p_document_id) THEN
            RETURN;
        END IF;
    END IF;

    UPDATE maludb_core.malu$source_package sp
       SET scope = v_ns
     WHERE sp.owner_schema = p_schema AND sp.source_package_id = v_doc.source_package_id;
    UPDATE maludb_core.malu$document d
       SET scope = v_ns
     WHERE d.owner_schema = p_schema AND d.document_id = p_document_id;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._document_adopt_scope(name, bigint, text) FROM PUBLIC;
-- ---------------------------------------------------------------------
-- 4. Skills: review is not the same thing as enabled; a grant may name a
--    principal; and a load is recorded.
-- ---------------------------------------------------------------------

ALTER TABLE maludb_core.malu$skill_package
    ADD COLUMN review_state text NOT NULL DEFAULT 'approved'
        CONSTRAINT malu$skill_package_review_state_ck
        CHECK (review_state IN ('proposed','approved','rejected')),
    ADD COLUMN proposed_by_principal text,
    ADD COLUMN reviewed_by   text,
    ADD COLUMN reviewed_at   timestamptz,
    ADD COLUMN review_note   text;

-- A skill written by a principal-bound session is a proposal, whatever the
-- caller says, and its author never decides it.
CREATE FUNCTION maludb_core._skill_review_guard_tg() RETURNS trigger
LANGUAGE plpgsql
AS $body$
DECLARE
    v_ref text := maludb_core.current_principal_ref();
BEGIN
    IF v_ref IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        NEW.proposed_by_principal := v_ref;
        NEW.review_state := 'proposed';
        NEW.reviewed_by := NULL;
        NEW.reviewed_at := NULL;
    ELSIF NEW.review_state IS DISTINCT FROM OLD.review_state
          AND OLD.proposed_by_principal IS NOT DISTINCT FROM v_ref THEN
        RAISE EXCEPTION 'principal % proposed skill % and cannot review it', v_ref, OLD.skill_name
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$body$;
CREATE TRIGGER malu$skill_package_review_guard
    BEFORE INSERT OR UPDATE ON maludb_core.malu$skill_package
    FOR EACH ROW EXECUTE FUNCTION maludb_core._skill_review_guard_tg();

-- malu$skill_access names a Postgres role and a dozen policies read it that
-- way, so principal grants get a table of their own.
CREATE TABLE maludb_core.malu$skill_principal_access (
    access_id     bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    skill_id      bigint NOT NULL,
    principal_ref text NOT NULL,
    access_level  text NOT NULL DEFAULT 'read'
        CHECK (access_level IN ('read','fork')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (owner_schema, skill_id)
        REFERENCES maludb_core.malu$skill_package(owner_schema, skill_id) ON DELETE CASCADE,
    UNIQUE (owner_schema, skill_id, principal_ref)
);
CREATE INDEX malu$skill_principal_access_skill_idx
    ON maludb_core.malu$skill_principal_access(skill_id);
ALTER TABLE maludb_core.malu$skill_principal_access ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$skill_principal_access
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
GRANT SELECT ON maludb_core.malu$skill_principal_access
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$skill_principal_access
    TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE ON SEQUENCE maludb_core.malu$skill_principal_access_access_id_seq
    TO maludb_memory_admin, maludb_memory_executor;
CREATE TRIGGER malu$skill_principal_access_admin_guard
    BEFORE INSERT OR UPDATE OR DELETE ON maludb_core.malu$skill_principal_access
    FOR EACH ROW EXECUTE FUNCTION maludb_core._principal_admin_guard_tg();

-- Visible = enabled AND approved AND reachable. For a principal-bound session a
-- skill of its own tenant that carries principal grants is reachable only
-- through one of them; a skill with none is the tenant's, as before.
CREATE OR REPLACE FUNCTION maludb_core._skill_is_visible(p_owner_schema name, p_skill_id bigint, p_requesting_schema name, p_include_public boolean DEFAULT true)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
    WITH caller AS (
        SELECT COALESCE(NULLIF(current_setting('role', true), 'none'), session_user)::name AS role_name,
               maludb_core.current_principal_ref() AS principal_ref
    )
    SELECT EXISTS (
        SELECT 1
          FROM maludb_core.malu$skill_package s
          CROSS JOIN caller c
         WHERE s.owner_schema = p_owner_schema
           AND s.skill_id = p_skill_id
           AND s.enabled
           AND s.review_state = 'approved'
           AND (
                (s.owner_schema = p_requesting_schema
                 AND (c.principal_ref IS NULL
                      OR NOT EXISTS (
                            SELECT 1 FROM maludb_core.malu$skill_principal_access pa
                             WHERE pa.owner_schema = s.owner_schema AND pa.skill_id = s.skill_id)
                      OR EXISTS (
                            SELECT 1 FROM maludb_core.malu$skill_principal_access pa
                             WHERE pa.owner_schema = s.owner_schema AND pa.skill_id = s.skill_id
                               AND pa.principal_ref = c.principal_ref COLLATE "default")))
             OR (p_include_public AND s.owner_schema = 'maludb_public' AND s.visibility = 'public')
             OR EXISTS (
                    SELECT 1
                      FROM maludb_core.malu$skill_access a
                     WHERE a.owner_schema = s.owner_schema
                       AND a.skill_id = s.skill_id
                       AND pg_catalog.pg_has_role(c.role_name, a.grantee_role, 'member')
                       AND a.access_level IN ('read','fork')
                )
           )
    )
$function$;

CREATE FUNCTION maludb_core._skill_review_for_schema(
    p_schema   name,
    p_skill_id bigint,
    p_decision text,
    p_reviewer text DEFAULT NULL,
    p_note     text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_decision text := lower(btrim(COALESCE(p_decision, '')));
    v_reviewer text := COALESCE(maludb_core.current_principal_ref(), NULLIF(btrim(COALESCE(p_reviewer, '')), ''));
    v_row      record;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    IF v_decision NOT IN ('approved','rejected','proposed') THEN
        RAISE EXCEPTION 'skill_review: decision must be approved, rejected or proposed'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT s.skill_id, s.skill_name, s.proposed_by_principal INTO v_row
      FROM maludb_core.malu$skill_package s
     WHERE s.owner_schema = p_schema AND s.skill_id = p_skill_id
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'skill_review: no skill % in %', p_skill_id, p_schema
            USING ERRCODE = 'no_data_found';
    END IF;
    IF v_decision <> 'proposed' AND v_reviewer IS NOT NULL
       AND v_row.proposed_by_principal IS NOT DISTINCT FROM v_reviewer THEN
        RAISE EXCEPTION 'skill_review: % proposed skill % and cannot review it', v_reviewer, v_row.skill_name
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    UPDATE maludb_core.malu$skill_package s
       SET review_state = v_decision,
           proposed_by_principal = CASE WHEN v_decision = 'proposed'
                                        THEN COALESCE(v_reviewer, s.proposed_by_principal)
                                        ELSE s.proposed_by_principal END,
           reviewed_by  = CASE WHEN v_decision = 'proposed' THEN NULL ELSE v_reviewer END,
           reviewed_at  = CASE WHEN v_decision = 'proposed' THEN NULL ELSE now() END,
           review_note  = p_note,
           updated_at   = now()
     WHERE s.owner_schema = p_schema AND s.skill_id = p_skill_id;

    RETURN (SELECT jsonb_build_object(
                'skill_id', s.skill_id, 'skill_name', s.skill_name, 'version', s.version,
                'enabled', s.enabled, 'review_state', s.review_state,
                'proposed_by_principal', s.proposed_by_principal,
                'reviewed_by', s.reviewed_by, 'reviewed_at', s.reviewed_at, 'review_note', s.review_note)
              FROM maludb_core.malu$skill_package s
             WHERE s.owner_schema = p_schema AND s.skill_id = p_skill_id);
END;
$body$;

CREATE FUNCTION maludb_core._skill_grant_principal_for_schema(
    p_schema name, p_skill_id bigint, p_principal_ref text, p_access_level text DEFAULT 'read'
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_id bigint;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    INSERT INTO maludb_core.malu$skill_principal_access AS a (owner_schema, skill_id, principal_ref, access_level)
    VALUES (p_schema, p_skill_id, btrim(p_principal_ref), lower(COALESCE(p_access_level, 'read')))
    ON CONFLICT (owner_schema, skill_id, principal_ref) DO UPDATE
       SET access_level = EXCLUDED.access_level
    RETURNING a.access_id INTO v_id;
    RETURN v_id;
END;
$body$;

CREATE FUNCTION maludb_core._skill_revoke_principal_for_schema(
    p_schema name, p_skill_id bigint, p_principal_ref text
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_n integer;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    DELETE FROM maludb_core.malu$skill_principal_access a
     WHERE a.owner_schema = p_schema
       AND a.skill_id = p_skill_id
       AND a.principal_ref = p_principal_ref COLLATE "default";
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END;
$body$;

-- What was loaded, by whom, for which run. The name, version and hash are
-- copied so the record outlives the skill.
CREATE TABLE maludb_core.malu$skill_load_event (
    load_event_id      bigserial PRIMARY KEY,
    owner_schema       name NOT NULL DEFAULT current_schema(),
    skill_owner_schema name,
    skill_id           bigint,
    skill_name         text NOT NULL,
    version            text,
    bundle_hash        text,
    principal_ref      text,
    run_ref            text,
    loaded_at          timestamptz NOT NULL DEFAULT now(),
    metadata_jsonb     jsonb NOT NULL DEFAULT '{}'::jsonb,
    FOREIGN KEY (skill_owner_schema, skill_id)
        REFERENCES maludb_core.malu$skill_package(owner_schema, skill_id) ON DELETE SET NULL
);
CREATE INDEX malu$skill_load_event_skill_idx
    ON maludb_core.malu$skill_load_event(skill_id) WHERE skill_id IS NOT NULL;
CREATE INDEX malu$skill_load_event_principal_idx
    ON maludb_core.malu$skill_load_event(owner_schema, principal_ref, loaded_at DESC);
ALTER TABLE maludb_core.malu$skill_load_event ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$skill_load_event
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
GRANT SELECT ON maludb_core.malu$skill_load_event
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core._skill_record_load_for_schema(
    p_schema             name,
    p_skill_id           bigint,
    p_run_ref            text  DEFAULT NULL,
    p_principal_ref      text  DEFAULT NULL,
    p_skill_owner_schema name  DEFAULT NULL,
    p_metadata           jsonb DEFAULT '{}'::jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_owner name := COALESCE(p_skill_owner_schema, p_schema);
    v_s     record;
    v_id    bigint;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    IF NOT maludb_core._skill_is_visible(v_owner, p_skill_id, p_schema, true) THEN
        RAISE EXCEPTION 'skill_record_load: skill % is not available to this caller', p_skill_id
            USING ERRCODE = 'no_data_found';
    END IF;
    SELECT s.skill_name, s.version, s.bundle_hash INTO v_s
      FROM maludb_core.malu$skill_package s
     WHERE s.owner_schema = v_owner AND s.skill_id = p_skill_id;

    INSERT INTO maludb_core.malu$skill_load_event
        (owner_schema, skill_owner_schema, skill_id, skill_name, version, bundle_hash,
         principal_ref, run_ref, metadata_jsonb)
    VALUES (p_schema, v_owner, p_skill_id, v_s.skill_name, v_s.version, v_s.bundle_hash,
            COALESCE(maludb_core.current_principal_ref(), NULLIF(btrim(COALESCE(p_principal_ref, '')), '')),
            NULLIF(btrim(COALESCE(p_run_ref, '')), ''), COALESCE(p_metadata, '{}'::jsonb))
    RETURNING load_event_id INTO v_id;
    RETURN v_id;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._skill_review_for_schema(name, bigint, text, text, text),
                       maludb_core._skill_grant_principal_for_schema(name, bigint, text, text),
                       maludb_core._skill_revoke_principal_for_schema(name, bigint, text),
                       maludb_core._skill_record_load_for_schema(name, bigint, text, text, name, jsonb)
    FROM PUBLIC;

-- ---------------------------------------------------------------------
-- 5. Pools: the roster with its cursor, and a scope setter for every
--    scoped kind. (Presence facades are in the tenant builder below.)
-- ---------------------------------------------------------------------

CREATE FUNCTION maludb_core.presence_roster(p_pool_id bigint, p_include_left boolean DEFAULT false)
RETURNS TABLE(presence_id bigint, participant_kind text, participant_ref text, role text,
              declared_task text, cursor_jsonb jsonb, ttl_seconds integer,
              last_seen_at timestamptz, left_at timestamptz)
LANGUAGE sql STABLE
AS $body$
    SELECT p.presence_id, p.participant_kind, p.participant_ref, p.role,
           p.declared_task, p.cursor_jsonb, p.ttl_seconds, p.last_seen_at, p.left_at
      FROM maludb_core.malu$pool_presence p
     WHERE p.pool_id = p_pool_id
       AND (p_include_left OR p.left_at IS NULL)
     ORDER BY p.last_seen_at DESC, p.presence_id
$body$;
REVOKE ALL ON FUNCTION maludb_core.presence_roster(bigint, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.presence_roster(bigint, boolean)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

CREATE FUNCTION maludb_core._set_scope_for_schema(
    p_schema name, p_object_kind text, p_object_id bigint, p_scope text
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_kind  text := lower(btrim(COALESCE(p_object_kind, '')));
    v_scope text := NULLIF(btrim(COALESCE(p_scope, '')), '');
    v_n     integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    -- the stamp trigger on each table refuses a principal without write on
    -- the old scope or the new one
    CASE v_kind
        WHEN 'document' THEN
            UPDATE maludb_core.malu$source_package sp SET scope = v_scope
              FROM maludb_core.malu$document d
             WHERE d.owner_schema = p_schema AND d.document_id = p_object_id
               AND sp.owner_schema = p_schema AND sp.source_package_id = d.source_package_id;
            UPDATE maludb_core.malu$document d SET scope = v_scope
             WHERE d.owner_schema = p_schema AND d.document_id = p_object_id;
            GET DIAGNOSTICS v_n = ROW_COUNT;
        WHEN 'source_package' THEN
            UPDATE maludb_core.malu$source_package sp SET scope = v_scope
             WHERE sp.owner_schema = p_schema AND sp.source_package_id = p_object_id;
            GET DIAGNOSTICS v_n = ROW_COUNT;
        WHEN 'memory' THEN
            UPDATE maludb_core.malu$memory m SET scope = v_scope
             WHERE m.owner_schema = p_schema AND m.memory_id = p_object_id;
            GET DIAGNOSTICS v_n = ROW_COUNT;
        WHEN 'episode_object', 'episode' THEN
            UPDATE maludb_core.malu$episode_object e SET scope = v_scope
             WHERE e.owner_schema = p_schema AND e.episode_id = p_object_id;
            GET DIAGNOSTICS v_n = ROW_COUNT;
        WHEN 'chat_session' THEN
            UPDATE maludb_core.malu$chat_session c SET scope = v_scope
             WHERE c.owner_schema = p_schema AND c.chat_session_id = p_object_id;
            GET DIAGNOSTICS v_n = ROW_COUNT;
        WHEN 'pool' THEN
            UPDATE maludb_core.malu$active_memory_pool p SET scope = v_scope
             WHERE p.owner_schema = p_schema AND p.pool_id = p_object_id;
            GET DIAGNOSTICS v_n = ROW_COUNT;
        ELSE
            RAISE EXCEPTION 'set_scope: unknown object kind %', p_object_kind
                USING ERRCODE = 'invalid_parameter_value';
    END CASE;
    RETURN v_n > 0;
END;
$body$;
REVOKE ALL ON FUNCTION maludb_core._set_scope_for_schema(name, text, bigint, text) FROM PUBLIC;

-- An event subject stands for its episode: visible when no episode hangs off
-- the subject, or when one the session may read does.
CREATE FUNCTION maludb_core._event_subject_visible(p_schema name, p_subject_id bigint) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_scopes  text[] := maludb_core._principal_scopes_for_schema(p_schema, 'read');
    v_ceiling integer;
BEGIN
    IF v_scopes IS NULL THEN
        RETURN true;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM maludb_core.malu$episode_object e
                    WHERE e.owner_schema = p_schema AND e.subject_id = p_subject_id) THEN
        RETURN true;
    END IF;
    v_ceiling := maludb_core._principal_ceiling_for_schema(p_schema);
    RETURN EXISTS (SELECT 1 FROM maludb_core.malu$episode_object e
                    WHERE e.owner_schema = p_schema AND e.subject_id = p_subject_id
                      AND COALESCE(e.scope, 'default') = ANY (v_scopes)
                      AND maludb_core._sensitivity_rank(e.sensitivity) <= v_ceiling);
END;
$body$;
GRANT EXECUTE ON FUNCTION maludb_core._event_subject_visible(name, bigint) TO PUBLIC;
-- ---------------------------------------------------------------------
-- 6. Workers re-emitted with the principal checks. Bodies are otherwise
--    identical to 0.105.3 (generated from the catalogue, not retyped).
-- ---------------------------------------------------------------------

-- maludb_core._memory_search_for_schema(name,text,text,text,malu_vector,integer,text): the namespace must be readable; hits whose source is above the ceiling are dropped
CREATE OR REPLACE FUNCTION maludb_core._memory_search_for_schema(p_owner_schema name, p_namespace text DEFAULT 'default'::text, p_subject text DEFAULT NULL::text, p_verb text DEFAULT NULL::text, p_query_embedding maludb_core.malu_vector DEFAULT NULL::maludb_core.malu_vector, p_limit integer DEFAULT 20, p_metric text DEFAULT NULL::text)
 RETURNS TABLE(chunk_id bigint, statement_id bigint, document_id bigint, source_text text, distance double precision, similarity double precision, rank_no integer, subject_name text, verb_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    v_namespace text    := COALESCE(p_namespace, 'default');
    v_limit     integer := GREATEST(COALESCE(p_limit, 20), 0);
    v_ceiling   integer;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);
    PERFORM maludb_core._principal_assert_scope(p_owner_schema, v_namespace, 'read', 'memory_search');
    v_ceiling := maludb_core._principal_ceiling_for_schema(p_owner_schema);

    IF p_query_embedding IS NULL THEN
        RAISE EXCEPTION 'memory_search: query embedding is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_subject IS NULL AND p_verb IS NULL THEN
        RAISE EXCEPTION 'memory_search: subject or verb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_limit = 0 THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH matching_compartments AS (
        SELECT c.compartment_id,
               s.subject_name,
               v.verb_name
          FROM maludb_core.malu$vector_compartment c
          JOIN maludb_core.malu$vector_subject s
            ON s.owner_schema = c.owner_schema
           AND s.namespace = c.namespace
           AND s.subject_id = c.subject_id
          JOIN maludb_core.malu$vector_verb v
            ON v.owner_schema = c.owner_schema
           AND v.namespace = c.namespace
           AND v.verb_id = c.verb_id
         WHERE c.owner_schema = p_owner_schema
           AND c.namespace = v_namespace COLLATE "default"
           AND (p_subject IS NULL OR s.subject_name = p_subject COLLATE "default")
           AND (p_verb IS NULL OR v.verb_name = p_verb COLLATE "default")
    ),
    compartment_hits AS (
        SELECT h.chunk_id      AS hit_chunk_id,
               h.source_text   AS hit_source_text,
               h.distance      AS hit_distance,
               h.similarity    AS hit_similarity,
               mc.compartment_id AS hit_compartment_id,
               mc.subject_name AS hit_subject_name,
               mc.verb_name    AS hit_verb_name
          FROM matching_compartments mc
          CROSS JOIN LATERAL maludb_core.exact_vector_search_sql(
              mc.compartment_id,
              p_query_embedding,
              v_limit,
              p_metric
          ) AS h
    ),
    ranked_hits AS (
        SELECT ch.hit_chunk_id,
               ch.hit_source_text,
               ch.hit_distance,
               ch.hit_similarity,
               ROW_NUMBER() OVER (
                   ORDER BY ch.hit_distance ASC,
                            ch.hit_compartment_id ASC,
                            ch.hit_chunk_id ASC
               )::integer AS hit_rank_no,
               ch.hit_subject_name,
               ch.hit_verb_name
          FROM compartment_hits ch
    )
    SELECT r.hit_chunk_id,
           vc.statement_id,
           vc.document_id,
           r.hit_source_text,
           r.hit_distance,
           r.hit_similarity,
           r.hit_rank_no,
           r.hit_subject_name,
           r.hit_verb_name
      FROM ranked_hits r
      JOIN maludb_core.malu$vector_chunk vc ON vc.chunk_id = r.hit_chunk_id
      LEFT JOIN maludb_core.malu$document d
        ON d.document_id = vc.document_id AND d.owner_schema = p_owner_schema
      LEFT JOIN maludb_core.malu$source_package sp
        ON sp.source_package_id = d.source_package_id AND sp.owner_schema = p_owner_schema
     WHERE r.hit_rank_no <= v_limit
       AND (v_ceiling IS NULL OR sp.source_package_id IS NULL
            OR maludb_core._sensitivity_rank(sp.sensitivity) <= v_ceiling)
     ORDER BY r.hit_rank_no;
END;
$function$;

-- maludb_core.vector_search_by_tags(text,text,text,malu_vector,integer,text): the namespace must be readable
CREATE OR REPLACE FUNCTION maludb_core.vector_search_by_tags(p_namespace text DEFAULT 'default'::text, p_subject text DEFAULT NULL::text, p_verb text DEFAULT NULL::text, p_query_embedding maludb_core.malu_vector DEFAULT NULL::maludb_core.malu_vector, p_limit integer DEFAULT 20, p_metric text DEFAULT NULL::text)
 RETURNS TABLE(chunk_id bigint, source_text text, distance double precision, similarity double precision, rank_no integer, compartment_id bigint, subject_name text, verb_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
#variable_conflict use_column
DECLARE
    v_schema      name := pg_catalog.current_schema();
    v_namespace   text := COALESCE(p_namespace, 'default');
    v_limit       integer := GREATEST(COALESCE(p_limit, 20), 0);
    v_search_path text := pg_catalog.current_setting('search_path');
BEGIN
    IF p_query_embedding IS NULL THEN
        RAISE EXCEPTION 'vector_search_by_tags: query embedding is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_subject IS NULL AND p_verb IS NULL THEN
        RAISE EXCEPTION 'vector_search_by_tags: subject or verb is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_limit = 0 THEN
        RETURN;
    END IF;

    PERFORM maludb_core._principal_assert_scope(v_schema, v_namespace, 'read', 'vector_search_by_tags');

    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, maludb_core, pg_temp', true);

    BEGIN
        RETURN QUERY
        WITH matching_compartments AS (
            SELECT c.compartment_id,
                   s.subject_name,
                   v.verb_name
              FROM maludb_core.malu$vector_compartment c
              JOIN maludb_core.malu$vector_subject s
                ON s.owner_schema = c.owner_schema
               AND s.namespace = c.namespace
               AND s.subject_id = c.subject_id
              JOIN maludb_core.malu$vector_verb v
                ON v.owner_schema = c.owner_schema
               AND v.namespace = c.namespace
               AND v.verb_id = c.verb_id
             WHERE c.owner_schema = v_schema
               AND c.namespace = v_namespace
               AND (p_subject IS NULL OR s.subject_name = p_subject)
               AND (p_verb IS NULL OR v.verb_name = p_verb)
        ),
        compartment_hits AS (
            SELECT h.chunk_id AS hit_chunk_id,
                   h.source_text AS hit_source_text,
                   h.distance AS hit_distance,
                   h.similarity AS hit_similarity,
                   mc.compartment_id AS hit_compartment_id,
                   mc.subject_name AS hit_subject_name,
                   mc.verb_name AS hit_verb_name
              FROM matching_compartments mc
              CROSS JOIN LATERAL maludb_core.exact_vector_search_sql(
                  mc.compartment_id,
                  p_query_embedding,
                  v_limit,
                  p_metric
              ) AS h
        ),
        ranked_hits AS (
            SELECT h.hit_chunk_id,
                   h.hit_source_text,
                   h.hit_distance,
                   h.hit_similarity,
                   ROW_NUMBER() OVER (
                       ORDER BY h.hit_distance ASC,
                                h.hit_compartment_id ASC,
                                h.hit_chunk_id ASC
                   )::integer AS global_rank_no,
                   h.hit_compartment_id,
                   h.hit_subject_name,
                   h.hit_verb_name
              FROM compartment_hits h
        )
        SELECT r.hit_chunk_id,
               r.hit_source_text,
               r.hit_distance,
               r.hit_similarity,
               r.global_rank_no,
               r.hit_compartment_id,
               r.hit_subject_name,
               r.hit_verb_name
          FROM ranked_hits r
         WHERE r.global_rank_no <= v_limit
         ORDER BY r.global_rank_no;

        PERFORM pg_catalog.set_config('search_path', v_search_path, true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_catalog.set_config('search_path', v_search_path, true);
        RAISE;
    END;
END;
$function$;

-- maludb_core._memory_ingest_edge_for_schema(...): the namespace must be writable; it becomes the document's scope
CREATE OR REPLACE FUNCTION maludb_core._memory_ingest_edge_for_schema(p_owner_schema name, p_source_kind text, p_source_id bigint, p_subject_text text, p_verb_text text, p_predicate jsonb DEFAULT '[]'::jsonb, p_embedding maludb_core.malu_vector DEFAULT NULL::maludb_core.malu_vector, p_embedding_model text DEFAULT NULL::text, p_subject_type text DEFAULT 'other'::text, p_source_span text DEFAULT NULL::text, p_confidence numeric DEFAULT NULL::numeric, p_provenance text DEFAULT 'suggested'::text, p_extraction_model text DEFAULT NULL::text, p_namespace text DEFAULT 'default'::text, p_document_id bigint DEFAULT NULL::bigint, p_valid_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_valid_to timestamp with time zone DEFAULT NULL::timestamp with time zone, p_distance_metric text DEFAULT 'cosine'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_source_kind   text := lower(btrim(COALESCE(p_source_kind, '')));
    v_prov          text := COALESCE(NULLIF(btrim(p_provenance), ''), 'suggested');
    v_subj          text := btrim(COALESCE(p_subject_text, ''));
    v_verb          text := btrim(COALESCE(p_verb_text, ''));
    v_subject_type  text := maludb_core._normalize_svpor_subject_type(
                                COALESCE(NULLIF(btrim(p_subject_type), ''), 'other'));
    v_subject_id    bigint;
    v_verb_id       bigint;
    v_statement_id  bigint;
    v_meta          jsonb;
    v_dim           integer;
    v_model         text;
    v_compartment_id bigint;
    v_chunk_id      bigint;
    v_span          text;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);
    PERFORM maludb_core._principal_assert_scope(p_owner_schema, p_namespace, 'write', 'memory_ingest_edge');

    -- the namespace of a document's first edge is the document's scope
    PERFORM maludb_core._document_adopt_scope(p_owner_schema, p_document_id, p_namespace);

    IF v_subj = '' OR v_verb = '' THEN
        RAISE EXCEPTION 'memory_ingest_edge: subject and verb text are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_source_id IS NULL OR v_source_kind = '' THEN
        RAISE EXCEPTION 'memory_ingest_edge: source_kind and source_id are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_prov NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'memory_ingest_edge: bad provenance %', v_prov
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_predicate IS NOT NULL AND jsonb_typeof(p_predicate) <> 'array' THEN
        RAISE EXCEPTION 'memory_ingest_edge: p_predicate must be a JSON array of attribute objects'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- the source endpoint must already exist in this tenant.
    PERFORM maludb_core._svpor_statement_assert_endpoint(p_owner_schema, v_source_kind, p_source_id);

    -- resolve (canonical or alias, exact) or create the subject.
    SELECT subject_id INTO v_subject_id
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_owner_schema
       AND (canonical_name = v_subj COLLATE "default" OR v_subj = ANY(aliases))
     ORDER BY (canonical_name = v_subj COLLATE "default") DESC
     LIMIT 1;
    IF v_subject_id IS NULL THEN
        INSERT INTO maludb_core.malu$svpor_subject(owner_schema, canonical_name, subject_type)
        VALUES (p_owner_schema, v_subj, v_subject_type)
        RETURNING subject_id INTO v_subject_id;
    END IF;

    -- resolve or create the verb.
    SELECT verb_id INTO v_verb_id
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_owner_schema
       AND (canonical_name = v_verb COLLATE "default" OR v_verb = ANY(aliases))
     ORDER BY (canonical_name = v_verb COLLATE "default") DESC
     LIMIT 1;
    IF v_verb_id IS NULL THEN
        INSERT INTO maludb_core.malu$svpor_verb(owner_schema, canonical_name)
        VALUES (p_owner_schema, v_verb)
        RETURNING verb_id INTO v_verb_id;
    END IF;

    -- edge provenance metadata (source span + extracting model), nulls dropped.
    v_meta := jsonb_strip_nulls(jsonb_build_object(
        'source_span',      NULLIF(btrim(COALESCE(p_source_span, '')), ''),
        'extraction_model', NULLIF(btrim(COALESCE(p_extraction_model, '')), '')));

    -- upsert the SVO edge: source --verb--> subject (idempotent on identity).
    INSERT INTO maludb_core.malu$svpor_statement
        (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id,
         valid_from, valid_to, confidence, provenance, metadata_jsonb)
    VALUES
        (p_owner_schema, v_source_kind, p_source_id, v_verb_id, 'subject', v_subject_id,
         p_valid_from, p_valid_to, p_confidence, v_prov, COALESCE(v_meta, '{}'::jsonb))
    ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id)
    DO UPDATE SET
        confidence     = COALESCE(EXCLUDED.confidence, malu$svpor_statement.confidence),
        provenance     = EXCLUDED.provenance,
        valid_from     = COALESCE(EXCLUDED.valid_from, malu$svpor_statement.valid_from),
        valid_to       = COALESCE(EXCLUDED.valid_to,   malu$svpor_statement.valid_to),
        metadata_jsonb = malu$svpor_statement.metadata_jsonb || EXCLUDED.metadata_jsonb
    RETURNING statement_id INTO v_statement_id;

    -- predicate -> typed edge attributes (upsert on attribute identity).
    IF p_predicate IS NOT NULL AND jsonb_typeof(p_predicate) = 'array' THEN
        INSERT INTO maludb_core.malu$svpor_attribute
            (owner_schema, target_kind, target_id, attr_name,
             value_timestamp, value_range, value_numeric, value_text, value_jsonb,
             unit, provenance, confidence, valid_from, valid_to, metadata_jsonb,
             ref_source, ref_entity, ref_key)
        SELECT p_owner_schema, 'svpor_statement', v_statement_id,
               btrim(e ->> 'attr_name'),
               (e ->> 'value_timestamp')::timestamptz,
               (e ->> 'value_range')::tstzrange,
               (e ->> 'value_numeric')::numeric,
               e ->> 'value_text',
               e -> 'value_jsonb',
               e ->> 'unit',
               COALESCE(e ->> 'provenance', v_prov),
               (e ->> 'confidence')::numeric,
               (e ->> 'valid_from')::timestamptz,
               (e ->> 'valid_to')::timestamptz,
               COALESCE(e -> 'metadata_jsonb', '{}'::jsonb),
               e ->> 'ref_source', e ->> 'ref_entity', e ->> 'ref_key'
          FROM jsonb_array_elements(p_predicate) AS e
         WHERE COALESCE(btrim(e ->> 'attr_name'), '') <> ''
        ON CONFLICT (owner_schema, target_kind, target_id, attr_name)
        DO UPDATE SET
            value_timestamp = EXCLUDED.value_timestamp,
            value_range     = EXCLUDED.value_range,
            value_numeric   = EXCLUDED.value_numeric,
            value_text      = EXCLUDED.value_text,
            value_jsonb     = EXCLUDED.value_jsonb,
            unit            = EXCLUDED.unit,
            provenance      = EXCLUDED.provenance,
            confidence      = EXCLUDED.confidence,
            valid_from      = EXCLUDED.valid_from,
            valid_to        = EXCLUDED.valid_to,
            metadata_jsonb  = EXCLUDED.metadata_jsonb,
            ref_source      = EXCLUDED.ref_source,
            ref_entity      = EXCLUDED.ref_entity,
            ref_key         = EXCLUDED.ref_key;
    END IF;

    -- embed the per-edge span into the graph-aligned compartment.
    IF p_embedding IS NOT NULL THEN
        v_dim   := maludb_core.vector_dims(p_embedding);
        v_model := COALESCE(NULLIF(btrim(COALESCE(p_embedding_model, '')), ''), 'unspecified');
        v_span  := COALESCE(NULLIF(btrim(COALESCE(p_source_span, '')), ''), '');

        v_compartment_id := maludb_core._vector_compartment_for_svpor(
            p_owner_schema, v_subject_id, v_verb_id, v_dim, v_model,
            p_namespace, p_distance_metric);

        v_chunk_id := maludb_core.register_vector_chunk(
            v_compartment_id, v_span, p_embedding, v_model);

        UPDATE maludb_core.malu$vector_chunk
           SET statement_id = v_statement_id,
               document_id  = p_document_id
         WHERE chunk_id = v_chunk_id;
    END IF;

    RETURN v_statement_id;
END;
$function$;

-- maludb_core._memory_request_extraction_for_schema(...): the namespace must be writable
CREATE OR REPLACE FUNCTION maludb_core._memory_request_extraction_for_schema(p_owner_schema name, p_source_kind text, p_source_id bigint, p_chunk_text text, p_namespace text DEFAULT 'default'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_namespace   text := COALESCE(NULLIF(p_namespace, ''), 'default');
    v_source_kind text := lower(btrim(COALESCE(p_source_kind, '')));
    v_alias       text;
    v_cfg_prompt  text;
    v_genparams   jsonb;
    v_template    text;
    v_prompt      text;
    v_request_id  bigint;
    v_alias_id    bigint;
    v_hash        text;
    v_default_prompt text :=
        'You convert a document chunk into canonical memory edges for a knowledge graph. '
     || 'Return ONLY JSON of the form '
     || '{"candidate_edges":[{"subject_text":"<entity the memory is about>",'
     || '"subject_type":"<person|software|project|...>","verb_text":"<small canonical verb>",'
     || '"predicate":[{"attr_name":"status","value_text":"completed"},'
     || '{"attr_name":"event_at","value_timestamp":"<ISO 8601>"}],'
     || '"source_span":"<verbatim span>","confidence":0.0,'
     || '"embedding":[<floats>],"embedding_model":"<model>"}]}. '
     || 'Use a small canonical verb (e.g. "upgrade", not "performed_upgrade"); put '
     || 'status / timing / details in predicate attributes.'
     || E'\n\nCHUNK:\n{{chunk}}';
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);
    PERFORM maludb_core._principal_assert_scope(p_owner_schema, v_namespace, 'write', 'memory_request_extraction');

    IF v_source_kind = '' OR p_source_id IS NULL THEN
        RAISE EXCEPTION 'memory_request_extraction: source_kind and source_id are required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF COALESCE(btrim(p_chunk_text), '') = '' THEN
        RAISE EXCEPTION 'memory_request_extraction: chunk_text is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT extraction_alias, prompt_template, generation_params
      INTO v_alias, v_cfg_prompt, v_genparams
      FROM maludb_core.malu$memory_extraction_config
     WHERE owner_schema = p_owner_schema AND namespace = v_namespace COLLATE "default";

    IF v_alias IS NULL THEN
        RAISE EXCEPTION 'memory_request_extraction: no extraction model configured for schema % namespace % (call maludb_memory_set_model_config first)',
            p_owner_schema, v_namespace
            USING ERRCODE = 'no_data_found';
    END IF;

    -- resolve the alias within THIS tenant (the gateway is owner_schema-scoped).
    SELECT alias_id INTO v_alias_id
      FROM maludb_core.malu$model_alias
     WHERE owner_schema = p_owner_schema AND alias_name = v_alias COLLATE "default" AND enabled = true;
    IF v_alias_id IS NULL THEN
        RAISE EXCEPTION 'memory_request_extraction: model alias % is not registered/enabled in schema %', v_alias, p_owner_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    v_template := COALESCE(NULLIF(btrim(COALESCE(v_cfg_prompt, '')), ''), v_default_prompt);
    IF position('{{chunk}}' IN v_template) > 0 THEN
        v_prompt := replace(v_template, '{{chunk}}', p_chunk_text);
    ELSE
        v_prompt := v_template || E'\n\nCHUNK:\n' || p_chunk_text;
    END IF;

    -- enqueue into the model gateway with EXPLICIT owner_schema (this runs under a
    -- DEFINER search_path where current_schema() is not the tenant, so we cannot lean
    -- on submit_request's current_schema()-based owner_schema default). UTF-8 prompt
    -- hash; idempotency_key left NULL so the gateway's idempotency index is bypassed.
    v_hash := encode(sha256(convert_to(v_prompt, 'UTF8')), 'hex');
    INSERT INTO maludb_core.malu$model_request
        (owner_schema, alias_id, rendered_prompt, prompt_hash, generation_params, timeout_ms)
    VALUES
        (p_owner_schema, v_alias_id, v_prompt, v_hash, COALESCE(v_genparams, '{}'::jsonb), 30000)
    RETURNING request_id INTO v_request_id;

    INSERT INTO maludb_core.malu$memory_extraction
        (owner_schema, namespace, source_kind, source_id, chunk_text, request_id, status)
    VALUES
        (p_owner_schema, v_namespace, v_source_kind, p_source_id, p_chunk_text, v_request_id, 'pending');

    RETURN v_request_id;
END;
$function$;

-- maludb_core._note_search_for_schema(...): only documents in a readable scope, at or under the ceiling
CREATE OR REPLACE FUNCTION maludb_core._note_search_for_schema(p_schema name, p_subject_like text[] DEFAULT NULL::text[], p_verb_like text DEFAULT NULL::text, p_verb_exact text DEFAULT NULL::text, p_source_type text DEFAULT 'note'::text, p_all_sources boolean DEFAULT false, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
 RETURNS TABLE(document_id bigint, title text, source_type text, snippet text, created_at timestamp with time zone, match_count integer, matched_edges jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    v_scopes  text[];
    v_ceiling integer;
    v_subject_like text[];
    v_verb_like    text := NULLIF(btrim(COALESCE(p_verb_like, '')), '');
    v_verb_exact   text := NULLIF(btrim(COALESCE(p_verb_exact, '')), '');
    v_source_type  text := COALESCE(NULLIF(btrim(COALESCE(p_source_type, '')), ''), 'note');
    v_limit        integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 200);
    v_offset       integer := GREATEST(COALESCE(p_offset, 0), 0);
    v_has_subject  boolean;
    v_has_verb     boolean;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    v_scopes  := maludb_core._principal_scopes_for_schema(p_schema, 'read');
    v_ceiling := maludb_core._principal_ceiling_for_schema(p_schema);

    SELECT array_agg(pat) INTO v_subject_like
      FROM (SELECT NULLIF(btrim(p), '') AS pat
              FROM unnest(COALESCE(p_subject_like, ARRAY[]::text[])) AS p) t
     WHERE pat IS NOT NULL;
    v_has_subject := v_subject_like IS NOT NULL AND cardinality(v_subject_like) > 0;
    v_has_verb    := v_verb_exact IS NOT NULL OR v_verb_like IS NOT NULL;

    IF NOT v_has_subject AND NOT v_has_verb THEN
        RAISE EXCEPTION 'note_search: at least one of subject_like, verb_like, verb_exact is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
    WITH matched_verbs AS (
        -- exact wins over like: when both are supplied only the exact
        -- branch runs (documented contract).
        SELECT v.verb_id
          FROM maludb_core.malu$svpor_verb v
         WHERE v.owner_schema = p_schema
           AND CASE
               WHEN v_verb_exact IS NOT NULL THEN
                    lower(v.canonical_name) = lower(v_verb_exact)
                 OR EXISTS (SELECT 1 FROM unnest(v.aliases) a
                             WHERE lower(a) = lower(v_verb_exact))
               ELSE
                    v.canonical_name ILIKE '%' || v_verb_like || '%'
                 OR v_verb_like ILIKE '%' || v.canonical_name || '%'
                 OR EXISTS (SELECT 1 FROM unnest(v.aliases) a
                             WHERE a ILIKE '%' || v_verb_like || '%'
                                OR v_verb_like ILIKE '%' || a || '%')
               END
    ),
    matched_subjects AS (
        SELECT s.subject_id
          FROM maludb_core.malu$svpor_subject s
         WHERE s.owner_schema = p_schema
           AND EXISTS (SELECT 1 FROM unnest(v_subject_like) pat
                        WHERE s.canonical_name ILIKE '%' || pat || '%'
                           OR EXISTS (SELECT 1 FROM unnest(s.aliases) a
                                       WHERE a ILIKE '%' || pat || '%'))
    ),
    stmts AS (
        SELECT st.statement_id
          FROM maludb_core.malu$svpor_statement st
         WHERE st.owner_schema = p_schema
           AND (NOT v_has_verb
                OR st.verb_id IN (SELECT mv.verb_id FROM matched_verbs mv))
           AND (NOT v_has_subject
                OR (st.subject_kind = 'subject'
                    AND st.subject_id IN (SELECT ms.subject_id FROM matched_subjects ms))
                OR (st.object_kind = 'subject'
                    AND st.object_id IN (SELECT ms.subject_id FROM matched_subjects ms)))
    ),
    doc_links AS (
        -- both statement->document rails; a statement linked over both
        -- collapses to one row (min() prefers 'statement_endpoint').
        SELECT l.doc_id, l.statement_id, min(l.match_via) AS match_via
          FROM (
            SELECT vc.document_id AS doc_id, s.statement_id,
                   'vector_chunk'::text AS match_via
              FROM stmts s
              JOIN maludb_core.malu$vector_chunk vc ON vc.statement_id = s.statement_id
             WHERE vc.document_id IS NOT NULL
            UNION ALL
            SELECT CASE WHEN st.subject_kind = 'document' THEN st.subject_id
                        ELSE st.object_id END,
                   st.statement_id,
                   'statement_endpoint'::text
              FROM stmts s
              JOIN maludb_core.malu$svpor_statement st ON st.statement_id = s.statement_id
             WHERE st.owner_schema = p_schema
               AND (st.subject_kind = 'document' OR st.object_kind = 'document')
          ) l
         GROUP BY l.doc_id, l.statement_id
    ),
    edge_detail AS (
        SELECT dl.doc_id, dl.statement_id, dl.match_via,
               st.confidence,
               CASE st.subject_kind
                    WHEN 'subject'  THEN subj_s.canonical_name
                    WHEN 'document' THEN 'document:' || st.subject_id
                    ELSE st.subject_kind || ':' || st.subject_id END AS subject_name,
               vb.canonical_name AS verb_name,
               CASE st.object_kind
                    WHEN 'subject'  THEN obj_s.canonical_name
                    WHEN 'document' THEN 'document:' || st.object_id
                    ELSE st.object_kind || ':' || st.object_id END AS object_name,
               CASE WHEN NOT v_has_subject THEN NULL
                    WHEN st.subject_kind = 'subject'
                     AND st.subject_id IN (SELECT ms.subject_id FROM matched_subjects ms)
                    THEN 'subject' ELSE 'object' END AS matched_endpoint
          FROM doc_links dl
          JOIN maludb_core.malu$svpor_statement st
            ON st.statement_id = dl.statement_id AND st.owner_schema = p_schema
          JOIN maludb_core.malu$svpor_verb vb
            ON vb.verb_id = st.verb_id AND vb.owner_schema = p_schema
          LEFT JOIN maludb_core.malu$svpor_subject subj_s
            ON st.subject_kind = 'subject' AND subj_s.subject_id = st.subject_id
           AND subj_s.owner_schema = p_schema
          LEFT JOIN maludb_core.malu$svpor_subject obj_s
            ON st.object_kind = 'subject' AND obj_s.subject_id = st.object_id
           AND obj_s.owner_schema = p_schema
    )
    SELECT d.document_id,
           d.title,
           d.source_type,
           left(sp.content_text, 240) AS snippet,
           d.created_at,
           count(DISTINCT ed.statement_id)::integer AS match_count,
           jsonb_agg(DISTINCT jsonb_strip_nulls(jsonb_build_object(
               'statement_id',     ed.statement_id,
               'subject_name',     ed.subject_name,
               'verb_name',        ed.verb_name,
               'object_name',      ed.object_name,
               'confidence',       ed.confidence,
               'match_via',        ed.match_via,
               'matched_endpoint', ed.matched_endpoint))) AS matched_edges
      FROM edge_detail ed
      JOIN maludb_core.malu$document d
        ON d.document_id = ed.doc_id AND d.owner_schema = p_schema
      LEFT JOIN maludb_core.malu$source_package sp
        ON sp.source_package_id = d.source_package_id AND sp.owner_schema = p_schema
     WHERE (p_all_sources OR d.source_type = v_source_type COLLATE "default")
       AND (v_scopes IS NULL
            OR (COALESCE(d.scope, 'default') = ANY (v_scopes)
                AND (sp.source_package_id IS NULL
                     OR maludb_core._sensitivity_rank(sp.sensitivity) <= v_ceiling)))
     GROUP BY d.document_id, d.title, d.source_type, sp.content_text, d.created_at
     ORDER BY d.created_at DESC, d.document_id DESC
     LIMIT v_limit OFFSET v_offset;
END;
$function$;

-- maludb_core.semantic_search(bytea,text[],integer,text,text): cards of rows the session may not read are left out
CREATE OR REPLACE FUNCTION maludb_core.semantic_search(p_query_embedding bytea, p_object_kinds text[] DEFAULT NULL::text[], p_k integer DEFAULT 10, p_embedding_space text DEFAULT NULL::text, p_metric text DEFAULT 'cosine'::text)
 RETURNS TABLE(object_kind text, object_id bigint, source_field text, sub_key text, score double precision, label text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_dim    integer;
    v_metric text := lower(COALESCE(p_metric, 'cosine'));
BEGIN
    IF p_query_embedding IS NULL THEN
        RAISE EXCEPTION 'semantic_search: query embedding is required' USING ERRCODE='invalid_parameter_value';
    END IF;
    IF v_metric NOT IN ('cosine','l2','inner_product') THEN
        RAISE EXCEPTION 'semantic_search: metric must be cosine/l2/inner_product' USING ERRCODE='invalid_parameter_value';
    END IF;
    v_dim := octet_length(p_query_embedding) / 4;

    RETURN QUERY
        SELECT oe.object_kind, oe.object_id, oe.source_field, oe.sub_key,
               -- raw-float bytea is binary-compatible with malu_vector (CAST
               -- ... WITHOUT FUNCTION); the distance primitives are
               -- malu_vector-typed, so cast both operands at compare time.
               CASE v_metric
                   WHEN 'cosine'        THEN 1.0 - maludb_core.cosine_distance(oe.embedding::maludb_core.malu_vector, p_query_embedding::maludb_core.malu_vector)
                   WHEN 'inner_product' THEN maludb_core.vector_dot_product(oe.embedding::maludb_core.malu_vector, p_query_embedding::maludb_core.malu_vector)
                   ELSE                      - maludb_core.vector_l2_squared(oe.embedding::maludb_core.malu_vector, p_query_embedding::maludb_core.malu_vector)
               END AS score,
               maludb_core._svpor_endpoint_label(oe.object_kind, oe.object_id) AS label
          FROM maludb_core.malu$object_embedding oe
         WHERE oe.owner_schema = current_schema()
           AND oe.embedding_dim = v_dim
           AND (p_embedding_space IS NULL OR oe.embedding_space = p_embedding_space)
           AND (p_object_kinds IS NULL OR cardinality(p_object_kinds)=0 OR oe.object_kind = ANY(p_object_kinds))
           AND (maludb_core.current_principal_ref() IS NULL
                OR CASE oe.object_kind
                       WHEN 'subject'        THEN maludb_core._event_subject_visible(oe.owner_schema, oe.object_id)
                       WHEN 'document'       THEN EXISTS (SELECT 1 FROM maludb_core.malu$document x WHERE x.document_id = oe.object_id)
                       WHEN 'episode_object' THEN EXISTS (SELECT 1 FROM maludb_core.malu$episode_object x WHERE x.episode_id = oe.object_id)
                       WHEN 'memory'         THEN EXISTS (SELECT 1 FROM maludb_core.malu$memory x WHERE x.memory_id = oe.object_id)
                       WHEN 'source_package' THEN EXISTS (SELECT 1 FROM maludb_core.malu$source_package x WHERE x.source_package_id = oe.object_id)
                       ELSE true
                   END)
         ORDER BY score DESC
         LIMIT GREATEST(COALESCE(p_k, 10), 1);
END;
$function$;

-- maludb_core._register_agent_skill_for_schema(...): a proposal does not supersede its parent
CREATE OR REPLACE FUNCTION maludb_core._register_agent_skill_for_schema(p_schema name, p_skill_name text, p_markdown text, p_bundle_hash text, p_description text DEFAULT NULL::text, p_frontmatter jsonb DEFAULT '{}'::jsonb, p_version text DEFAULT NULL::text, p_keywords text[] DEFAULT NULL::text[], p_subjects jsonb DEFAULT NULL::jsonb, p_verbs jsonb DEFAULT NULL::jsonb, p_files jsonb DEFAULT NULL::jsonb, p_parent_owner_schema name DEFAULT NULL::name, p_parent_skill_id bigint DEFAULT NULL::bigint, p_materially_different boolean DEFAULT true, p_enabled boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_name        text := btrim(COALESCE(p_skill_name, ''));
    v_hash        text := lower(btrim(COALESCE(p_bundle_hash, '')));
    v_version     text;
    v_skill_id    bigint;
    v_existing    bigint;
    v_superseded  bigint;
    v_parent      maludb_core.malu$skill_package%ROWTYPE;
    v_notes       jsonb := '[]'::jsonb;
    r             record;
    v_tag_name    text;
    v_tag_id      bigint;
    v_kw          text;
    v_sp_id       bigint;
    v_sp          maludb_core.malu$source_package%ROWTYPE;
    c_kw integer := 0; c_subj integer := 0; c_verb integer := 0; c_files integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    IF v_name = '' THEN
        RAISE EXCEPTION 'register_agent_skill: skill_name is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF COALESCE(btrim(p_markdown), '') = '' THEN
        RAISE EXCEPTION 'register_agent_skill: markdown (the SKILL.md body) is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'register_agent_skill: bundle_hash must be 64 lowercase hex chars (sha256), got %', p_bundle_hash
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF (p_parent_owner_schema IS NULL) <> (p_parent_skill_id IS NULL) THEN
        RAISE EXCEPTION 'register_agent_skill: parent schema and skill id must be provided together'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Idempotent re-push of an unchanged bundle.
    SELECT skill_id INTO v_existing
      FROM maludb_core.malu$skill_package
     WHERE owner_schema = p_schema
       AND skill_name = v_name COLLATE "default"
       AND bundle_hash = v_hash
     ORDER BY skill_id
     LIMIT 1;
    IF v_existing IS NOT NULL THEN
        RETURN jsonb_build_object(
            'skill_id', v_existing,
            'skill_name', v_name,
            'reused', true);
    END IF;

    IF p_parent_skill_id IS NOT NULL THEN
        SELECT * INTO v_parent
          FROM maludb_core.malu$skill_package
         WHERE owner_schema = p_parent_owner_schema
           AND skill_id = p_parent_skill_id;
        IF NOT FOUND
           OR NOT (v_parent.owner_schema = p_schema
                   OR maludb_core._skill_is_visible(v_parent.owner_schema, v_parent.skill_id, p_schema, true)) THEN
            RAISE EXCEPTION 'register_agent_skill: parent skill %.% not found or not visible from %',
                p_parent_owner_schema, p_parent_skill_id, p_schema
                USING ERRCODE = 'P0002';
        END IF;
    END IF;

    -- Version: caller-supplied (frontmatter metadata.version), else the
    -- bundle hash prefix. (owner, name, version) is UNIQUE; a stale
    -- caller version on changed content falls back to a hash suffix.
    v_version := COALESCE(NULLIF(btrim(p_version), ''), left(v_hash, 12));
    IF EXISTS (SELECT 1 FROM maludb_core.malu$skill_package
                WHERE owner_schema = p_schema AND skill_name = v_name COLLATE "default" AND version = v_version COLLATE "default") THEN
        v_version := v_version || '+' || left(v_hash, 8);
        IF EXISTS (SELECT 1 FROM maludb_core.malu$skill_package
                    WHERE owner_schema = p_schema AND skill_name = v_name COLLATE "default" AND version = v_version COLLATE "default") THEN
            RAISE EXCEPTION 'register_agent_skill: version % already taken for skill % (and so is its hash-suffixed fallback)',
                v_version, v_name
                USING ERRCODE = 'unique_violation';
        END IF;
    END IF;

    INSERT INTO maludb_core.malu$skill_package(
        owner_schema, skill_name, version, description,
        packaging_kind, enabled, visibility,
        markdown, bundle_hash, frontmatter_jsonb,
        source_owner_schema, source_skill_id, forked_at
    )
    VALUES (
        p_schema, v_name, v_version, NULLIF(btrim(COALESCE(p_description, '')), ''),
        'markdown', COALESCE(p_enabled, true), 'private',
        p_markdown, v_hash, COALESCE(p_frontmatter, '{}'::jsonb),
        p_parent_owner_schema, p_parent_skill_id,
        CASE WHEN p_parent_skill_id IS NOT NULL THEN now() END
    )
    RETURNING skill_id INTO v_skill_id;

    -- Discovery tags (provenance 'extracted').
    FOREACH v_kw IN ARRAY COALESCE(p_keywords, ARRAY[]::text[])
    LOOP
        CONTINUE WHEN btrim(COALESCE(v_kw, '')) = '';
        INSERT INTO maludb_core.malu$skill_keyword(owner_schema, skill_id, keyword, provenance)
        VALUES (p_schema, v_skill_id, btrim(v_kw), 'extracted')
        ON CONFLICT (owner_schema, skill_id, lower(keyword)) DO NOTHING;
        c_kw := c_kw + 1;
    END LOOP;

    FOR r IN SELECT val FROM jsonb_array_elements(COALESCE(p_subjects, '[]'::jsonb)) AS t(val)
    LOOP
        v_tag_name := btrim(COALESCE(r.val ->> 'name', ''));
        CONTINUE WHEN v_tag_name = '';
        v_tag_id := NULLIF(btrim(COALESCE(r.val ->> 'id', '')), '')::bigint;
        IF v_tag_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM maludb_core.malu$svpor_subject
             WHERE owner_schema = p_schema AND subject_id = v_tag_id) THEN
            v_tag_id := NULL;
        END IF;
        INSERT INTO maludb_core.malu$skill_subject(owner_schema, skill_id, subject_id, subject_name, weight, provenance)
        VALUES (p_schema, v_skill_id, v_tag_id, v_tag_name,
                COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'weight', '')), '')::numeric, 1.0), 'extracted')
        ON CONFLICT (owner_schema, skill_id, lower(subject_name)) DO NOTHING;
        c_subj := c_subj + 1;
    END LOOP;

    FOR r IN SELECT val FROM jsonb_array_elements(COALESCE(p_verbs, '[]'::jsonb)) AS t(val)
    LOOP
        v_tag_name := btrim(COALESCE(r.val ->> 'name', ''));
        CONTINUE WHEN v_tag_name = '';
        v_tag_id := NULLIF(btrim(COALESCE(r.val ->> 'id', '')), '')::bigint;
        IF v_tag_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = p_schema AND verb_id = v_tag_id) THEN
            v_tag_id := NULL;
        END IF;
        INSERT INTO maludb_core.malu$skill_verb(owner_schema, skill_id, verb_id, verb_name, weight, provenance)
        VALUES (p_schema, v_skill_id, v_tag_id, v_tag_name,
                COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'weight', '')), '')::numeric, 1.0), 'extracted')
        ON CONFLICT (owner_schema, skill_id, lower(verb_name)) DO NOTHING;
        c_verb := c_verb + 1;
    END LOOP;

    -- Bundle manifest. Each file's bytes must already sit in a source
    -- package owned by the registering schema; hash/size/media default
    -- from the package when omitted.
    FOR r IN SELECT val FROM jsonb_array_elements(COALESCE(p_files, '[]'::jsonb)) AS t(val)
    LOOP
        v_sp_id := NULLIF(btrim(COALESCE(r.val ->> 'source_package_id', '')), '')::bigint;
        IF v_sp_id IS NULL OR btrim(COALESCE(r.val ->> 'relative_path', '')) = '' THEN
            RAISE EXCEPTION 'register_agent_skill: each file needs relative_path and source_package_id (got %)', r.val
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
        SELECT * INTO v_sp
          FROM maludb_core.malu$source_package
         WHERE source_package_id = v_sp_id
           AND owner_schema = p_schema;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'register_agent_skill: source package % not found in schema %', v_sp_id, p_schema
                USING ERRCODE = 'P0002';
        END IF;
        INSERT INTO maludb_core.malu$skill_file(
            owner_schema, skill_id, relative_path, source_package_id,
            file_hash, file_size, is_executable, media_type)
        VALUES (
            p_schema, v_skill_id, btrim(r.val ->> 'relative_path'), v_sp_id,
            COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'file_hash', '')), ''), v_sp.content_hash),
            COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'file_size', '')), '')::bigint, v_sp.content_size),
            COALESCE((r.val ->> 'is_executable')::boolean, false),
            COALESCE(NULLIF(btrim(COALESCE(r.val ->> 'media_type', '')), ''), v_sp.media_type));
        c_files := c_files + 1;
    END LOOP;

    -- Supersession: a non-materially-different revision hides its
    -- parent from discovery (enabled = false). Cross-schema parents
    -- are another team's rows -- never touched, only reported.
    -- (0.106.0) ...unless a principal-bound session wrote it: that is a proposal,
    -- and a proposal retires nothing until someone approves it.
    IF p_parent_skill_id IS NOT NULL AND NOT COALESCE(p_materially_different, true)
       AND maludb_core.current_principal_ref() IS NULL THEN
        IF p_parent_owner_schema = p_schema THEN
            UPDATE maludb_core.malu$skill_package
               SET enabled = false,
                   updated_at = now()
             WHERE owner_schema = p_schema
               AND skill_id = p_parent_skill_id
               AND enabled;
            IF FOUND THEN
                v_superseded := p_parent_skill_id;
            END IF;
        ELSE
            v_notes := v_notes || jsonb_build_object(
                'note', 'parent_not_disabled',
                'reason', 'parent lives in another schema',
                'parent_owner_schema', p_parent_owner_schema::text,
                'parent_skill_id', p_parent_skill_id);
        END IF;
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'skill_id', v_skill_id,
        'skill_name', v_name,
        'version', v_version,
        'reused', false,
        'superseded_skill_id', v_superseded,
        'tags', jsonb_build_object('keywords', c_kw, 'subjects', c_subj, 'verbs', c_verb),
        'files_linked', c_files,
        'notes', CASE WHEN v_notes = '[]'::jsonb THEN NULL ELSE v_notes END));
END;
$function$;

-- maludb_core._memory_ingest_extraction_for_schema(name,jsonb,text,bigint,text,text): gains p_namespace -- the scope of the episodes it mints and of its source document. A five-argument call (a tenant facade not yet rebuilt) still resolves, to 'default'.
DROP FUNCTION maludb_core._memory_ingest_extraction_for_schema(name, jsonb, text, bigint, text);
CREATE FUNCTION maludb_core._memory_ingest_extraction_for_schema(p_owner_schema name, p_extraction jsonb, p_source_kind text DEFAULT 'document'::text, p_source_id bigint DEFAULT NULL::bigint, p_provenance text DEFAULT 'accepted'::text, p_namespace text DEFAULT 'default'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_namespace    text := COALESCE(NULLIF(btrim(COALESCE(p_namespace, '')), ''), 'default');
    v_prov         text := COALESCE(NULLIF(btrim(p_provenance), ''), 'accepted');
    v_src_kind     text := lower(btrim(COALESCE(p_source_kind, '')));
    v_src_id       bigint := p_source_id;
    v_doc          jsonb;
    v_ids          jsonb := '{}'::jsonb;   -- key -> id
    v_kinds        jsonb := '{}'::jsonb;   -- key -> kind
    v_skipped      jsonb := '[]'::jsonb;
    r              record;
    v_key          text;
    v_name         text;
    v_type         text;
    v_occ          timestamptz;
    v_occu         timestamptz;
    v_id           bigint;
    -- counters
    c_subj_c integer := 0; c_subj_r integer := 0;
    c_verb_c integer := 0; c_verb_r integer := 0;
    c_epi_c  integer := 0; c_epi_r  integer := 0;
    c_edges  integer := 0; c_rels   integer := 0;
    c_nattr  integer := 0; c_eattr  integer := 0;
    -- edge resolution
    v_sk text; v_si bigint; v_ok text; v_oi bigint; v_vid bigint; v_stmt bigint;
    v_ref text; v_okind text;
    v_span text; v_span_doc bigint;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);
    PERFORM maludb_core._principal_assert_scope(p_owner_schema, v_namespace, 'write', 'memory_ingest_extraction');

    IF p_extraction IS NULL OR jsonb_typeof(p_extraction) <> 'object' THEN
        RAISE EXCEPTION 'memory_ingest_extraction: p_extraction must be a JSON object'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_prov NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'memory_ingest_extraction: bad provenance %', v_prov
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    -- BREAKING (0.94.0): fail fast so a stale extractor cannot silently
    -- drop its events.
    IF p_extraction ? 'episodes' THEN
        RAISE EXCEPTION 'memory_ingest_extraction: the episodes[] section was removed in 0.94.0; emit events as subjects[] entries with occurred_at/occurred_until (see docs/memory-extraction-json-contract.md)'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- ---- source anchor: create the document, or use the passed source -----
    v_doc := p_extraction -> 'document';
    IF v_doc IS NOT NULL AND jsonb_typeof(v_doc) = 'object' THEN
        v_src_id := maludb_core._upload_document_for_schema(
            p_owner_schema,
            v_doc ->> 'title',
            v_doc ->> 'content_text',
            COALESCE(NULLIF(v_doc ->> 'source_type', ''), 'document'),
            CASE WHEN jsonb_typeof(v_doc -> 'content_jsonb') = 'object' THEN v_doc -> 'content_jsonb' ELSE NULL END,
            v_doc ->> 'media_type',
            ARRAY[]::text[], ARRAY[]::text[], ARRAY[]::text[], ARRAY[]::text[],
            COALESCE(v_doc -> 'metadata', '{}'::jsonb),
            v_doc ->> 'document_type');
        v_src_kind := 'document';
    END IF;
    v_span_doc := CASE WHEN v_src_kind = 'document' THEN v_src_id ELSE NULL END;
    -- the source document lives in the namespace it was ingested into
    PERFORM maludb_core._document_adopt_scope(p_owner_schema, v_span_doc, v_namespace);

    -- ---- subjects (entities AND events) ------------------------------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'subjects', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_key  := r.val ->> 'key';
            v_name := btrim(COALESCE(r.val ->> 'name', ''));
            v_type := NULLIF(btrim(COALESCE(r.val ->> 'type', '')), '');
            v_occ  := (r.val ->> 'occurred_at')::timestamptz;
            v_occu := (r.val ->> 'occurred_until')::timestamptz;
            IF COALESCE(btrim(v_key), '') = '' OR v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','subjects','index',r.idx,'reason','missing key or name');
                CONTINUE;
            END IF;

            IF v_occ IS NOT NULL OR v_occu IS NOT NULL THEN
                -- Events resolve by EXACT canonical name (the extractor
                -- reusing the dated KNOWN_SUBJECTS name) or by the dedup
                -- triple (kind, title, occurred_at) -- NEVER by alias:
                -- recurring titles ("Daily standup") alias many distinct
                -- occurrences, and an alias hit would swallow new ones.
                SELECT subject_id INTO v_id
                  FROM maludb_core.malu$svpor_subject
                 WHERE owner_schema = p_owner_schema
                   AND canonical_name = v_name COLLATE "default";
                IF v_id IS NULL THEN
                    SELECT e.subject_id INTO v_id
                      FROM maludb_core.malu$episode_object e
                     WHERE e.owner_schema = p_owner_schema
                       AND e.episode_kind = COALESCE(v_type, 'event')
                       AND e.title = v_name COLLATE "default"
                       AND e.occurred_at IS NOT DISTINCT FROM v_occ
                       AND e.subject_id IS NOT NULL;
                    IF v_id IS NOT NULL THEN
                        c_epi_r := c_epi_r + 1;
                    END IF;
                END IF;
            ELSE
                SELECT subject_id INTO v_id
                  FROM maludb_core.malu$svpor_subject
                 WHERE owner_schema = p_owner_schema
                   AND (canonical_name = v_name COLLATE "default" OR v_name = ANY(aliases))
                 ORDER BY (canonical_name = v_name COLLATE "default") DESC
                 LIMIT 1;
            END IF;

            IF v_id IS NULL THEN
                IF v_occ IS NOT NULL OR v_occu IS NOT NULL THEN
                    -- event: the sidecar insert mints the subject identity
                    INSERT INTO maludb_core.malu$episode_object
                        (owner_schema, episode_kind, title, summary, occurred_at, occurred_until, scope)
                    VALUES (p_owner_schema, COALESCE(v_type, 'event'), v_name,
                            r.val ->> 'description', v_occ, v_occu,
                            NULLIF(v_namespace, 'default'))
                    RETURNING subject_id INTO v_id;
                    c_epi_c := c_epi_c + 1;
                ELSE
                    INSERT INTO maludb_core.malu$svpor_subject (owner_schema, canonical_name, subject_type, aliases)
                    VALUES (p_owner_schema, v_name,
                            maludb_core._normalize_svpor_subject_type(COALESCE(v_type, 'other')),
                            CASE WHEN jsonb_typeof(r.val -> 'aliases') = 'array'
                                 THEN ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases')) ELSE ARRAY[]::text[] END)
                    RETURNING subject_id INTO v_id;
                END IF;
                c_subj_c := c_subj_c + 1;
                IF (v_occ IS NOT NULL OR v_occu IS NOT NULL)
                   AND jsonb_typeof(r.val -> 'aliases') = 'array' THEN
                    UPDATE maludb_core.malu$svpor_subject s
                       SET aliases = (SELECT array_agg(DISTINCT a)
                                        FROM unnest(s.aliases || ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases'))) a)
                     WHERE s.owner_schema = p_owner_schema AND s.subject_id = v_id;
                END IF;
            ELSE
                IF jsonb_typeof(r.val -> 'aliases') = 'array' THEN
                    UPDATE maludb_core.malu$svpor_subject s
                       SET aliases = (SELECT array_agg(DISTINCT a)
                                        FROM unnest(s.aliases || ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases'))) a)
                     WHERE s.owner_schema = p_owner_schema AND s.subject_id = v_id;
                END IF;
                c_subj_r := c_subj_r + 1;
            END IF;

            c_nattr := c_nattr + maludb_core._memory_apply_attributes_for_schema(
                           p_owner_schema, 'subject', v_id, r.val -> 'attributes', v_prov);

            -- external ref pointer (sugar) -> a single reference attribute
            IF jsonb_typeof(r.val -> 'ref') = 'object' THEN
                c_nattr := c_nattr + maludb_core._memory_apply_attributes_for_schema(
                    p_owner_schema, 'subject', v_id,
                    jsonb_build_array(jsonb_build_object(
                        'attr_name', 'external_ref',
                        'value_text', COALESCE(r.val -> 'ref' ->> 'key', v_name),
                        'ref_source', r.val -> 'ref' ->> 'source',
                        'ref_entity', r.val -> 'ref' ->> 'entity',
                        'ref_key',    r.val -> 'ref' ->> 'key')),
                    v_prov);
            END IF;

            v_ids   := jsonb_set(v_ids,   ARRAY[v_key], to_jsonb(v_id));
            v_kinds := jsonb_set(v_kinds, ARRAY[v_key], to_jsonb('subject'::text));
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','subjects','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- verbs (explicit registration; edges also auto-create) ------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'verbs', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_name := btrim(COALESCE(r.val ->> 'name', ''));
            IF v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','verbs','index',r.idx,'reason','missing name');
                CONTINUE;
            END IF;
            SELECT verb_id INTO v_id FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = p_owner_schema AND canonical_name = v_name COLLATE "default";
            IF v_id IS NULL THEN
                INSERT INTO maludb_core.malu$svpor_verb (owner_schema, canonical_name, verb_type, aliases, description)
                VALUES (p_owner_schema, v_name,
                        maludb_core._normalize_svpor_verb_type(NULLIF(btrim(r.val ->> 'type'), ''), v_name),
                        CASE WHEN jsonb_typeof(r.val -> 'aliases') = 'array'
                             THEN ARRAY(SELECT jsonb_array_elements_text(r.val -> 'aliases')) ELSE ARRAY[]::text[] END,
                        r.val ->> 'description')
                RETURNING verb_id INTO v_id;
                c_verb_c := c_verb_c + 1;
            ELSE
                c_verb_r := c_verb_r + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','verbs','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- edges (verb-typed SVO statements) --------------------------------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'edges', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            -- subject endpoint
            v_ref := COALESCE(r.val ->> 'subject', '$source');
            IF v_ref = '$source' THEN
                v_sk := v_src_kind; v_si := v_src_id;
            ELSIF v_ids ? v_ref THEN
                v_sk := v_kinds ->> v_ref; v_si := (v_ids ->> v_ref)::bigint;
            ELSE
                v_sk := NULL; v_si := NULL;
            END IF;

            -- object endpoint (default $source)
            v_ref := COALESCE(r.val ->> 'object', '$source');
            IF v_ref = '$source' THEN
                v_ok := v_src_kind; v_oi := v_src_id;
            ELSIF v_ids ? v_ref THEN
                v_ok := v_kinds ->> v_ref; v_oi := (v_ids ->> v_ref)::bigint;
            ELSE
                v_ok := NULL; v_oi := NULL;
            END IF;

            IF v_si IS NULL OR v_oi IS NULL THEN
                v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,
                    'reason','unresolved endpoint (unknown key or no source anchor)');
                CONTINUE;
            END IF;

            v_name := btrim(COALESCE(r.val ->> 'verb', ''));
            IF v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,'reason','missing verb');
                CONTINUE;
            END IF;
            SELECT verb_id INTO v_vid FROM maludb_core.malu$svpor_verb
             WHERE owner_schema = p_owner_schema AND (canonical_name = v_name COLLATE "default" OR v_name = ANY(aliases))
             ORDER BY (canonical_name = v_name COLLATE "default") DESC LIMIT 1;
            IF v_vid IS NULL THEN
                INSERT INTO maludb_core.malu$svpor_verb (owner_schema, canonical_name)
                VALUES (p_owner_schema, v_name) RETURNING verb_id INTO v_vid;
                c_verb_c := c_verb_c + 1;
            END IF;

            v_span := NULLIF(btrim(COALESCE(r.val ->> 'source_span', '')), '');

            INSERT INTO maludb_core.malu$svpor_statement
                (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id,
                 valid_from, valid_to, confidence, provenance, metadata_jsonb)
            VALUES
                (p_owner_schema, v_sk, v_si, v_vid, v_ok, v_oi,
                 (r.val ->> 'valid_from')::timestamptz, (r.val ->> 'valid_to')::timestamptz,
                 (r.val ->> 'confidence')::numeric, v_prov,
                 jsonb_strip_nulls(jsonb_build_object('source_span', v_span))
                 || CASE WHEN v_span IS NOT NULL
                         THEN jsonb_build_object('source_spans',
                                  maludb_core._statement_spans_accrete(NULL, v_span, v_span_doc))
                         ELSE '{}'::jsonb END)
            ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id)
            DO UPDATE SET
                confidence     = COALESCE(EXCLUDED.confidence, malu$svpor_statement.confidence),
                provenance     = EXCLUDED.provenance,
                valid_from     = COALESCE(EXCLUDED.valid_from, malu$svpor_statement.valid_from),
                valid_to       = COALESCE(EXCLUDED.valid_to,   malu$svpor_statement.valid_to),
                metadata_jsonb = (malu$svpor_statement.metadata_jsonb || EXCLUDED.metadata_jsonb)
                    || CASE WHEN v_span IS NOT NULL
                            THEN jsonb_build_object('source_spans',
                                     maludb_core._statement_spans_accrete(
                                         malu$svpor_statement.metadata_jsonb -> 'source_spans',
                                         v_span, v_span_doc))
                            ELSE '{}'::jsonb END
            RETURNING statement_id INTO v_stmt;

            c_edges := c_edges + 1;
            c_eattr := c_eattr + maludb_core._memory_apply_attributes_for_schema(
                           p_owner_schema, 'svpor_statement', v_stmt, r.val -> 'attributes', v_prov);
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','edges','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    -- ---- relationships (subject<->subject directed/temporal layer) --------
    FOR r IN SELECT val, (ord - 1) AS idx
               FROM jsonb_array_elements(COALESCE(p_extraction -> 'relationships', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
    LOOP
        BEGIN
            v_ref  := r.val ->> 'from';
            v_okind:= r.val ->> 'to';
            v_name := btrim(COALESCE(r.val ->> 'relationship_type', ''));
            IF NOT (v_ids ? COALESCE(v_ref,'')) OR NOT (v_ids ? COALESCE(v_okind,'')) OR v_name = '' THEN
                v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason','unknown from/to key or missing relationship_type');
                CONTINUE;
            END IF;
            IF (v_kinds ->> v_ref) <> 'subject' OR (v_kinds ->> v_okind) <> 'subject' THEN
                v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason','relationship endpoints must be subjects');
                CONTINUE;
            END IF;
            v_si := (v_ids ->> v_ref)::bigint;
            v_oi := (v_ids ->> v_okind)::bigint;

            -- The directed subject-relationship edge stores relationship_type as
            -- free text in the live schema (no per-schema relationship_type FK);
            -- labels are NOT NULL, so resolve them from the subjects.
            INSERT INTO maludb_core.malu$svpor_subject_relationship_edge
                (owner_schema, from_subject_id, to_subject_id, from_subject_label, to_subject_label,
                 relationship_type, valid_from, valid_to)
            VALUES (p_owner_schema, v_si, v_oi,
                    (SELECT canonical_name FROM maludb_core.malu$svpor_subject WHERE owner_schema=p_owner_schema AND subject_id=v_si),
                    (SELECT canonical_name FROM maludb_core.malu$svpor_subject WHERE owner_schema=p_owner_schema AND subject_id=v_oi),
                    v_name, (r.val ->> 'valid_from')::timestamptz, (r.val ->> 'valid_to')::timestamptz);
            c_rels := c_rels + 1;
        EXCEPTION WHEN OTHERS THEN
            v_skipped := v_skipped || jsonb_build_object('section','relationships','index',r.idx,'reason',left(SQLERRM,300));
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'source',   jsonb_strip_nulls(jsonb_build_object('kind', v_src_kind, 'id', v_src_id)),
        'created',  jsonb_build_object('subjects', c_subj_c, 'verbs', c_verb_c, 'episodes', c_epi_c,
                                       'edges', c_edges, 'relationships', c_rels,
                                       'node_attributes', c_nattr, 'edge_attributes', c_eattr),
        'resolved', jsonb_build_object('subjects', c_subj_r, 'verbs', c_verb_r, 'episodes', c_epi_r),
        'ids',      v_ids,
        'skipped',  v_skipped);
END;
$function$;
REVOKE ALL ON FUNCTION maludb_core._memory_ingest_extraction_for_schema(name, jsonb, text, bigint, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._memory_ingest_extraction_for_schema(name, jsonb, text, bigint, text, text)
    TO maludb_memory_admin, maludb_memory_executor;
-- ---------------------------------------------------------------------
-- 7. Tenant facades. enable_memory_schema() must be re-run for every tenant
--    after the upgrade; until then a tenant keeps its 0.105.3 facades, which
--    go on working (their workers kept their signatures or gained a default).
-- ---------------------------------------------------------------------

CREATE FUNCTION maludb_core._enable_memory_schema_01060_facade(p_schema name)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- ---- scoped views: the same columns as before, then principal_ref and scope ----

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_source_package', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_source_package AS
        SELECT source_package_id, source_type, content_bytes, content_text, content_jsonb,
               content_hash, content_size, media_type, origin_jsonb, captured_at, ingested_at,
               retention_class, legal_hold, legal_hold_reason, retain_until, sensitivity,
               sealed_at, archived_at, tombstoned_at, created_at, updated_at,
               principal_ref, scope
          FROM maludb_core.malu$source_package
         WHERE owner_schema = %L
           AND (maludb_core.current_principal_ref() IS NULL
                OR (COALESCE(scope, 'default') = ANY ((SELECT maludb_core._principal_scopes_for_schema(%L::name, 'read'))::text[])
                    AND maludb_core._sensitivity_rank(sensitivity) <= (SELECT maludb_core._principal_ceiling_for_schema(%L::name))))
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema, p_schema, p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_source_package', 'view', 'Source packages the session may read, with their scope.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory AS
        SELECT memory_id, memory_kind, title, summary, payload_jsonb, occurred_at, occurred_until,
               recorded_at, sensitivity, lifecycle_state, consolidated_into_memory_id,
               created_at, updated_at, issue_closed_at,
               principal_ref, scope
          FROM maludb_core.malu$memory
         WHERE owner_schema = %L
           AND (maludb_core.current_principal_ref() IS NULL
                OR (COALESCE(scope, 'default') = ANY ((SELECT maludb_core._principal_scopes_for_schema(%L::name, 'read'))::text[])
                    AND maludb_core._sensitivity_rank(sensitivity) <= (SELECT maludb_core._principal_ceiling_for_schema(%L::name))))
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema, p_schema, p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory', 'view', 'Memories the session may read, with their scope.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_document WITH (security_invoker = true) AS
        SELECT d.document_id, d.source_package_id, d.title, d.source_type, d.media_type,
               d.primary_project_id, d.lifecycle_state, d.metadata_jsonb, d.created_at, d.updated_at,
               (SELECT sp.content_text
                  FROM maludb_core.malu$source_package sp
                 WHERE sp.owner_schema = d.owner_schema
                   AND sp.source_package_id = d.source_package_id
                   AND sp.source_type = d.source_type) AS body_text,
               d.document_type,
               d.principal_ref, d.scope
          FROM maludb_core.malu$document d
         WHERE d.owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document', 'view', 'Documents, with their scope.');
    v_count := v_count + 1;

    EXECUTE format('DROP VIEW IF EXISTS %I.maludb_document_with_attributes', p_schema);
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_document_with_attributes', 'view');
    EXECUTE format($sql$
        CREATE VIEW %I.maludb_document_with_attributes WITH (security_invoker = true) AS
        SELECT b.*, maludb_core.attributes_jsonb('document', b.document_id) AS attributes
          FROM %I.maludb_document b
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_document_with_attributes TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_document_with_attributes', 'view', 'Documents with attributes bundled.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_episode', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_episode WITH (security_invoker = true) AS
        SELECT e.episode_id, e.episode_kind, e.title, e.summary, e.payload_jsonb, e.occurred_at,
               e.occurred_until, e.recorded_at, e.sensitivity, e.lifecycle_state, e.provenance,
               e.created_at, e.subject_id,
               (SELECT s.canonical_name
                  FROM maludb_core.malu$svpor_subject s
                 WHERE s.owner_schema = e.owner_schema AND s.subject_id = e.subject_id) AS canonical_name,
               e.principal_ref, e.scope
          FROM maludb_core.malu$episode_object e
         WHERE e.owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_episode', 'view', 'Episodes, with their scope.');
    v_count := v_count + 1;

    EXECUTE format('DROP VIEW IF EXISTS %I.maludb_episode_with_attributes', p_schema);
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_episode_with_attributes', 'view');
    EXECUTE format($sql$
        CREATE VIEW %I.maludb_episode_with_attributes WITH (security_invoker = true) AS
        SELECT b.*, maludb_core.attributes_jsonb('subject', b.subject_id) AS attributes
          FROM %I.maludb_episode b
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_episode_with_attributes TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_episode_with_attributes', 'view', 'Episodes with their event subject''s attributes bundled.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_chat_session', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_chat_session WITH (security_invoker = true) AS
        SELECT chat_session_id, account_id, model_session_id, document_id, source_package_id,
               chat_title, lifecycle_state, primary_project_subject_id, projects, subjects, verbs,
               svpor_frames, started_at, last_message_at, closed_at, message_count, metadata_jsonb,
               principal_ref, scope
          FROM maludb_core.malu$chat_session
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_chat_session', 'view', 'Chat sessions, with their scope.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_pool', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_memory_pool WITH (security_invoker = true) AS
        SELECT pool_id, pool_name, creation_kind, created_by, task_objective, authorized_partitions,
               confidence_floor, validity_start, validity_end, max_member_count, lifecycle_state,
               sealed_at, archived_at, tombstoned_at, created_at, updated_at,
               principal_ref, scope
          FROM maludb_core.malu$active_memory_pool
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_pool', 'view', 'Active memory pools, with their scope.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_pool_presence', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_pool_presence WITH (security_invoker = true) AS
        SELECT p.pool_id, p.pool_name, pr.presence_id, pr.participant_kind, pr.participant_ref,
               pr.role, pr.declared_task, pr.cursor_jsonb, pr.last_seen_at, pr.left_at,
               pr.ttl_seconds
          FROM maludb_core.malu$active_memory_pool p
          JOIN maludb_core.malu$pool_presence pr
            ON pr.owner_schema = p.owner_schema AND pr.pool_id = p.pool_id
         WHERE p.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_pool_presence TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_pool_presence', 'view', 'Who is present in which pool, with cursor and TTL.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill WITH (security_invoker = true) AS
        SELECT skill_id, skill_name, version, description, packaging_kind, applicability_jsonb,
               precondition_jsonb, enabled, created_at, updated_at, visibility, source_owner_schema,
               source_skill_id, forked_at, owner_schema, markdown, bundle_hash, frontmatter_jsonb,
               review_state, proposed_by_principal, reviewed_by, reviewed_at, review_note
          FROM maludb_core.malu$skill_package
         WHERE owner_schema = %L
        WITH LOCAL CHECK OPTION
    $sql$, p_schema, p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill', 'view', 'Skills, with their review state.');
    v_count := v_count + 1;

    -- ---- principals ----

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_principal', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_principal WITH (security_invoker = true) AS
        SELECT principal_id, principal_ref, principal_kind, display_name, home_scope,
               max_sensitivity, enabled, created_at, updated_at
          FROM maludb_core.malu$principal
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_principal TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_principal', 'view', 'The principals this tenant has told the engine about.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_principal_scope', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_principal_scope WITH (security_invoker = true) AS
        SELECT g.principal_scope_id, p.principal_ref, g.scope, g.access_level,
               g.granted_by, g.granted_at, g.revoked_at
          FROM maludb_core.malu$principal_scope g
          JOIN maludb_core.malu$principal p
            ON p.owner_schema = g.owner_schema AND p.principal_id = g.principal_id
         WHERE g.owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_principal_scope TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_principal_scope', 'view', 'Scope grants, live and revoked.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_principal_upsert', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_principal_upsert(
            p_principal_ref   text,
            p_principal_kind  text    DEFAULT 'agent',
            p_display_name    text    DEFAULT NULL,
            p_home_scope      text    DEFAULT NULL,
            p_max_sensitivity text    DEFAULT NULL,
            p_enabled         boolean DEFAULT NULL
        ) RETURNS bigint
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._principal_upsert_for_schema(%L::name, p_principal_ref, p_principal_kind,
                       p_display_name, p_home_scope, p_max_sensitivity, p_enabled)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_principal_upsert(text, text, text, text, text, boolean) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_principal_upsert(text, text, text, text, text, boolean) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_principal_upsert', 'function', 'Register or update a principal (an agent or a person) the engine should know.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_principal_grant_scope', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_principal_grant_scope(
            p_principal_ref text, p_scope text, p_access_level text DEFAULT 'read'
        ) RETURNS bigint
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._principal_grant_scope_for_schema(%L::name, p_principal_ref, p_scope, p_access_level)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_principal_grant_scope(text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_principal_grant_scope(text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_principal_grant_scope', 'function', 'Let a principal read (or write) a scope.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_principal_revoke_scope', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_principal_revoke_scope(
            p_principal_ref text, p_scope text
        ) RETURNS boolean
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._principal_revoke_scope_for_schema(%L::name, p_principal_ref, p_scope)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_principal_revoke_scope(text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_principal_revoke_scope(text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_principal_revoke_scope', 'function', 'Take a scope away from a principal.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_principal_whoami', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_principal_whoami() RETURNS jsonb
        LANGUAGE sql STABLE SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._principal_whoami_for_schema(%L::name)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_principal_whoami() FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_principal_whoami() TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_principal_whoami', 'function', 'What this session is allowed: principal, scopes, ceiling.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_set_scope', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_set_scope(
            p_object_kind text, p_object_id bigint, p_scope text
        ) RETURNS boolean
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._set_scope_for_schema(%L::name, p_object_kind, p_object_id, p_scope)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_set_scope(text, bigint, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_set_scope(text, bigint, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_set_scope', 'function', 'Move a document, memory, episode, chat session or pool into a scope.');
    v_count := v_count + 1;

    -- ---- forgetting ----

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_forget_document', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_forget_document(
            p_document_id bigint
        ) RETURNS jsonb
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._forget_document_for_schema(%L::name, p_document_id)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_forget_document(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_forget_document(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_forget_document', 'function', 'Delete a document with its chunks, its edges and its source.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_forget_chunk', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_forget_chunk(
            p_chunk_id bigint
        ) RETURNS boolean
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._forget_chunk_for_schema(%L::name, p_chunk_id)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_forget_chunk(bigint) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_forget_chunk(bigint) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_forget_chunk', 'function', 'Delete one vector chunk.');
    v_count := v_count + 1;

    -- ---- one-call ingest, now with a namespace ----

    EXECUTE format('DROP FUNCTION IF EXISTS %I.maludb_memory_ingest_extraction(jsonb, text, bigint, text)', p_schema);
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_memory_ingest_extraction', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_memory_ingest_extraction(
            p_extraction  jsonb,
            p_source_kind text   DEFAULT 'document',
            p_source_id   bigint DEFAULT NULL,
            p_provenance  text   DEFAULT 'accepted',
            p_namespace   text   DEFAULT 'default'
        ) RETURNS jsonb
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._memory_ingest_extraction_for_schema(
                %L::name, p_extraction, p_source_kind, p_source_id, p_provenance, p_namespace)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_memory_ingest_extraction(jsonb, text, bigint, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_memory_ingest_extraction(jsonb, text, bigint, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_memory_ingest_extraction', 'function', 'One-call ingest of an extraction, into a namespace.');
    v_count := v_count + 1;

    -- ---- skills ----

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_principal_access', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_principal_access WITH (security_invoker = true) AS
        SELECT access_id, skill_id, principal_ref, access_level, created_at
          FROM maludb_core.malu$skill_principal_access
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_principal_access TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_principal_access', 'view', 'Which principals a skill is reserved for.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_load_event', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_skill_load_event WITH (security_invoker = true) AS
        SELECT load_event_id, skill_owner_schema, skill_id, skill_name, version, bundle_hash,
               principal_ref, run_ref, loaded_at, metadata_jsonb
          FROM maludb_core.malu$skill_load_event
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_skill_load_event TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_load_event', 'view', 'Every recorded skill load.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_review', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_review(
            p_skill_id bigint, p_decision text, p_reviewer text DEFAULT NULL, p_note text DEFAULT NULL
        ) RETURNS jsonb
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._skill_review_for_schema(%L::name, p_skill_id, p_decision, p_reviewer, p_note)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_review(bigint, text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_review(bigint, text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_review', 'function', 'Approve, reject or (re)propose a skill.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_grant_principal', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_grant_principal(
            p_skill_id bigint, p_principal_ref text, p_access_level text DEFAULT 'read'
        ) RETURNS bigint
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._skill_grant_principal_for_schema(%L::name, p_skill_id, p_principal_ref, p_access_level)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_grant_principal(bigint, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_grant_principal(bigint, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_grant_principal', 'function', 'Reserve a skill for a principal.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_revoke_principal', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_revoke_principal(
            p_skill_id bigint, p_principal_ref text
        ) RETURNS boolean
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._skill_revoke_principal_for_schema(%L::name, p_skill_id, p_principal_ref)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_revoke_principal(bigint, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_revoke_principal(bigint, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_revoke_principal', 'function', 'Remove a principal''s reservation on a skill.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_skill_record_load', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_skill_record_load(
            p_skill_id           bigint,
            p_run_ref            text  DEFAULT NULL,
            p_principal_ref      text  DEFAULT NULL,
            p_skill_owner_schema name  DEFAULT NULL,
            p_metadata           jsonb DEFAULT '{}'::jsonb
        ) RETURNS bigint
        LANGUAGE sql SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._skill_record_load_for_schema(%L::name, p_skill_id, p_run_ref,
                       p_principal_ref, p_skill_owner_schema, p_metadata)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_skill_record_load(bigint, text, text, name, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_record_load(bigint, text, text, name, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_skill_record_load', 'function', 'Record that a skill was loaded, by whom and for which run.');
    v_count := v_count + 1;

    -- ---- presence: join / heartbeat / cursor, leave, roster ----
    -- SECURITY INVOKER with the tenant first on the search_path, like the chat
    -- facades: the core functions resolve tenancy through current_schema() and
    -- row security decides which pools this session can see at all.

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_presence_update', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_presence_update(
            p_pool_name        text,
            p_participant_kind text    DEFAULT NULL,
            p_participant_ref  text    DEFAULT NULL,
            p_role             text    DEFAULT NULL,
            p_declared_task    text    DEFAULT NULL,
            p_cursor_jsonb     jsonb   DEFAULT NULL,
            p_ttl_seconds      integer DEFAULT NULL
        ) RETURNS bigint
        LANGUAGE plpgsql
        SET search_path = %I, maludb_core, pg_temp
        AS $fn$
        DECLARE
            v_pool bigint;
            v_me   text := maludb_core.current_principal_ref();
            v_kind text;
        BEGIN
            SELECT p.pool_id INTO v_pool
              FROM maludb_core.malu$active_memory_pool p
             WHERE p.owner_schema = current_schema() AND p.pool_name = p_pool_name COLLATE "default";
            IF v_pool IS NULL THEN
                RAISE EXCEPTION 'presence_update: no pool named %% is open to this session', p_pool_name
                    USING ERRCODE = 'no_data_found';
            END IF;
            IF v_me IS NOT NULL THEN
                -- a principal is present as itself, never as somebody else
                SELECT CASE pr.principal_kind WHEN 'human' THEN 'human' WHEN 'agent' THEN 'agent' ELSE 'tool' END
                  INTO v_kind
                  FROM maludb_core.malu$principal pr
                 WHERE pr.owner_schema = current_schema() AND pr.principal_ref = v_me COLLATE "default";
                RETURN maludb_core.presence_update(v_pool, COALESCE(v_kind, 'agent'), v_me,
                           p_role, p_declared_task, p_cursor_jsonb, p_ttl_seconds);
            END IF;
            IF p_participant_ref IS NULL THEN
                RAISE EXCEPTION 'presence_update: participant_ref is required'
                    USING ERRCODE = 'invalid_parameter_value';
            END IF;
            RETURN maludb_core.presence_update(v_pool, COALESCE(p_participant_kind, 'agent'), p_participant_ref,
                       p_role, p_declared_task, p_cursor_jsonb, p_ttl_seconds);
        END;
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_presence_update(text, text, text, text, text, jsonb, integer) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_presence_update(text, text, text, text, text, jsonb, integer) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_presence_update', 'function', 'Join a pool, or say you are still there and where you have got to.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_presence_leave', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_presence_leave(
            p_pool_name        text,
            p_participant_kind text DEFAULT NULL,
            p_participant_ref  text DEFAULT NULL,
            p_reason           text DEFAULT NULL
        ) RETURNS boolean
        LANGUAGE plpgsql
        SET search_path = %I, maludb_core, pg_temp
        AS $fn$
        DECLARE
            v_pool bigint;
            v_me   text := maludb_core.current_principal_ref();
            v_kind text;
        BEGIN
            SELECT p.pool_id INTO v_pool
              FROM maludb_core.malu$active_memory_pool p
             WHERE p.owner_schema = current_schema() AND p.pool_name = p_pool_name COLLATE "default";
            IF v_pool IS NULL THEN
                RETURN false;
            END IF;
            IF v_me IS NOT NULL THEN
                SELECT CASE pr.principal_kind WHEN 'human' THEN 'human' WHEN 'agent' THEN 'agent' ELSE 'tool' END
                  INTO v_kind
                  FROM maludb_core.malu$principal pr
                 WHERE pr.owner_schema = current_schema() AND pr.principal_ref = v_me COLLATE "default";
                RETURN maludb_core.presence_leave(v_pool, COALESCE(v_kind, 'agent'), v_me, p_reason);
            END IF;
            RETURN maludb_core.presence_leave(v_pool, COALESCE(p_participant_kind, 'agent'), p_participant_ref, p_reason);
        END;
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_presence_leave(text, text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_presence_leave(text, text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_presence_leave', 'function', 'Leave a pool.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_presence_list', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_presence_list(
            p_pool_name text, p_include_left boolean DEFAULT false
        ) RETURNS TABLE(presence_id bigint, participant_kind text, participant_ref text, role text,
                        declared_task text, cursor_jsonb jsonb, ttl_seconds integer,
                        last_seen_at timestamptz, left_at timestamptz)
        LANGUAGE sql STABLE
        SET search_path = %I, maludb_core, pg_temp
        AS $fn$
            SELECT r.*
              FROM maludb_core.malu$active_memory_pool p
             CROSS JOIN LATERAL maludb_core.presence_roster(p.pool_id, p_include_left) r
             WHERE p.owner_schema = current_schema() AND p.pool_name = p_pool_name COLLATE "default"
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_presence_list(text, boolean) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_presence_list(text, boolean) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_presence_list', 'function', 'Who is in a pool, what each is doing, and where each has got to.');
    v_count := v_count + 1;

    IF p_schema = 'maludb_public' THEN
        -- the public catalogue is the curator's, as maludb_skill_register already is
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.maludb_skill_review(bigint, text, text, text) FROM maludb_memory_executor', p_schema);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_review(bigint, text, text, text) TO maludb_skill_curator', p_schema);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.maludb_skill_grant_principal(bigint, text, text) FROM maludb_memory_executor', p_schema);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_grant_principal(bigint, text, text) TO maludb_skill_curator', p_schema);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.maludb_skill_revoke_principal(bigint, text) FROM maludb_memory_executor', p_schema);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_skill_revoke_principal(bigint, text) TO maludb_skill_curator', p_schema);
    END IF;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_01060_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_01060_facade(name)
    TO maludb_memory_admin, maludb_memory_executor, maludb_user, maludb_admin;

CREATE OR REPLACE FUNCTION maludb_core.enable_memory_schema(p_schema name DEFAULT current_schema())
RETURNS TABLE(schema_name name, enabled_version text, object_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_enabled_version text := maludb_core.maludb_core_version();
    v_count integer := 0;
    v_view  name;
BEGIN
    IF p_schema IS NULL THEN
        p_schema := current_schema();
    END IF;

    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document','maludb_svpor_attribute','maludb_episode','maludb_episode_with_attributes','maludb_subject_type',
                                 -- 0.106.0 appends columns to these; an older builder cannot REPLACE the longer view
                                 'maludb_source_package','maludb_chat_session','maludb_memory_pool','maludb_pool_presence']::name[]
    LOOP
        IF EXISTS (
            SELECT 1 FROM maludb_core.malu$enabled_schema_object o
             WHERE o.schema_name = p_schema
               AND o.object_name = v_view
               AND o.object_kind = 'view'
        ) THEN
            EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE', p_schema, v_view);
        END IF;
    END LOOP;

    INSERT INTO maludb_core.malu$enabled_schema(schema_name, enabled_version, enabled_by)
    VALUES (p_schema, v_enabled_version, session_user)
    ON CONFLICT ON CONSTRAINT malu$enabled_schema_pkey DO UPDATE
       SET enabled_version   = EXCLUDED.enabled_version,
           last_refreshed_at = now();

    v_count := v_count + maludb_core._enable_memory_schema_subject_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_core_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ingest_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_pool_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_ai_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_075_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_076_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_078_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_080_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0802_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0803_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0810_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0820_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0830_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0840_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0850_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0860_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0870_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0880_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0890_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0900_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0910_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0920_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0940_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0950_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0960_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0970_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0980_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_0990_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_01000_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_01010_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_01020_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_01030_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_01040_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_01060_facade(p_schema);
    PERFORM maludb_core._grant_memory_schema_reader_access(p_schema);

    schema_name := p_schema;
    enabled_version := v_enabled_version;
    object_count := v_count;
    RETURN NEXT;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.enable_memory_schema(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.enable_memory_schema(name)
    TO maludb_memory_admin, maludb_memory_executor, maludb_user, maludb_admin;
-- ---------------------------------------------------------------------
-- 8. Dump registration for the new tables, and their sequences.
-- ---------------------------------------------------------------------

SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$principal"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$principal_scope"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_principal_access"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_load_event"', '');

DO $reg$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT DISTINCT s.oid::regclass AS seq
          FROM pg_catalog.pg_extension e
          JOIN pg_catalog.pg_class t ON t.oid = ANY (e.extconfig)
          JOIN pg_catalog.pg_depend d ON d.refobjid = t.oid AND d.classid = 'pg_catalog.pg_class'::regclass
                                     AND d.deptype IN ('a', 'i')
          JOIN pg_catalog.pg_class s ON s.oid = d.objid AND s.relkind = 'S'
         WHERE e.extname = 'maludb_core'
           AND NOT (s.oid = ANY (COALESCE(e.extconfig, ARRAY[]::oid[])))
    LOOP
        PERFORM pg_catalog.pg_extension_config_dump(r.seq, '');
    END LOOP;
END
$reg$;

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.106.0'::text $body$;
