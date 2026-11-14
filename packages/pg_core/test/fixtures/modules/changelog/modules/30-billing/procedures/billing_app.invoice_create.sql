--liquibase formatted sql

--changeset fx:procedure-billing-app-invoice-create runOnChange:true splitStatements:false
--comment: Faktura do zamówienia - moduł wyżej może czytać kontrakt niższego.
SET LOCAL ROLE fx_owner;
CREATE OR REPLACE PROCEDURE billing_app.invoice_create(p_order_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_actor_id uuid := platform.actor_id();
BEGIN
    PERFORM l.id FROM partners_app.customer_list AS l;
    INSERT INTO billing.invoices (id, order_id) VALUES (gen_random_uuid(), p_order_id);
END
$$;
RESET ROLE;
