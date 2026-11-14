--liquibase formatted sql

--changeset rx:20260101-01-shop-seed
--comment: Zapis do tabeli z RLS bez aktora (fixture).
SET LOCAL ROLE rx_owner;
INSERT INTO shop.items (id, name) VALUES ('00000000-0000-0000-0000-000000000001', 'a');
RESET ROLE;
