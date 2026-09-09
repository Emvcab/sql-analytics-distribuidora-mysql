-- =============================================================================
-- 50_rfm_segmentacion.sql — Segmentación RFM de la cartera (MySQL 8.0)
-- =============================================================================
-- Pregunta de negocio: ¿a quién llamo primero el lunes a la mañana?
--
-- RFM puntúa a cada cliente en tres ejes:
--   R (recencia)   — cuántos días hace que no compra
--   F (frecuencia) — cuántos pedidos hizo
--   M (monto)      — cuánto margen dejó
-- Cada eje se divide en quintiles con NTILE(5). En recencia el puntaje se
-- invierte: menos días sin comprar = mejor.
--
-- La ventaja sobre un ranking por facturación es que separa al cliente grande
-- que sigue comprando del cliente grande que se está yendo. Los dos facturan
-- parecido; solo uno necesita una llamada urgente.
--
-- DIFERENCIA CON POSTGRESQL: MySQL no admite CTEs en la definición de una
-- vista, así que v_rfm se arma con subconsultas anidadas en lugar de WITH.
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 5.1 Vista con el cálculo del RFM y el segmento
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_rfm AS
SELECT
    p.*,
    p.r * 100 + p.f * 10 + p.m AS codigo_rfm,
    CASE
        WHEN p.r >= 4 AND p.f >= 4 AND p.m >= 4 THEN 'Campeones'
        WHEN p.r >= 3 AND p.f >= 3 AND p.m >= 3 THEN 'Leales'
        WHEN p.r >= 4 AND p.f <= 2              THEN 'Nuevos / Prometedores'
        WHEN p.r <= 2 AND p.f >= 4 AND p.m >= 4 THEN 'En riesgo (alto valor)'
        WHEN p.r <= 2 AND p.f >= 3              THEN 'En riesgo'
        WHEN p.r <= 2 AND p.f <= 2              THEN 'Dormidos'
        ELSE 'Ocasionales'
    END AS segmento
FROM (
    SELECT
        b.*,
        -- recencia invertida: DESC porque menos días es mejor puntaje
        NTILE(5) OVER (ORDER BY b.recencia_dias DESC) AS r,
        NTILE(5) OVER (ORDER BY b.frecuencia ASC)     AS f,
        NTILE(5) OVER (ORDER BY b.monto ASC)          AS m
    FROM (
        SELECT
            v.cliente_id,
            v.razon_social,
            v.canal,
            v.localidad,
            DATEDIFF((SELECT MAX(fecha) FROM fact_pedido WHERE estado = 'entregado'),
                     MAX(v.fecha))         AS recencia_dias,
            count(DISTINCT v.pedido_id)    AS frecuencia,
            SUM(v.importe_neto)            AS facturacion,
            SUM(v.margen)                  AS monto,
            MAX(v.fecha)                   AS ultima_compra
        FROM v_ventas v
        WHERE v.estado = 'entregado'
        GROUP BY v.cliente_id, v.razon_social, v.canal, v.localidad
    ) b
) p;

-- -----------------------------------------------------------------------------
-- 5.2 Tabla de segmentos con su acción comercial
-- -----------------------------------------------------------------------------
SELECT
    segmento,
    count(*)                                              AS clientes,
    ROUND(100 * count(*) / SUM(count(*)) OVER (), 1)      AS pct_cartera,
    ROUND(AVG(recencia_dias))                             AS recencia_prom_dias,
    ROUND(AVG(frecuencia), 1)                             AS pedidos_prom,
    ROUND(SUM(monto))                                     AS margen_total,
    ROUND(100 * SUM(monto) / SUM(SUM(monto)) OVER (), 1)  AS pct_margen,
    CASE segmento
        WHEN 'Campeones'              THEN 'Sostener: atención preferencial, primero en stock escaso'
        WHEN 'Leales'                 THEN 'Crecer: cross-sell de categorías que no compra'
        WHEN 'Nuevos / Prometedores'  THEN 'Consolidar: seguimiento en los primeros 90 días'
        WHEN 'En riesgo (alto valor)' THEN 'URGENTE: llamada del jefe de ventas esta semana'
        WHEN 'En riesgo'              THEN 'Recuperar: promo puntual y visita del vendedor'
        WHEN 'Dormidos'               THEN 'Reactivar o depurar de la cartera'
        ELSE                               'Mantener con esfuerzo bajo'
    END AS accion
FROM v_rfm
GROUP BY segmento
ORDER BY margen_total DESC;

-- -----------------------------------------------------------------------------
-- 5.3 Los 20 clientes en riesgo de mayor valor
-- -----------------------------------------------------------------------------
-- Esta es la lista que se le pasa al jefe de ventas, ordenada por lo que se
-- pierde si el cliente no vuelve.
-- -----------------------------------------------------------------------------
SELECT
    razon_social,
    canal,
    localidad,
    recencia_dias,
    frecuencia,
    ROUND(monto)      AS margen_historico,
    ROUND(monto / 24) AS margen_mensual_en_juego,
    ultima_compra
FROM v_rfm
WHERE segmento IN ('En riesgo (alto valor)', 'En riesgo')
ORDER BY monto DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 5.4 Distribución cruzada R x F
-- -----------------------------------------------------------------------------
-- Matriz de 5x5: dónde está parada la cartera. Idealmente el peso se concentra
-- arriba a la derecha (compran seguido y hace poco).
-- -----------------------------------------------------------------------------
SELECT
    r AS recencia_score,
    SUM(f = 1) AS f1,
    SUM(f = 2) AS f2,
    SUM(f = 3) AS f3,
    SUM(f = 4) AS f4,
    SUM(f = 5) AS f5,
    count(*)   AS total
FROM v_rfm
GROUP BY r
ORDER BY r DESC;

-- -----------------------------------------------------------------------------
-- 5.5 Valor del segmento por canal
-- -----------------------------------------------------------------------------
-- ¿Los supermercados son todos campeones y los kioscos todos ocasionales?
-- Sirve para decidir si conviene segmentar la estrategia por tipo de comercio.
-- -----------------------------------------------------------------------------
SELECT
    canal,
    count(*)                                        AS clientes,
    SUM(segmento = 'Campeones')                     AS campeones,
    SUM(segmento LIKE 'En riesgo%')                 AS en_riesgo,
    SUM(segmento = 'Dormidos')                      AS dormidos,
    ROUND(AVG(monto))                               AS margen_prom,
    ROUND(100 * SUM(segmento LIKE 'En riesgo%') / count(*), 1) AS pct_en_riesgo
FROM v_rfm
GROUP BY canal
ORDER BY margen_prom DESC;
