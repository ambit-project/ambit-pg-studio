--liquibase formatted sql

--changeset fx:function-platform-actor-id runOnChange:true splitStatements:false
--comment: Aktor z ustawienia transakcji.
SET LOCAL ROLE fx_owner;
CREATE OR REPLACE FUNCTION platform.actor_id() RETURNS uuid
LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('fx.actor_id', true), '')::uuid $$;
RESET ROLE;
