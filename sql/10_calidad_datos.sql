-- =============================================================================
-- 10_calidad_datos.sql — Auditoría previa al análisis (MySQL 8.0)
-- =============================================================================
-- Antes de reportar un solo número hay que saber qué tan sucio está el dato.
--
-- DIFERENCIA CON POSTGRESQL: MySQL no tiene la cláusula FILTER de los
-- agregados. Todo `COUNT(*) FILTER (WHERE cond)` se traduce a
-- `SUM(CASE WHEN cond THEN 1 ELSE 0 END)`. Hace lo mismo, se lee peor.
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 1.1 Panorama general
-- -----------------------------------------------------------------------------
SELECT
    (SELECT count(*) FROM dim_cliente)      AS clientes,
    (SELECT count(*) FROM dim_producto)     AS productos,
    (SELECT count(*) FROM fact_pedido)      AS pedidos,
    (SELECT count(*) FROM fact_pedido_item) AS lineas,
    (SELECT min(fecha) FROM fact_pedido)    AS desde,
    (SELECT max(fecha) FROM fact_pedido)    AS hasta;

-- -----------------------------------------------------------------------------
-- 1.2 Impacto de no filtrar por estado
-- -----------------------------------------------------------------------------
SELECT
    count(*)                                                     AS pedidos_totales,
    SUM(estado = 'entregado')                                    AS entregados,
    SUM(estado = 'cancelado')                                    AS cancelados,
    SUM(estado = 'pendiente')                                    AS pendientes,
    ROUND(100 * SUM(estado <> 'entregado') / count(*), 2)        AS pct_no_facturable
FROM fact_pedido;

-- Cuánta plata se sobreestima si alguien olvida el filtro
SELECT
    ROUND(SUM(importe_neto))                                              AS total_sin_filtrar,
    ROUND(SUM(CASE WHEN estado = 'entregado'  THEN importe_neto END))     AS total_real,
    ROUND(SUM(CASE WHEN estado <> 'entregado' THEN importe_neto END))     AS sobreestimacion,
    ROUND(100 * SUM(CASE WHEN estado <> 'entregado' THEN importe_neto ELSE 0 END)
              / SUM(importe_neto), 2)                                     AS pct_error
FROM v_ventas;

-- -----------------------------------------------------------------------------
-- 1.3 Campos incompletos en la dimensión cliente
-- -----------------------------------------------------------------------------
SELECT
    count(*)                                          AS clientes,
    count(zona)                                       AS con_zona,
    count(*) - count(zona)                            AS sin_zona,
    ROUND(100 * (count(*) - count(zona)) / count(*), 2) AS pct_sin_zona
FROM dim_cliente;

-- -----------------------------------------------------------------------------
-- 1.4 Precios en cero
-- -----------------------------------------------------------------------------
SELECT
    count(*)                                                              AS lineas_precio_cero,
    ROUND(100 * count(*) / (SELECT count(*) FROM fact_pedido_item), 3)    AS pct,
    count(DISTINCT pedido_id)                                             AS pedidos_afectados
FROM fact_pedido_item
WHERE precio_unitario = 0;

-- -----------------------------------------------------------------------------
-- 1.5 Márgenes negativos
-- -----------------------------------------------------------------------------
-- Se distingue el error de carga (precio cero) del problema comercial
-- (descuento por debajo del costo). Son dos cosas distintas: una la arregla
-- sistemas, la otra el jefe de ventas.
-- -----------------------------------------------------------------------------
SELECT
    CASE WHEN precio_unitario = 0 THEN 'error de carga (precio 0)'
         ELSE 'descuento por debajo del costo'
    END                 AS causa,
    count(*)            AS lineas,
    ROUND(SUM(margen))  AS margen_perdido
FROM fact_pedido_item
WHERE margen < 0
GROUP BY causa
ORDER BY margen_perdido;

-- -----------------------------------------------------------------------------
-- 1.6 Posibles clientes duplicados
-- -----------------------------------------------------------------------------
-- MySQL no tiene array_agg(); se usa GROUP_CONCAT, que devuelve una cadena.
-- -----------------------------------------------------------------------------
SELECT
    razon_social,
    count(*)                                        AS veces,
    GROUP_CONCAT(cliente_id ORDER BY cliente_id)    AS ids,
    GROUP_CONCAT(DISTINCT localidad)                AS localidades
FROM dim_cliente
GROUP BY razon_social
HAVING count(*) > 1
ORDER BY veces DESC, razon_social
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 1.7 Registros huérfanos (integridad referencial)
-- -----------------------------------------------------------------------------
-- Con las FK declaradas debería dar 0. Se corre igual: en un ERP real muchas
-- veces las FK no existen y el anti-join es la única forma de saberlo.
-- NOT EXISTS es preferible a NOT IN, que se comporta mal si hay NULLs.
-- -----------------------------------------------------------------------------
SELECT 'pedidos sin cliente' AS control, count(*) AS registros
FROM fact_pedido p
WHERE NOT EXISTS (SELECT 1 FROM dim_cliente c WHERE c.cliente_id = p.cliente_id)
UNION ALL
SELECT 'items sin producto', count(*)
FROM fact_pedido_item i
WHERE NOT EXISTS (SELECT 1 FROM dim_producto pr WHERE pr.producto_id = i.producto_id)
UNION ALL
SELECT 'pedidos sin líneas', count(*)
FROM fact_pedido p
WHERE NOT EXISTS (SELECT 1 FROM fact_pedido_item i WHERE i.pedido_id = p.pedido_id);

-- -----------------------------------------------------------------------------
-- 1.8 Días sin actividad
-- -----------------------------------------------------------------------------
-- Solo se detectan cruzando contra dim_calendario: un GROUP BY sobre la tabla
-- de hechos nunca puede mostrar un día que no tiene filas.
-- -----------------------------------------------------------------------------
SELECT
    cal.nombre_dia,
    count(*) AS dias_sin_pedidos
FROM dim_calendario cal
LEFT JOIN fact_pedido p ON p.fecha = cal.fecha
WHERE p.pedido_id IS NULL
GROUP BY cal.nombre_dia, cal.dia_semana
ORDER BY cal.dia_semana;
