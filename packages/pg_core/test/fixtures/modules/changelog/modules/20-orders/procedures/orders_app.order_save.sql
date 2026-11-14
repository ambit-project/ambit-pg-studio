--liquibase formatted sql

--changeset fx:procedure-orders-app-order-save runOnChange:true splitStatements:false
--comment: Zapis zamówienia - narusza granice: cudza tabela, cudze _internal, tabela platformy, moduł wyżej.
SET LOCAL ROLE fx_owner;
CREATE OR REPLACE PROCEDURE orders_app.order_save(p_id uuid, p_customer_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor_id uuid := platform.actor_id();
    v_name text;
BEGIN
    SELECT l.name INTO v_name FROM partners_app.customer_list AS l WHERE l.id = p_customer_id;
    SELECT c.name INTO v_name FROM partners.customers AS c WHERE c.id = p_customer_id;
    CALL partners_internal.customer_check(p_customer_id);
    PERFORM s.value FROM platform.settings AS s;
    CALL billing_app.invoice_create(p_id);
    -- U1101 (404): zamówienie nie istnieje.
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The order does not exist.' USING ERRCODE = 'U1101';
    END IF;
    INSERT INTO orders.orders (id, customer_id) VALUES (p_id, p_customer_id);
END
$$;
RESET ROLE;
