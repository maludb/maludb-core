\set ECHO all
\pset format unaligned
SET client_min_messages = WARNING;

-- 0.105.3: text comparisons inside functions called with a `name` argument.
--
-- PL/pgSQL runs a function under the collation of its call's arguments, and gives
-- that collation to every collatable parameter and local variable. A `name`
-- argument -- OLD.owner_schema in a trigger, current_schema(), 'x'::name --
-- carries "C", which outranks a text literal's default. The extension's text
-- columns and their indexes use the database collation, and the planner cannot
-- use an index for a comparison under another collation. So `object_kind =
-- p_object_kind` became a filter over every row matching the index's leading
-- owner_schema: _embedding_dirty_purge, fired per deleted statement, read the
-- whole dirty queue each time.

-- The mechanism: the same comparison, planned from inside a function called with
-- a `name` argument, is compared under "C" unless it says otherwise.
CREATE FUNCTION pg_temp.plan_is_under_c(p_owner_schema name, p_object_kind text, p_collate boolean)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE r record; v_c boolean := false;
BEGIN
  IF p_collate THEN
    FOR r IN EXPLAIN (COSTS OFF) DELETE FROM maludb_core."malu$embedding_dirty"
              WHERE owner_schema = p_owner_schema AND object_kind = p_object_kind COLLATE "default"
                AND object_id = 1 LOOP
      v_c := v_c OR r."QUERY PLAN" LIKE '%COLLATE "C"%';
    END LOOP;
  ELSE
    FOR r IN EXPLAIN (COSTS OFF) DELETE FROM maludb_core."malu$embedding_dirty"
              WHERE owner_schema = p_owner_schema AND object_kind = p_object_kind
                AND object_id = 1 LOOP
      v_c := v_c OR r."QUERY PLAN" LIKE '%COLLATE "C"%';
    END LOOP;
  END IF;
  RETURN v_c;
END $$;
SELECT pg_temp.plan_is_under_c('s'::name, 'svpor_statement', false) AS plain_comparison_under_c,
       pg_temp.plan_is_under_c('s'::name, 'svpor_statement', true)  AS collated_comparison_under_c;

-- The guard. Every PL/pgSQL or SQL function taking a `name` argument, searched for
-- a text parameter or text local variable (v_*, l_*, _*) compared with = or <> to
-- a text column that some index covers, without a COLLATE clause. Assignments in
-- an UPDATE ... SET list are not comparisons and are skipped. A function added or
-- changed with this shape is listed here and fails the test.
CREATE FUNCTION pg_temp.uncollated_comparisons()
RETURNS TABLE (function_name text, column_name text, compared_to text)
LANGUAGE plpgsql AS $$
DECLARE
  f record; ident text; col text; src text; pos int; occ int; pat text; before text; kw text;
  v_cols text[];
BEGIN
  SELECT array_agg(DISTINCT a.attname::text) INTO v_cols
    FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (i.indkey)
   WHERE n.nspname = 'maludb_core' AND a.atttypid IN ('text'::regtype, 'varchar'::regtype);

  FOR f IN
    SELECT p.oid, p.proname::text AS proname, p.prosrc,
           ARRAY(SELECT p.proargnames[k + 1] FROM generate_series(0, p.pronargs - 1) k
                  WHERE p.proargtypes[k] IN ('text'::regtype, 'varchar'::regtype)
                    AND p.proargnames IS NOT NULL AND p.proargnames[k + 1] <> '') AS text_args
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_language l ON l.oid = p.prolang
     WHERE n.nspname = 'maludb_core' AND l.lanname IN ('plpgsql', 'sql')
       AND 'name'::regtype = ANY (p.proargtypes::oid[])
  LOOP
    src := f.prosrc;
    FOR ident IN
      SELECT DISTINCT x FROM (
        SELECT unnest(f.text_args) AS x
        UNION
        SELECT (regexp_matches(src, '\m((?:v|l)_[a-z0-9_]+|_[a-z0-9_]+)\s+(?:text|varchar)\M(?!\s*\[)', 'gi'))[1]
      ) s
    LOOP
      FOREACH col IN ARRAY v_cols LOOP
        FOREACH pat IN ARRAY ARRAY[
          '\m' || col || '\s*(=|<>|!=)\s*' || ident || '\M(?!\s*COLLATE)',
          '\m' || ident || '\s*(=|<>|!=)\s*(?:[a-z_][a-z0-9_]*\.)?' || col || '\M(?!\s*\()'] LOOP
          occ := 1;
          LOOP
            pos := regexp_instr(src, pat, 1, occ, 0, 'i');
            EXIT WHEN pos = 0;
            before := substr(src, greatest(1, pos - 400), least(pos - 1, 400));
            SELECT upper(m[1]) INTO kw
              FROM regexp_matches(before, '\m(SET|WHERE|AND|OR|ON|WHEN|IF|ELSIF|WHILE|RETURN|SELECT|VALUES|BY)\M', 'gi')
                   WITH ORDINALITY AS t(m, o)
             ORDER BY o DESC LIMIT 1;
            IF kw IS DISTINCT FROM 'SET'
               AND NOT (substr(src, pos, 400) ~* ('^' || ident || '\s*(=|<>|!=)\s*(?:[a-z_][a-z0-9_]*\.)?' || col || '\M')
                        AND substr(src, pos + length(ident), 30) ~* '^\s*COLLATE') THEN
              function_name := f.proname; column_name := col; compared_to := ident;
              RETURN NEXT;
            END IF;
            occ := occ + 1;
          END LOOP;
        END LOOP;
      END LOOP;
    END LOOP;
  END LOOP;
END $$;

SELECT count(*) AS functions_taking_name
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
 WHERE n.nspname = 'maludb_core' AND l.lanname IN ('plpgsql', 'sql')
   AND 'name'::regtype = ANY (p.proargtypes::oid[]);

SELECT DISTINCT function_name, column_name, compared_to
  FROM pg_temp.uncollated_comparisons()
 ORDER BY 1, 2, 3;
