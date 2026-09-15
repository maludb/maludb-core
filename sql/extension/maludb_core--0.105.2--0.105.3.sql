\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.105.3'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.105.3  --  compare text under the column's collation
--
-- PL/pgSQL runs a function under the collation of its call's arguments, and
-- gives that collation to every collatable parameter and local variable. A
-- `name` argument -- OLD.owner_schema in a trigger, current_schema(), a
-- 'mem_x'::name literal -- carries the implicit collation "C", which outranks a
-- text literal's default. So inside these functions `object_kind = p_kind`
-- compares under "C", while the indexed column uses the database collation.
-- The planner cannot use an index for a comparison under another collation:
-- the key column becomes a filter over every row that matches the index's
-- leading `owner_schema`, or a sequential scan.
--
-- The worst case is _embedding_dirty_purge, fired once per deleted
-- svpor_statement: each call read every dirty-queue row in the database, so
-- deleting a memory schema's 32,000 statements spent 51.7 s of 66 s there
-- (13.3 million blocks). With the comparison under the column's collation the
-- purge takes 0.4 s and the delete 18 s. _memory_search_for_schema had the
-- same shape on namespace, subject_name and verb_name.
--
-- Every function taking a `name` argument was audited from the catalogue for
-- a text parameter or variable compared to an indexed text column; the 17
-- found compare with COLLATE "default" below. For deterministic collations
-- equality is unchanged; only index use is. Bodies are otherwise identical to
-- 0.105.2. Regress: collation_index_use.
-- =====================================================================

-- maludb_core._community_replace_for_schema(name,text,text,jsonb): 2 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._community_replace_for_schema(p_schema name, p_namespace text, p_algorithm text DEFAULT 'louvain'::text, p_communities jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
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
     WHERE owner_schema = p_schema AND namespace = v_ns COLLATE "default";

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
             WHERE owner_schema = p_schema AND canonical_name = v_member COLLATE "default";
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
$function$;

-- maludb_core._document_graph_link(name,bigint,text,text,text): 4 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._document_graph_link(p_owner_schema name, p_document_id bigint, p_tag_kind text, p_tag_value text, p_provenance text DEFAULT 'provided'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_value        text := pg_catalog.btrim(COALESCE(p_tag_value, ''));
    v_subject_type text;
    v_verb         text;
    v_subject_id   bigint;
    v_verb_id      bigint;
    v_prov         text := COALESCE(NULLIF(pg_catalog.btrim(p_provenance), ''), 'provided');
BEGIN
    IF v_value = '' THEN
        RETURN NULL;
    END IF;

    CASE p_tag_kind
        WHEN 'project'     THEN v_subject_type := 'project'; v_verb := 'concerns';
        WHEN 'stakeholder' THEN v_subject_type := 'person';  v_verb := 'involves';
        WHEN 'subject'     THEN v_subject_type := 'concept'; v_verb := 'mentions';
        ELSE
            RETURN NULL;   -- only subject-like tag kinds become graph edges
    END CASE;

    -- resolve or create the subject (do not override an existing type)
    SELECT subject_id INTO v_subject_id
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_owner_schema AND canonical_name = v_value COLLATE "default";
    IF v_subject_id IS NULL THEN
        INSERT INTO maludb_core.malu$svpor_subject(owner_schema, canonical_name, subject_type)
        VALUES (p_owner_schema, v_value, v_subject_type)
        RETURNING subject_id INTO v_subject_id;
    END IF;

    -- resolve or create the verb
    SELECT verb_id INTO v_verb_id
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_owner_schema AND canonical_name = v_verb COLLATE "default";
    IF v_verb_id IS NULL THEN
        INSERT INTO maludb_core.malu$svpor_verb(owner_schema, canonical_name)
        VALUES (p_owner_schema, v_verb)
        RETURNING verb_id INTO v_verb_id;
    END IF;

    -- the edge: document --verb--> subject (idempotent on the SVO identity)
    INSERT INTO maludb_core.malu$svpor_statement
        (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id, provenance)
    VALUES
        (p_owner_schema, 'document', p_document_id, v_verb_id, 'subject', v_subject_id, v_prov)
    ON CONFLICT (owner_schema, subject_kind, subject_id, verb_id, object_kind, object_id) DO NOTHING;

    -- record the resolved object on the soft tag
    UPDATE maludb_core.malu$document_tag
       SET tag_object_type = 'subject', tag_object_id = v_subject_id
     WHERE owner_schema = p_owner_schema
       AND document_id = p_document_id
       AND tag_kind = p_tag_kind COLLATE "default"
       AND tag_value = v_value COLLATE "default"
       AND tag_object_id IS DISTINCT FROM v_subject_id;

    RETURN v_subject_id;
END;
$function$;

-- maludb_core._embedding_dirty_purge(name,text,bigint): 3 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._embedding_dirty_purge(p_owner_schema name, p_object_kind text, p_object_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
BEGIN
    DELETE FROM maludb_core.malu$embedding_dirty
     WHERE owner_schema = p_owner_schema
       AND object_kind = p_object_kind COLLATE "default" AND object_id = p_object_id;
    DELETE FROM maludb_core.malu$object_embedding
     WHERE owner_schema = p_owner_schema
       AND object_kind = p_object_kind COLLATE "default" AND object_id = p_object_id
       AND source_field = 'entity_card';
    DELETE FROM maludb_core.malu$semantic_edge
     WHERE owner_schema = p_owner_schema
       AND object_kind = p_object_kind COLLATE "default"
       AND (source_id = p_object_id OR target_id = p_object_id);
END;
$function$;

-- maludb_core._memory_harvest_extractions_for_schema(name,integer,text): 1 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._memory_harvest_extractions_for_schema(p_owner_schema name, p_limit integer DEFAULT 100, p_namespace text DEFAULT NULL::text)
 RETURNS TABLE(extraction_id bigint, request_id bigint, status text, edge_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    v_eid    bigint;
    v_req    bigint;
    v_payload jsonb;
    v_edges  jsonb;
    v_edge   jsonb;
    v_subj   text;
    v_vrb    text;
    v_pred   jsonb;
    v_emb    maludb_core.malu_vector;
    v_stmt   bigint;
    v_cnt    integer;
    v_ids    bigint[];
    v_status text;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    FOR r IN
        SELECT me.extraction_id AS eid,
               me.request_id    AS req,
               me.namespace     AS ns,
               me.source_kind   AS source_kind,
               me.source_id     AS source_id,
               resp.status      AS resp_status,
               resp.output_json AS out_json,
               resp.output_text AS out_text,
               COALESCE(cfg.embedding_model, 'unspecified')  AS cfg_embedding_model,
               COALESCE(cfg.default_subject_type, 'other')   AS cfg_subject_type,
               COALESCE(cfg.default_provenance, 'suggested') AS cfg_provenance,
               COALESCE(cfg.extraction_alias, 'unknown')     AS cfg_alias
          FROM maludb_core.malu$memory_extraction me
          JOIN maludb_core.malu$model_response resp ON resp.request_id = me.request_id
          LEFT JOIN maludb_core.malu$memory_extraction_config cfg
                 ON cfg.owner_schema = me.owner_schema AND cfg.namespace = me.namespace
         WHERE me.owner_schema = p_owner_schema
           AND me.status = 'pending'
           AND (p_namespace IS NULL OR me.namespace = p_namespace COLLATE "default")
         ORDER BY me.extraction_id
         LIMIT GREATEST(COALESCE(p_limit, 100), 1)
    LOOP
        v_eid := r.eid;
        v_req := r.req;
        BEGIN
            IF r.resp_status <> 'succeeded' THEN
                UPDATE maludb_core.malu$memory_extraction
                   SET status = 'failed', error = 'model response status: ' || r.resp_status,
                       harvested_at = now()
                 WHERE extraction_id = v_eid;
                extraction_id := v_eid; request_id := v_req; status := 'failed'; edge_count := 0;
                RETURN NEXT; CONTINUE;
            END IF;

            v_payload := COALESCE(r.out_json, NULLIF(btrim(COALESCE(r.out_text, '')), '')::jsonb);
            v_edges := CASE
                WHEN jsonb_typeof(v_payload) = 'array' THEN v_payload
                WHEN v_payload ? 'candidate_edges'     THEN v_payload -> 'candidate_edges'
                ELSE '[]'::jsonb
            END;

            v_cnt := 0;
            v_ids := ARRAY[]::bigint[];

            FOR v_edge IN SELECT * FROM jsonb_array_elements(COALESCE(v_edges, '[]'::jsonb))
            LOOP
                v_subj := COALESCE(v_edge ->> 'subject_text', v_edge ->> 'subject');
                v_vrb  := COALESCE(v_edge ->> 'verb_text',    v_edge ->> 'verb');
                IF COALESCE(btrim(v_subj), '') = '' OR COALESCE(btrim(v_vrb), '') = '' THEN
                    CONTINUE;
                END IF;

                -- predicate: accept the attributes_apply array form, or convert a
                -- flat {key:value} object to text attributes.
                v_pred := v_edge -> 'predicate';
                IF v_pred IS NULL OR jsonb_typeof(v_pred) = 'null' THEN
                    v_pred := '[]'::jsonb;
                ELSIF jsonb_typeof(v_pred) = 'object' THEN
                    SELECT COALESCE(jsonb_agg(jsonb_build_object('attr_name', k, 'value_text', val)), '[]'::jsonb)
                      INTO v_pred
                      FROM jsonb_each_text(v_edge -> 'predicate') AS e(k, val);
                ELSIF jsonb_typeof(v_pred) <> 'array' THEN
                    v_pred := '[]'::jsonb;
                END IF;

                -- per-edge embedding, if the daemon supplied one.
                v_emb := NULL;
                IF jsonb_typeof(v_edge -> 'embedding') = 'array' THEN
                    v_emb := (v_edge -> 'embedding')::text::maludb_core.malu_vector;
                END IF;

                v_stmt := maludb_core._memory_ingest_edge_for_schema(
                    p_owner_schema,
                    r.source_kind,
                    r.source_id,
                    v_subj,
                    v_vrb,
                    v_pred,
                    v_emb,
                    COALESCE(v_edge ->> 'embedding_model', r.cfg_embedding_model),
                    COALESCE(v_edge ->> 'subject_type',    r.cfg_subject_type),
                    v_edge ->> 'source_span',
                    (v_edge ->> 'confidence')::numeric,
                    r.cfg_provenance,
                    r.cfg_alias,                                  -- extraction_model label
                    r.ns,
                    CASE WHEN lower(r.source_kind) = 'document' THEN r.source_id ELSE NULL END,
                    NULL, NULL, 'cosine');

                v_cnt := v_cnt + 1;
                v_ids := v_ids || v_stmt;
            END LOOP;

            v_status := CASE WHEN v_cnt > 0 THEN 'harvested' ELSE 'empty' END;
            UPDATE maludb_core.malu$memory_extraction
               SET status = v_status, edge_count = v_cnt, statement_ids = v_ids,
                   error = NULL, harvested_at = now()
             WHERE extraction_id = v_eid;

            extraction_id := v_eid; request_id := v_req; status := v_status; edge_count := v_cnt;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            UPDATE maludb_core.malu$memory_extraction
               SET status = 'failed', error = left(SQLERRM, 500), harvested_at = now()
             WHERE extraction_id = v_eid;
            extraction_id := v_eid; request_id := v_req; status := 'failed'; edge_count := 0;
            RETURN NEXT;
        END;
    END LOOP;

    RETURN;
END;
$function$;

-- maludb_core._memory_ingest_edge_for_schema(name,text,bigint,text,text,jsonb,maludb_core.malu_vector,text,text,text,numeric,text,text,text,bigint,timestamp with time zone,timestamp with time zone,text): 4 comparison(s)
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

-- maludb_core._memory_ingest_extraction_for_schema(name,jsonb,text,bigint,text): 7 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._memory_ingest_extraction_for_schema(p_owner_schema name, p_extraction jsonb, p_source_kind text DEFAULT 'document'::text, p_source_id bigint DEFAULT NULL::bigint, p_provenance text DEFAULT 'accepted'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
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
                        (owner_schema, episode_kind, title, summary, occurred_at, occurred_until)
                    VALUES (p_owner_schema, COALESCE(v_type, 'event'), v_name,
                            r.val ->> 'description', v_occ, v_occu)
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

-- maludb_core._memory_model_config_for_schema(name,text): 1 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._memory_model_config_for_schema(p_owner_schema name, p_namespace text DEFAULT 'default'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_namespace text := COALESCE(NULLIF(p_namespace, ''), 'default');
    v_result    jsonb;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    SELECT jsonb_strip_nulls(jsonb_build_object(
               'namespace',            c.namespace,
               'extraction_alias',     c.extraction_alias,
               'model_identifier',     a.model_identifier,
               'provider_name',        p.provider_name,
               'provider_kind',        p.provider_kind,
               'adapter_name',         p.adapter_name,
               'secret_ref',           p.secret_ref,           -- pointer only, NOT the value
               'base_url',             a.runtime_params ->> 'base_url',
               'context_length',       a.context_length,
               'generation_params',    c.generation_params,
               'embedding_model',      c.embedding_model,
               'prompt_template',      c.prompt_template,
               'default_subject_type', c.default_subject_type,
               'default_provenance',   c.default_provenance,
               'alias_enabled',        a.enabled))
      INTO v_result
      FROM maludb_core.malu$memory_extraction_config c
      LEFT JOIN maludb_core.malu$model_alias    a ON a.owner_schema = c.owner_schema
                                                 AND a.alias_name   = c.extraction_alias
      LEFT JOIN maludb_core.malu$model_provider p ON p.provider_id  = a.provider_id
     WHERE c.owner_schema = p_owner_schema
       AND c.namespace    = v_namespace COLLATE "default";

    RETURN v_result;   -- NULL if nothing configured for this namespace
END;
$function$;

-- maludb_core._memory_request_extraction_for_schema(name,text,bigint,text,text): 2 comparison(s)
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

-- maludb_core._memory_schema_assert_object_slot(name,name,text): 1 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._memory_schema_assert_object_slot(p_schema name, p_object name, p_kind text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_exists boolean := false;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    IF p_kind = 'view' THEN
        SELECT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_class c
              JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = p_schema
               AND c.relname = p_object
               AND c.relkind = 'v'
        ) INTO v_exists;
    ELSIF p_kind = 'function' THEN
        SELECT EXISTS (
            SELECT 1
              FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = p_schema
               AND p.proname = p_object
        ) INTO v_exists;
    ELSE
        RAISE EXCEPTION 'enable_memory_schema: unsupported object kind % for %.%',
            p_kind, p_schema, p_object
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_exists
       AND NOT EXISTS (
            SELECT 1
              FROM maludb_core.malu$enabled_schema_object o
             WHERE o.schema_name = p_schema
               AND o.object_name = p_object
               AND o.object_kind = p_kind COLLATE "default"
       )
    THEN
        RAISE EXCEPTION 'enable_memory_schema: refusing to replace unmanaged % %.%',
            p_kind, p_schema, p_object
            USING ERRCODE = 'duplicate_object';
    END IF;
END;
$function$;

-- maludb_core._memory_search_for_schema(name,text,text,text,maludb_core.malu_vector,integer,text): 3 comparison(s)
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
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

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
     WHERE r.hit_rank_no <= v_limit
     ORDER BY r.hit_rank_no;
END;
$function$;

-- maludb_core._memory_set_model_config_for_schema(name,text,text,text,text,jsonb,text,text): 1 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._memory_set_model_config_for_schema(p_owner_schema name, p_extraction_alias text, p_prompt_template text DEFAULT NULL::text, p_embedding_model text DEFAULT NULL::text, p_namespace text DEFAULT 'default'::text, p_generation_params jsonb DEFAULT '{}'::jsonb, p_default_subject_type text DEFAULT 'other'::text, p_default_provenance text DEFAULT 'suggested'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_namespace text := COALESCE(NULLIF(p_namespace, ''), 'default');
    v_alias     text := btrim(COALESCE(p_extraction_alias, ''));
    v_prov      text := COALESCE(NULLIF(btrim(p_default_provenance), ''), 'suggested');
    v_subjtype  text := maludb_core._normalize_svpor_subject_type(
                            COALESCE(NULLIF(btrim(p_default_subject_type), ''), 'other'));
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    IF v_alias = '' THEN
        RAISE EXCEPTION 'memory_set_model_config: extraction_alias is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_prov NOT IN ('provided','suggested','accepted','rejected') THEN
        RAISE EXCEPTION 'memory_set_model_config: bad default_provenance %', v_prov
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    -- the model alias is per-tenant gateway config; it must already be registered
    -- in this schema (owner_schema-scoped: malu$model_alias UNIQUE(owner_schema, alias_name)).
    IF NOT EXISTS (SELECT 1 FROM maludb_core.malu$model_alias
                    WHERE owner_schema = p_owner_schema AND alias_name = v_alias COLLATE "default") THEN
        RAISE EXCEPTION 'memory_set_model_config: unknown model alias % in schema % (register it with maludb_core.register_model_alias first)', v_alias, p_owner_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    INSERT INTO maludb_core.malu$memory_extraction_config
        (owner_schema, namespace, extraction_alias, prompt_template, embedding_model,
         generation_params, default_subject_type, default_provenance)
    VALUES
        (p_owner_schema, v_namespace, v_alias,
         NULLIF(btrim(COALESCE(p_prompt_template, '')), ''),
         NULLIF(btrim(COALESCE(p_embedding_model, '')), ''),
         COALESCE(p_generation_params, '{}'::jsonb), v_subjtype, v_prov)
    ON CONFLICT (owner_schema, namespace) DO UPDATE SET
        extraction_alias     = EXCLUDED.extraction_alias,
        prompt_template      = EXCLUDED.prompt_template,
        embedding_model      = EXCLUDED.embedding_model,
        generation_params    = EXCLUDED.generation_params,
        default_subject_type = EXCLUDED.default_subject_type,
        default_provenance   = EXCLUDED.default_provenance,
        updated_at           = now();

    RETURN maludb_core._memory_model_config_for_schema(p_owner_schema, v_namespace);
END;
$function$;

-- maludb_core._note_search_for_schema(name,text[],text,text,text,boolean,integer,integer): 1 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._note_search_for_schema(p_schema name, p_subject_like text[] DEFAULT NULL::text[], p_verb_like text DEFAULT NULL::text, p_verb_exact text DEFAULT NULL::text, p_source_type text DEFAULT 'note'::text, p_all_sources boolean DEFAULT false, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
 RETURNS TABLE(document_id bigint, title text, source_type text, snippet text, created_at timestamp with time zone, match_count integer, matched_edges jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
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
     WHERE p_all_sources OR d.source_type = v_source_type COLLATE "default"
     GROUP BY d.document_id, d.title, d.source_type, sp.content_text, d.created_at
     ORDER BY d.created_at DESC, d.document_id DESC
     LIMIT v_limit OFFSET v_offset;
END;
$function$;

-- maludb_core._pool_remove_named_member_for_schema(name,text,text,text): 8 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._pool_remove_named_member_for_schema(p_schema name, p_pool_name text, p_member_kind text, p_member_name text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_pool_id     bigint;
    v_kind        text := pg_catalog.lower(pg_catalog.btrim(p_member_kind));
    v_name        text := pg_catalog.btrim(p_member_name);
    v_object_type text;
    v_object_id   bigint;
    v_count       integer;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT pool_id INTO v_pool_id
      FROM maludb_core.malu$active_memory_pool
     WHERE owner_schema = p_schema AND pool_name = p_pool_name COLLATE "default";
    IF v_pool_id IS NULL THEN
        RAISE EXCEPTION 'pool_remove_named_member: pool % not found in schema %', p_pool_name, p_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    IF v_kind = 'project' THEN
        SELECT subject_id INTO v_object_id FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = p_schema AND canonical_name = v_name COLLATE "default" AND subject_type = 'project'
         ORDER BY subject_id LIMIT 1;
        v_object_type := 'subject';
    ELSIF v_kind = 'subject' THEN
        SELECT subject_id INTO v_object_id FROM maludb_core.malu$svpor_subject
         WHERE owner_schema = p_schema AND canonical_name = v_name COLLATE "default"
         ORDER BY subject_id LIMIT 1;
        v_object_type := 'subject';
    ELSIF v_kind = 'verb' THEN
        SELECT verb_id INTO v_object_id FROM maludb_core.malu$svpor_verb
         WHERE owner_schema = p_schema AND canonical_name = v_name COLLATE "default"
         ORDER BY verb_id LIMIT 1;
        v_object_type := 'verb';
    ELSIF v_kind = 'document' THEN
        SELECT document_id INTO v_object_id FROM maludb_core.malu$document
         WHERE owner_schema = p_schema AND title = v_name COLLATE "default"
         ORDER BY document_id LIMIT 1;
        v_object_type := 'document';
    ELSIF v_kind = 'skill' THEN
        SELECT skill_id INTO v_object_id FROM maludb_core.malu$skill_package
         WHERE owner_schema = p_schema AND skill_name = v_name COLLATE "default"
         ORDER BY updated_at DESC, skill_id DESC LIMIT 1;
        v_object_type := 'skill';
    ELSIF v_kind = 'memory' THEN
        SELECT memory_id INTO v_object_id FROM maludb_core.malu$memory
         WHERE owner_schema = p_schema AND title = v_name COLLATE "default"
         ORDER BY memory_id LIMIT 1;
        v_object_type := 'memory';
    ELSE
        RAISE EXCEPTION 'pool_remove_named_member: unsupported named member_kind %', p_member_kind
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_object_id IS NULL THEN
        RAISE EXCEPTION 'pool_remove_named_member: % named % not found in schema %', v_kind, v_name, p_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    DELETE FROM maludb_core.malu$active_memory_pool_member
     WHERE owner_schema = p_schema
       AND pool_id = v_pool_id
       AND member_kind = v_kind COLLATE "default"
       AND member_object_type = v_object_type
       AND member_object_id = v_object_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$function$;

-- maludb_core._register_agent_skill_for_schema(name,text,text,text,text,jsonb,text,text[],jsonb,jsonb,jsonb,name,bigint,boolean,boolean): 5 comparison(s)
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
    IF p_parent_skill_id IS NOT NULL AND NOT COALESCE(p_materially_different, true) THEN
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

-- maludb_core._unlink_subject_verb_for_schema(name,bigint,bigint): 2 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._unlink_subject_verb_for_schema(p_schema name, p_subject_id bigint, p_verb_id bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_sname text;
    v_vname text;
    v_count integer;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_schema);

    SELECT canonical_name INTO v_sname
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_schema AND subject_id = p_subject_id;
    SELECT canonical_name INTO v_vname
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_schema AND verb_id = p_verb_id;

    IF v_sname IS NULL OR v_vname IS NULL THEN
        RAISE EXCEPTION 'subject_id % or verb_id % not found in schema %',
            p_subject_id, p_verb_id, p_schema
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    DELETE FROM maludb_core.malu$vector_compartment c
     USING maludb_core.malu$vector_subject s, maludb_core.malu$vector_verb v
     WHERE c.owner_schema = p_schema AND c.namespace = 'default'
       AND s.owner_schema = p_schema AND s.namespace = 'default'
       AND s.subject_name = v_sname COLLATE "default" AND c.subject_id = s.subject_id
       AND v.owner_schema = p_schema AND v.namespace = 'default'
       AND v.verb_name = v_vname COLLATE "default" AND c.verb_id = v.verb_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$function$;

-- maludb_core._vector_compartment_for_svpor(name,bigint,bigint,integer,text,text,text): 4 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core._vector_compartment_for_svpor(p_owner_schema name, p_subject_id bigint, p_verb_id bigint, p_embedding_dim integer, p_embedding_model text, p_namespace text DEFAULT 'default'::text, p_distance_metric text DEFAULT 'cosine'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'maludb_core', 'pg_temp'
AS $function$
DECLARE
    v_namespace      text := COALESCE(NULLIF(p_namespace, ''), 'default');
    v_metric         text := COALESCE(NULLIF(p_distance_metric, ''), 'cosine');
    v_subj_canon     text;
    v_verb_canon     text;
    v_compartment_id bigint;
BEGIN
    PERFORM maludb_core._memory_schema_assert_manageable(p_owner_schema);

    SELECT canonical_name INTO v_subj_canon
      FROM maludb_core.malu$svpor_subject
     WHERE owner_schema = p_owner_schema AND subject_id = p_subject_id;
    SELECT canonical_name INTO v_verb_canon
      FROM maludb_core.malu$svpor_verb
     WHERE owner_schema = p_owner_schema AND verb_id = p_verb_id;

    IF v_subj_canon IS NULL OR v_verb_canon IS NULL THEN
        RAISE EXCEPTION '_vector_compartment_for_svpor: unknown subject_id % / verb_id % in schema %',
            p_subject_id, p_verb_id, p_owner_schema
            USING ERRCODE = 'no_data_found';
    END IF;

    -- reuse the tenant-correct compartment primitive (upserts subject/verb
    -- routing rows by name, then the compartment).
    v_compartment_id := maludb_core._register_vector_compartment_for_schema(
        p_owner_schema, v_namespace, v_subj_canon, v_verb_canon,
        p_embedding_dim, p_embedding_model, v_metric);

    -- stamp the graph link onto the routing rows (idempotent).
    UPDATE maludb_core.malu$vector_subject
       SET svpor_subject_id = p_subject_id
     WHERE owner_schema = p_owner_schema
       AND namespace = v_namespace COLLATE "default"
       AND subject_name = v_subj_canon COLLATE "default"
       AND svpor_subject_id IS DISTINCT FROM p_subject_id;

    UPDATE maludb_core.malu$vector_verb
       SET svpor_verb_id = p_verb_id
     WHERE owner_schema = p_owner_schema
       AND namespace = v_namespace COLLATE "default"
       AND verb_name = v_verb_canon COLLATE "default"
       AND svpor_verb_id IS DISTINCT FROM p_verb_id;

    RETURN v_compartment_id;
END;
$function$;

-- maludb_core.grant_object_access(text,bigint,name,text,timestamp with time zone,text): 1 comparison(s)
CREATE OR REPLACE FUNCTION maludb_core.grant_object_access(p_object_type text, p_object_id bigint, p_granted_to_schema name, p_grant_level text DEFAULT 'read'::text, p_expires_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_note text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id     bigint;
    v_exists boolean;
BEGIN
    IF p_grant_level NOT IN ('read','write','full') THEN
        RAISE EXCEPTION 'grant_object_access: bad level %', p_grant_level
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_granted_to_schema IS NULL OR p_granted_to_schema = current_schema() THEN
        RAISE EXCEPTION 'grant_object_access: must grant to a different schema'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM maludb_core.%I WHERE %I = $1)',
        CASE p_object_type
            WHEN 'source_package'        THEN 'malu$source_package'
            WHEN 'claim'                 THEN 'malu$claim'
            WHEN 'fact'                  THEN 'malu$fact'
            WHEN 'memory'                THEN 'malu$memory'
            WHEN 'episode_object'        THEN 'malu$episode_object'
            WHEN 'memory_detail_object'  THEN 'malu$memory_detail_object'
            WHEN 'relationship_edge'     THEN 'malu$relationship_edge'
            WHEN 'derivation_ledger'     THEN 'malu$derivation_ledger'
        END,
        CASE p_object_type
            WHEN 'source_package'        THEN 'source_package_id'
            WHEN 'claim'                 THEN 'claim_id'
            WHEN 'fact'                  THEN 'fact_id'
            WHEN 'memory'                THEN 'memory_id'
            WHEN 'episode_object'        THEN 'episode_id'
            WHEN 'memory_detail_object'  THEN 'mdo_id'
            WHEN 'relationship_edge'     THEN 'edge_id'
            WHEN 'derivation_ledger'     THEN 'derivation_id'
        END
    ) INTO v_exists USING p_object_id;
    IF NOT v_exists THEN
        RAISE EXCEPTION 'grant_object_access: %s id=% not visible to current schema',
            p_object_type, p_object_id
            USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE malu$object_grant
       SET grant_level = p_grant_level,
           expires_at  = p_expires_at,
           note        = COALESCE(p_note, note),
           granted_at  = now()
     WHERE object_type        = p_object_type COLLATE "default"
       AND object_id          = p_object_id
       AND granted_to_schema  = p_granted_to_schema
       AND revoked_at         IS NULL
     RETURNING grant_id INTO v_id;
    IF FOUND THEN
        PERFORM audit_event('grant_upgrade', p_object_type, p_object_id,
            jsonb_build_object('grant_id', v_id, 'granted_to', p_granted_to_schema,
                               'grant_level', p_grant_level));
        RETURN v_id;
    END IF;

    INSERT INTO malu$object_grant
        (object_type, object_id, granted_to_schema,
         grant_level, expires_at, note)
    VALUES (p_object_type, p_object_id, p_granted_to_schema,
            p_grant_level, p_expires_at, p_note)
    RETURNING grant_id INTO v_id;

    PERFORM audit_event('grant', p_object_type, p_object_id,
        jsonb_build_object('grant_id', v_id, 'granted_to', p_granted_to_schema,
                           'grant_level', p_grant_level));
    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.105.3'::text $body$;
