\set ECHO all
\set VERBOSITY terse
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

-- =====================================================================
-- pool_presence_facade -- 0.106.0
--
-- Until now a tenant could read maludb_pool_presence and nothing else: the
-- presence functions had no facade. Now:
--   * maludb_presence_update / _leave / _list, by pool name;
--   * the roster returns the cursor and the TTL (presence_list never did);
--   * a pool has a scope -- a principal outside it can neither see nor join it;
--   * a principal-bound session is present as itself, whatever it claims.
-- =====================================================================

DO $body$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'mpp_user') THEN
        RAISE EXCEPTION 'Refusing to start pool_presence_facade test: role mpp_user already exists';
    END IF;
END;
$body$;

CREATE ROLE mpp_user NOLOGIN;
GRANT maludb_memory_executor TO mpp_user;
GRANT USAGE ON SCHEMA maludb_core TO mpp_user;
GRANT mpp_user TO CURRENT_USER;
CREATE SCHEMA mpp AUTHORIZATION mpp_user;

SET ROLE mpp_user;
SET search_path TO mpp, maludb_core, public;
SELECT object_count > 0 AS enabled FROM maludb_core.enable_memory_schema('mpp');

\set ON_ERROR_STOP on

SELECT maludb_principal_upsert('agent:44', 'agent', 'Sasha', 'agent:44') > 0 AS sasha;
SELECT maludb_principal_upsert('agent:45', 'agent', 'Seamus', 'agent:45') > 0 AS seamus;
SELECT maludb_principal_upsert('member:1', 'human', 'Owner', 'member:1') > 0 AS owner;
SELECT maludb_principal_grant_scope('agent:44', 'dept:3', 'read') > 0 AS sasha_dept3;
SELECT maludb_principal_grant_scope('member:1', 'dept:3', 'write') > 0 AS owner_dept3;
SELECT maludb_principal_grant_scope('agent:45', 'dept:4', 'read') > 0 AS seamus_dept4;

INSERT INTO maludb_memory_pool (pool_name, creation_kind, task_objective, scope)
VALUES ('month-end close', 'sql', 'Close September', 'dept:3');

-- ---------------------------------------------------------------------
-- 1. The tenant (a runner, say) joins on an agent's behalf, then heartbeats.
-- ---------------------------------------------------------------------
SELECT maludb_presence_update('month-end close', 'tool', 'runner', 'scheduler', 'starting runs', NULL, 600) > 0 AS runner_joined;
SELECT participant_kind, participant_ref, role, declared_task, cursor_jsonb, ttl_seconds, left_at IS NULL AS present
  FROM maludb_presence_list('month-end close');

-- ---------------------------------------------------------------------
-- 2. Sasha joins as herself -- the name she gives is ignored -- and moves her cursor.
-- ---------------------------------------------------------------------
SET maludb_core.principal_ref = 'agent:44';
SELECT maludb_presence_update('month-end close', 'human', 'member:1', 'bookkeeper', 'reconciling the bank', '{"step": 1}'::jsonb) > 0 AS joined;
SELECT maludb_presence_update('month-end close', p_cursor_jsonb => '{"step": 2}'::jsonb) > 0 AS heartbeat;
SELECT participant_kind, participant_ref, role, declared_task, cursor_jsonb, ttl_seconds
  FROM maludb_presence_list('month-end close') ORDER BY participant_ref;
SELECT pool_name, participant_ref, cursor_jsonb, ttl_seconds FROM maludb_pool_presence ORDER BY participant_ref;

-- ---------------------------------------------------------------------
-- 3. Seamus is not in dept:3: the pool is not there for him.
-- ---------------------------------------------------------------------
SET maludb_core.principal_ref = 'agent:45';
SELECT count(*) AS pools_seamus_sees FROM maludb_memory_pool;
SELECT count(*) AS roster_seamus_sees FROM maludb_presence_list('month-end close');
SELECT count(*) AS presence_seamus_sees FROM maludb_pool_presence;
SELECT maludb_presence_leave('month-end close') AS seamus_leaves_nothing;
\set ON_ERROR_STOP off
SELECT maludb_presence_update('month-end close', p_declared_task => 'looking around');
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- 4. Leaving, and the roster with those who left.
-- ---------------------------------------------------------------------
SET maludb_core.principal_ref = 'agent:44';
SELECT maludb_presence_leave('month-end close', p_reason => 'run finished') AS sasha_left;
RESET maludb_core.principal_ref;
SELECT participant_ref, left_at IS NULL AS present FROM maludb_presence_list('month-end close', true) ORDER BY participant_ref;
SELECT participant_ref FROM maludb_presence_list('month-end close');
SELECT maludb_presence_leave('month-end close', 'tool', 'runner') AS runner_left;
\set ON_ERROR_STOP off
SELECT maludb_presence_update('no such pool', 'tool', 'runner');
SELECT maludb_presence_update('month-end close');                        -- the tenant must say who
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- Teardown.
-- ---------------------------------------------------------------------
RESET ROLE;
SET search_path TO maludb_core, public;
DO $body$
DECLARE
    v_table text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'malu$pool_presence', 'malu$active_memory_pool',
        'malu$skill_load_event', 'malu$skill_principal_access', 'malu$skill_keyword',
        'malu$skill_file', 'malu$skill_package',
        'malu$source_package',
        'malu$principal_scope', 'malu$principal',
        'malu$enabled_schema_object', 'malu$enabled_schema']
    LOOP
        EXECUTE format('DELETE FROM maludb_core.%I WHERE %s = $1', v_table,
                       CASE WHEN v_table LIKE 'malu$enabled%' THEN 'schema_name' ELSE 'owner_schema' END)
        USING 'mpp'::name;
    END LOOP;
END;
$body$;
DROP SCHEMA IF EXISTS mpp CASCADE;
DROP OWNED BY mpp_user;
DROP ROLE mpp_user;
