--liquibase formatted sql

--changeset fx:procedure-orders-app-order-cancel runOnChange:true splitStatements:false
--comment: Anulowanie zamówienia - zgodne z regułami (tylko własne tabele i platform.*()).
SET LOCAL ROLE fx_owner;
CREATE OR REPLACE PROCEDURE orders_app.order_cancel(p_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor_id uuid := platform.actor_id();
BEGIN
    DELETE FROM orders.orders WHERE id = p_id;
END
$$;
RESET ROLE;
