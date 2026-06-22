-- setup_role.sql: choose how approx_count gets its ANALYZE privilege.
--
-- approx_count ships SECURITY INVOKER, so the stale-path ANALYZE runs as the
-- caller, and the caller needs ANALYZE rights on the target relations (own them,
-- be superuser, hold per-table MAINTAIN, or be a member of pg_maintain). This
-- script sets that up with the least privilege your PostgreSQL version allows,
-- and tells you which model fits. Roles are cluster-global and are NOT created
-- or dropped by the extension, so this lives outside it; run it as a superuser
-- or the extension owner.
--
-- Usage (set the three names for your environment; defaults shown):
--   psql -v schema=approx_count -v owner_role=app_owner -v app_role=app_user \
--        -f setup_role.sql
--
-- TWO MODELS, with the tradeoffs spelled out:
--
--   MODEL A  SECURITY DEFINER owned by the table-owner role   (default; works 14+)
--     The role that already OWNS your application tables owns the approx_count
--     functions, which then run SECURITY DEFINER. Callers need only EXECUTE; the
--     ANALYZE runs as that owner, which could already ANALYZE those tables.
--     + Works on every supported version (14+); no pg_maintain needed.
--     + Callers never need maintenance privileges of their own.
--     + Bounded escalation: a caller can only trigger an ANALYZE the owner could
--       already run, plus a metrics write. ANALYZE leaks no data (reltuples is
--       already world-readable in pg_class, and pg_stats hides ANALYZE results
--       from anyone who cannot read the table).
--     - Actions audit as the owner, not the caller.
--     - The owner must own (or otherwise be able to ANALYZE) the target tables.
--       Never own these SECURITY DEFINER functions with a superuser.
--
--   MODEL B  least-privilege runner, SECURITY INVOKER          (PostgreSQL 17+)
--     A dedicated runner role holds pg_maintain (or per-table MAINTAIN) and runs
--     approx_count as itself. Callers must BE that role (or have it GRANTed).
--     + No SECURITY DEFINER, no escalation surface; fully audited as the runner.
--     + Per-table MAINTAIN is true least privilege.
--     - Requires PostgreSQL 17+ (MAINTAIN / pg_maintain do not exist before 17).
--     - The calling role itself must hold the maintenance grant.
--
-- Pre-17: there is no MAINTAIN privilege and no pg_maintain, so the only way a
-- non-owner can run ANALYZE is Model A (or a superuser). If autovacuum keeps your
-- statistics fresh, which is the recommended primary refresh on every version,
-- approx_count stays on its catalog-read fast path and never needs to refresh.

\set ON_ERROR_STOP on
-- Default any name not supplied with -v (each \if block must span its own lines).
\if :{?schema}
\else
  \set schema approx_count
\endif
\if :{?owner_role}
\else
  \set owner_role approx_count_owner
\endif
\if :{?app_role}
\else
  \set app_role app_user
\endif

-- Recommend a model for THIS server version.
DO $$
DECLARE v int := current_setting('server_version_num')::int;
BEGIN
    IF v >= 170000 THEN
        RAISE NOTICE 'PostgreSQL % detected: Model A (SECURITY DEFINER owned by the table owner) is applied below. Model B (a pg_maintain/MAINTAIN runner) is also available here and is the tightest least-privilege option for cross-owner reach.', current_setting('server_version');
    ELSE
        RAISE NOTICE 'PostgreSQL % detected: MAINTAIN/pg_maintain do not exist before 17, so Model A (SECURITY DEFINER owned by the table owner) is the only non-superuser way to grant ANALYZE rights. It is applied below.', current_setting('server_version');
    END IF;
    RAISE NOTICE 'The owner role you pass must own (or be able to ANALYZE) the target tables, and must NOT be a superuser.';
END $$;

-- ---------------------------------------------------------------------------
-- MODEL A (default): SECURITY DEFINER owned by the table-owner role.
-- :owner_role must already exist and own (or be able to ANALYZE) your tables.
--
-- Precondition: refuse to proceed if the owner role is missing or a superuser.
-- A superuser owner would turn every caller's EXECUTE into a superuser-level
-- ANALYZE, defeating the bounded-escalation property Model A relies on.
-- ---------------------------------------------------------------------------
-- psql does NOT interpolate :'owner_role' inside a $$ ... $$ block, so the role
-- name is carried into the check via a session setting set outside the block.
SET approx_count.setup_owner_role = :'owner_role';
DO $$
DECLARE
    target  text := current_setting('approx_count.setup_owner_role');
    is_super boolean;
BEGIN
    SELECT rolsuper INTO is_super FROM pg_roles WHERE rolname = target;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'refusing: owner_role % does not exist; create it (and have it own your tables) first', target;
    END IF;
    IF is_super THEN
        RAISE EXCEPTION 'refusing: owner_role % is a superuser; pick a non-superuser table owner', target;
    END IF;
END $$;
RESET approx_count.setup_owner_role;

-- Apply Model A atomically: OWNER + SECURITY DEFINER + grants in one transaction.
-- If any statement fails, the whole block rolls back to the shipped SECURITY
-- INVOKER default rather than stranding a half-converted state. ON_ERROR_STOP is
-- on, so a failure here aborts the transaction and leaves the functions untouched.
BEGIN;

ALTER FUNCTION :"schema".approx_count(regclass, interval, boolean)      OWNER TO :"owner_role";
ALTER FUNCTION :"schema".approx_count_info(regclass, interval, boolean) OWNER TO :"owner_role";
ALTER FUNCTION :"schema".approx_count(regclass, interval, boolean)      SECURITY DEFINER;
ALTER FUNCTION :"schema".approx_count_info(regclass, interval, boolean) SECURITY DEFINER;

-- The owner is the effective user under SECURITY DEFINER and the function bodies
-- reference the approx_count schema, so the owner needs USAGE on it too; without
-- this every call fails 'permission denied for schema'.
GRANT USAGE   ON SCHEMA :"schema" TO :"owner_role";

-- Callers need only EXECUTE and schema USAGE; the ledger write runs as the owner.
GRANT USAGE   ON SCHEMA :"schema" TO :"app_role";
GRANT EXECUTE ON FUNCTION :"schema".approx_count(regclass, interval, boolean)      TO :"app_role";
GRANT EXECUTE ON FUNCTION :"schema".approx_count_info(regclass, interval, boolean) TO :"app_role";
GRANT SELECT  ON :"schema".dashboard TO :"app_role";
GRANT SELECT, INSERT, UPDATE ON :"schema".metrics TO :"owner_role";

COMMIT;

-- ---------------------------------------------------------------------------
-- MODEL B (alternative, PostgreSQL 17+): least-privilege SECURITY INVOKER runner.
-- Leave the functions SECURITY INVOKER (the shipped default). If you already ran
-- Model A above and want B instead, first reset the security on both functions:
--   ALTER FUNCTION :"schema".approx_count(regclass, interval, boolean)      SECURITY INVOKER;
--   ALTER FUNCTION :"schema".approx_count_info(regclass, interval, boolean) SECURITY INVOKER;
-- then grant a dedicated runner the maintenance rights it needs:
--
-- CREATE ROLE approx_count_runner NOLOGIN;
-- GRANT USAGE   ON SCHEMA :"schema" TO approx_count_runner;
-- GRANT EXECUTE ON FUNCTION :"schema".approx_count(regclass, interval, boolean)      TO approx_count_runner;
-- GRANT EXECUTE ON FUNCTION :"schema".approx_count_info(regclass, interval, boolean) TO approx_count_runner;
-- GRANT SELECT, INSERT, UPDATE ON :"schema".metrics TO approx_count_runner;
-- GRANT SELECT ON :"schema".dashboard TO approx_count_runner;
-- -- Maintenance rights, pick one:
-- GRANT pg_maintain TO approx_count_runner;                                  -- any relation
-- -- GRANT MAINTAIN ON TABLE analytics.fact_events TO approx_count_runner;   -- per table, tightest
-- GRANT approx_count_runner TO app_user;                                     -- callers run as the runner
