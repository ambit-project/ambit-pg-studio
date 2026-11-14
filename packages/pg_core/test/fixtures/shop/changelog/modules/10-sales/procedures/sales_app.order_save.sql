--liquibase formatted sql

--changeset shop:procedure-sales-app-order-save runOnChange:true splitStatements:false
--comment: Zapis zamówienia klienta z liniami.
--comment: Druga linia komentarza.
SET LOCAL ROLE shop_owner;

CREATE OR REPLACE PROCEDURE sales_app.order_save(
    p_id uuid,
    p_customer_id uuid,
    p_lines sales_app.order_line_input[],
    INOUT p_row_version bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_line sales_app.order_line_input;
    v_order sales.orders%ROWTYPE;
BEGIN
    -- U1101 (404): klient nie istnieje.
    IF NOT EXISTS (SELECT 1 FROM sales.customers AS c WHERE c.id = p_customer_id) THEN
        RAISE EXCEPTION 'The customer does not exist.' USING ERRCODE = 'U1101';
    END IF;
    SELECT o.* INTO v_order FROM sales.orders AS o WHERE o.id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO sales.orders (id, customer_id) VALUES (p_id, p_customer_id);
    ELSE
        UPDATE sales.orders SET customer_id = p_customer_id WHERE id = p_id;
    END IF;
    PERFORM sales_app.order_total(p_id);
    PERFORM sales_app.order_total(p_id, true);
    CALL sales_app.missing_proc(p_id);
    p_row_version := nextval('sales.order_numbers');
END
$$;
