\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.105.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.105.0  --  pg_dump carries MaluDB's data (issue #27)
--
-- Until now no table was registered with pg_extension_config_dump, so
-- PostgreSQL treated every row of every maludb_core table as part of the
-- extension and pg_dump left all of it out: a logical backup, a pg_dump /
-- pg_restore migration or a database copy silently lost everything stored
-- through MaluDB. This release registers the data tables, so pg_dump
-- carries the rows written after install and none of the rows the
-- extension installs itself (which the target's own CREATE EXTENSION
-- brings).
--
-- Every table is in exactly one of three groups, and the regress test
-- dump_registration fails on a table added later that is in none:
--
--   1. Registered, no filter: tables with no installed rows (140).
--   2. Registered with a filter excluding installed rows (12): marked by
--      owner_schema = 'maludb_core' (the schema current when the
--      extension script ran), or by system_defined -- a column this
--      release adds to metric_definition, safety_policy and
--      retry_policy, which had no marker.
--   3. Not registered (5): three catalogues only the installing
--      superuser can write, and two per-database secrets
--      (malu$secret_master_key, malu$auth_pepper). A dump must never hold
--      either key, so MaluDB's in-database secret store and auth tokens
--      do NOT survive pg_dump: their rows arrive, but the target's own
--      key cannot decrypt or verify them.
--
-- Sequences owned by registered tables are registered with them, so a
-- restored database does not reissue ids its rows already hold.
--
-- Two things pg_dump still cannot give, stated in docs:
--   * a change to an INSTALLED row (disabling a built-in REST endpoint,
--     say) is not carried -- the target keeps its own installed row;
--   * extension triggers exist before pg_restore loads data, so they
--     fire on restored rows. Restore with
--     PGOPTIONS='-c session_replication_role=replica' (as a superuser).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Markers for installed rows where none existed.
--    Marked by natural key, never "every row present": on an upgraded
--    database a customer row may already be there.
-- ---------------------------------------------------------------------
ALTER TABLE maludb_core."malu$metric_definition"
    ADD COLUMN IF NOT EXISTS system_defined boolean NOT NULL DEFAULT false;
UPDATE maludb_core."malu$metric_definition" SET system_defined = true
 WHERE name IN ('maludb_extension_version', 'maludb_catalog_tables',
                'maludb_audit_event_total', 'maludb_audit_event_by_kind_total',
                'maludb_mc2db_invocation_total', 'maludb_mc2db_invocation_outcome_total',
                'maludb_rest_invocation_total', 'maludb_rest_invocation_outcome_total',
                'maludb_auth_token_total', 'maludb_secret_total', 'maludb_queue_depth',
                'maludb_cron_schedule_total', 'maludb_source_object_total',
                'maludb_event_total', 'maludb_event_subscription_total',
                'maludb_vector_compartment_total', 'maludb_embedding_job_total');

ALTER TABLE maludb_core."malu$safety_policy"
    ADD COLUMN IF NOT EXISTS system_defined boolean NOT NULL DEFAULT false;
UPDATE maludb_core."malu$safety_policy" SET system_defined = true
 WHERE policy_name IN ('open', 'pii_redact', 'legal_review', 'internal_only');

ALTER TABLE maludb_core."malu$retry_policy"
    ADD COLUMN IF NOT EXISTS system_defined boolean NOT NULL DEFAULT false;
-- The one installed policy: the provider-independent default.
UPDATE maludb_core."malu$retry_policy" SET system_defined = true
 WHERE provider_id IS NULL
   AND policy_id = (SELECT min(policy_id) FROM maludb_core."malu$retry_policy" WHERE provider_id IS NULL);

-- The SVPOR type tables already have system_defined, but it DEFAULTS TO TRUE:
-- a row inserted directly (by maludb_memory_admin, say) was marked built-in,
-- and with the filter below would silently never reach a dump. The two
-- functions that create types at runtime already pass false explicitly, and
-- every installed row is true, so only the default changes. A row inserted
-- directly before this release cannot be told apart and stays marked.
ALTER TABLE maludb_core."malu$svpor_subject_type" ALTER COLUMN system_defined SET DEFAULT false;
ALTER TABLE maludb_core."malu$svpor_verb_type" ALTER COLUMN system_defined SET DEFAULT false;

-- ---------------------------------------------------------------------
-- 2. Registered with a filter that excludes installed rows.
-- ---------------------------------------------------------------------
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$audit_event"', 'WHERE owner_schema <> ''maludb_core''');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_server"', 'WHERE owner_schema <> ''maludb_core''');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_tool"', 'WHERE owner_schema <> ''maludb_core''');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_tool_external_exec"', 'WHERE tool_id IN (SELECT tool_id FROM maludb_core."malu$mc2db_tool" WHERE owner_schema <> ''maludb_core'')');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_tool_mcp_proxy"', 'WHERE tool_id IN (SELECT tool_id FROM maludb_core."malu$mc2db_tool" WHERE owner_schema <> ''maludb_core'')');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_tool_sql_function"', 'WHERE tool_id IN (SELECT tool_id FROM maludb_core."malu$mc2db_tool" WHERE owner_schema <> ''maludb_core'')');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$metric_definition"', 'WHERE NOT system_defined');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$rest_endpoint"', 'WHERE owner_schema <> ''maludb_core''');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$retry_policy"', 'WHERE NOT system_defined');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$safety_policy"', 'WHERE NOT system_defined');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$svpor_subject_type"', 'WHERE NOT system_defined');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$svpor_verb_type"', 'WHERE NOT system_defined');

-- ---------------------------------------------------------------------
-- 3. Registered without a filter: no rows at install.
-- ---------------------------------------------------------------------
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$account"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$account_role"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$active_memory_pool"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$active_memory_pool_access"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$active_memory_pool_member"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$active_memory_pool_tag"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$ann_delta"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$ann_index"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$attribute_template"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$auth_token"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$auth_token_use"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$backup_manifest"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$backup_verification"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$bound_prompt"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$budget_policy"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$chat_index_append_audit"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$chat_index_tree"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$chat_message"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$chat_session"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$claim"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$community"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$community_membership"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$derivation_ledger"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$document"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$document_svpor_hint"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$document_tag"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$document_type"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$embedding_adapter"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$embedding_dirty"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$embedding_job"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$embedding_output"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$embedding_space"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$enabled_schema"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$enabled_schema_object"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$episode_object"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$episode_replay"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$episode_type"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$event"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$event_delivery"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$event_subscription"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$fact"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$fact_claim"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$index_migration"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$ingest_extraction"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$ingestion_checkpoint"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$ingestion_connector"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$jwt_signing_key"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$legal_hold"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$lifecycle_policy"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$listener_config"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$local_memory_node"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$local_model_capability"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$log_drain"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$log_drain_run"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$maut_score"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$maut_weight"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_invocation"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_prompt"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_resource"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$mc2db_tool_http_endpoint"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$memory"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$memory_detail_object"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$memory_extraction"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$memory_extraction_config"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$model_alias"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$model_provider"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$model_registry"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$model_request"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$model_response"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$node_conflict_record"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$node_sync_record"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$object_embedding"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$object_grant"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$page_index_tree"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$partition"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$payload_schema"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$pending_claim"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$pool_presence"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$pool_presence_event"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$preview_env"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$preview_env_seed"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$prompt_render"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$prompt_template"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$prompt_variable"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$query_hint"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$queue"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$queue_job"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$queue_lease"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$raw_ingest"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$reinforcement_event"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$relationship_edge"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$rest_invocation"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$retrieval_decision_audit"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$retrieval_envelope"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$role"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$schedule"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$schedule_run"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$secret"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$secret_use"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$secret_version"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$semantic_edge"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$session"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$session_context"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_access"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_embedding"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_execution_record"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_execution_step"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_file"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_keyword"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_package"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_state"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_subject"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_transition"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$skill_verb"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$source_object"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$source_object_reference"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$source_package"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$source_verification"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$storage_adapter"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$structure_pass_audit"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$supersession_edge"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$svpor_attribute"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$svpor_predicate"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$svpor_statement"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$svpor_subject"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$svpor_subject_relationship_edge"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$svpor_verb"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$vector_chunk"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$vector_compartment"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$vector_demo"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$vector_index_status"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$vector_subject"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$vector_tombstone"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$vector_verb"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$verbatim_archive"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$workflow_candidate"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$workflow_cluster"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$workflow_cluster_member"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$workflow_step"', '');
SELECT pg_catalog.pg_extension_config_dump('maludb_core."malu$workflow_trace"', '');

-- ---------------------------------------------------------------------
-- 4. The sequences behind every registered table, read from the catalogue
--    here so none is missed by hand. Identity sequences included.
-- ---------------------------------------------------------------------
DO $reg$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT DISTINCT s.oid::regclass AS seq
          FROM pg_catalog.pg_extension e
          JOIN pg_catalog.pg_class t ON t.oid = ANY (e.extconfig)
          JOIN pg_catalog.pg_depend d ON d.refobjid = t.oid AND d.classid = 'pg_catalog.pg_class'::regclass
                                     AND d.deptype IN ('a', 'i')
          JOIN pg_catalog.pg_class s ON s.oid = d.objid AND s.relkind = 'S'
         WHERE e.extname = 'maludb_core'
    LOOP
        PERFORM pg_catalog.pg_extension_config_dump(r.seq, '');
    END LOOP;
END
$reg$;

-- ---------------------------------------------------------------------
-- 5. Version.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION maludb_core.maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.105.0'::text $body$;
