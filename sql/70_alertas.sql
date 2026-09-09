-- =============================================================================
-- 70_alertas.sql — Motor de alertas operativas (MySQL 8.0)
-- =============================================================================
-- Todo lo anterior describe el pasado. Esto genera acciones concretas para
-- mañana: una lista priorizada, con responsable y con el monto en juego.
--
-- Criterio de diseño: una alerta sin dueño y sin plata asociada no se ejecuta
-- nunca. Cada consulta devuelve las dos cosas.
--
-- DIFERENCIA CON POSTGRESQL: los LATERAL correlacionados se reemplazan por
-- subconsultas escalares y por window functions, que en MySQL rinden mejor.
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 7.1 Clientes dormidos: compraban seguido y dejaron de comprar
-- -----------------------------------------------------------------------------
-- No alcanza con "hace 60 días que no compra": un cliente que compra dos veces
-- por año no está dormido, está comprando normal. Se compara los días sin
-- comprar contra el intervalo HABITUAL de ese cliente en particular.
-- -----------------------------------------------------------------------------
WITH corte AS (
    SELECT MAX(fecha) AS hoy FROM fact_pedido WHERE estado = 'entregado'
),
dias_cliente AS (
    SELECT DISTINCT cliente_id, fecha
    FROM fact_pedido WHERE estado = 'entregado'
),
intervalos AS (
    SELECT
        cliente_id,
        fecha,
        DATEDIFF(fecha, LAG(fecha) OVER (PARTITION BY cliente_id ORDER BY fecha))
            AS dias_entre_compras
    FROM dias_cliente
),
perfil AS (
    SELECT
        i.cliente_id,
        ROUND(AVG(i.dias_entre_compras))                     AS intervalo_habitual,
        MAX(i.fecha)                                         AS ultima_compra,
        DATEDIFF((SELECT hoy FROM corte), MAX(i.fecha))      AS dias_sin_comprar,
        count(*)                                             AS compras
    FROM intervalos i
    GROUP BY i.cliente_id
    HAVING count(*) >= 5      -- se ignoran clientes sin historia suficiente
),
ultimo_vendedor AS (
    SELECT cliente_id, vendedor_id
    FROM (
        SELECT
            cliente_id, vendedor_id,
            ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY fecha DESC) AS rn
        FROM fact_pedido
    ) z
    WHERE rn = 1
),
margen_cliente AS (
    SELECT cliente_id, SUM(margen) / 24 AS margen_mensual
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY cliente_id
)
SELECT
    c.razon_social,
    c.canal,
    c.localidad,
    v.nombre                            AS vendedor_responsable,
    p.intervalo_habitual,
    p.dias_sin_comprar,
    ROUND(p.dias_sin_comprar / NULLIF(p.intervalo_habitual, 0), 1) AS veces_el_intervalo,
    ROUND(m.margen_mensual)             AS margen_mensual_en_riesgo
FROM perfil p
JOIN dim_cliente     c  ON c.cliente_id  = p.cliente_id
JOIN ultimo_vendedor uv ON uv.cliente_id = p.cliente_id
JOIN dim_vendedor    v  ON v.vendedor_id = uv.vendedor_id
JOIN margen_cliente  m  ON m.cliente_id  = p.cliente_id
WHERE p.dias_sin_comprar > GREATEST(p.intervalo_habitual * 3, 30)
ORDER BY margen_mensual_en_riesgo DESC
LIMIT 25;

-- -----------------------------------------------------------------------------
-- 7.2 Caída de compra: sigue comprando, pero mucho menos
-- -----------------------------------------------------------------------------
-- Más difícil de ver que un cliente que se va, y más frecuente: el comercio
-- empezó a comprarle a la competencia y reparte el pedido entre las dos.
-- Compara el último trimestre contra los tres anteriores del MISMO cliente.
-- -----------------------------------------------------------------------------
WITH corte AS (
    SELECT MAX(fecha) AS hoy FROM fact_pedido WHERE estado = 'entregado'
),
periodos AS (
    SELECT
        v.cliente_id,
        v.razon_social,
        v.canal,
        SUM(CASE WHEN v.fecha > DATE_SUB((SELECT hoy FROM corte), INTERVAL 90 DAY)
                 THEN v.importe_neto END) AS ult_trimestre,
        SUM(CASE WHEN v.fecha <= DATE_SUB((SELECT hoy FROM corte), INTERVAL 90 DAY)
                  AND v.fecha >  DATE_SUB((SELECT hoy FROM corte), INTERVAL 360 DAY)
                 THEN v.importe_neto END) / 3 AS trimestre_promedio_previo
    FROM v_ventas v
    WHERE v.estado = 'entregado'
    GROUP BY v.cliente_id, v.razon_social, v.canal
)
SELECT
    razon_social,
    canal,
    ROUND(trimestre_promedio_previo)  AS promedio_trimestral_previo,
    ROUND(ult_trimestre)              AS ultimo_trimestre,
    ROUND(100 * (ult_trimestre - trimestre_promedio_previo)
              / NULLIF(trimestre_promedio_previo, 0), 1) AS variacion_pct,
    ROUND(trimestre_promedio_previo - ult_trimestre)     AS caida_en_pesos
FROM periodos
WHERE trimestre_promedio_previo > 0
  AND ult_trimestre > 0                                  -- sigue comprando: no es baja
  AND ult_trimestre < trimestre_promedio_previo * 0.6    -- pero cayó más del 40%
ORDER BY caida_en_pesos DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 7.3 Cross-sell: categorías que el cliente NO compra y sus pares sí
-- -----------------------------------------------------------------------------
-- Anti-join con NOT EXISTS. La oportunidad se dimensiona con lo que gasta en
-- esa categoría un cliente promedio del mismo canal.
-- -----------------------------------------------------------------------------
WITH gasto_tipico AS (
    SELECT
        canal,
        categoria,
        SUM(importe_neto) / count(DISTINCT cliente_id) AS gasto_prom_por_cliente
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY canal, categoria
),
clientes_activos AS (
    SELECT DISTINCT cliente_id, razon_social, canal
    FROM v_ventas
    WHERE estado = 'entregado'
      AND fecha > (SELECT DATE_SUB(MAX(fecha), INTERVAL 90 DAY) FROM fact_pedido)
)
SELECT
    ca.razon_social,
    ca.canal,
    gt.categoria                      AS categoria_no_comprada,
    ROUND(gt.gasto_prom_por_cliente)  AS oportunidad_estimada
FROM clientes_activos ca
JOIN gasto_tipico gt ON gt.canal = ca.canal
WHERE NOT EXISTS (
    SELECT 1
    FROM v_ventas v
    WHERE v.cliente_id = ca.cliente_id
      AND v.categoria  = gt.categoria
      AND v.estado     = 'entregado'
)
ORDER BY oportunidad_estimada DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 7.4 Productos en caída sostenida
-- -----------------------------------------------------------------------------
-- Tres meses consecutivos de baja en unidades. Puede ser competencia, precio
-- mal puesto o faltante de stock; en cualquier caso hay que mirarlo.
-- -----------------------------------------------------------------------------
WITH mensual AS (
    SELECT
        producto_id, producto, categoria, anio_mes,
        SUM(cantidad) AS unidades
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY producto_id, producto, categoria, anio_mes
),
con_lags AS (
    SELECT
        m.*,
        LAG(unidades, 1) OVER (PARTITION BY producto_id ORDER BY anio_mes) AS m1,
        LAG(unidades, 2) OVER (PARTITION BY producto_id ORDER BY anio_mes) AS m2,
        LAG(unidades, 3) OVER (PARTITION BY producto_id ORDER BY anio_mes) AS m3,
        MAX(anio_mes)    OVER ()                                           AS ultimo_mes
    FROM mensual m
)
SELECT
    producto,
    categoria,
    m3       AS hace_3_meses,
    m2       AS hace_2_meses,
    m1       AS mes_anterior,
    unidades AS mes_actual,
    ROUND(100 * (unidades - m3) / NULLIF(m3, 0), 1) AS caida_pct
FROM con_lags
WHERE anio_mes = ultimo_mes
  AND unidades < m1 AND m1 < m2 AND m2 < m3
ORDER BY caida_pct
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 7.5 Tablero consolidado de alertas
-- -----------------------------------------------------------------------------
-- Todo junto, priorizado por impacto en pesos. Es la salida que consumiría un
-- dashboard o un envío automático por mail los lunes a la mañana.
-- -----------------------------------------------------------------------------
WITH corte AS (
    SELECT MAX(fecha) AS hoy FROM fact_pedido WHERE estado = 'entregado'
),
dormidos AS (
    SELECT
        'Cliente dormido'        AS tipo_alerta,
        c.razon_social           AS entidad,
        'Contactar en la semana' AS accion,
        SUM(v.margen) / 24       AS impacto_mensual
    FROM v_ventas v
    JOIN dim_cliente c ON c.cliente_id = v.cliente_id
    WHERE v.estado = 'entregado'
    GROUP BY c.cliente_id, c.razon_social
    HAVING MAX(v.fecha) < DATE_SUB((SELECT hoy FROM corte), INTERVAL 75 DAY)
       AND SUM(v.margen) > 0
),
margen_negativo AS (
    SELECT
        'Producto con margen negativo',
        pr.nombre,
        'Revisar precio de lista y descuentos',
        ABS(SUM(i.margen)) / 24
    FROM fact_pedido_item i
    JOIN dim_producto pr ON pr.producto_id = i.producto_id
    JOIN fact_pedido p   ON p.pedido_id    = i.pedido_id
    WHERE p.estado = 'entregado' AND i.precio_unitario > 0
    GROUP BY pr.producto_id, pr.nombre
    HAVING SUM(i.margen) < 0
),
descuento_alto AS (
    SELECT
        'Descuento excesivo',
        c.razon_social,
        'Revisar condición comercial con el vendedor',
        SUM(i.importe_bruto - i.importe_neto) / 24
    FROM fact_pedido_item i
    JOIN fact_pedido p ON p.pedido_id  = i.pedido_id
    JOIN dim_cliente c ON c.cliente_id = p.cliente_id
    WHERE p.estado = 'entregado'
    GROUP BY c.cliente_id, c.razon_social
    HAVING AVG(i.descuento_pct) > 0.09
),
todas AS (
    SELECT * FROM dormidos
    UNION ALL SELECT * FROM margen_negativo
    UNION ALL SELECT * FROM descuento_alto
)
SELECT
    tipo_alerta,
    entidad,
    accion,
    ROUND(impacto_mensual) AS impacto_mensual_pesos,
    ROW_NUMBER() OVER (ORDER BY impacto_mensual DESC) AS prioridad
FROM todas
ORDER BY impacto_mensual DESC
LIMIT 30;
