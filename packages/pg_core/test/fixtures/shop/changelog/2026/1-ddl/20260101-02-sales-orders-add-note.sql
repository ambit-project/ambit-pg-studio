--liquibase formatted sql

--changeset shop:20260101-02-sales-orders-add-note
--comment: Notatka do zamówienia.
ALTER TABLE sales.orders ADD COLUMN note text, DROP COLUMN total;

--changeset shop:20260101-02-sales-broken
--comment: Celowo błędny changeset - reszta pliku i projektu ma się zindeksować.
CREATE TABLE sales.broken (id uuid,, name text);

--changeset shop:20260101-02-sales-audit
CREATE FUNCTION sales.touch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.note := coalesce(NEW.note, '');
    RETURN NEW;
END $$;

CREATE TRIGGER orders_touch BEFORE UPDATE ON sales.orders FOR EACH ROW EXECUTE FUNCTION sales.touch();
