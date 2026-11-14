--liquibase formatted sql

--changeset fx:20260101-04-billing-create-tables
--comment: Faktury.
SET LOCAL ROLE fx_owner;
CREATE TABLE billing.invoices (id uuid PRIMARY KEY, order_id uuid NOT NULL REFERENCES orders.orders (id));
RESET ROLE;
