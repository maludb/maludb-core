\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.105.1'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.105.1  --  malu_vector text output reads back exactly (#31)
--
-- malu_vector_out printed each element with "%g", six significant digits,
-- which is not enough to reproduce a float4. Every text read of an
-- embedding returned a rounded copy: pg_dump and COPY wrote rounded
-- vectors, so a restored or copied database held different embeddings from
-- its source (cosine distances moved by ~1e-8, enough to reorder near-ties).
-- The output now uses PostgreSQL's shortest round-trip formatting, the
-- routine float4out uses, so text -> malu_vector reproduces the stored
-- bytes. Values already stored were never damaged; only their text form was.
--
-- The change is in the shared library. This script exists so a database
-- and a node report which behaviour they have: 0.105.0 with the old library
-- rounds, 0.105.1 does not.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.105.1'::text $body$;
