--liquibase formatted sql

--changeset fx:view-partners-app-customer-list runOnChange:true splitStatements:false
--comment: Lista klientów - kontrakt modułu partners.
SET LOCAL ROLE fx_owner;
CREATE OR REPLACE VIEW partners_app.customer_list AS
SELECT c.id, c.name FROM partners.customers AS c;
RESET ROLE;
