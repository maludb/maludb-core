\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.103.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.103.0  --  in-core graph import
--
-- Graphify integration Phase 5 (docs/GRAPHIFY-INTEGRATION.md in the
-- cross-repo docs). Importing a knowledge graph is core functionality,
-- not an API-server feature: 0.102.0 shipped the storage (communities,
-- analytics, type registration) but the node-link -> subjects/SVO
-- transformation lived in the Python API server, so every other API
-- server would have had to re-implement it. This release moves the
-- whole import into one SQL call:
--
--   maludb_graph_import(p_namespace, p_graph jsonb, p_options jsonb)
--
--   1. Validates the namespace and caps (50k nodes / 200k links).
--   2. Registers each distinct node type (file_type/type) into the
--      global subject-type catalog via register_subject_type_if_absent
--      (sanitized slug); unrepresentable types fall back to 'concept'
--      with the declared type kept in a graphify_type attribute.
--   3. Transforms nodes -> subjects (canonical "<namespace>/<node id>",
--      label as alias, graphify_* attributes) and links -> SVO edges
--      (relation as verb; EXTRACTED/INFERRED/AMBIGUOUS confidence maps
--      to 1.0/0.7/0.4, numeric passes through clamped) and materializes
--      everything with ONE _memory_ingest_extraction_for_schema call --
--      no client-side chunking, the whole graph is a single payload
--      with per-item subtransaction error isolation.
--   4. Stores node community tags first-class via
--      _community_replace_for_schema (replace semantics per namespace).
--
-- API servers become thin wrappers (validate HTTP input, call the
-- facade, return the report) -- the LAMP and Fastify ports get import
-- for free.
-- =====================================================================

CREATE FUNCTION maludb_core._graph_import_for_schema(
    p_schema    name,
    p_namespace text,
    p_graph     jsonb,
    p_options   jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_ns          text := btrim(COALESCE(p_namespace, ''));
    v_nodes       jsonb := COALESCE(p_graph -> 'nodes', '[]'::jsonb);
    v_links       jsonb := COALESCE(p_graph -> 'links', p_graph -> 'edges', '[]'::jsonb);
    v_provenance  text := left(COALESCE(NULLIF(btrim(COALESCE(p_options ->> 'provenance', '')), ''), 'graphify'), 200);
    v_algorithm   text := COALESCE(NULLIF(btrim(COALESCE(p_options ->> 'algorithm', '')), ''), 'louvain');
    v_typemap     jsonb := '{}'::jsonb;
    v_declared    text;
    v_slug        text;
    v_subjects    jsonb;
    v_edges       jsonb;
    v_communities jsonb;
    v_report      jsonb;
    v_comm_report jsonb := NULL;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    IF v_ns !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' THEN
        RAISE EXCEPTION 'graph_import: namespace must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ (got %)', p_namespace
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF jsonb_typeof(v_nodes) <> 'array' OR jsonb_array_length(v_nodes) = 0 THEN
        RAISE EXCEPTION 'graph_import: graph.nodes must be a non-empty array'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF jsonb_typeof(v_links) <> 'array' THEN
        RAISE EXCEPTION 'graph_import: graph.links must be an array'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF jsonb_array_length(v_nodes) > 50000 THEN
        RAISE EXCEPTION 'graph_import: graph.nodes exceeds the 50000 node cap'
            USING ERRCODE = 'program_limit_exceeded';
    END IF;
    IF jsonb_array_length(v_links) > 200000 THEN
        RAISE EXCEPTION 'graph_import: graph.links exceeds the 200000 link cap'
            USING ERRCODE = 'program_limit_exceeded';
    END IF;

    -- ---- 1. resolve node types (register or fall back to 'concept') ----
    PERFORM maludb_core.register_subject_type_if_absent('graph_namespace');
    FOR v_declared IN
        SELECT DISTINCT COALESCE(NULLIF(btrim(n ->> 'file_type'), ''), NULLIF(btrim(n ->> 'type'), ''), 'concept')
          FROM jsonb_array_elements(v_nodes) n
    LOOP
        v_slug := regexp_replace(lower(left(v_declared, 60)), '[^a-z0-9_]', '_', 'g');
        IF v_slug ~ '^[a-z][a-z0-9_]{0,59}$' THEN
            PERFORM maludb_core.register_subject_type_if_absent(v_slug);
            v_typemap := v_typemap || jsonb_build_object(v_declared, v_slug);
        ELSE
            v_typemap := v_typemap || jsonb_build_object(v_declared, 'concept');
        END IF;
    END LOOP;

    -- ---- 2. nodes -> subjects ------------------------------------------
    SELECT jsonb_agg(subj) INTO v_subjects
      FROM (
        SELECT jsonb_strip_nulls(jsonb_build_object(
                   'key',  left(btrim(n ->> 'id'), 512),
                   'name', v_ns || '/' || left(btrim(n ->> 'id'), 512),
                   'type', v_typemap ->> COALESCE(NULLIF(btrim(n ->> 'file_type'), ''), NULLIF(btrim(n ->> 'type'), ''), 'concept'),
                   'aliases', CASE
                       WHEN NULLIF(btrim(COALESCE(n ->> 'label', '')), '') IS NOT NULL
                        AND btrim(n ->> 'label') <> btrim(n ->> 'id')
                       THEN jsonb_build_array(left(btrim(n ->> 'label'), 256))
                   END,
                   'attributes', (
                       SELECT jsonb_agg(jsonb_build_object(
                                  'attr_name', 'graphify_' || attr,
                                  'value_text', left(btrim(n ->> attr), 2000)))
                         FROM unnest(ARRAY['label','source_file','source_location','community','file_type']) attr
                        WHERE NULLIF(btrim(COALESCE(n ->> attr, '')), '') IS NOT NULL
                   )
               )) AS subj
          FROM jsonb_array_elements(v_nodes) n
         WHERE NULLIF(btrim(COALESCE(n ->> 'id', '')), '') IS NOT NULL
      ) s;

    -- namespace root subject makes imported namespaces discoverable
    v_subjects := jsonb_build_array(jsonb_build_object(
                      'key', '$namespace', 'name', v_ns, 'type', 'graph_namespace',
                      'attributes', jsonb_build_array(jsonb_build_object(
                          'attr_name', 'provenance', 'value_text', v_provenance))))
                  || COALESCE(v_subjects, '[]'::jsonb);

    -- ---- 3. links -> SVO edges -----------------------------------------
    SELECT jsonb_agg(edge) INTO v_edges
      FROM (
        SELECT jsonb_strip_nulls(jsonb_build_object(
                   'subject', left(btrim(l ->> 'source'), 512),
                   'verb',    COALESCE(NULLIF(btrim(left(COALESCE(l ->> 'relation', ''), 120)), ''), 'related_to'),
                   'object',  left(btrim(l ->> 'target'), 512),
                   'confidence', CASE upper(btrim(COALESCE(l ->> 'confidence', '')))
                       WHEN 'EXTRACTED' THEN 1.0
                       WHEN 'INFERRED'  THEN 0.7
                       WHEN 'AMBIGUOUS' THEN 0.4
                       ELSE CASE WHEN jsonb_typeof(l -> 'confidence') = 'number'
                                 THEN LEAST(GREATEST((l ->> 'confidence')::numeric, 0), 1)
                            END
                   END
               )) AS edge
          FROM jsonb_array_elements(v_links) l
         WHERE NULLIF(btrim(COALESCE(l ->> 'source', '')), '') IS NOT NULL
           AND NULLIF(btrim(COALESCE(l ->> 'target', '')), '') IS NOT NULL
      ) e;

    -- ---- 4. one ingest call materializes everything ---------------------
    v_report := maludb_core._memory_ingest_extraction_for_schema(
                    p_owner_schema => p_schema,
                    p_extraction   => jsonb_build_object(
                        'subjects', v_subjects,
                        'edges',    COALESCE(v_edges, '[]'::jsonb)),
                    p_source_kind  => 'document',
                    p_source_id    => NULL,
                    p_provenance   => 'accepted');

    -- ---- 5. communities (replace semantics per namespace) ----------------
    SELECT jsonb_agg(jsonb_build_object('key', comm, 'members', members) ORDER BY comm) INTO v_communities
      FROM (
        SELECT (n ->> 'community')::integer AS comm,
               jsonb_agg(v_ns || '/' || left(btrim(n ->> 'id'), 512)) AS members
          FROM jsonb_array_elements(v_nodes) n
         WHERE NULLIF(btrim(COALESCE(n ->> 'id', '')), '') IS NOT NULL
           AND COALESCE(n ->> 'community', '') ~ '^-?[0-9]+$'
         GROUP BY 1
      ) c;
    IF v_communities IS NOT NULL THEN
        v_comm_report := maludb_core._community_replace_for_schema(
                             p_schema, v_ns, v_algorithm, v_communities);
    END IF;

    RETURN jsonb_build_object(
        'namespace',   v_ns,
        'nodes',       jsonb_build_object(
                           'received', jsonb_array_length(v_nodes),
                           'created',  v_report -> 'created' ->> 'subjects',
                           'resolved', v_report -> 'resolved' ->> 'subjects'),
        'edges',       jsonb_build_object(
                           'received', jsonb_array_length(v_links),
                           'created',  v_report -> 'created' ->> 'edges'),
        'verbs_created', v_report -> 'created' ->> 'verbs',
        'communities', v_comm_report,
        'skipped',     COALESCE(v_report -> 'skipped', '[]'::jsonb));
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._graph_import_for_schema(name, text, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._graph_import_for_schema(name, text, jsonb, jsonb)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 01030 facade builder: maludb_graph_import (write).
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_01030_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_graph_import', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_graph_import(
            p_namespace text,
            p_graph     jsonb,
            p_options   jsonb DEFAULT '{}'::jsonb
        ) RETURNS jsonb
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._graph_import_for_schema(
                %L::name, p_namespace, p_graph, p_options)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_graph_import(text, jsonb, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_graph_import(text, jsonb, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_graph_import', 'function', 'One-call import of a node-link knowledge graph (nodes->subjects, links->SVO edges, communities).');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_01030_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_01030_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;
-- Wire the 01030 facade into enable_memory_schema. Functions and
--    views only -- the drop-first view list is untouched.
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
    v_count := v_count + maludb_core._enable_memory_schema_01020_facade(p_schema);
    v_count := v_count + maludb_core._enable_memory_schema_01030_facade(p_schema);
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
-- Version stamp.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.103.0'::text $body$;
