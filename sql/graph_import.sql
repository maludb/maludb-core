\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS graph_import_a CASCADE;
DROP ROLE IF EXISTS graph_import_user;
DELETE FROM maludb_core.malu$svpor_subject_type WHERE subject_type IN ('code', 'graph_namespace') AND NOT system_defined;
CREATE ROLE graph_import_user NOLOGIN;
GRANT maludb_memory_executor TO graph_import_user;
GRANT USAGE ON SCHEMA maludb_core TO graph_import_user;
CREATE SCHEMA graph_import_a AUTHORIZATION graph_import_user;

SET ROLE graph_import_user;
SET search_path TO graph_import_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

-- ---------------------------------------------------------------------
-- 1. One-call import: typed nodes, enum + numeric confidence,
--    communities, a link with an unknown endpoint (skipped, not fatal).
-- ---------------------------------------------------------------------
SELECT maludb_graph_import('demo-repo', $json$
{
  "nodes": [
    {"id": "a.rs::f", "label": "f()", "file_type": "code", "source_file": "a.rs", "community": 0},
    {"id": "a.rs::g", "label": "g()", "file_type": "code", "community": 0},
    {"id": "b.rs::h", "label": "h()", "file_type": "code", "community": 1}
  ],
  "links": [
    {"source": "a.rs::f", "target": "a.rs::g", "relation": "calls", "confidence": "EXTRACTED"},
    {"source": "a.rs::g", "target": "b.rs::h", "relation": "uses", "confidence": 0.65},
    {"source": "a.rs::f", "target": "ghost", "relation": "calls"}
  ]
}
$json$::jsonb, '{"provenance": "regress"}'::jsonb) AS report \gset

SELECT :'report'::jsonb -> 'nodes'   AS nodes,
       :'report'::jsonb -> 'edges'   AS edges,
       :'report'::jsonb -> 'communities' -> 'communities' AS communities,
       jsonb_array_length(:'report'::jsonb -> 'skipped')  AS skipped;

-- typed subjects + namespace root
SELECT subject_type, count(*) FROM maludb_subject
WHERE canonical_name LIKE 'demo-repo%' GROUP BY 1 ORDER BY 1;

-- confidence mapping survived (enum -> 1.0, numeric passthrough)
SELECT rel, confidence FROM maludb_edge
WHERE source_kind = 'subject' ORDER BY rel;

-- communities stored
SELECT community_key, count(*) AS members
FROM maludb_community_membership m JOIN maludb_community c ON c.community_id = m.community_id
WHERE c.namespace = 'demo-repo' GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 2. Idempotent re-import: no new subjects, no duplicate statements.
-- ---------------------------------------------------------------------
SELECT (maludb_graph_import('demo-repo', $json$
{
  "nodes": [
    {"id": "a.rs::f", "label": "f()", "file_type": "code", "community": 0},
    {"id": "a.rs::g", "label": "g()", "file_type": "code", "community": 0},
    {"id": "b.rs::h", "label": "h()", "file_type": "code", "community": 1}
  ],
  "links": [
    {"source": "a.rs::f", "target": "a.rs::g", "relation": "calls", "confidence": "EXTRACTED"},
    {"source": "a.rs::g", "target": "b.rs::h", "relation": "uses", "confidence": 0.65}
  ]
}
$json$::jsonb) -> 'nodes' ->> 'created')::int AS created_on_reimport;

SELECT count(*) AS statements FROM maludb_edge WHERE source_kind = 'subject';

-- ---------------------------------------------------------------------
-- 3. Validation errors.
-- ---------------------------------------------------------------------
SELECT maludb_graph_import('bad/ns', '{"nodes": [{"id": "x"}]}'::jsonb);
SELECT maludb_graph_import('ok-ns', '{"nodes": []}'::jsonb);

-- ---------------------------------------------------------------------
-- 4. Cleanup.
-- ---------------------------------------------------------------------
RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$community WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$semantic_edge WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$embedding_dirty WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$object_embedding WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$svpor_subject_relationship_edge WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$svpor_statement WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$svpor_attribute WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$episode_object WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$document WHERE owner_schema = 'graph_import_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'graph_import_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'graph_import_a';
DELETE FROM malu$svpor_subject_type WHERE subject_type IN ('code', 'graph_namespace') AND NOT system_defined;
DROP SCHEMA graph_import_a CASCADE;
DROP OWNED BY graph_import_user;
DROP ROLE graph_import_user;
