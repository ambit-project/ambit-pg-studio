--liquibase formatted sql

--changeset rx:procedure-other-app-bad-proc runOnChange:true splitStatements:false
--comment: Procedura w złym schemacie, z COMMIT i blokiem EXCEPTION (fixture).
SET LOCAL ROLE rx_owner;
CREATE OR REPLACE PROCEDURE other_app.bad_proc()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor_id uuid := platform.require_actor_id();
BEGIN
    COMMIT;
EXCEPTION WHEN others THEN
    NULL;
END
$$;
RESET ROLE;
