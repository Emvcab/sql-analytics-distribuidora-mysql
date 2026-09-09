-- =============================================================================
-- 40_pareto_abc.sql — Concentración de la facturación y curva ABC (MySQL 8.0)
-- =============================================================================
-- Pregunta de negocio: ¿qué porcentaje de clientes explica el 80% de la venta?
-- ¿Cuántos SKUs podríamos discontinuar sin que se note?
--
-- La respuesta cambia cómo se asigna la fuerza de venta y qué se compra.
--
-- Técnicas: suma acumulada con SUM() OVER (ORDER BY ... ROWS UNBOUNDED
-- PRECEDING), porcentaje sobre total con SUM() OVER (), clasificación con CASE.
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 4.1 Curva ABC de clientes
-- -----------------------------------------------------------------------------
-- A = hasta el 80% acumulado del margen | B = del 80 al 95% | C = el resto.
-- Se clasifica por MARGEN, no por facturación: un cliente que compra mucho con
-- descuento máximo puede ser menos valioso que uno más chico sin descuento.
-- -----------------------------------------------------------------------------
WITH por_cliente AS (
    SELECT
        cliente_id, razon_social, canal, localidad,
        SUM(importe_neto) AS facturacion,
        SUM(margen)       AS margen
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY cliente_id, razon_social, canal, localidad
),
acumulado AS (
    SELECT
        pc.*,
        SUM(margen) OVER (ORDER BY margen DESC
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS margen_acum,
        SUM(margen) OVER ()                      AS margen_total,
        ROW_NUMBER() OVER (ORDER BY margen DESC) AS puesto,
        COUNT(*) OVER ()                         AS clientes_total
    FROM por_cliente pc
)
SELECT
    puesto,
    razon_social,
    canal,
    localidad,
    ROUND(facturacion)                          AS facturacion,
    ROUND(margen)                               AS margen,
    ROUND(100 * margen_acum / margen_total, 1)  AS pct_margen_acum,
    ROUND(100 * puesto / clientes_total, 1)     AS pct_clientes_acum,
    CASE
        WHEN 100 * margen_acum / margen_total <= 80 THEN 'A'
        WHEN 100 * margen_acum / margen_total <= 95 THEN 'B'
        ELSE 'C'
    END AS clase
FROM acumulado
ORDER BY puesto
LIMIT 25;

-- -----------------------------------------------------------------------------
-- 4.2 Resumen de la curva ABC de clientes
-- -----------------------------------------------------------------------------
WITH por_cliente AS (
    SELECT cliente_id, SUM(margen) AS margen, SUM(importe_neto) AS facturacion
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY cliente_id
),
acumulado AS (
    SELECT
        cliente_id, margen, facturacion,
        100 * SUM(margen) OVER (ORDER BY margen DESC
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            / SUM(margen) OVER () AS pct_acum
    FROM por_cliente
),
clasificado AS (
    SELECT *,
           CASE WHEN pct_acum <= 80 THEN 'A'
                WHEN pct_acum <= 95 THEN 'B'
                ELSE 'C' END AS clase
    FROM acumulado
)
SELECT
    clase,
    count(*)                                           AS clientes,
    ROUND(100 * count(*) / SUM(count(*)) OVER (), 1)   AS pct_clientes,
    ROUND(SUM(facturacion))                            AS facturacion,
    ROUND(SUM(margen))                                 AS margen,
    ROUND(100 * SUM(margen) / SUM(SUM(margen)) OVER (), 1) AS pct_margen,
    ROUND(AVG(margen))                                 AS margen_promedio
FROM clasificado
GROUP BY clase
ORDER BY clase;

-- -----------------------------------------------------------------------------
-- 4.3 Curva ABC de productos
-- -----------------------------------------------------------------------------
-- Los SKUs clase C son candidatos a discontinuar: ocupan depósito, capital
-- inmovilizado y espacio en la lista de preventa.
-- -----------------------------------------------------------------------------
WITH por_producto AS (
    SELECT
        producto_id, producto, categoria,
        SUM(cantidad)     AS unidades,
        SUM(importe_neto) AS facturacion
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY producto_id, producto, categoria
),
acumulado AS (
    SELECT *,
           100 * SUM(facturacion) OVER (ORDER BY facturacion DESC
                                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
               / SUM(facturacion) OVER () AS pct_acum
    FROM por_producto
),
clasificado AS (
    SELECT *,
           CASE WHEN pct_acum <= 80 THEN 'A'
                WHEN pct_acum <= 95 THEN 'B'
                ELSE 'C' END AS clase
    FROM acumulado
)
SELECT
    clase,
    count(*)                                          AS skus,
    ROUND(100 * count(*) / SUM(count(*)) OVER (), 1)  AS pct_skus,
    ROUND(SUM(facturacion))                           AS facturacion,
    ROUND(100 * SUM(facturacion) / SUM(SUM(facturacion)) OVER (), 1) AS pct_facturacion,
    SUM(unidades)                                     AS unidades
FROM clasificado
GROUP BY clase
ORDER BY clase;

-- -----------------------------------------------------------------------------
-- 4.4 El número de Pareto exacto
-- -----------------------------------------------------------------------------
-- "El 20/80" es un slogan. Acá se calcula el número real de esta empresa:
-- qué porcentaje de clientes hace falta para llegar al 80% del margen.
-- -----------------------------------------------------------------------------
WITH por_cliente AS (
    SELECT cliente_id, SUM(margen) AS margen
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY cliente_id
),
acumulado AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY margen DESC) AS puesto,
        COUNT(*)     OVER ()                     AS total_clientes,
        100 * SUM(margen) OVER (ORDER BY margen DESC
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            / SUM(margen) OVER ()                AS pct_acum
    FROM por_cliente
),
umbrales AS (
    SELECT 50 AS pct UNION ALL SELECT 80 UNION ALL SELECT 90 UNION ALL SELECT 95
)
SELECT
    u.pct                                            AS pct_margen_objetivo,
    MIN(a.puesto)                                    AS clientes_necesarios,
    ROUND(100 * MIN(a.puesto) / MAX(a.total_clientes), 1) AS pct_de_la_cartera
FROM acumulado a
CROSS JOIN umbrales u
WHERE a.pct_acum >= u.pct
GROUP BY u.pct
ORDER BY u.pct;
