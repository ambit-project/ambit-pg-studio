--liquibase formatted sql

--changeset fx:20260101-02-partners-create-tables
--comment: Klienci.
SET LOCAL ROLE fx_owner;
CREATE TABLE partners.customers (id uuid PRIMARY KEY, name text NOT NULL);
RESET ROLE;
