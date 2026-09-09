-- =============================================================================
-- 60_cohortes_retencion.sql — Retención de clientes por cohorte (MySQL 8.0)
-- =============================================================================
-- Pregunta de negocio: de los clientes que entraron en un mes dado, ¿cuántos
-- siguen comprando 1, 3 y 6 meses después?
--
-- Es la métrica que distingue crecimiento sano de crecimiento por reposición:
-- una empresa puede sumar 50 clientes por mes y no crecer nunca si pierde 50.
--
-- DIFERENCIAS CON POSTGRESQL:
--   date_trunc('month', x)  ->  DATE_FORMAT(x, '%Y-%m-01')
--   age() + EXTRACT         ->  TIMESTAMPDIFF(MONTH, a, b)
--   COUNT(*) FILTER (...)   ->  COUNT(DISTINCT CASE WHEN ... THEN ... END)
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 6.1 Matriz de retención (en cantidad de clientes)
-- -----------------------------------------------------------------------------
WITH primera_compra AS (
    SELECT
        cliente_id,
        DATE_FORMAT(MIN(fecha), '%Y-%m-01') AS cohorte
    FROM fact_pedido
    WHERE estado = 'entregado'
    GROUP BY cliente_id
),
con_offset AS (
    SELECT DISTINCT
        pc.cohorte,
        p.cliente_id,
        TIMESTAMPDIFF(MONTH, pc.cohorte, DATE_FORMAT(p.fecha, '%Y-%m-01')) AS mes_n
    FROM fact_pedido p
    JOIN primera_compra pc ON pc.cliente_id = p.cliente_id
    WHERE p.estado = 'entregado'
)
SELECT
    DATE_FORMAT(cohorte, '%Y-%m')                              AS cohorte,
    COUNT(DISTINCT CASE WHEN mes_n = 0  THEN cliente_id END)   AS m0,
    COUNT(DISTINCT CASE WHEN mes_n = 1  THEN cliente_id END)   AS m1,
    COUNT(DISTINCT CASE WHEN mes_n = 2  THEN cliente_id END)   AS m2,
    COUNT(DISTINCT CASE WHEN mes_n = 3  THEN cliente_id END)   AS m3,
    COUNT(DISTINCT CASE WHEN mes_n = 6  THEN cliente_id END)   AS m6,
    COUNT(DISTINCT CASE WHEN mes_n = 12 THEN cliente_id END)   AS m12
FROM con_offset
GROUP BY cohorte
ORDER BY cohorte;

-- -----------------------------------------------------------------------------
-- 6.2 Misma matriz, en porcentaje de retención
-- -----------------------------------------------------------------------------
-- Los valores absolutos no se pueden comparar entre cohortes de distinto
-- tamaño, así que se normaliza contra el mes 0 de cada cohorte.
--
-- Las cohortes jóvenes todavía no vivieron 6 o 12 meses. Mostrar 0% ahí sería
-- un error de lectura grave: se devuelve NULL para que la celda quede vacía y
-- nadie promedie un dato que no existe.
-- -----------------------------------------------------------------------------
WITH primera_compra AS (
    SELECT cliente_id, DATE_FORMAT(MIN(fecha), '%Y-%m-01') AS cohorte
    FROM fact_pedido WHERE estado = 'entregado'
    GROUP BY cliente_id
),
con_offset AS (
    SELECT DISTINCT
        pc.cohorte,
        p.cliente_id,
        TIMESTAMPDIFF(MONTH, pc.cohorte, DATE_FORMAT(p.fecha, '%Y-%m-01')) AS mes_n
    FROM fact_pedido p
    JOIN primera_compra pc ON pc.cliente_id = p.cliente_id
    WHERE p.estado = 'entregado'
),
matriz AS (
    SELECT
        cohorte,
        COUNT(DISTINCT CASE WHEN mes_n = 0  THEN cliente_id END) AS base,
        COUNT(DISTINCT CASE WHEN mes_n = 1  THEN cliente_id END) AS m1,
        COUNT(DISTINCT CASE WHEN mes_n = 3  THEN cliente_id END) AS m3,
        COUNT(DISTINCT CASE WHEN mes_n = 6  THEN cliente_id END) AS m6,
        COUNT(DISTINCT CASE WHEN mes_n = 12 THEN cliente_id END) AS m12
    FROM con_offset
    GROUP BY cohorte
),
corte AS (
    SELECT MAX(fecha) AS hoy FROM fact_pedido WHERE estado = 'entregado'
)
SELECT
    DATE_FORMAT(m.cohorte, '%Y-%m')                  AS cohorte,
    m.base                                           AS clientes_nuevos,
    ROUND(100 * m.m1 / NULLIF(m.base, 0), 1)         AS ret_mes_1_pct,
    CASE WHEN DATE_ADD(m.cohorte, INTERVAL 3 MONTH) <= c.hoy
         THEN ROUND(100 * m.m3 / NULLIF(m.base, 0), 1) END  AS ret_mes_3_pct,
    CASE WHEN DATE_ADD(m.cohorte, INTERVAL 6 MONTH) <= c.hoy
         THEN ROUND(100 * m.m6 / NULLIF(m.base, 0), 1) END  AS ret_mes_6_pct,
    CASE WHEN DATE_ADD(m.cohorte, INTERVAL 12 MONTH) <= c.hoy
         THEN ROUND(100 * m.m12 / NULLIF(m.base, 0), 1) END AS ret_mes_12_pct
FROM matriz m
CROSS JOIN corte c
ORDER BY m.cohorte;

-- -----------------------------------------------------------------------------
-- 6.3 Altas y bajas mes a mes
-- -----------------------------------------------------------------------------
-- Un cliente cuenta como "baja" cuando estuvo activo el mes anterior y no
-- compró en el actual. La diferencia entre altas y bajas es el crecimiento neto
-- de la cartera, que puede ser negativo aunque la facturación suba.
-- -----------------------------------------------------------------------------
WITH activos AS (
    SELECT DISTINCT
        cliente_id,
        DATE_FORMAT(fecha, '%Y-%m-01') AS mes
    FROM fact_pedido
    WHERE estado = 'entregado'
),
con_vecinos AS (
    SELECT
        cliente_id,
        mes,
        LAG(mes)  OVER (PARTITION BY cliente_id ORDER BY mes) AS mes_previo,
        LEAD(mes) OVER (PARTITION BY cliente_id ORDER BY mes) AS mes_siguiente
    FROM activos
)
SELECT
    DATE_FORMAT(mes, '%Y-%m') AS mes,
    count(*)                                                            AS activos,
    SUM(mes_previo IS NULL)                                             AS nuevos,
    SUM(mes_previo = DATE_SUB(mes, INTERVAL 1 MONTH))                   AS retenidos,
    SUM(mes_previo IS NOT NULL
        AND mes_previo < DATE_SUB(mes, INTERVAL 1 MONTH))               AS reactivados,
    SUM(mes_siguiente IS NULL
        OR mes_siguiente > DATE_ADD(mes, INTERVAL 1 MONTH))             AS se_van
FROM con_vecinos
GROUP BY mes
ORDER BY mes;

-- -----------------------------------------------------------------------------
-- 6.4 Valor de vida por cohorte
-- -----------------------------------------------------------------------------
-- ¿Los clientes que entraron en temporada alta valen lo mismo que los que
-- entraron en un mes normal? Si valen menos, la promo de fiestas está
-- atrayendo clientes de baja calidad.
-- -----------------------------------------------------------------------------
WITH primera_compra AS (
    SELECT cliente_id, DATE_FORMAT(MIN(fecha), '%Y-%m-01') AS cohorte
    FROM fact_pedido WHERE estado = 'entregado'
    GROUP BY cliente_id
),
valor AS (
    SELECT
        pc.cohorte,
        v.cliente_id,
        SUM(v.importe_neto)         AS facturacion,
        SUM(v.margen)               AS margen,
        count(DISTINCT v.pedido_id) AS pedidos
    FROM v_ventas v
    JOIN primera_compra pc ON pc.cliente_id = v.cliente_id
    WHERE v.estado = 'entregado'
    GROUP BY pc.cohorte, v.cliente_id
)
SELECT
    DATE_FORMAT(cohorte, '%Y-%m') AS cohorte,
    count(*)                      AS clientes,
    ROUND(AVG(pedidos), 1)        AS pedidos_prom,
    ROUND(AVG(facturacion))       AS facturacion_prom,
    ROUND(AVG(margen))            AS margen_prom_por_cliente,
    ROUND(SUM(margen))            AS margen_total_cohorte
FROM valor
GROUP BY cohorte
ORDER BY cohorte;
