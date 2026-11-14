--liquibase formatted sql

--changeset shop:function-sales-app-order-total runOnChange:true splitStatements:false
--comment: Suma zamówienia (dwie wersje: bez i z podatkiem).
CREATE OR REPLACE FUNCTION sales_app.order_total(p_id uuid) RETURNS numeric
LANGUAGE sql STABLE
AS $$
    SELECT count(*)::numeric FROM sales.orders AS o WHERE o.id = p_id
$$;

CREATE OR REPLACE FUNCTION sales_app.order_total(p_id uuid, p_with_tax boolean) RETURNS numeric
LANGUAGE sql STABLE
AS $$
    SELECT sales_app.order_total(p_id) * CASE WHEN p_with_tax THEN 1.23 ELSE 1 END
$$;
