--liquibase formatted sql

--changeset rx:20260101-02-shop-rls
--comment: Druga tabela z RLS i FORCE (fixture).
SET LOCAL ROLE rx_owner;
CREATE TABLE shop.tags (id uuid PRIMARY KEY);
ALTER TABLE shop.tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop.tags FORCE ROW LEVEL SECURITY;
RESET ROLE;
