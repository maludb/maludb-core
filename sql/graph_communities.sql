\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS graph_comm_a CASCADE;
DROP ROLE IF EXISTS graph_comm_user;
DELETE FROM maludb_core.malu$svpor_subject_type WHERE subject_type = 'code_symbol';
CREATE ROLE graph_comm_user NOLOGIN;
GRANT maludb_memory_executor TO graph_comm_user;
GRANT USAGE ON SCHEMA maludb_core TO graph_comm_user;
CREATE SCHEMA graph_comm_a AUTHORIZATION graph_comm_user;

SET ROLE graph_comm_user;
SET search_path TO graph_comm_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

-- ---------------------------------------------------------------------
-- 1. Subject-type registration: first call registers, second no-ops,
--    bad names are rejected, and the new type is usable at ingest.
-- ---------------------------------------------------------------------
SELECT maludb_register_subject_type('code_symbol', 'Code Symbol', 'AST-extracted code entity') AS registered;
SELECT maludb_register_subject_type('code_symbol') AS registered_again;
SELECT maludb_register_subject_type('Bad-Type!');
SELECT subject_type, display_name, system_defined
FROM maludb_subject_type WHERE subject_type = 'code_symbol';

-- ---------------------------------------------------------------------
-- 2. Fixture: two clusters joined by one cross edge.
--    A: a1 -calls-> a2      B: b1 -calls-> b2      cross: a2 -uses-> b1
-- ---------------------------------------------------------------------
SELECT maludb_memory_ingest_extraction($json$
{
  "subjects": [
    {"key": "a1", "name": "ns/a1", "type": "code_symbol"},
    {"key": "a2", "name": "ns/a2", "type": "code_symbol"},
    {"key": "b1", "name": "ns/b1", "type": "code_symbol"},
    {"key": "b2", "name": "ns/b2", "type": "code_symbol"}
  ],
  "edges": [
    {"subject": "a1", "verb": "calls", "object": "a2", "confidence": 1.0},
    {"subject": "b1", "verb": "calls", "object": "b2", "confidence": 1.0},
    {"subject": "a2", "verb": "uses",  "object": "b1", "confidence": 0.7}
  ]
}
$json$::jsonb) AS report \gset

SELECT (:'report'::jsonb -> 'created' ->> 'subjects')::int AS subjects_created,
       (:'report'::jsonb -> 'created' ->> 'edges')::int    AS edges_created;

-- ---------------------------------------------------------------------
-- 3. Community replace: A and B, plus one unknown member (reported,
--    not fatal).
-- ---------------------------------------------------------------------
SELECT maludb_community_replace('ns', 'louvain', $json$
[
  {"key": 0, "label": "cluster A", "members": ["ns/a1", "ns/a2"]},
  {"key": 1, "label": "cluster B", "members": ["ns/b1", "ns/b2", "ns/ghost"]}
]
$json$::jsonb) AS comm_report \gset

SELECT (:'comm_report'::jsonb ->> 'communities')::int AS communities,
       (:'comm_report'::jsonb ->> 'members')::int     AS members,
       :'comm_report'::jsonb -> 'unknown_members'     AS unknown_members;

SELECT namespace, community_key, label, algorithm
FROM maludb_community ORDER BY community_key;

SELECT c.community_key, count(*) AS member_count
FROM maludb_community_membership m
JOIN maludb_community c ON c.community_id = m.community_id
GROUP BY c.community_key ORDER BY c.community_key;

-- ---------------------------------------------------------------------
-- 4. Degree: a2 and b1 have degree 2 (they touch the cross edge).
-- ---------------------------------------------------------------------
SELECT label, degree_out, degree_in, degree_total
FROM maludb_graph_degree(4) ORDER BY degree_total DESC, label;

-- ---------------------------------------------------------------------
-- 5. Surprises: exactly the one cross-community edge, pair count 1.
-- ---------------------------------------------------------------------
SELECT source_label, source_community, rel, target_label, target_community, community_pair_edges
FROM maludb_graph_surprises('ns', 10);

-- ---------------------------------------------------------------------
-- 6. Replace is idempotent swap: same payload -> same shape, no
--    duplicate rows; dropping a community removes its memberships.
-- ---------------------------------------------------------------------
SELECT (maludb_community_replace('ns', 'louvain', $json$
[
  {"key": 0, "label": "cluster A", "members": ["ns/a1", "ns/a2"]}
]
$json$::jsonb) ->> 'communities')::int AS communities_after_shrink;

SELECT count(*) AS communities, (SELECT count(*) FROM maludb_community_membership) AS memberships
FROM maludb_community;

SELECT count(*) AS surprises_without_b
FROM maludb_graph_surprises('ns', 10);

-- ---------------------------------------------------------------------
-- 7. Validation errors.
-- ---------------------------------------------------------------------
SELECT maludb_community_replace('', 'louvain', '[]'::jsonb);

-- ---------------------------------------------------------------------
-- 8. Cleanup.
-- ---------------------------------------------------------------------
RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$community WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$semantic_edge WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$embedding_dirty WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$object_embedding WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$svpor_subject_relationship_edge WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$svpor_statement WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$svpor_attribute WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$episode_object WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$document WHERE owner_schema = 'graph_comm_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'graph_comm_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'graph_comm_a';
DELETE FROM malu$svpor_subject_type WHERE subject_type = 'code_symbol';
DROP SCHEMA graph_comm_a CASCADE;
DROP OWNED BY graph_comm_user;
DROP ROLE graph_comm_user;
