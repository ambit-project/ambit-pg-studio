--liquibase formatted sql

--changeset shop:view-sales-app-order-list runOnChange:true
--comment: Lista zamówień z nazwą klienta.
CREATE OR REPLACE VIEW sales_app.order_list AS
SELECT o.id, c.name AS customer_name, o.note
FROM sales.orders AS o
JOIN sales.customers AS c ON c.id = o.customer_id;
