\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.101.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.100.0 -> 0.101.0  --  unified graph path finding
--
-- Graphify integration Phase 1 (docs/GRAPHIFY-INTEGRATION.md in the
-- cross-repo docs). Path finding has existed since the relationship-
-- edge era (graph_path over malu$relationship_edge) but was never
-- lifted onto the unified graph, so /v1 clients can walk and fetch
-- neighbors across every edge store yet cannot ask "how are A and B
-- connected?". This release adds:
--
--   1. uedge_path -- source -> target paths over malu$edge_unified,
--      built on uedge_walk exactly the way graph_path is built on
--      graph_walk: filter the walk frontier to the target endpoint and
--      order by depth, so the first row is a shortest path and every
--      row is a distinct simple path within the depth budget. Inherits
--      uedge_walk's cycle safety and rel filtering; direction defaults
--      to 'both' because knowledge-graph "how are these connected"
--      questions are undirected by default (unlike the legacy
--      graph_path whose 'out' default predates the unified view).
--   2. Tenant facade maludb_graph_path via a new _01010 builder,
--      following the 0860 graph facade idiom (SECURITY INVOKER, tenant
--      search_path pins current_schema() for the owner_schema filter).
--      Tenants pick it up by re-running enable_memory_schema().
--
-- No table changes. Depth is capped at 32 like graph_walk; the walk
-- fans out over ALL simple paths, so callers should keep p_max_depth
-- modest (default 6) on dense graphs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. uedge_path -- all simple paths source -> target, shortest first.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core.uedge_path(
    p_source_kind text, p_source_id bigint,
    p_target_kind text, p_target_id bigint,
    p_max_depth   integer DEFAULT 6,
    p_direction   text    DEFAULT 'both',
    p_rel_filter  text[]  DEFAULT NULL
) RETURNS TABLE(depth integer, path text[])
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
BEGIN
    IF p_direction NOT IN ('out','in','both') THEN
        RAISE EXCEPTION 'uedge_path: bad direction %', p_direction
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_max_depth < 1 OR p_max_depth > 32 THEN
        RAISE EXCEPTION 'uedge_path: max_depth must be in [1, 32]'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    RETURN QUERY
    SELECT w.depth, w.path
      FROM maludb_core.uedge_walk(p_source_kind, p_source_id,
                                  p_max_depth, p_direction, p_rel_filter) w
     WHERE w.object_kind = p_target_kind
       AND w.object_id   = p_target_id
     ORDER BY w.depth ASC, w.path;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.uedge_path(text, bigint, text, bigint, integer, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.uedge_path(text, bigint, text, bigint, integer, text, text[])
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 2. 01010 facade builder: maludb_graph_path (read-only).
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_01010_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_graph_path', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_graph_path(
            p_source_kind text, p_source_id bigint,
            p_target_kind text, p_target_id bigint,
            p_max_depth   integer DEFAULT 6,
            p_direction   text    DEFAULT 'both',
            p_rel_filter  text[]  DEFAULT NULL)
        RETURNS TABLE(depth integer, path text[])
        LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.uedge_path(p_source_kind, p_source_id, p_target_kind, p_target_id, p_max_depth, p_direction, p_rel_filter) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_graph_path(text, bigint, text, bigint, integer, text, text[]) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_graph_path(text, bigint, text, bigint, integer, text, text[]) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_graph_path', 'function', 'Source-to-target paths over the unified graph, shortest first.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_01010_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_01010_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 3. Wire the 01010 facade into enable_memory_schema. Functions only --
--    the drop-first view list is untouched.
-- ---------------------------------------------------------------------
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

    FOREACH v_view IN ARRAY ARRAY['maludb_subject','maludb_memory','maludb_skill','maludb_document','maludb_svpor_attribute','maludb_episode','maludb_episode_with_attributes','maludb_subject_type']::name[]
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
-- 4. Version stamp.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.101.0'::text $body$;
