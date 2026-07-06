\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS graph_path_a CASCADE;
DROP ROLE IF EXISTS graph_path_user;
CREATE ROLE graph_path_user NOLOGIN;
GRANT maludb_memory_executor TO graph_path_user;
GRANT USAGE ON SCHEMA maludb_core TO graph_path_user;
CREATE SCHEMA graph_path_a AUTHORIZATION graph_path_user;

SET ROLE graph_path_user;
SET search_path TO graph_path_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

-- ---------------------------------------------------------------------
-- 1. Build a small diamond: api -> cache -> db (depends_on chain) plus
--    a direct api -> db shortcut (reads_from), and one isolated node.
-- ---------------------------------------------------------------------
SELECT maludb_memory_ingest_extraction($json$
{
  "subjects": [
    {"key": "api",   "name": "Billing API",      "type": "software"},
    {"key": "cache", "name": "Billing Cache",    "type": "software"},
    {"key": "db",    "name": "Billing Database", "type": "software"},
    {"key": "iso",   "name": "Orphan Service",   "type": "software"}
  ],
  "relationships": [
    {"from": "api",   "to": "cache", "relationship_type": "depends_on"},
    {"from": "cache", "to": "db",    "relationship_type": "depends_on"},
    {"from": "api",   "to": "db",    "relationship_type": "reads_from"}
  ]
}
$json$::jsonb) AS report \gset

SELECT (:'report'::jsonb -> 'created' ->> 'subjects')::int      AS subjects_created,
       (:'report'::jsonb -> 'created' ->> 'relationships')::int AS rels_created;

SELECT (:'report'::jsonb -> 'ids' ->> 'api')::bigint   AS api_id \gset
SELECT (:'report'::jsonb -> 'ids' ->> 'cache')::bigint AS cache_id \gset
SELECT (:'report'::jsonb -> 'ids' ->> 'db')::bigint    AS db_id \gset
SELECT (:'report'::jsonb -> 'ids' ->> 'iso')::bigint   AS iso_id \gset

-- ---------------------------------------------------------------------
-- 2. Both paths api -> db are found, shortest first: the direct
--    reads_from edge (depth 1) then the depends_on chain (depth 2).
-- ---------------------------------------------------------------------
SELECT count(*) AS paths_found
FROM maludb_graph_path('subject', :api_id, 'subject', :db_id, 4, 'out');

SELECT array_agg(depth ORDER BY depth) AS path_depths
FROM maludb_graph_path('subject', :api_id, 'subject', :db_id, 4, 'out');

SELECT depth AS shortest_depth, array_length(path, 1) AS shortest_nodes
FROM maludb_graph_path('subject', :api_id, 'subject', :db_id, 4, 'out')
LIMIT 1;

-- ---------------------------------------------------------------------
-- 3. Relationship filter: only the depends_on chain survives.
-- ---------------------------------------------------------------------
SELECT depth, array_length(path, 1) AS nodes
FROM maludb_graph_path('subject', :api_id, 'subject', :db_id, 4, 'out',
                       ARRAY['depends_on']);

-- ---------------------------------------------------------------------
-- 4. Direction: walking 'in' from db reaches api the same two ways;
--    'out' from db reaches nothing.
-- ---------------------------------------------------------------------
SELECT count(*) AS reverse_paths
FROM maludb_graph_path('subject', :db_id, 'subject', :api_id, 4, 'in');

SELECT count(*) AS outbound_from_sink
FROM maludb_graph_path('subject', :db_id, 'subject', :api_id, 4, 'out');

-- ---------------------------------------------------------------------
-- 5. Isolated node: no path within budget.
-- ---------------------------------------------------------------------
SELECT count(*) AS orphan_paths
FROM maludb_graph_path('subject', :api_id, 'subject', :iso_id, 6, 'both');

-- ---------------------------------------------------------------------
-- 6. Depth budget: max_depth 1 hides the depth-2 chain.
-- ---------------------------------------------------------------------
SELECT count(*) AS depth1_paths
FROM maludb_graph_path('subject', :api_id, 'subject', :db_id, 1, 'out');

-- ---------------------------------------------------------------------
-- 7. Parameter validation.
-- ---------------------------------------------------------------------
SELECT * FROM maludb_graph_path('subject', :api_id, 'subject', :db_id, 4, 'sideways');
SELECT * FROM maludb_graph_path('subject', :api_id, 'subject', :db_id, 0, 'out');
SELECT * FROM maludb_graph_path('subject', :api_id, 'subject', :db_id, 33, 'out');

-- ---------------------------------------------------------------------
-- 8. Cleanup.
-- ---------------------------------------------------------------------
RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$semantic_edge WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$embedding_dirty WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$object_embedding WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$svpor_subject_relationship_edge WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$svpor_statement WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$svpor_attribute WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$episode_object WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$document WHERE owner_schema = 'graph_path_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'graph_path_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'graph_path_a';
DROP SCHEMA graph_path_a CASCADE;
DROP OWNED BY graph_path_user;
DROP ROLE graph_path_user;
