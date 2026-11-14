--liquibase formatted sql

--changeset rx:procedure-shop-app-no-actor runOnChange:true splitStatements:false
--comment: Procedura kontraktu bez platform.require_actor_id() (fixture).
SET LOCAL ROLE rx_owner;
CREATE OR REPLACE PROCEDURE shop_app.no_actor()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    NULL;
END
$$;
RESET ROLE;

--changeset rx:second
SELECT 1;
