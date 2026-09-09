-- =============================================================================
-- 80_cross_sell.sql — Análisis de canasta (market basket) en SQL puro
-- MySQL 8.0+
-- =============================================================================
-- Pregunta de negocio: ¿qué productos se piden juntos? Sirve para armar combos,
-- ubicar productos en la lista de preventa y sugerir agregados al pedido.
--
-- Se calculan las tres métricas clásicas de reglas de asociación sin salir de
-- SQL:
--   soporte    — en qué % de los pedidos aparece el par
--   confianza  — de los que compraron A, qué % compró también B
--   lift       — cuántas veces más probable es B dado A, contra el azar.
--                lift > 1 indica asociación real; lift = 1 es independencia.
--
-- Técnica central: SELF JOIN de la tabla de líneas contra sí misma con
-- a.producto_id < b.producto_id, que evita contar (A,B) y (B,A) por separado.
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 8.1 Pares de productos más frecuentes, con lift
-- -----------------------------------------------------------------------------
WITH pedidos_validos AS (
    SELECT pedido_id FROM fact_pedido WHERE estado = 'entregado'
),
total AS (
    SELECT count(*) AS n_pedidos FROM pedidos_validos
),
frecuencia_individual AS (
    SELECT
        i.producto_id,
        count(DISTINCT i.pedido_id) AS pedidos
    FROM fact_pedido_item i
    JOIN pedidos_validos p ON p.pedido_id = i.pedido_id
    GROUP BY i.producto_id
),
pares AS (
    SELECT
        a.producto_id AS prod_a,
        b.producto_id AS prod_b,
        count(*)      AS pedidos_juntos
    FROM fact_pedido_item a
    JOIN fact_pedido_item b
      ON a.pedido_id   = b.pedido_id
     AND a.producto_id < b.producto_id      -- evita duplicar el par y auto-pares
    JOIN pedidos_validos p ON p.pedido_id = a.pedido_id
    GROUP BY a.producto_id, b.producto_id
    HAVING count(*) >= 25                   -- corte de ruido estadístico
)
SELECT
    pa.nombre                                                    AS producto_a,
    pb.nombre                                                    AS producto_b,
    pares.pedidos_juntos,
    ROUND(100 * pares.pedidos_juntos / t.n_pedidos, 2)           AS soporte_pct,
    ROUND(100 * pares.pedidos_juntos / fa.pedidos, 1)            AS confianza_a_b_pct,
    ROUND(100 * pares.pedidos_juntos / fb.pedidos, 1)            AS confianza_b_a_pct,
    ROUND((pares.pedidos_juntos * t.n_pedidos) / (fa.pedidos * fb.pedidos), 2) AS lift
FROM pares
CROSS JOIN total t
JOIN frecuencia_individual fa ON fa.producto_id = pares.prod_a
JOIN frecuencia_individual fb ON fb.producto_id = pares.prod_b
JOIN dim_producto pa ON pa.producto_id = pares.prod_a
JOIN dim_producto pb ON pb.producto_id = pares.prod_b
ORDER BY lift DESC, pares.pedidos_juntos DESC
LIMIT 20;

-- -----------------------------------------------------------------------------
-- 8.2 Afinidad entre categorías
-- -----------------------------------------------------------------------------
-- Misma lógica un nivel más arriba. Es más estable que el análisis por SKU y
-- más útil para decidir el orden del catálogo de preventa.
-- -----------------------------------------------------------------------------
WITH pedido_categoria AS (
    SELECT DISTINCT p.pedido_id, pr.categoria
    FROM fact_pedido p
    JOIN fact_pedido_item i ON i.pedido_id   = p.pedido_id
    JOIN dim_producto pr    ON pr.producto_id = i.producto_id
    WHERE p.estado = 'entregado'
),
total AS (SELECT count(DISTINCT pedido_id) AS n FROM pedido_categoria),
individual AS (
    SELECT categoria, count(*) AS pedidos
    FROM pedido_categoria GROUP BY categoria
)
SELECT
    a.categoria AS categoria_a,
    b.categoria AS categoria_b,
    count(*)                                  AS pedidos_juntos,
    ROUND(100 * count(*) / MIN(t.n), 1)       AS soporte_pct,
    ROUND((count(*) * MIN(t.n)) / (MIN(ia.pedidos) * MIN(ib.pedidos)), 3) AS lift
FROM pedido_categoria a
JOIN pedido_categoria b
  ON a.pedido_id = b.pedido_id AND a.categoria < b.categoria
CROSS JOIN total t
JOIN individual ia ON ia.categoria = a.categoria
JOIN individual ib ON ib.categoria = b.categoria
GROUP BY a.categoria, b.categoria
ORDER BY lift DESC
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 8.3 Recomendación concreta por cliente
-- -----------------------------------------------------------------------------
-- Para cada cliente activo, el producto más asociado a lo que ya compra y que
-- todavía no lleva. Es la salida que consumiría el vendedor en el celular
-- antes de entrar al comercio.
-- -----------------------------------------------------------------------------
WITH pedidos_validos AS (
    SELECT pedido_id, cliente_id FROM fact_pedido WHERE estado = 'entregado'
),
pares AS (
    SELECT
        a.producto_id AS base,
        b.producto_id AS sugerido,
        count(*)      AS juntos
    FROM fact_pedido_item a
    JOIN fact_pedido_item b
      ON a.pedido_id = b.pedido_id AND a.producto_id <> b.producto_id
    JOIN pedidos_validos p ON p.pedido_id = a.pedido_id
    GROUP BY a.producto_id, b.producto_id
    HAVING count(*) >= 20
),
compras_cliente AS (
    SELECT DISTINCT p.cliente_id, i.producto_id
    FROM fact_pedido_item i
    JOIN pedidos_validos p ON p.pedido_id = i.pedido_id
),
candidatos AS (
    SELECT
        cc.cliente_id,
        pa.sugerido,
        SUM(pa.juntos) AS score
    FROM compras_cliente cc
    JOIN pares pa ON pa.base = cc.producto_id
    WHERE NOT EXISTS (
        SELECT 1 FROM compras_cliente cc2
        WHERE cc2.cliente_id  = cc.cliente_id
          AND cc2.producto_id = pa.sugerido
    )
    GROUP BY cc.cliente_id, pa.sugerido
),
mejor AS (
    SELECT
        cliente_id, sugerido, score,
        ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY score DESC) AS rn
    FROM candidatos
)
SELECT
    c.razon_social,
    c.canal,
    pr.nombre    AS producto_sugerido,
    pr.categoria,
    m.score      AS fuerza_de_asociacion
FROM mejor m
JOIN dim_cliente  c  ON c.cliente_id   = m.cliente_id
JOIN dim_producto pr ON pr.producto_id = m.sugerido
WHERE m.rn = 1
ORDER BY m.score DESC
LIMIT 20;
