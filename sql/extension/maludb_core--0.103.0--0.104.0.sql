\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.104.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.104.0  --  relational data-model graph (DM-1)
--
-- Graphify Phase 6 (cross-repo docs/DATA-MODEL-GRAPH.md). Database
-- objects and their relationships become a graph namespace so coding
-- tools can ask "how do I join A to B" / "what breaks if I change X"
-- through the same graph surface as the code graphs. This release:
--
--   1. _datamodel_refresh_for_schema + facade maludb_datamodel_refresh
--      (namespace 'datamodel' by default): introspects pg_catalog --
--      tables/views/matviews (columns + pk as attributes), routines,
--      non-internal triggers, one node per schema -- and edges:
--      fk_references (EXTRACTED, from pg_constraint incl. composite),
--      depends_on (view -> relation via pg_rewrite/pg_depend),
--      triggers_on, belongs_to, and routine reads/writes (INFERRED,
--      coarse prosrc text scan). Builds node-link jsonb and feeds
--      _graph_import_for_schema, so namespaces/types/communities
--      (one per DB schema) come for free and refresh is replace-style.
--      Visibility guard: requested schemas must be the tenant's own
--      schema, 'maludb_core', or 'public' (docs/DATA-MODEL-GRAPH.md §6).
--   2. _datamodel_describe_for_schema + facade
--      maludb_datamodel_describe(relation): live-catalog description
--      (columns, pk, FKs out and in) for one relation.
--   3. _graph_import_for_schema (REPLACE) gains two options:
--      node-level "attributes" pass-through (arrays of
--      {attr_name,value_text} ride along verbatim), and
--      options.resolve_external -- link endpoints that match an
--      EXISTING subject canonical name resolve instead of being
--      skipped, which is what lets code-mining edges (DM-3) stitch
--      repo namespaces to the datamodel namespace.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Import upgrades: attribute pass-through + resolve_external.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core._graph_import_for_schema(
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
    v_resolve_ext boolean := COALESCE((p_options ->> 'resolve_external')::boolean, false);
    v_typemap     jsonb := '{}'::jsonb;
    v_declared    text;
    v_slug        text;
    v_subjects    jsonb;
    v_external    jsonb;
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

    -- ---- 2. nodes -> subjects (graphify_* + caller attributes) ----------
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
                   'attributes', NULLIF(
                       COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                                      'attr_name', 'graphify_' || attr,
                                      'value_text', left(btrim(n ->> attr), 2000)))
                             FROM unnest(ARRAY['label','source_file','source_location','community','file_type']) attr
                            WHERE NULLIF(btrim(COALESCE(n ->> attr, '')), '') IS NOT NULL
                       ), '[]'::jsonb)
                       || CASE WHEN jsonb_typeof(n -> 'attributes') = 'array'
                               THEN n -> 'attributes' ELSE '[]'::jsonb END,
                       '[]'::jsonb)
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

    -- ---- 2b. resolve_external: link endpoints naming an EXISTING subject
    -- (typically in another namespace) join the payload as resolve-only
    -- entries, so the ingest's same-payload key resolution finds them.
    IF v_resolve_ext THEN
        SELECT jsonb_agg(jsonb_build_object('key', s.canonical_name, 'name', s.canonical_name, 'type', 'concept'))
          INTO v_external
          FROM (
            SELECT DISTINCT endpoint
              FROM jsonb_array_elements(v_links) l,
                   LATERAL unnest(ARRAY[left(btrim(l ->> 'source'), 512), left(btrim(l ->> 'target'), 512)]) endpoint
             WHERE NULLIF(endpoint, '') IS NOT NULL
               AND NOT EXISTS (
                   SELECT 1 FROM jsonb_array_elements(v_nodes) n
                    WHERE left(btrim(n ->> 'id'), 512) = endpoint)
          ) ext
          JOIN maludb_core.malu$svpor_subject s
            ON s.owner_schema = p_schema AND s.canonical_name = ext.endpoint;
        v_subjects := v_subjects || COALESCE(v_external, '[]'::jsonb);
    END IF;

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

-- ---------------------------------------------------------------------
-- 2. _datamodel_refresh_for_schema -- pg_catalog -> node-link -> import.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._datamodel_refresh_for_schema(
    p_schema    name,
    p_namespace text DEFAULT 'datamodel',
    p_schemas   name[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_schemas name[] := COALESCE(p_schemas, ARRAY[p_schema]);
    v_s       name;
    v_nodes   jsonb := '[]'::jsonb;
    v_links   jsonb := '[]'::jsonb;
    v_part    jsonb;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    FOREACH v_s IN ARRAY v_schemas LOOP
        IF v_s <> p_schema AND v_s NOT IN ('maludb_core', 'public') THEN
            RAISE EXCEPTION 'datamodel_refresh: schema % is not visible to this tenant (own schema, maludb_core, or public only)', v_s
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END LOOP;

    -- schema nodes
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', s.s, 'label', s.s, 'type', 'db_schema_ns',
               'community', s.ord - 1)), '[]'::jsonb)
      INTO v_part FROM unnest(v_schemas) WITH ORDINALITY s(s, ord);
    v_nodes := v_nodes || v_part;

    -- relations (tables / views / matviews) with columns + pk attributes
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', n.nspname || '.' || c.relname,
               'label', c.relname,
               'type', CASE c.relkind WHEN 'r' THEN 'db_table' WHEN 'p' THEN 'db_table'
                                      WHEN 'v' THEN 'db_view' ELSE 'db_matview' END,
               'community', array_position(v_schemas, n.nspname) - 1,
               'attributes', jsonb_build_array(
                   jsonb_build_object('attr_name', 'columns', 'value_text', left((
                       SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
                                         || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END, ', '
                                         ORDER BY a.attnum)
                         FROM pg_attribute a
                        WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped), 2000)),
                   jsonb_build_object('attr_name', 'primary_key', 'value_text', COALESCE((
                       SELECT string_agg(a.attname, ', ' ORDER BY k.ord)
                         FROM pg_constraint pc,
                              LATERAL unnest(pc.conkey) WITH ORDINALITY k(attnum, ord)
                         JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
                        WHERE pc.conrelid = c.oid AND pc.contype = 'p'), '(none)')))
           )), '[]'::jsonb)
      INTO v_part
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY(v_schemas) AND c.relkind IN ('r', 'p', 'v', 'm');
    v_nodes := v_nodes || v_part;

    -- routines (distinct by name; overloads collapse)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', r.id, 'label', r.label, 'type', 'db_routine',
               'community', r.comm)), '[]'::jsonb)
      INTO v_part
      FROM (SELECT DISTINCT n.nspname || '.' || p.proname AS id, p.proname AS label,
                   array_position(v_schemas, n.nspname) - 1 AS comm
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = ANY(v_schemas)) r;
    v_nodes := v_nodes || v_part;

    -- triggers (non-internal)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', n.nspname || '.' || c.relname || '::' || t.tgname,
               'label', t.tgname, 'type', 'db_trigger',
               'community', array_position(v_schemas, n.nspname) - 1)), '[]'::jsonb)
      INTO v_part
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY(v_schemas) AND NOT t.tgisinternal;
    v_nodes := v_nodes || v_part;

    -- belongs_to: every non-schema node -> its schema node
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'source', nd ->> 'id', 'target', split_part(nd ->> 'id', '.', 1),
               'relation', 'belongs_to', 'confidence', 'EXTRACTED')), '[]'::jsonb)
      INTO v_part
      FROM jsonb_array_elements(v_nodes) nd
     WHERE nd ->> 'type' <> 'db_schema_ns';
    v_links := v_links || v_part;

    -- fk_references
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'source', ns.nspname || '.' || sc.relname,
               'target', nt.nspname || '.' || tc.relname,
               'relation', 'fk_references', 'confidence', 'EXTRACTED')), '[]'::jsonb)
      INTO v_part
      FROM pg_constraint pc
      JOIN pg_class sc ON sc.oid = pc.conrelid
      JOIN pg_namespace ns ON ns.oid = sc.relnamespace
      JOIN pg_class tc ON tc.oid = pc.confrelid
      JOIN pg_namespace nt ON nt.oid = tc.relnamespace
     WHERE pc.contype = 'f'
       AND ns.nspname = ANY(v_schemas) AND nt.nspname = ANY(v_schemas);
    v_links := v_links || v_part;

    -- depends_on: view/matview -> referenced relation
    SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
               'source', nv.nspname || '.' || v.relname,
               'target', nt.nspname || '.' || t.relname,
               'relation', 'depends_on', 'confidence', 'EXTRACTED')), '[]'::jsonb)
      INTO v_part
      FROM pg_depend d
      JOIN pg_rewrite rw ON rw.oid = d.objid
      JOIN pg_class v ON v.oid = rw.ev_class
      JOIN pg_namespace nv ON nv.oid = v.relnamespace
      JOIN pg_class t ON t.oid = d.refobjid
      JOIN pg_namespace nt ON nt.oid = t.relnamespace
     WHERE d.classid = 'pg_rewrite'::regclass AND d.refclassid = 'pg_class'::regclass
       AND v.oid <> t.oid AND t.relkind IN ('r', 'p', 'v', 'm')
       AND nv.nspname = ANY(v_schemas) AND nt.nspname = ANY(v_schemas);
    v_links := v_links || v_part;

    -- triggers_on
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'source', n.nspname || '.' || c.relname || '::' || t.tgname,
               'target', n.nspname || '.' || c.relname,
               'relation', 'triggers_on', 'confidence', 'EXTRACTED')), '[]'::jsonb)
      INTO v_part
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY(v_schemas) AND NOT t.tgisinternal;
    v_links := v_links || v_part;

    -- routine reads/writes: coarse prosrc scan (INFERRED)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'source', rw.rid, 'target', rw.tid,
               'relation', rw.rel, 'confidence', 'INFERRED')), '[]'::jsonb)
      INTO v_part
      FROM (
        SELECT DISTINCT np.nspname || '.' || p.proname AS rid,
               nc.nspname || '.' || c.relname AS tid,
               CASE WHEN strpos(lower(p.prosrc), 'insert into ' || lower(c.relname)) > 0
                      OR strpos(lower(p.prosrc), 'update ' || lower(c.relname)) > 0
                      OR strpos(lower(p.prosrc), 'delete from ' || lower(c.relname)) > 0
                    THEN 'writes' ELSE 'reads' END AS rel
          FROM pg_proc p
          JOIN pg_namespace np ON np.oid = p.pronamespace
          CROSS JOIN pg_class c
          JOIN pg_namespace nc ON nc.oid = c.relnamespace
         WHERE np.nspname = ANY(v_schemas) AND nc.nspname = ANY(v_schemas)
           AND c.relkind IN ('r', 'p', 'v', 'm')
           AND p.prosrc IS NOT NULL
           AND length(c.relname) >= 6
           AND strpos(lower(p.prosrc), lower(c.relname)) > 0
      ) rw;
    v_links := v_links || v_part;

    RETURN maludb_core._graph_import_for_schema(
        p_schema, p_namespace,
        jsonb_build_object('nodes', v_nodes, 'links', v_links),
        jsonb_build_object('provenance', 'datamodel-introspection', 'algorithm', 'schema'));
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._datamodel_refresh_for_schema(name, text, name[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._datamodel_refresh_for_schema(name, text, name[])
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 3. _datamodel_describe_for_schema -- live description of one relation.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._datamodel_describe_for_schema(
    p_schema   name,
    p_relation text
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_schema name := CASE WHEN strpos(p_relation, '.') > 0 THEN split_part(p_relation, '.', 1) ELSE p_schema END;
    v_rel    text := CASE WHEN strpos(p_relation, '.') > 0 THEN split_part(p_relation, '.', 2) ELSE p_relation END;
    v_oid    oid;
    v_kind   char;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    IF v_schema <> p_schema AND v_schema NOT IN ('maludb_core', 'public') THEN
        RAISE EXCEPTION 'datamodel_describe: schema % is not visible to this tenant', v_schema
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT c.oid, c.relkind INTO v_oid, v_kind
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = v_schema AND c.relname = v_rel AND c.relkind IN ('r', 'p', 'v', 'm');
    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'datamodel_describe: relation %.% not found', v_schema, v_rel
            USING ERRCODE = 'undefined_table';
    END IF;

    RETURN jsonb_build_object(
        'schema', v_schema,
        'name',   v_rel,
        'kind',   CASE v_kind WHEN 'r' THEN 'table' WHEN 'p' THEN 'table'
                              WHEN 'v' THEN 'view' ELSE 'matview' END,
        'columns', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'name', a.attname,
                       'type', format_type(a.atttypid, a.atttypmod),
                       'nullable', NOT a.attnotnull,
                       'pk', EXISTS (SELECT 1 FROM pg_constraint pc
                                      WHERE pc.conrelid = v_oid AND pc.contype = 'p'
                                        AND a.attnum = ANY(pc.conkey))
                   ) ORDER BY a.attnum), '[]'::jsonb)
              FROM pg_attribute a
             WHERE a.attrelid = v_oid AND a.attnum > 0 AND NOT a.attisdropped),
        'fks_out', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'constraint', pc.conname,
                       'columns', (SELECT string_agg(a.attname, ', ' ORDER BY k.ord)
                                     FROM unnest(pc.conkey) WITH ORDINALITY k(attnum, ord)
                                     JOIN pg_attribute a ON a.attrelid = pc.conrelid AND a.attnum = k.attnum),
                       'references', nt.nspname || '.' || tc.relname)), '[]'::jsonb)
              FROM pg_constraint pc
              JOIN pg_class tc ON tc.oid = pc.confrelid
              JOIN pg_namespace nt ON nt.oid = tc.relnamespace
             WHERE pc.conrelid = v_oid AND pc.contype = 'f'),
        'fks_in', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'constraint', pc.conname,
                       'from', ns.nspname || '.' || sc.relname)), '[]'::jsonb)
              FROM pg_constraint pc
              JOIN pg_class sc ON sc.oid = pc.conrelid
              JOIN pg_namespace ns ON ns.oid = sc.relnamespace
             WHERE pc.confrelid = v_oid AND pc.contype = 'f'));
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._datamodel_describe_for_schema(name, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._datamodel_describe_for_schema(name, text)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 4. 01040 facade builder: maludb_datamodel_refresh + _describe.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_01040_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_datamodel_refresh', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_datamodel_refresh(
            p_namespace text DEFAULT 'datamodel',
            p_schemas   name[] DEFAULT NULL
        ) RETURNS jsonb
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._datamodel_refresh_for_schema(%L::name, p_namespace, p_schemas)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_datamodel_refresh(text, name[]) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_datamodel_refresh(text, name[]) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_datamodel_refresh', 'function', 'Introspect the database into the data-model graph namespace.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_datamodel_describe', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_datamodel_describe(p_relation text) RETURNS jsonb
        LANGUAGE sql STABLE
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._datamodel_describe_for_schema(%L::name, p_relation)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_datamodel_describe(text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_datamodel_describe(text) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_datamodel_describe', 'function', 'Live columns/pk/FK description of one relation.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_01040_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_01040_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;
-- Wire the 01040 facade into enable_memory_schema. Functions and
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
    v_count := v_count + maludb_core._enable_memory_schema_01040_facade(p_schema);
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
    AS $body$ SELECT '0.104.0'::text $body$;
