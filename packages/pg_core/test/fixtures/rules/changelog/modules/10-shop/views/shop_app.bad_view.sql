--liquibase formatted sql

--changeset rx:view-shop-app-bad-view runOnChange:true splitStatements:false
SET LOCAL ROLE rx_owner;
DROP VIEW IF EXISTS shop_app.bad_view;
CREATE VIEW shop_app.bad_view AS
SELECT i.*, platform.actor_id() AS actor, now()::timestamp AS at, '{}'::json AS doc FROM shop.items AS i;
