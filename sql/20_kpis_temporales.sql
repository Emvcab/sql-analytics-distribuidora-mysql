-- =============================================================================
-- 20_kpis_temporales.sql — Evolución del negocio mes a mes (MySQL 8.0)
-- =============================================================================
-- Pregunta de negocio: ¿estamos creciendo, y ese crecimiento es real o es
-- inflación? ¿qué meses concentran la venta?
--
-- Técnicas: LAG, window frame ROWS BETWEEN, SUM() OVER acumulado,
-- COUNT(DISTINCT) por período.
--
-- Las window functions existen en MySQL desde la versión 8.0. En MySQL 5.7
-- nada de este script funciona: había que emularlas con variables de sesión
-- (@prev := ...), que es la razón por la que tanto código viejo de MySQL se
-- ve tan raro.
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 2.1 Tablero mensual: facturación, margen, ticket y clientes activos
-- -----------------------------------------------------------------------------
WITH mensual AS (
    SELECT
        anio_mes,
        count(DISTINCT pedido_id)  AS pedidos,
        count(DISTINCT cliente_id) AS clientes_activos,
        SUM(cantidad)              AS unidades,
        SUM(importe_neto)          AS facturacion,
        SUM(margen)                AS margen
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY anio_mes
)
SELECT
    anio_mes,
    pedidos,
    clientes_activos,
    ROUND(facturacion)                      AS facturacion,
    ROUND(facturacion / pedidos)            AS ticket_promedio,
    ROUND(100 * margen / facturacion, 1)    AS margen_pct,
    -- variación contra el mes anterior
    ROUND(100 * (facturacion - LAG(facturacion) OVER (ORDER BY anio_mes))
              / LAG(facturacion) OVER (ORDER BY anio_mes), 1)      AS var_mom_pct,
    -- variación contra el mismo mes del año anterior (12 posiciones atrás)
    ROUND(100 * (facturacion - LAG(facturacion, 12) OVER (ORDER BY anio_mes))
              / LAG(facturacion, 12) OVER (ORDER BY anio_mes), 1)  AS var_yoy_pct,
    -- media móvil de 3 meses: suaviza el ruido y deja ver la tendencia
    ROUND(AVG(facturacion) OVER (ORDER BY anio_mes
                                 ROWS BETWEEN 2 PRECEDING AND CURRENT ROW))
                                                                   AS media_movil_3m,
    -- acumulado del período completo
    ROUND(SUM(facturacion) OVER (ORDER BY anio_mes
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))
                                                                   AS acumulado
FROM mensual
ORDER BY anio_mes;

-- -----------------------------------------------------------------------------
-- 2.2 ¿Crecimiento real o nominal?
-- -----------------------------------------------------------------------------
-- En un contexto inflacionario, facturar más en pesos no significa vender más.
-- Si los pesos suben y las unidades bajan, el negocio se está achicando.
-- -----------------------------------------------------------------------------
WITH mensual AS (
    SELECT anio_mes, SUM(importe_neto) AS pesos, SUM(cantidad) AS unidades
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY anio_mes
)
SELECT
    anio_mes,
    ROUND(100 * (pesos - LAG(pesos, 12) OVER (ORDER BY anio_mes))
              / LAG(pesos, 12) OVER (ORDER BY anio_mes), 1)          AS var_pesos_pct,
    ROUND(100 * (unidades - LAG(unidades, 12) OVER (ORDER BY anio_mes))
              / LAG(unidades, 12) OVER (ORDER BY anio_mes), 1)       AS var_unidades_pct,
    CASE
        WHEN LAG(unidades, 12) OVER (ORDER BY anio_mes) IS NULL THEN 'sin base'
        WHEN unidades > LAG(unidades, 12) OVER (ORDER BY anio_mes)
            THEN 'crecimiento real'
        ELSE 'crecimiento solo nominal'
    END AS lectura
FROM mensual
ORDER BY anio_mes;

-- -----------------------------------------------------------------------------
-- 2.3 Estacionalidad: peso de cada mes calendario
-- -----------------------------------------------------------------------------
SELECT
    nombre_mes,
    ROUND(SUM(importe_neto))                                          AS facturacion,
    ROUND(100 * SUM(importe_neto) / SUM(SUM(importe_neto)) OVER (), 1) AS pct_del_total,
    -- índice de estacionalidad: 100 = mes promedio
    ROUND(100 * SUM(importe_neto) / AVG(SUM(importe_neto)) OVER ())    AS indice
FROM v_ventas
WHERE estado = 'entregado'
GROUP BY nombre_mes, mes
ORDER BY mes;

-- -----------------------------------------------------------------------------
-- 2.4 Días de la semana: cuándo entra el pedido
-- -----------------------------------------------------------------------------
SELECT
    nombre_dia,
    count(DISTINCT pedido_id)  AS pedidos,
    ROUND(SUM(importe_neto))   AS facturacion,
    ROUND(100 * count(DISTINCT pedido_id)
              / SUM(count(DISTINCT pedido_id)) OVER (), 1) AS pct_pedidos
FROM v_ventas
WHERE estado = 'entregado'
GROUP BY nombre_dia, dia_semana
ORDER BY dia_semana;

-- -----------------------------------------------------------------------------
-- 2.5 Desempeño por vendedor con ranking
-- -----------------------------------------------------------------------------
SELECT
    vendedor,
    zona_vendedor,
    count(DISTINCT cliente_id)                            AS cartera_activa,
    count(DISTINCT pedido_id)                             AS pedidos,
    ROUND(SUM(importe_neto))                              AS facturacion,
    ROUND(SUM(importe_neto) / count(DISTINCT pedido_id))  AS ticket_promedio,
    ROUND(100 * SUM(margen) / SUM(importe_neto), 1)       AS margen_pct,
    RANK() OVER (ORDER BY SUM(importe_neto) DESC)         AS puesto_facturacion,
    RANK() OVER (ORDER BY SUM(margen) / SUM(importe_neto) DESC) AS puesto_rentabilidad
FROM v_ventas
WHERE estado = 'entregado'
GROUP BY vendedor, zona_vendedor
ORDER BY facturacion DESC;
