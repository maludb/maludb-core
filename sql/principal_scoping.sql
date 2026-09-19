\set ECHO all
\set VERBOSITY terse
\pset format unaligned
SET client_min_messages = WARNING;

CREATE EXTENSION IF NOT EXISTS maludb_core CASCADE;
SET search_path TO maludb_core, public;

-- =====================================================================
-- principal_scoping -- 0.106.0
--
-- Inside one tenant, a session that names a principal reads and writes only
-- the scopes that principal holds, at or under its sensitivity ceiling:
--   * no principal set = unrestricted, exactly as before;
--   * documents, source packages, episodes, memories, chat sessions and pools
--     through their views (row security, or the view's own predicate);
--   * the SECURITY DEFINER search / ingest workers, which bypass row security;
--   * writes through the stamp trigger, on every path;
--   * the session's scope list narrows and never widens; read-only refuses
--     writes; an unknown or disabled principal gets nothing;
--   * a principal-bound session cannot administer principals;
--   * maludb_memory_ingest_extraction carries its namespace;
--   * semantic_search leaves out the card of an episode out of scope.
-- =====================================================================

DO $body$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'mbp_user') THEN
        RAISE EXCEPTION 'Refusing to start principal_scoping test: role mbp_user already exists';
    END IF;
END;
$body$;

CREATE ROLE mbp_user NOLOGIN;
GRANT maludb_memory_executor TO mbp_user;
GRANT USAGE ON SCHEMA maludb_core TO mbp_user;
GRANT mbp_user TO CURRENT_USER;
CREATE SCHEMA mbp AUTHORIZATION mbp_user;

SET ROLE mbp_user;
SET search_path TO mbp, maludb_core, public;
SELECT object_count > 0 AS enabled FROM maludb_core.enable_memory_schema('mbp');

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- 1. The tenant itself (no principal) sets the scene.
-- ---------------------------------------------------------------------
SELECT maludb_principal_whoami();

SELECT maludb_principal_upsert('agent:44', 'agent', 'Sasha', 'agent:44') > 0 AS sasha;
SELECT maludb_principal_upsert('agent:45', 'agent', 'Seamus', 'agent:45') > 0 AS seamus;
SELECT maludb_principal_upsert('member:1', 'human', 'Owner', 'member:1', 'restricted') > 0 AS owner;
SELECT maludb_principal_upsert('agent:99', 'agent', 'Gone', 'agent:99', NULL, false) > 0 AS disabled_one;
SELECT maludb_principal_grant_scope('agent:44', 'dept:3', 'read') > 0 AS sasha_reads_dept3;
SELECT maludb_principal_grant_scope('agent:44', 'org', 'read') > 0 AS sasha_reads_org;
SELECT maludb_principal_grant_scope('agent:45', 'dept:4', 'write') > 0 AS seamus_writes_dept4;
SELECT maludb_principal_grant_scope('member:1', 'dept:3', 'write') > 0 AS owner_writes_dept3;
SELECT maludb_principal_grant_scope('member:1', 'org', 'write') > 0 AS owner_writes_org;
SELECT principal_ref, scope, access_level FROM maludb_principal_scope WHERE revoked_at IS NULL ORDER BY 1, 2;

-- one remembered fact per scope: a document + an embedded edge in that namespace
CREATE FUNCTION mbp.remember(p_title text, p_text text, p_namespace text, p_vec text) RETURNS bigint
LANGUAGE plpgsql AS $fn$
DECLARE
    v_doc bigint;
BEGIN
    v_doc := mbp.maludb_upload_document(p_title, p_text, 'note');
    PERFORM mbp.maludb_memory_ingest_edge(
        p_source_kind => 'document', p_source_id => v_doc,
        p_subject_text => 'Northwind', p_verb_text => 'pays',
        p_embedding => p_vec::maludb_core.malu_vector, p_embedding_model => 'test-model',
        p_source_span => p_text, p_namespace => p_namespace, p_document_id => v_doc);
    RETURN v_doc;
END;
$fn$;

SELECT mbp.remember('org fact',    'Northwind pays in 30 days.',          'org',      '[1, 0, 0]') AS doc_org \gset
SELECT mbp.remember('dept3 fact',  'Northwind pays Accounting by wire.',  'dept:3',   '[0.9, 0.1, 0]') AS doc_d3 \gset
SELECT mbp.remember('dept3 secret','Northwind pays a private rebate.',    'dept:3',   '[0.8, 0.2, 0]') AS doc_d3r \gset
SELECT mbp.remember('dept4 fact',  'Northwind pays Sales a commission.',  'dept:4',   '[0.7, 0.3, 0]') AS doc_d4 \gset
SELECT mbp.remember('legacy fact', 'Northwind pays on time.',             'default',  '[0.6, 0.4, 0]') AS doc_legacy \gset

-- the namespace of the first edge became the document's scope (and its source's)
SELECT d.title, d.scope, sp.scope AS source_scope
  FROM maludb_document d JOIN maludb_source_package sp USING (source_package_id)
 ORDER BY d.document_id;

UPDATE maludb_source_package SET sensitivity = 'restricted'
 WHERE source_package_id = (SELECT source_package_id FROM maludb_document WHERE document_id = :doc_d3r);

SELECT maludb_register_episode('meeting', 'Dept 3 standup', 'Accounting talked rebates', p_occurred_at => '2026-09-01T09:00:00Z') AS ep_d3 \gset
SELECT maludb_register_episode('meeting', 'Dept 4 standup', 'Sales talked commission', p_occurred_at => '2026-09-01T10:00:00Z') AS ep_d4 \gset
SELECT maludb_set_scope('episode', :ep_d3, 'dept:3') AS ep3_scoped, maludb_set_scope('episode', :ep_d4, 'dept:4') AS ep4_scoped;

SELECT maludb_chat_start('run:12 transcript') AS chat_44 \gset
SELECT maludb_chat_append_message(:chat_44, 'user', 'hello') > 0 AS said_hello;
SELECT maludb_set_scope('chat_session', :chat_44, 'agent:44') AS chat_scoped;
SELECT maludb_chat_start('run:13 transcript') AS chat_45 \gset
SELECT maludb_set_scope('chat_session', :chat_45, 'agent:45') AS chat45_scoped;

INSERT INTO maludb_memory_pool (pool_name, creation_kind, scope) VALUES ('dept3 close', 'sql', 'dept:3'), ('dept4 pipeline', 'sql', 'dept:4');
INSERT INTO maludb_memory (memory_kind, title, scope) VALUES ('core_memory', 'sasha profile', 'agent:44'), ('core_memory', 'seamus profile', 'agent:45');

-- unrestricted: everything
SELECT (SELECT count(*) FROM maludb_document) AS docs, (SELECT count(*) FROM maludb_episode) AS episodes,
       (SELECT count(*) FROM maludb_chat_session) AS chats, (SELECT count(*) FROM maludb_memory_pool) AS pools,
       (SELECT count(*) FROM maludb_memory) AS memories, (SELECT count(*) FROM maludb_source_package) AS sources;

-- ---------------------------------------------------------------------
-- 2. Sasha: her own scope, dept:3 and org -- read only outside her own.
-- ---------------------------------------------------------------------
SET maludb_core.principal_ref = 'agent:44';
SELECT maludb_principal_whoami();

SELECT title, scope FROM maludb_document ORDER BY document_id;          -- no dept:4, no default, no restricted
SELECT count(*) AS sources FROM maludb_source_package;
SELECT title, scope FROM maludb_episode ORDER BY episode_id;
SELECT chat_title FROM maludb_chat_session ORDER BY 1;
SELECT count(*) AS messages FROM maludb_chat_message;
SELECT pool_name FROM maludb_memory_pool ORDER BY 1;
SELECT title FROM maludb_memory ORDER BY 1;

-- search: a readable namespace answers, and the restricted source is dropped
SELECT source_text FROM maludb_memory_search('[1, 0, 0]'::malu_vector, 'Northwind', NULL, 'dept:3') ORDER BY rank_no;
SELECT source_text FROM maludb_vector_search('org', 'Northwind', NULL, '[1, 0, 0]'::malu_vector);
SELECT title FROM maludb_note_search(p_subject_like => ARRAY['northwind']) ORDER BY 1;

\set ON_ERROR_STOP off
-- a namespace she does not hold: refused, not silently empty
SELECT count(*) FROM maludb_memory_search('[1, 0, 0]'::malu_vector, 'Northwind', NULL, 'dept:4');
SELECT count(*) FROM maludb_vector_search('dept:4', 'Northwind', NULL, '[1, 0, 0]'::malu_vector);
-- writes: read access is not write access
SELECT mbp.remember('sneaky', 'Northwind pays Sasha.', 'dept:3', '[0.5, 0.5, 0]');
SELECT maludb_set_scope('document', :doc_d3, 'agent:44');
UPDATE maludb_document SET title = 'rewritten' WHERE document_id = :doc_d3;
DELETE FROM maludb_episode WHERE episode_id = :ep_d3;
SELECT maludb_forget_document(:doc_d3);
-- and she administers nobody, herself included
SELECT maludb_principal_grant_scope('agent:44', 'dept:4', 'write');
SELECT maludb_principal_upsert('agent:44', 'agent', 'Sasha', 'agent:44', 'prohibited');
\set ON_ERROR_STOP on

-- her own writes land in her home scope, stamped with her name whatever she claims
SELECT mbp.remember('sasha note', 'Northwind pays late in August.', 'agent:44', '[0.4, 0.6, 0]') AS doc_own \gset
INSERT INTO maludb_episode (episode_kind, title, principal_ref) VALUES ('meeting', 'Sasha planning', 'member:1');
SELECT d.title, d.scope, d.principal_ref FROM maludb_document d WHERE document_id = :doc_own;
SELECT title, scope, principal_ref FROM maludb_episode WHERE title = 'Sasha planning';

-- ---------------------------------------------------------------------
-- 3. The session's own list narrows the grants and never widens them.
-- ---------------------------------------------------------------------
SET maludb_core.principal_scopes = '["agent:44"]';
SELECT title FROM maludb_document ORDER BY document_id;
SET maludb_core.principal_scopes = '["dept:4", "org"]';
SELECT title FROM maludb_document ORDER BY document_id;
SET maludb_core.principal_scopes = 'not json';
SELECT count(*) AS unreadable_list_reads FROM maludb_document;
RESET maludb_core.principal_scopes;

SET maludb_core.principal_readonly = 'on';
\set ON_ERROR_STOP off
INSERT INTO maludb_episode (episode_kind, title) VALUES ('meeting', 'read-only write');
\set ON_ERROR_STOP on
SELECT count(*) AS readonly_still_reads FROM maludb_document;
RESET maludb_core.principal_readonly;

-- ---------------------------------------------------------------------
-- 4. Unknown and disabled principals get nothing at all.
-- ---------------------------------------------------------------------
SET maludb_core.principal_ref = 'agent:404';
SELECT (SELECT count(*) FROM maludb_document) AS docs, (SELECT count(*) FROM maludb_episode) AS episodes,
       (SELECT count(*) FROM maludb_memory) AS memories, (SELECT count(*) FROM maludb_source_package) AS sources;
SET maludb_core.principal_ref = 'agent:99';
SELECT (SELECT count(*) FROM maludb_document) AS docs, (SELECT count(*) FROM maludb_memory_pool) AS pools;
SELECT maludb_principal_whoami() -> 'read_scopes' AS disabled_scopes;

-- ---------------------------------------------------------------------
-- 5. The owner: a higher ceiling, and write where Sasha could only read.
-- ---------------------------------------------------------------------
SET maludb_core.principal_ref = 'member:1';
SELECT title FROM maludb_document ORDER BY document_id;
SELECT source_text FROM maludb_memory_search('[1, 0, 0]'::malu_vector, 'Northwind', NULL, 'dept:3') ORDER BY rank_no;
UPDATE maludb_document SET title = 'dept3 fact (checked)' WHERE document_id = :doc_d3;
SELECT title, principal_ref FROM maludb_document WHERE document_id = :doc_d3;
-- "remember this in dept:3": her fresh upload leaves her home scope for the namespace of its first edge
SELECT mbp.remember('owner dept3 note', 'Northwind pays Accounting quarterly.', 'dept:3', '[0.3, 0.7, 0]') AS doc_owner_d3 \gset
SELECT d.title, d.scope, sp.scope AS source_scope, d.principal_ref
  FROM maludb_document d JOIN maludb_source_package sp USING (source_package_id)
 WHERE d.document_id = :doc_owner_d3;

-- ---------------------------------------------------------------------
-- 6. One-call ingest carries its namespace: the document and the event it
--    mints live there.
-- ---------------------------------------------------------------------
SELECT maludb_memory_ingest_extraction($json$
{
  "document": {"title": "Quarter close", "content_text": "Accounting closed Q3 on October 4, 2026."},
  "subjects": [{"key": "q3", "name": "Q3 close", "type": "event", "occurred_at": "2026-10-04T00:00:00Z",
                "description": "Accounting closed the third quarter"}],
  "edges": [{"subject": "$source", "verb": "describe", "object": "q3"}]
}
$json$::jsonb, p_namespace => 'dept:3') -> 'created' ->> 'episodes' AS episodes_created;
SELECT title, scope, principal_ref FROM maludb_document WHERE title = 'Quarter close';
SELECT title, scope FROM maludb_episode WHERE title = 'Q3 close';
\set ON_ERROR_STOP off
SELECT maludb_memory_ingest_extraction('{"document": {"title": "x", "content_text": "y"}}'::jsonb, p_namespace => 'dept:4');
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- 7. semantic_search: the card of an episode out of scope is left out.
-- ---------------------------------------------------------------------
RESET maludb_core.principal_ref;
SELECT maludb_register_object_embedding('subject', (SELECT subject_id FROM maludb_episode WHERE episode_id = :ep_d3),
           '\x0000803f0000000000000000'::bytea, 3, 'test-space') > 0 AS ep3_embedded;
SELECT maludb_register_object_embedding('subject', (SELECT subject_id FROM maludb_episode WHERE episode_id = :ep_d4),
           '\x0000803f0000000000000000'::bytea, 3, 'test-space') > 0 AS ep4_embedded;
SELECT count(*) AS tenant_sees FROM maludb_semantic_search('\x0000803f0000000000000000'::bytea, ARRAY['subject'], 10, 'test-space');
SET maludb_core.principal_ref = 'agent:44';
SELECT label FROM maludb_semantic_search('\x0000803f0000000000000000'::bytea, ARRAY['subject'], 10, 'test-space');

-- ---------------------------------------------------------------------
-- 8. A revoked grant stops working at once.
-- ---------------------------------------------------------------------
RESET maludb_core.principal_ref;
SELECT maludb_principal_revoke_scope('agent:44', 'dept:3') AS revoked;
SET maludb_core.principal_ref = 'agent:44';
SELECT title FROM maludb_document ORDER BY document_id;
RESET maludb_core.principal_ref;

-- ---------------------------------------------------------------------
-- 9. Nothing above answers about a schema the session cannot use.
-- ---------------------------------------------------------------------
RESET ROLE;
CREATE ROLE mbp_other NOLOGIN;
GRANT USAGE ON SCHEMA maludb_core TO mbp_other;
SET ROLE mbp_other;
SET maludb_core.principal_ref = 'member:1';
SELECT maludb_core._principal_scopes_for_schema('mbp', 'read') AS other_tenant_learns;
RESET maludb_core.principal_ref;
RESET ROLE;

-- ---------------------------------------------------------------------
-- Teardown.
-- ---------------------------------------------------------------------
SET search_path TO maludb_core, public;
DO $body$
DECLARE
    v_table text;
BEGIN
    DELETE FROM maludb_core."malu$vector_chunk"
     WHERE compartment_id IN (SELECT compartment_id FROM maludb_core."malu$vector_compartment" WHERE owner_schema = 'mbp');
    FOREACH v_table IN ARRAY ARRAY[
        'malu$vector_compartment', 'malu$vector_subject', 'malu$vector_verb',
        'malu$object_embedding', 'malu$embedding_dirty', 'malu$semantic_edge',
        'malu$chat_message', 'malu$chat_session',
        'malu$active_memory_pool', 'malu$memory',
        'malu$svpor_attribute', 'malu$svpor_statement',
        'malu$document', 'malu$episode_object', 'malu$source_package',
        'malu$svpor_subject', 'malu$svpor_verb',
        'malu$principal_scope', 'malu$principal',
        'malu$enabled_schema_object', 'malu$enabled_schema']
    LOOP
        EXECUTE format('DELETE FROM maludb_core.%I WHERE %s = $1', v_table,
                       CASE WHEN v_table LIKE 'malu$enabled%' THEN 'schema_name' ELSE 'owner_schema' END)
        USING 'mbp'::name;
    END LOOP;
END;
$body$;
DROP SCHEMA IF EXISTS mbp CASCADE;
DROP OWNED BY mbp_user;
DROP OWNED BY mbp_other;
DROP ROLE mbp_user;
DROP ROLE mbp_other;
