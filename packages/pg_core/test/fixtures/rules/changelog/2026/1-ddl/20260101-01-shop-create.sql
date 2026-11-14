--liquibase formatted sql

--changeset rx:20260101-01-shop-create
--comment: Schemat i tabela sklepu, bez roli właściciela (fixture).
CREATE SCHEMA shop;
CREATE TABLE shop.items (id uuid PRIMARY KEY, name text, price real);
CREATE VIEW shop.items_v AS SELECT id FROM shop.items;
ALTER TABLE shop.items ENABLE ROW LEVEL SECURITY;
CREATE POLICY items_p ON shop.items USING (session_user = 'x' OR platform.actor_id() IS NOT NULL);
