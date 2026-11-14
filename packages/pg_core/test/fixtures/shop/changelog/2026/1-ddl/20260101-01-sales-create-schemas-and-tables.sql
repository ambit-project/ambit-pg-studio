--liquibase formatted sql

--changeset shop:20260101-01-sales-create-schemas-and-tables
--comment: Schematy i tabele sprzedaży (zażółć gęślą jaźń).
CREATE SCHEMA sales;
CREATE SCHEMA sales_app;

CREATE TABLE sales.customers (
    id uuid PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE sales.orders (
    id uuid PRIMARY KEY,
    customer_id uuid NOT NULL REFERENCES sales.customers (id),
    total numeric(12, 2) NOT NULL DEFAULT 0
);

CREATE TYPE sales_app.order_line_input AS (product text, quantity integer);

CREATE UNIQUE INDEX IF NOT EXISTS orders_customer_ix ON sales.orders (customer_id);

CREATE SEQUENCE sales.order_numbers;

CREATE EXTENSION IF NOT EXISTS pg_trgm;
