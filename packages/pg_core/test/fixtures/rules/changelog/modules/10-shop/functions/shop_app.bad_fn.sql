--liquibase formatted sql

--changeset rx:function-shop-app-wrong-id
--comment: Funkcja łamiąca reguły (fixture).
--rollback DROP FUNCTION shop_app.bad_fn;
DROP FUNCTION IF EXISTS shop_app.other_fn;
CREATE OR REPLACE FUNCTION shop_app.bad_fn(p_x money) RETURNS integer
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'x' USING ERRCODE = 'P0001';
END
$$;
