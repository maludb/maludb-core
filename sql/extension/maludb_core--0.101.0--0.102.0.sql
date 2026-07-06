\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.102.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.101.0 -> 0.102.0  --  graph communities + analytics
--
-- Graphify integration Phase 3 (docs/GRAPHIFY-INTEGRATION.md in the
-- cross-repo docs). The 0.101.0 unified graph can be walked and
-- path-queried but has no notion of clusters or hubs, and graph
-- importers had no way to carry node types (the subject-type catalog
-- had no tenant-reachable registration). This release adds:
--
--   1. malu$community + malu$community_membership -- namespace-scoped
--      community sets over graph objects. Clustering runs CLIENT-side
--      for now (graphify ships Louvain); core stores the results.
--      Replace semantics per (owner_schema, namespace): re-importing a
--      graph atomically swaps its community set.
--   2. _community_replace_for_schema + tenant facade
--      maludb_community_replace(namespace, algorithm, communities
--      jsonb) -- members are subject canonical names, resolved
--      server-side; unknown names are reported, not fatal.
--   3. uedge_degree(limit) -- in/out/total degree over
--      malu$edge_unified, highest first (the "god nodes" query).
--   4. uedge_surprises(namespace, limit) -- cross-community edges
--      ranked by community-pair rarity: an edge between two
--      communities that are otherwise barely connected ranks first
--      (graphify's "surprising connections").
--   5. register_subject_type_if_absent -- tenant-callable, idempotent
--      registration into the GLOBAL subject-type catalog
--      (system_defined = false, sort_order 500, never overwrites).
--      Lets graph importers carry real node types instead of falling
--      back to 'concept'.
--   6. Tenant facades via a new _01020 builder: maludb_community /
--      maludb_community_membership views, maludb_community_replace,
--      maludb_graph_degree, maludb_graph_surprises,
--      maludb_register_subject_type. Tenants pick them up by
--      re-running enable_memory_schema().
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Community tables (RLS + grants idiom).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS maludb_core.malu$community (
    community_id  bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    namespace     text NOT NULL,
    community_key integer NOT NULL,
    label         text,
    algorithm     text NOT NULL DEFAULT 'louvain',
    computed_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_schema, namespace, community_key)
);

CREATE TABLE IF NOT EXISTS maludb_core.malu$community_membership (
    membership_id bigserial PRIMARY KEY,
    owner_schema  name NOT NULL DEFAULT current_schema(),
    community_id  bigint NOT NULL
        REFERENCES maludb_core.malu$community(community_id) ON DELETE CASCADE,
    object_kind   text NOT NULL DEFAULT 'subject',
    object_id     bigint NOT NULL,
    score         numeric,
    UNIQUE (owner_schema, community_id, object_kind, object_id)
);
CREATE INDEX IF NOT EXISTS malu$community_membership_object_idx
    ON maludb_core.malu$community_membership(owner_schema, object_kind, object_id);

ALTER TABLE maludb_core.malu$community ENABLE ROW LEVEL SECURITY;
ALTER TABLE maludb_core.malu$community_membership ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_owner ON maludb_core.malu$community
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());
CREATE POLICY tenant_owner ON maludb_core.malu$community_membership
    USING (owner_schema = current_schema())
    WITH CHECK (owner_schema = current_schema());

GRANT SELECT ON maludb_core.malu$community, maludb_core.malu$community_membership
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
GRANT INSERT, UPDATE, DELETE ON maludb_core.malu$community, maludb_core.malu$community_membership
    TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$community_community_id_seq
    TO maludb_memory_admin, maludb_memory_executor;
GRANT USAGE, SELECT ON SEQUENCE maludb_core.malu$community_membership_membership_id_seq
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 2. _community_replace_for_schema -- atomic namespace-scoped swap.
--    SECURITY DEFINER bypasses RLS, so every statement carries an
--    explicit owner_schema predicate.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._community_replace_for_schema(
    p_schema      name,
    p_namespace   text,
    p_algorithm   text DEFAULT 'louvain',
    p_communities jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    r         record;
    v_member  text;
    v_cid     bigint;
    v_sid     bigint;
    c_comm    integer := 0;
    c_memb    integer := 0;
    v_unknown jsonb   := '[]'::jsonb;
    v_ns      text    := btrim(COALESCE(p_namespace, ''));
    v_algo    text    := COALESCE(NULLIF(btrim(COALESCE(p_algorithm, '')), ''), 'louvain');
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);
    IF v_ns = '' THEN
        RAISE EXCEPTION 'community_replace: namespace is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Replace semantics: memberships go with their communities (FK CASCADE).
    DELETE FROM maludb_core.malu$community
     WHERE owner_schema = p_schema AND namespace = v_ns;

    FOR r IN
        SELECT val, (ord - 1) AS idx
          FROM jsonb_array_elements(COALESCE(p_communities, '[]'::jsonb))
               WITH ORDINALITY AS t(val, ord)
    LOOP
        INSERT INTO maludb_core.malu$community(owner_schema, namespace, community_key, label, algorithm)
        VALUES (p_schema, v_ns,
                COALESCE((r.val ->> 'key')::integer, r.idx::integer),
                NULLIF(btrim(COALESCE(r.val ->> 'label', '')), ''),
                v_algo)
        RETURNING community_id INTO v_cid;
        c_comm := c_comm + 1;

        FOR v_member IN
            SELECT jsonb_array_elements_text(COALESCE(r.val -> 'members', '[]'::jsonb))
        LOOP
            SELECT subject_id INTO v_sid
              FROM maludb_core.malu$svpor_subject
             WHERE owner_schema = p_schema AND canonical_name = v_member;
            IF v_sid IS NULL THEN
                IF jsonb_array_length(v_unknown) < 50 THEN
                    v_unknown := v_unknown || to_jsonb(v_member);
                END IF;
                CONTINUE;
            END IF;
            INSERT INTO maludb_core.malu$community_membership(owner_schema, community_id, object_kind, object_id)
            VALUES (p_schema, v_cid, 'subject', v_sid)
            ON CONFLICT DO NOTHING;
            IF FOUND THEN
                c_memb := c_memb + 1;
            END IF;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'namespace',       v_ns,
        'algorithm',       v_algo,
        'communities',     c_comm,
        'members',         c_memb,
        'unknown_members', v_unknown);
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._community_replace_for_schema(name, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._community_replace_for_schema(name, text, text, jsonb)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 3. uedge_degree -- highest-degree nodes over the unified graph.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core.uedge_degree(p_limit integer DEFAULT 100)
RETURNS TABLE(object_kind text, object_id bigint, label text,
              degree_out bigint, degree_in bigint, degree_total bigint)
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000);
BEGIN
    RETURN QUERY
    WITH endpoints AS (
        SELECT e.source_kind AS kind, e.source_id AS id, 1 AS n_out, 0 AS n_in
          FROM maludb_core.malu$edge_unified e
         WHERE e.owner_schema = current_schema()
        UNION ALL
        SELECT e.target_kind, e.target_id, 0, 1
          FROM maludb_core.malu$edge_unified e
         WHERE e.owner_schema = current_schema()
    )
    SELECT ep.kind, ep.id,
           maludb_core._svpor_endpoint_label(ep.kind, ep.id),
           sum(ep.n_out)::bigint, sum(ep.n_in)::bigint, count(*)::bigint
      FROM endpoints ep
     GROUP BY ep.kind, ep.id
     ORDER BY count(*) DESC, ep.kind, ep.id
     LIMIT v_limit;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.uedge_degree(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.uedge_degree(integer)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 4. uedge_surprises -- cross-community edges, rarest community pair
--    first. An edge between two communities that share few other edges
--    is a "surprising connection" worth a reviewer's attention.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core.uedge_surprises(
    p_namespace text,
    p_limit     integer DEFAULT 25
) RETURNS TABLE(source_kind text, source_id bigint, source_label text, source_community integer,
                rel text,
                target_kind text, target_id bigint, target_label text, target_community integer,
                community_pair_edges bigint)
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $body$
DECLARE
    v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 200);
BEGIN
    RETURN QUERY
    WITH memb AS (
        SELECT cm.object_kind AS kind, cm.object_id AS id, c.community_key
          FROM maludb_core.malu$community_membership cm
          JOIN maludb_core.malu$community c
            ON c.community_id = cm.community_id
           AND c.owner_schema = cm.owner_schema
         WHERE cm.owner_schema = current_schema()
           AND c.namespace = p_namespace
    ),
    cross_edges AS (
        SELECT e.source_kind AS s_kind, e.source_id AS s_id, e.rel AS e_rel,
               e.target_kind AS t_kind, e.target_id AS t_id,
               ms.community_key AS s_comm, mt.community_key AS t_comm
          FROM maludb_core.malu$edge_unified e
          JOIN memb ms ON ms.kind = e.source_kind AND ms.id = e.source_id
          JOIN memb mt ON mt.kind = e.target_kind AND mt.id = e.target_id
         WHERE e.owner_schema = current_schema()
           AND ms.community_key <> mt.community_key
    ),
    pair_counts AS (
        SELECT LEAST(ce.s_comm, ce.t_comm) AS comm_a,
               GREATEST(ce.s_comm, ce.t_comm) AS comm_b,
               count(*) AS pair_edges
          FROM cross_edges ce
         GROUP BY 1, 2
    )
    SELECT ce.s_kind, ce.s_id,
           maludb_core._svpor_endpoint_label(ce.s_kind, ce.s_id), ce.s_comm,
           ce.e_rel,
           ce.t_kind, ce.t_id,
           maludb_core._svpor_endpoint_label(ce.t_kind, ce.t_id), ce.t_comm,
           pc.pair_edges
      FROM cross_edges ce
      JOIN pair_counts pc
        ON pc.comm_a = LEAST(ce.s_comm, ce.t_comm)
       AND pc.comm_b = GREATEST(ce.s_comm, ce.t_comm)
     ORDER BY pc.pair_edges ASC, ce.s_id, ce.t_id
     LIMIT v_limit;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.uedge_surprises(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.uedge_surprises(text, integer)
    TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;

-- ---------------------------------------------------------------------
-- 5. register_subject_type_if_absent -- idempotent, tenant-callable
--    registration into the GLOBAL subject-type catalog. Never touches
--    existing rows (system or user); user rows get system_defined =
--    false and a fixed sort_order bucket.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core.register_subject_type_if_absent(
    p_type         text,
    p_display_name text DEFAULT NULL,
    p_description  text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_type text := btrim(COALESCE(p_type, ''));
BEGIN
    IF v_type !~ '^[a-z][a-z0-9_]{0,59}$' THEN
        RAISE EXCEPTION 'register_subject_type: type must match ^[a-z][a-z0-9_]{0,59}$ (got %)', p_type
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    INSERT INTO maludb_core.malu$svpor_subject_type(subject_type, display_name, description, sort_order, system_defined)
    VALUES (v_type,
            COALESCE(NULLIF(btrim(COALESCE(p_display_name, '')), ''), initcap(replace(v_type, '_', ' '))),
            p_description,
            500,
            false)
    ON CONFLICT (subject_type) DO NOTHING;
    RETURN FOUND;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core.register_subject_type_if_absent(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core.register_subject_type_if_absent(text, text, text)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 6. 01020 facade builder.
-- ---------------------------------------------------------------------
CREATE FUNCTION maludb_core._enable_memory_schema_01020_facade(p_schema name) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, maludb_core, pg_temp
AS $body$
DECLARE
    v_count integer := 0;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    -- community views (read-only) -----------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_community', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_community WITH (security_invoker = true) AS
        SELECT community_id, namespace, community_key, label, algorithm, computed_at
          FROM maludb_core.malu$community
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_community TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_community', 'view', 'Namespace-scoped graph communities.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_community_membership', 'view');
    EXECUTE format($sql$
        CREATE OR REPLACE VIEW %I.maludb_community_membership WITH (security_invoker = true) AS
        SELECT membership_id, community_id, object_kind, object_id, score
          FROM maludb_core.malu$community_membership
         WHERE owner_schema = %L
    $sql$, p_schema, p_schema);
    EXECUTE format('GRANT SELECT ON %I.maludb_community_membership TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_community_membership', 'view', 'Graph community memberships.');
    v_count := v_count + 1;

    -- community_replace (write) --------------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_community_replace', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_community_replace(
            p_namespace   text,
            p_algorithm   text DEFAULT 'louvain',
            p_communities jsonb DEFAULT '[]'::jsonb
        ) RETURNS jsonb
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core._community_replace_for_schema(
                %L::name, p_namespace, p_algorithm, p_communities)
        $fn$;
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_community_replace(text, text, jsonb) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_community_replace(text, text, jsonb) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_community_replace', 'function', 'Atomic namespace-scoped community set replace (members by canonical name).');
    v_count := v_count + 1;

    -- degree / surprises (read) ---------------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_graph_degree', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_graph_degree(p_limit integer DEFAULT 100)
        RETURNS TABLE(object_kind text, object_id bigint, label text,
                      degree_out bigint, degree_in bigint, degree_total bigint)
        LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.uedge_degree(p_limit) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_graph_degree(integer) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_graph_degree(integer) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_graph_degree', 'function', 'Highest-degree nodes over the unified graph.');
    v_count := v_count + 1;

    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_graph_surprises', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_graph_surprises(
            p_namespace text, p_limit integer DEFAULT 25)
        RETURNS TABLE(source_kind text, source_id bigint, source_label text, source_community integer,
                      rel text,
                      target_kind text, target_id bigint, target_label text, target_community integer,
                      community_pair_edges bigint)
        LANGUAGE sql STABLE SECURITY INVOKER
        SET search_path = %I, maludb_core, pg_temp
        AS $facade$ SELECT * FROM maludb_core.uedge_surprises(p_namespace, p_limit) $facade$
    $sql$, p_schema, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_graph_surprises(text, integer) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_graph_surprises(text, integer) TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_graph_surprises', 'function', 'Cross-community edges ranked by community-pair rarity.');
    v_count := v_count + 1;

    -- subject-type registration (write) -------------------------------
    PERFORM maludb_core._memory_schema_assert_object_slot(p_schema, 'maludb_register_subject_type', 'function');
    EXECUTE format($sql$
        CREATE OR REPLACE FUNCTION %I.maludb_register_subject_type(
            p_type         text,
            p_display_name text DEFAULT NULL,
            p_description  text DEFAULT NULL
        ) RETURNS boolean
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = pg_catalog, maludb_core, pg_temp
        AS $fn$
            SELECT maludb_core.register_subject_type_if_absent(p_type, p_display_name, p_description)
        $fn$;
    $sql$, p_schema);
    EXECUTE format('REVOKE ALL ON FUNCTION %I.maludb_register_subject_type(text, text, text) FROM PUBLIC', p_schema);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %I.maludb_register_subject_type(text, text, text) TO maludb_memory_admin, maludb_memory_executor', p_schema);
    PERFORM maludb_core._memory_schema_record_object(p_schema, 'maludb_register_subject_type', 'function', 'Idempotent registration into the global subject-type catalog.');
    v_count := v_count + 1;

    RETURN v_count;
END;
$body$;

REVOKE ALL ON FUNCTION maludb_core._enable_memory_schema_01020_facade(name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION maludb_core._enable_memory_schema_01020_facade(name)
    TO maludb_memory_admin, maludb_memory_executor;

-- ---------------------------------------------------------------------
-- 7. Wire the 01020 facade into enable_memory_schema. Functions and
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
-- 8. Version stamp.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.102.0'::text $body$;
