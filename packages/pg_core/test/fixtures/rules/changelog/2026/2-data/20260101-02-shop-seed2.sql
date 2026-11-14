--liquibase formatted sql

--changeset rx:20260101-02-shop-seed2
--comment: NO FORCE bez przywrócenia FORCE (fixture).
SET LOCAL ROLE rx_owner;
ALTER TABLE shop.tags NO FORCE ROW LEVEL SECURITY;
DELETE FROM shop.tags;
RESET ROLE;
