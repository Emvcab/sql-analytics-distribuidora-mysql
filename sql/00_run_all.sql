-- =============================================================================
-- 00_run_all.sql — Carga completa desde cero (MySQL 8.0)
-- =============================================================================
-- Desde MySQL Workbench:
--   File > Open SQL Script... > elegir este archivo > ejecutar con el rayo.
--   OJO: Workbench NO soporta el comando SOURCE. Si lo abrís desde ahí,
--   cargá y ejecutá los cuatro scripts de abajo uno por uno.
--
-- Desde la consola mysql (ahí SOURCE sí funciona):
--   mysql -u root -p
--   SOURCE /ruta/completa/sql/00_run_all.sql;
-- =============================================================================

SOURCE 01_schema.sql;
SOURCE 02_seed.sql;
SOURCE 03_indices.sql;
SOURCE 90_vistas.sql;

SELECT
    (SELECT count(*) FROM mayorista.dim_cliente)      AS clientes,
    (SELECT count(*) FROM mayorista.dim_producto)     AS productos,
    (SELECT count(*) FROM mayorista.fact_pedido)      AS pedidos,
    (SELECT count(*) FROM mayorista.fact_pedido_item) AS lineas;
