-- =============================================================================
-- 99_practica_entrevista.sql — 12 ejercicios tipo prueba técnica (MySQL 8.0)
-- =============================================================================
-- Preguntas del estilo que aparece en entrevistas de Data Analyst, resueltas
-- sobre este mismo dataset. Cada una lleva el enunciado, la solución y la
-- trampa que suele hacerla fallar.
--
-- Forma de usarlo: leer el enunciado, taparse la solución, escribirla, comparar.
-- =============================================================================

USE mayorista;

-- =============================================================================
-- 1. Segundo mayor valor sin usar LIMIT/OFFSET
-- =============================================================================
-- Enunciado: el segundo cliente por facturación.
-- Trampa: con LIMIT 1 OFFSET 1 sale, pero si hay empate en el primer puesto la
-- respuesta es incorrecta. Con DENSE_RANK el empate se maneja bien.
WITH f AS (
    SELECT cliente_id, razon_social, SUM(importe_neto) AS facturacion
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY cliente_id, razon_social
),
r AS (SELECT f.*, DENSE_RANK() OVER (ORDER BY facturacion DESC) AS puesto FROM f)
SELECT razon_social, ROUND(facturacion) AS facturacion
FROM r WHERE puesto = 2;

-- =============================================================================
-- 2. Top N por grupo
-- =============================================================================
-- Enunciado: los 2 productos más vendidos de cada categoría.
-- Trampa: no se resuelve con GROUP BY + LIMIT. Hace falta numerar dentro de la
-- partición y filtrar en una capa externa, porque las window functions se
-- evalúan DESPUÉS del WHERE.
WITH v AS (
    SELECT categoria, producto, SUM(cantidad) AS unidades
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY categoria, producto
)
SELECT categoria, producto, unidades
FROM (SELECT v.*, ROW_NUMBER() OVER (PARTITION BY categoria ORDER BY unidades DESC) AS rn
      FROM v) z
WHERE rn <= 2
ORDER BY categoria, rn;

-- =============================================================================
-- 3. Registros que existen en A y no en B
-- =============================================================================
-- Enunciado: clientes que nunca hicieron un pedido entregado.
-- Trampa: NOT IN devuelve cero filas si la subconsulta contiene un solo NULL.
-- NOT EXISTS es inmune a eso y suele ser más rápido.
SELECT c.cliente_id, c.razon_social, c.canal, c.fecha_alta
FROM dim_cliente c
WHERE NOT EXISTS (
    SELECT 1 FROM fact_pedido p
    WHERE p.cliente_id = c.cliente_id AND p.estado = 'entregado'
);

-- =============================================================================
-- 4. Variación mes contra mes
-- =============================================================================
-- Enunciado: facturación mensual y su variación porcentual.
-- Trampa: hacer un self-join de la tabla contra sí misma con mes-1 rompe en el
-- cambio de año y en meses sin ventas. LAG no tiene ese problema.
WITH m AS (
    SELECT anio_mes, SUM(importe_neto) AS facturacion
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY anio_mes
)
SELECT
    anio_mes,
    ROUND(facturacion) AS facturacion,
    ROUND(facturacion - LAG(facturacion) OVER (ORDER BY anio_mes)) AS diferencia,
    ROUND(100 * (facturacion - LAG(facturacion) OVER (ORDER BY anio_mes))
              / LAG(facturacion) OVER (ORDER BY anio_mes), 1)      AS var_pct
FROM m ORDER BY anio_mes;

-- =============================================================================
-- 5. Suma acumulada
-- =============================================================================
-- Enunciado: acumulado de facturación a lo largo del año 2025.
-- Trampa: olvidar el frame. Por defecto, con ORDER BY el frame es RANGE
-- UNBOUNDED PRECEDING, que agrupa los empates: si dos filas tienen el mismo
-- valor de orden, ambas muestran el total de las dos. ROWS evita eso.
WITH d AS (
    SELECT fecha, SUM(importe_neto) AS venta
    FROM v_ventas
    WHERE estado = 'entregado' AND anio = 2025
    GROUP BY fecha
)
SELECT
    fecha,
    ROUND(venta) AS venta_dia,
    ROUND(SUM(venta) OVER (ORDER BY fecha ROWS UNBOUNDED PRECEDING)) AS acumulado
FROM d ORDER BY fecha LIMIT 15;

-- =============================================================================
-- 6. Mediana y percentiles
-- =============================================================================
-- Enunciado: ticket mediano por canal, no promedio.
-- Trampa: MySQL NO tiene PERCENTILE_CONT ni una función median(). Se resuelve
-- numerando las filas dentro de cada grupo y quedándose con la del medio.
-- (PostgreSQL lo resuelve en una línea con percentile_cont ... WITHIN GROUP.)
WITH tickets AS (
    SELECT canal, pedido_id, SUM(importe_neto) AS ticket
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY canal, pedido_id
),
numerado AS (
    SELECT
        canal, ticket,
        ROW_NUMBER() OVER (PARTITION BY canal ORDER BY ticket) AS rn,
        COUNT(*)     OVER (PARTITION BY canal)                 AS n
    FROM tickets
)
SELECT
    canal,
    MAX(n)                                                       AS pedidos,
    ROUND(AVG(CASE WHEN rn IN (FLOOR((n+1)/2), CEIL((n+1)/2))
                   THEN ticket END))                             AS mediana,
    ROUND(AVG(CASE WHEN rn = CEIL(n * 0.90) THEN ticket END))     AS p90
FROM numerado
GROUP BY canal
ORDER BY mediana DESC;

-- =============================================================================
-- 7. Días consecutivos (gaps and islands)
-- =============================================================================
-- Enunciado: la racha más larga de días seguidos con ventas.
-- Truco clásico: al restar row_number() a la fecha, todos los días
-- consecutivos comparten el mismo resultado y se pueden agrupar por él.
WITH dias AS (
    SELECT DISTINCT fecha FROM fact_pedido WHERE estado = 'entregado'
),
grupos AS (
    SELECT
        fecha,
        DATE_SUB(fecha, INTERVAL ROW_NUMBER() OVER (ORDER BY fecha) DAY) AS grupo
    FROM dias
)
SELECT
    MIN(fecha) AS desde,
    MAX(fecha) AS hasta,
    count(*)   AS dias_consecutivos
FROM grupos
GROUP BY grupo
ORDER BY dias_consecutivos DESC
LIMIT 3;

-- =============================================================================
-- 8. Pivot
-- =============================================================================
-- Enunciado: facturación por categoría y trimestre, con los trimestres en
-- columnas. En MySQL se hace con SUM(CASE WHEN ...); PostgreSQL tiene FILTER,
-- que se lee mejor y hace lo mismo.
SELECT
    categoria,
    ROUND(SUM(CASE WHEN trimestre = 1 THEN importe_neto END)) AS q1,
    ROUND(SUM(CASE WHEN trimestre = 2 THEN importe_neto END)) AS q2,
    ROUND(SUM(CASE WHEN trimestre = 3 THEN importe_neto END)) AS q3,
    ROUND(SUM(CASE WHEN trimestre = 4 THEN importe_neto END)) AS q4
FROM v_ventas WHERE estado = 'entregado'
GROUP BY categoria ORDER BY categoria;

-- =============================================================================
-- 9. Porcentaje sobre el total del grupo
-- =============================================================================
-- Enunciado: participación de cada canal dentro de su localidad.
-- Trampa: intentarlo con una subconsulta correlacionada. Una window function
-- con PARTITION BY resuelve en una pasada.
SELECT
    localidad,
    canal,
    ROUND(SUM(importe_neto)) AS facturacion,
    ROUND(100 * SUM(importe_neto)
              / SUM(SUM(importe_neto)) OVER (PARTITION BY localidad), 1) AS pct_localidad
FROM v_ventas WHERE estado = 'entregado'
GROUP BY localidad, canal
ORDER BY localidad, facturacion DESC;

-- =============================================================================
-- 10. Duplicados
-- =============================================================================
-- Enunciado: encontrar razones sociales cargadas más de una vez.
-- Se resuelve con GROUP BY + HAVING. Nota: HAVING filtra DESPUÉS de agrupar;
-- WHERE filtra antes. Confundirlos es un error habitual.
SELECT razon_social, count(*) AS veces,
       GROUP_CONCAT(cliente_id ORDER BY cliente_id) AS ids
FROM dim_cliente
GROUP BY razon_social
HAVING count(*) > 1
ORDER BY veces DESC LIMIT 10;

-- =============================================================================
-- 11. Primer registro por grupo
-- =============================================================================
-- Enunciado: primera compra de cada cliente, con su monto.
-- Trampa: MIN(fecha) da la fecha, pero no el monto de ESE pedido. Hay que
-- traerse la fila entera. PostgreSQL tiene DISTINCT ON; en MySQL se usa
-- ROW_NUMBER en una CTE y se filtra por rn = 1.
WITH por_pedido AS (
    SELECT cliente_id, razon_social, fecha, pedido_id,
           SUM(importe_neto) AS monto
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY cliente_id, razon_social, fecha, pedido_id
),
numerado AS (
    SELECT p.*, ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY fecha) AS rn
    FROM por_pedido p
)
SELECT cliente_id, razon_social, fecha AS primera_compra,
       ROUND(monto) AS monto_primera_compra
FROM numerado WHERE rn = 1
ORDER BY cliente_id LIMIT 10;

-- =============================================================================
-- 12. Comparar contra el promedio del propio grupo
-- =============================================================================
-- Enunciado: clientes que facturan por encima del promedio de SU canal.
-- Trampa: comparar contra el promedio general. El promedio del grupo se
-- consigue con AVG() OVER (PARTITION BY canal).
WITH f AS (
    SELECT cliente_id, razon_social, canal, SUM(importe_neto) AS facturacion
    FROM v_ventas WHERE estado = 'entregado'
    GROUP BY cliente_id, razon_social, canal
),
c AS (
    SELECT f.*, AVG(facturacion) OVER (PARTITION BY canal) AS prom_canal
    FROM f
)
SELECT razon_social, canal,
       ROUND(facturacion) AS facturacion,
       ROUND(prom_canal)  AS promedio_del_canal,
       ROUND(100 * facturacion / prom_canal - 100, 1) AS pct_sobre_promedio
FROM c
WHERE facturacion > prom_canal
ORDER BY pct_sobre_promedio DESC
LIMIT 15;
