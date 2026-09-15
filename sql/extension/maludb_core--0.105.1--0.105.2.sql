\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.105.2'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.105.2  --  index svpor_statement.source_package_id (#33)
--
-- malu$svpor_statement.source_package_id references malu$source_package
-- ON DELETE SET NULL, and nothing indexed it. PostgreSQL checks a foreign key
-- once per deleted parent row, so every deleted source package scanned the
-- whole statement table: deleting N source packages read N x statements.
-- maludb_upload_document plus maludb_memory_ingest_edge make one source
-- package and one statement per item, so deleting a memory schema's data was
-- quadratic -- 229 s for 32,000 items, 80 million rows read at 8,000, and
-- ~10^12 at a million. With this index the same delete is 65 s, and batched
-- 56 s with nothing large scanned.
--
-- Partial: most statements carry no source package, and the check only ever
-- looks up a non-null key, which a partial index answers.
--
-- Building it takes a SHARE lock on malu$svpor_statement for the length of the
-- build: writes to that table wait during ALTER EXTENSION UPDATE on a
-- database that holds many statements. Reads are unaffected.
-- =====================================================================

CREATE INDEX IF NOT EXISTS "malu$svpor_statement_source_package_idx"
    ON maludb_core."malu$svpor_statement" (source_package_id)
    WHERE source_package_id IS NOT NULL;

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.105.2'::text $body$;
