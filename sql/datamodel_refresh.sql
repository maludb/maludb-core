\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

DROP SCHEMA IF EXISTS dm_a CASCADE;
DROP ROLE IF EXISTS dm_user;
CREATE ROLE dm_user NOLOGIN;
GRANT maludb_memory_executor TO dm_user;
GRANT USAGE ON SCHEMA maludb_core TO dm_user;
CREATE SCHEMA dm_a AUTHORIZATION dm_user;

SET ROLE dm_user;
SET search_path TO dm_a, maludb_core, public;

SELECT object_count > 0 AS enabled
FROM maludb_core.enable_memory_schema();

-- ---------------------------------------------------------------------
-- 1. Fixture: customers <-fk- orders, a view over the join, a trigger,
--    and a routine that reads customers and writes orders.
-- ---------------------------------------------------------------------
CREATE TABLE dm_a.customers (
    customer_id bigserial PRIMARY KEY,
    email       text NOT NULL
);
CREATE TABLE dm_a.orders (
    order_id    bigserial PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES dm_a.customers(customer_id),
    total       numeric
);
CREATE VIEW dm_a.order_totals AS
    SELECT c.email, sum(o.total) AS total
      FROM dm_a.orders o JOIN dm_a.customers c USING (customer_id)
     GROUP BY c.email;
CREATE FUNCTION dm_a.place_order(p_customer bigint, p_total numeric) RETURNS void
LANGUAGE plpgsql AS $fn$
BEGIN
    PERFORM 1 FROM dm_a.customers WHERE customer_id = p_customer;
    INSERT INTO dm_a.orders (customer_id, total) VALUES (p_customer, p_total);
END;
$fn$;
CREATE FUNCTION dm_a.orders_touch() RETURNS trigger
LANGUAGE plpgsql AS $fn$ BEGIN RETURN NEW; END; $fn$;
CREATE TRIGGER orders_touch_tg BEFORE INSERT ON dm_a.orders
    FOR EACH ROW EXECUTE FUNCTION dm_a.orders_touch();

-- ---------------------------------------------------------------------
-- 2. Refresh into namespace 'dm-test' and check the report shape.
-- ---------------------------------------------------------------------
SELECT maludb_datamodel_refresh('dm-test') AS report \gset

SELECT (:'report'::jsonb ->> 'namespace') AS namespace,
       ((:'report'::jsonb -> 'nodes' ->> 'received')::int > 5) AS has_nodes,
       ((:'report'::jsonb -> 'edges' ->> 'received')::int > 5) AS has_edges;

-- targeted node facts (facade objects also become db_* nodes; assert
-- only the fixture's, so enablement-count changes never break this)
SELECT subject_type, count(*) FROM maludb_subject
WHERE canonical_name IN ('dm-test/dm_a.customers', 'dm-test/dm_a.orders',
                         'dm-test/dm_a.order_totals', 'dm-test/dm_a.place_order',
                         'dm-test/dm_a.orders::orders_touch_tg', 'dm-test/dm_a')
GROUP BY 1 ORDER BY 1;

-- fk edge: orders -> customers
SELECT count(*) AS fk_edges FROM maludb_edge e
JOIN maludb_subject s ON s.subject_id = e.source_id
JOIN maludb_subject t ON t.subject_id = e.target_id
WHERE e.rel = 'fk_references'
  AND s.canonical_name = 'dm-test/dm_a.orders'
  AND t.canonical_name = 'dm-test/dm_a.customers';

-- view dependency: order_totals -> both tables
SELECT t.canonical_name FROM maludb_edge e
JOIN maludb_subject s ON s.subject_id = e.source_id
JOIN maludb_subject t ON t.subject_id = e.target_id
WHERE e.rel = 'depends_on' AND s.canonical_name = 'dm-test/dm_a.order_totals'
ORDER BY 1;

-- routine usage: place_order writes orders, reads customers (INFERRED 0.7)
SELECT e.rel, t.canonical_name, e.confidence FROM maludb_edge e
JOIN maludb_subject s ON s.subject_id = e.source_id
JOIN maludb_subject t ON t.subject_id = e.target_id
WHERE s.canonical_name = 'dm-test/dm_a.place_order' AND e.rel IN ('reads', 'writes')
ORDER BY 1, 2;

-- trigger edge
SELECT count(*) AS trigger_edges FROM maludb_edge e
JOIN maludb_subject s ON s.subject_id = e.source_id
WHERE e.rel = 'triggers_on' AND s.canonical_name = 'dm-test/dm_a.orders::orders_touch_tg';

-- columns + pk attributes on the orders node
SELECT (SELECT count(*) FROM maludb_svpor_attribute a
         WHERE a.target_id = s.subject_id AND a.target_kind = 'subject'
           AND a.attr_name IN ('columns', 'primary_key')) AS table_attrs
FROM maludb_subject s WHERE s.canonical_name = 'dm-test/dm_a.orders';

-- ---------------------------------------------------------------------
-- 3. describe: live catalog detail.
-- ---------------------------------------------------------------------
SELECT maludb_datamodel_describe('orders') AS d \gset
SELECT (:'d'::jsonb ->> 'kind') AS kind,
       jsonb_array_length(:'d'::jsonb -> 'columns') AS columns,
       :'d'::jsonb -> 'fks_out' -> 0 ->> 'references' AS fk_ref,
       (:'d'::jsonb -> 'columns' -> 0 ->> 'pk')::boolean AS first_col_pk;

-- ---------------------------------------------------------------------
-- 4. Guards: foreign schema refused; unknown relation refused.
-- ---------------------------------------------------------------------
SELECT maludb_datamodel_refresh('dm-test', ARRAY['pg_catalog']::name[]);
SELECT maludb_datamodel_describe('nope_missing');

-- ---------------------------------------------------------------------
-- 5. resolve_external: an import may target existing datamodel nodes.
-- ---------------------------------------------------------------------
SELECT maludb_graph_import('dm-app', $json$
{
  "nodes": [{"id": "app.py::checkout", "label": "checkout()", "file_type": "code"}],
  "links": [{"source": "app.py::checkout", "target": "dm-test/dm_a.orders", "relation": "writes", "confidence": "INFERRED"}]
}
$json$::jsonb, '{"resolve_external": true}'::jsonb) -> 'edges' ->> 'created' AS cross_ns_edges;

SELECT t.canonical_name FROM maludb_edge e
JOIN maludb_subject s ON s.subject_id = e.source_id
JOIN maludb_subject t ON t.subject_id = e.target_id
WHERE s.canonical_name = 'dm-app/app.py::checkout' AND e.rel = 'writes';

-- ---------------------------------------------------------------------
-- 6. Cleanup.
-- ---------------------------------------------------------------------
RESET ROLE;
SET search_path TO maludb_core, public;

DELETE FROM malu$community WHERE owner_schema = 'dm_a';
DELETE FROM malu$semantic_edge WHERE owner_schema = 'dm_a';
DELETE FROM malu$embedding_dirty WHERE owner_schema = 'dm_a';
DELETE FROM malu$object_embedding WHERE owner_schema = 'dm_a';
DELETE FROM malu$svpor_subject_relationship_edge WHERE owner_schema = 'dm_a';
DELETE FROM malu$svpor_statement WHERE owner_schema = 'dm_a';
DELETE FROM malu$svpor_attribute WHERE owner_schema = 'dm_a';
DELETE FROM malu$episode_object WHERE owner_schema = 'dm_a';
DELETE FROM malu$svpor_verb WHERE owner_schema = 'dm_a';
DELETE FROM malu$svpor_subject WHERE owner_schema = 'dm_a';
DELETE FROM malu$document WHERE owner_schema = 'dm_a';
DELETE FROM malu$enabled_schema_object WHERE schema_name = 'dm_a';
DELETE FROM malu$enabled_schema WHERE schema_name = 'dm_a';
DROP SCHEMA dm_a CASCADE;
DROP OWNED BY dm_user;
DROP ROLE dm_user;
