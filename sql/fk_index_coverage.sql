\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

-- 0.105.2 (issue #33): foreign keys and the indexes their checks need.
-- PostgreSQL checks a foreign key once per deleted or re-keyed parent row. With no
-- index that a lookup on the referencing columns can use, each check scans the
-- child table, and deleting many parents costs parents x child rows.
--
-- A key counts as covered when an index's first column is one of its referencing
-- columns other than owner_schema, or owner_schema followed by one of them. An
-- index led by owner_schema alone matches every row of the schema, so a
-- schema-scoped delete gains nothing from it.
CREATE TEMP VIEW fk_lookup AS
SELECT cl.relname AS child, rf.relname AS parent,
       (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
          FROM unnest(c.conkey) WITH ORDINALITY k(n, ord)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n) AS cols,
       CASE c.confdeltype WHEN 'a' THEN 'no action' WHEN 'r' THEN 'restrict'
            WHEN 'c' THEN 'cascade' WHEN 'n' THEN 'set null' ELSE 'set default' END AS on_delete,
       EXISTS (SELECT 1 FROM pg_index i
                WHERE i.indrelid = c.conrelid AND i.indkey[0] = ANY (c.conkey)
                  AND (SELECT attname FROM pg_attribute
                        WHERE attrelid = c.conrelid AND attnum = i.indkey[0]) <> 'owner_schema')
       OR EXISTS (SELECT 1 FROM pg_index i
                   WHERE i.indrelid = c.conrelid AND array_length(c.conkey, 1) > 1
                     AND i.indkey[0] = ANY (c.conkey) AND i.indkey[1] = ANY (c.conkey)) AS covered
  FROM pg_constraint c
  JOIN pg_class cl ON cl.oid = c.conrelid
  JOIN pg_class rf ON rf.oid = c.confrelid
 WHERE c.contype = 'f' AND cl.relnamespace = 'maludb_core'::regnamespace;

-- The key 0.105.2 indexes: deleting a source package no longer scans every statement.
SELECT covered FROM fk_lookup
 WHERE child = 'malu$svpor_statement' AND cols = 'source_package_id';

-- And the check itself uses it. This is the shape of the query PostgreSQL runs per
-- deleted source package, as a generic plan; with sequential scans off, a plan that
-- still scans means the index cannot serve it.
SET enable_seqscan = off;
SET plan_cache_mode = force_generic_plan;
PREPARE fk_check(bigint) AS
    SELECT 1 FROM ONLY maludb_core."malu$svpor_statement" x WHERE $1 = source_package_id FOR KEY SHARE OF x;
CREATE FUNCTION pg_temp.fk_check_plan() RETURNS text LANGUAGE plpgsql AS $plan$
DECLARE line text; plan text := '';
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) EXECUTE fk_check(1)' LOOP
        plan := plan || line || E'\n';
    END LOOP;
    RETURN plan;
END
$plan$;
SELECT position('Seq Scan' IN pg_temp.fk_check_plan()) = 0 AS uses_index;
RESET enable_seqscan;
RESET plan_cache_mode;
DEALLOCATE fk_check;

-- Every foreign key still without such an index. A new unindexed key changes this
-- list: index it, or record here why its parents are never deleted in bulk.
SELECT child, cols, parent, on_delete FROM fk_lookup WHERE NOT covered ORDER BY child, cols, parent;
SELECT count(*) AS uncovered, (SELECT count(*) FROM fk_lookup) AS foreign_keys FROM fk_lookup WHERE NOT covered;
