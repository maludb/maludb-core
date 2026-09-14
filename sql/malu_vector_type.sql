-- R1.1-17: malu_vector custom varlena type.
--
-- Exercises:
--   * text I/O round-trip ("[1, 2, 3]" parses and prints back)
--   * empty vector "[]" is accepted
--   * malformed input raises invalid_text_representation
--   * binary-compatible cast bytea ↔ malu_vector is zero-cost
--   * vector_dims / vector_norm / vector_dot_product work on the new type
--   * malu$vector_chunk.embedding is now declared malu_vector
--   * pg_attribute reflects the type swap

\set ECHO all
SET search_path = maludb_core, public;

-- ---------- text I/O ---------------------------------------------------
SELECT '[1, 2, 3, 4]'::malu_vector::text                 AS roundtrip_basic;
SELECT '[0.5, -0.5, 1.25]'::malu_vector::text             AS roundtrip_signed;
SELECT '[]'::malu_vector::text                            AS empty_vec;
SELECT '[1, 2,3 , 4 ]'::malu_vector::text                 AS whitespace_ok;
SELECT vector_dims('[1, 2, 3, 4, 5]'::malu_vector)        AS dim_5;
SELECT vector_dims('[]'::malu_vector)                     AS dim_0;

-- ---------- text output reads back exactly (0.105.1, #31) -------------
-- "%g" printed six significant digits; a float4 needs up to nine. Each value
-- below lost bits through the old text form.
SELECT '[0.123456789, 1e-7, 3.14159265, 16777217, -0.0, 1.17549435e-38]'::malu_vector::text AS shortest_roundtrip;
SELECT v::bytea = (v::text)::malu_vector::bytea AS text_roundtrip_is_exact
  FROM (SELECT '[0.123456789, 1e-7, 3.14159265, 16777217, -0.0, 1.17549435e-38]'::malu_vector AS v) s;
-- And across many values, not just chosen ones.
SELECT count(*) FILTER (WHERE v::bytea <> (v::text)::malu_vector::bytea) AS inexact_roundtrips
  FROM (SELECT ('[' || string_agg((sin(i * 1000 + d) * 1e3)::text, ',') || ']')::malu_vector AS v
          FROM generate_series(1, 200) i, generate_series(1, 64) d GROUP BY i) s;

-- ---------- malformed input -------------------------------------------
DO $$ BEGIN
    PERFORM '1, 2, 3'::malu_vector;
    RAISE EXCEPTION 'should have rejected missing opening bracket';
EXCEPTION WHEN invalid_text_representation THEN
    RAISE NOTICE 'OK: missing [ rejected';
END $$;

DO $$ BEGIN
    PERFORM '[1, 2, 3'::malu_vector;
    RAISE EXCEPTION 'should have rejected missing closing bracket';
EXCEPTION WHEN invalid_text_representation THEN
    RAISE NOTICE 'OK: missing ] rejected';
END $$;

DO $$ BEGIN
    PERFORM '[1, two, 3]'::malu_vector;
    RAISE EXCEPTION 'should have rejected non-numeric token';
EXCEPTION WHEN invalid_text_representation THEN
    RAISE NOTICE 'OK: non-numeric token rejected';
END $$;

-- ---------- bytea ↔ malu_vector zero-cost cast -------------------------
-- A bytea built from the right number of bytes is the SAME value when
-- viewed as malu_vector. Round-trip both ways.
SELECT vector_from_real_array('{1,2,3,4}'::real[])::bytea = vector_from_real_array('{1,2,3,4}'::real[])::bytea
       AS bytea_cast_works;

-- Cast preserves bits: build the bytea by hand and read it as malu_vector.
WITH bytes AS (
    SELECT decode('0000803f0000004000004040', 'hex')::bytea AS b
)
SELECT (b::malu_vector)::text AS three_floats
FROM bytes;
-- 0000803f = 1.0, 00000040 = 2.0, 00004040 = 3.0 (host-order LE)

-- ---------- function surface (post-swap) ------------------------------
SELECT vector_dims('[1, 0, 0, 0]'::malu_vector)                        AS dims_4;
SELECT round(vector_norm('[3, 4, 0, 0]'::malu_vector)::numeric, 4)     AS norm_5;
SELECT vector_dot_product('[1, 0, 0, 0]'::malu_vector,
                          '[0.5, 0.5, 0, 0]'::malu_vector)             AS dot;
SELECT vector_l2_squared('[1, 0, 0, 0]'::malu_vector,
                         '[0, 1, 0, 0]'::malu_vector)                  AS l2sq_2;
SELECT round(vector_norm(vector_normalize('[3, 4, 0, 0]'::malu_vector))::numeric, 6)
       AS unit_norm;

-- ---------- distance wrappers -----------------------------------------
SELECT round(cosine_distance('[1, 0, 0, 0]'::malu_vector,
                             '[1, 0, 0, 0]'::malu_vector)::numeric, 6) AS cos_identical;
SELECT round(cosine_distance('[1, 0, 0, 0]'::malu_vector,
                             '[0, 1, 0, 0]'::malu_vector)::numeric, 6) AS cos_orthogonal;
SELECT l2_squared_distance('[1, 0, 0, 0]'::malu_vector,
                           '[0, 1, 0, 0]'::malu_vector) AS l2sq_2_again;
SELECT inner_product('[1, 2, 3]'::malu_vector,
                     '[4, 5, 6]'::malu_vector)          AS ip_32;

-- ---------- malu$vector_chunk.embedding column type --------------------
SELECT atttypid::regtype AS embedding_type
FROM   pg_attribute
WHERE  attrelid = 'malu$vector_chunk'::regclass
  AND  attname  = 'embedding';

-- ---------- vector_to_real_array round-trip ----------------------------
SELECT vector_to_real_array('[1, 2, 3, 4]'::malu_vector) AS reals;
