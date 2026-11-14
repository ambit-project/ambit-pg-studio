--liquibase formatted sql

--changeset fx:20260101-01-platform-create-schemas
--comment: Schematy wszystkich modułów i tabela platformy.
CREATE SCHEMA platform AUTHORIZATION fx_owner;
CREATE SCHEMA platform_app AUTHORIZATION fx_owner;
CREATE TABLE platform.settings (id uuid PRIMARY KEY, value text);
CREATE SCHEMA partners AUTHORIZATION fx_owner;
CREATE SCHEMA partners_app AUTHORIZATION fx_owner;
CREATE SCHEMA partners_internal AUTHORIZATION fx_owner;
CREATE SCHEMA orders AUTHORIZATION fx_owner;
CREATE SCHEMA orders_app AUTHORIZATION fx_owner;
CREATE SCHEMA billing AUTHORIZATION fx_owner;
CREATE SCHEMA billing_app AUTHORIZATION fx_owner;
