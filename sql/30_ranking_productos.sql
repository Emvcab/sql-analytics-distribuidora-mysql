-- =============================================================================
-- 30_ranking_productos.sql — Qué vende y qué deja plata (MySQL 8.0)
-- =============================================================================
-- Pregunta de negocio: ¿cuáles son los productos que sostienen la facturación?
-- ¿Y cuáles venden mucho pero dejan poco margen?
--
-- Técnicas: ROW_NUMBER vs RANK vs DENSE_RANK, PARTITION BY, porcentaje sobre
-- el total del grupo con SUM() OVER (PARTITION BY ...).
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 3.1 Top 15 productos por facturación
-- -----------------------------------------------------------------------------
SELECT
    producto,
    categoria,
    SUM(cantidad)                                   AS unidades,
    ROUND(SUM(importe_neto))                        AS facturacion,
    ROUND(SUM(margen))                              AS margen,
    ROUND(100 * SUM(margen) / SUM(importe_neto), 1) AS margen_pct,
    ROUND(100 * SUM(importe_neto) / SUM(SUM(importe_neto)) OVER (), 2)
                                                    AS pct_facturacion_total
FROM v_ventas
WHERE estado = 'entregado'
GROUP BY producto, categoria
ORDER BY facturacion DESC
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 3.2 Top 3 de cada categoría
-- -----------------------------------------------------------------------------
-- Patrón clásico de entrevista: "traeme los N mejores de cada grupo".
-- No se puede resolver con GROUP BY + LIMIT. Se numera dentro de la partición
-- en una CTE y se filtra afuera, porque las window functions no se pueden usar
-- en el WHERE de la misma consulta donde se calculan.
-- -----------------------------------------------------------------------------
WITH ventas_producto AS (
    SELECT
        categoria,
        producto,
        SUM(importe_neto) AS facturacion,
        SUM(margen)       AS margen
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY categoria, producto
),
rankeado AS (
    SELECT
        categoria,
        producto,
        facturacion,
        margen,
        ROW_NUMBER() OVER (PARTITION BY categoria ORDER BY facturacion DESC) AS puesto,
        -- participación del producto dentro de SU categoría
        ROUND(100 * facturacion
                  / SUM(facturacion) OVER (PARTITION BY categoria), 1) AS pct_categoria
    FROM ventas_producto
)
SELECT categoria, puesto, producto,
       ROUND(facturacion) AS facturacion,
       pct_categoria
FROM rankeado
WHERE puesto <= 3
ORDER BY categoria, puesto;

-- -----------------------------------------------------------------------------
-- 3.3 ROW_NUMBER vs RANK vs DENSE_RANK
-- -----------------------------------------------------------------------------
-- Las tres numeran, pero se comportan distinto ante empates:
--   ROW_NUMBER : siempre correlativo, rompe empates arbitrariamente (1,2,3,4)
--   RANK       : empatados comparten puesto y deja huecos      (1,2,2,4)
--   DENSE_RANK : empatados comparten puesto y NO deja huecos   (1,2,2,3)
--
-- Se rankea por CANTIDAD DE CLIENTES que compraron el producto (métrica de
-- alcance, no de volumen) justamente porque tiene empates y se nota la
-- diferencia entre las tres funciones.
-- -----------------------------------------------------------------------------
WITH u AS (
    SELECT producto, count(DISTINCT cliente_id) AS clientes
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY producto
)
SELECT
    producto,
    clientes,
    ROW_NUMBER() OVER (ORDER BY clientes DESC) AS n_row_number,
    RANK()       OVER (ORDER BY clientes DESC) AS n_rank,
    DENSE_RANK() OVER (ORDER BY clientes DESC) AS n_dense_rank
FROM u
ORDER BY clientes DESC
LIMIT 14 OFFSET 28;   -- ventana elegida a propósito: acá hay empates

-- -----------------------------------------------------------------------------
-- 3.4 Volumen alto, margen bajo
-- -----------------------------------------------------------------------------
-- Los productos que hay que renegociar con el proveedor o repreciar: mueven
-- mucha plata pero rinden por debajo del promedio de la empresa.
--
-- DIFERENCIA CON POSTGRESQL: MySQL no tiene PERCENTILE_CONT. El corte del
-- cuartil superior se calcula con NTILE(4) en una CTE previa.
-- -----------------------------------------------------------------------------
WITH prod AS (
    SELECT
        producto, categoria, marca,
        SUM(importe_neto) AS facturacion,
        SUM(margen)       AS margen,
        100 * SUM(margen) / NULLIF(SUM(importe_neto), 0) AS margen_pct
    FROM v_ventas
    WHERE estado = 'entregado'
    GROUP BY producto, categoria, marca
),
cuartiles AS (
    SELECT *, NTILE(4) OVER (ORDER BY facturacion) AS cuartil FROM prod
),
promedio AS (
    SELECT 100 * SUM(margen) / SUM(importe_neto) AS margen_empresa
    FROM v_ventas WHERE estado = 'entregado'
)
SELECT
    c.producto,
    c.categoria,
    ROUND(c.facturacion)                          AS facturacion,
    ROUND(c.margen_pct, 1)                        AS margen_pct,
    ROUND(pr.margen_empresa, 1)                   AS margen_empresa_pct,
    ROUND(c.margen_pct - pr.margen_empresa, 1)    AS brecha_pp,
    -- cuánto margen extra entraría si rindiera como el promedio
    ROUND(c.facturacion * (pr.margen_empresa - c.margen_pct) / 100) AS margen_potencial
FROM cuartiles c
CROSS JOIN promedio pr
WHERE c.margen_pct < pr.margen_empresa
  AND c.cuartil = 4                               -- solo el 25% que más factura
ORDER BY margen_potencial DESC
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 3.5 Participación por categoría y canal (tabla cruzada)
-- -----------------------------------------------------------------------------
-- Un pivot con SUM(CASE WHEN ...). En PostgreSQL se escribiría con FILTER,
-- que se lee mejor pero hace exactamente lo mismo.
-- -----------------------------------------------------------------------------
SELECT
    categoria,
    ROUND(SUM(CASE WHEN canal = 'Kiosco'       THEN importe_neto END)) AS kiosco,
    ROUND(SUM(CASE WHEN canal = 'Almacén'      THEN importe_neto END)) AS almacen,
    ROUND(SUM(CASE WHEN canal = 'Autoservicio' THEN importe_neto END)) AS autoservicio,
    ROUND(SUM(CASE WHEN canal = 'Minimercado'  THEN importe_neto END)) AS minimercado,
    ROUND(SUM(CASE WHEN canal = 'Supermercado' THEN importe_neto END)) AS supermercado,
    ROUND(SUM(importe_neto))                                           AS total
FROM v_ventas
WHERE estado = 'entregado'
GROUP BY categoria
ORDER BY total DESC;
