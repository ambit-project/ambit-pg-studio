-- psql script, not a changeset
\set scale 1
INSERT INTO sales.customers (id, name)
SELECT gen_random_uuid(), 'c' || g FROM generate_series(1, (100 * :scale)::int) g;
