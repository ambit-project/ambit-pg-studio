--liquibase formatted sql

--changeset fx:20260101-03-orders-create-tables
--comment: Zamówienia: FK do klienta (moduł niżej - dozwolone) i do faktury (moduł wyżej - naruszenie).
SET LOCAL ROLE fx_owner;
CREATE TABLE orders.orders (
    id uuid PRIMARY KEY,
    customer_id uuid NOT NULL REFERENCES partners.customers (id),
    invoice_id uuid REFERENCES billing.invoices (id)
);
RESET ROLE;
