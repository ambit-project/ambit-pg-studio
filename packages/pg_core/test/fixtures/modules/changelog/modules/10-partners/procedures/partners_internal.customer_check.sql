--liquibase formatted sql

--changeset fx:procedure-partners-internal-customer-check runOnChange:true splitStatements:false
--comment: Sprawdzenie klienta - wnętrze modułu partners.
SET LOCAL ROLE fx_owner;
CREATE OR REPLACE PROCEDURE partners_internal.customer_check(p_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- U1101 (404): klient nie istnieje.
    IF NOT EXISTS (SELECT 1 FROM partners.customers AS c WHERE c.id = p_id) THEN
        RAISE EXCEPTION 'The customer does not exist.' USING ERRCODE = 'U1101';
    END IF;
END
$$;
RESET ROLE;
