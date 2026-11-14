--liquibase formatted sql

--changeset shop:20260101-03-grants
GRANT EXECUTE ON PROCEDURE sales_app.order_save(uuid, uuid, sales_app.order_line_input[], bigint) TO ${app_role};
GRANT SELECT ON sales_app.order_list TO ${app_role};
