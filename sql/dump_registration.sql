\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

-- 0.105.0 (issue #27): pg_dump carries what MaluDB stores, and none of what
-- it installs. Checked on a database with nothing but the extension in it,
-- because every earlier regress test has written customer rows here.
DROP DATABASE IF EXISTS dump_registration_fresh;
CREATE DATABASE dump_registration_fresh;
\c dump_registration_fresh
SET client_min_messages = WARNING;
CREATE EXTENSION maludb_core CASCADE;

SELECT maludb_core.maludb_core_version();

-- The five tables deliberately not registered: three superuser-only
-- catalogues and two per-database secrets a dump must never hold.
CREATE TEMP TABLE not_registered(relname name);
INSERT INTO not_registered VALUES
    ('malu$object_type'), ('malu$relationship_type'), ('malu$source_type'),
    ('malu$secret_master_key'), ('malu$auth_pepper');

CREATE TEMP VIEW ext_tables AS
SELECT c.oid, c.relname,
       c.oid = ANY (e.extconfig) AS registered,
       e.extcondition[array_position(e.extconfig, c.oid)] AS condition
  FROM pg_extension e
  JOIN pg_depend d ON d.refobjid = e.oid AND d.deptype = 'e' AND d.classid = 'pg_class'::regclass
  JOIN pg_class c ON c.oid = d.objid AND c.relkind = 'r'
 WHERE e.extname = 'maludb_core';

-- Every table is registered or named above. A table added by a later release
-- must be registered by that release, or listed here with its reason.
SELECT relname AS unclassified FROM ext_tables
 WHERE NOT registered AND relname NOT IN (SELECT relname FROM not_registered)
 ORDER BY 1;

-- The listed ones really are not registered.
SELECT relname AS listed_but_registered FROM ext_tables
 WHERE registered AND relname IN (SELECT relname FROM not_registered) ORDER BY 1;

SELECT count(*) FILTER (WHERE registered) AS registered,
       count(*) FILTER (WHERE registered AND condition <> '') AS filtered,
       count(*) FILTER (WHERE NOT registered) AS not_registered
  FROM ext_tables;

-- The property itself: on a fresh install, no row of any registered table
-- passes its filter -- so pg_dump carries none of the installed rows.
CREATE TEMP TABLE installed_rows_dumped(relname name, n bigint);
DO $$
DECLARE r record; v bigint;
BEGIN
    FOR r IN SELECT oid, relname, condition FROM ext_tables WHERE registered LOOP
        EXECUTE format('SELECT count(*) FROM %s %s', r.oid::regclass, coalesce(r.condition, '')) INTO v;
        IF v > 0 THEN INSERT INTO installed_rows_dumped VALUES (r.relname, v); END IF;
    END LOOP;
END $$;
SELECT * FROM installed_rows_dumped ORDER BY 1;

-- And the filters do not exclude everything: a customer row passes.
SET search_path = maludb_core, public;
INSERT INTO "malu$svpor_verb_type" (verb_type, display_name, sort_order) VALUES ('customer_verb', 'Customer verb', 999);
INSERT INTO "malu$metric_definition" (name, kind, help_text) VALUES ('customer_metric', 'counter', 'x');
INSERT INTO "malu$safety_policy" (policy_name, description) VALUES ('customer_policy', 'x');
SELECT (SELECT count(*) FROM "malu$svpor_verb_type" WHERE NOT system_defined) AS verb_types_dumped,
       (SELECT count(*) FROM "malu$metric_definition" WHERE NOT system_defined) AS metrics_dumped,
       (SELECT count(*) FROM "malu$safety_policy" WHERE NOT system_defined) AS policies_dumped;

-- Markers this release added mark exactly the installed rows.
SELECT (SELECT count(*) FROM "malu$metric_definition" WHERE system_defined) AS metric_builtins,
       (SELECT count(*) FROM "malu$safety_policy" WHERE system_defined) AS safety_builtins,
       (SELECT count(*) FROM "malu$retry_policy" WHERE system_defined) AS retry_builtins;

-- Every sequence owned by a registered table is registered too.
SELECT s.relname AS unregistered_sequence
  FROM ext_tables t
  JOIN pg_depend d ON d.refobjid = t.oid AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
  JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
  JOIN pg_extension e ON e.extname = 'maludb_core'
 WHERE t.registered AND NOT s.oid = ANY (e.extconfig)
 ORDER BY 1;

\c contrib_regression
DROP DATABASE dump_registration_fresh;
