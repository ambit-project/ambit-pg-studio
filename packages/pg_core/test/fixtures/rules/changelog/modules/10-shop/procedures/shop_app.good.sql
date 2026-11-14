--liquibase formatted sql

--changeset rx:procedure-shop-app-good runOnChange:true splitStatements:false
--comment: Procedura zgodna z regułami (fixture).
SET LOCAL ROLE rx_owner;
CREATE OR REPLACE PROCEDURE shop_app.good(p_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor_id uuid := platform.require_actor_id();
BEGIN
    UPDATE shop.items SET name = name WHERE id = p_id;
END
$$;
RESET ROLE;
