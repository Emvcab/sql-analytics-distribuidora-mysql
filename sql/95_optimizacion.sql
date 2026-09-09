-- =============================================================================
-- 95_optimizacion.sql — Lectura de planes de ejecución (MySQL 8.0)
-- =============================================================================
-- Escribir SQL que devuelve el resultado correcto es la mitad del trabajo. La
-- otra mitad es que termine antes de que al usuario se le acabe la paciencia.
--
-- EXPLAIN ANALYZE existe en MySQL desde la versión 8.0.18: ejecuta la consulta
-- de verdad y muestra tiempos reales, igual que en PostgreSQL. En versiones
-- anteriores solo hay EXPLAIN, que muestra el plan estimado sin ejecutarlo.
--
-- Cómo se lee: de adentro hacia afuera. Lo que importa es `actual time`
-- (tiempo real), `rows` (filas procesadas) y la diferencia entre las filas
-- estimadas y las reales: si el optimizador estima 10 y procesa 100.000,
-- eligió mal la estrategia y hay que revisar estadísticas con ANALYZE TABLE.
--
-- Señales de alarma en un plan de MySQL:
--   "Table scan on tabla_grande" con WHERE selectivo  -> falta un índice
--   "Nested loop" con muchas filas del lado interno   -> falta índice en el join
--   estimación muy distinta de la realidad            -> correr ANALYZE TABLE
--   "Using temporary; Using filesort" sobre mucho     -> revisar ORDER BY/GROUP BY
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 10.1 El costo de no tener índice en un filtro selectivo
-- -----------------------------------------------------------------------------
-- NOTA IMPORTANTE (diferencia con PostgreSQL): InnoDB EXIGE un índice sobre
-- toda columna que sea FOREIGN KEY, y no deja borrarlo mientras la FK exista:
--
--     ERROR 1553: Cannot drop index ... needed in a foreign key constraint
--
-- Por eso la demostración no puede usar producto_id ni cliente_id. Se usa
-- canal_venta, que no participa de ninguna FK y es razonablemente selectiva
-- (los pedidos por Web son ~6% del total).
-- -----------------------------------------------------------------------------
DROP INDEX idx_pedido_canal ON fact_pedido;

-- Sin índice: hay que recorrer los 27.000 pedidos para encontrar los de Web
EXPLAIN ANALYZE
SELECT count(*), COUNT(DISTINCT cliente_id)
FROM fact_pedido
WHERE canal_venta = 'Web';

CREATE INDEX idx_pedido_canal ON fact_pedido (canal_venta);
ANALYZE TABLE fact_pedido;

-- Con índice: se va directo a las filas que importan
EXPLAIN ANALYZE
SELECT count(*), COUNT(DISTINCT cliente_id)
FROM fact_pedido
WHERE canal_venta = 'Web';

-- -----------------------------------------------------------------------------
-- Caso B: agregado sobre TODA la tabla. El mismo índice no aporta nada y MySQL
-- lo ignora, con razón: si hay que leer todas las filas igual, el escaneo
-- secuencial es más rápido que saltar por el índice.
-- Conclusión: un índice no acelera "la tabla", acelera un patrón de acceso.
-- Agregar índices sin mirar el plan es cargar costo de escritura a cambio de
-- nada.
-- -----------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT pr.categoria, SUM(i.importe_neto)
FROM fact_pedido_item i
JOIN dim_producto pr ON pr.producto_id = i.producto_id
GROUP BY pr.categoria;

-- -----------------------------------------------------------------------------
-- 10.2 Vista calculada al vuelo vs tabla materializada
-- -----------------------------------------------------------------------------
-- Misma información desde las dos fuentes. La diferencia de tiempo es el
-- argumento concreto para justificar la materialización ante quien pregunte
-- por qué existe una tabla que "duplica" datos.
-- -----------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT cliente_id, SUM(importe_neto), count(DISTINCT pedido_id)
FROM v_ventas
WHERE estado = 'entregado'
GROUP BY cliente_id;

EXPLAIN ANALYZE
SELECT cliente_id, facturacion, pedidos
FROM mv_ficha_cliente;

-- -----------------------------------------------------------------------------
-- 10.3 Antipatrón: función aplicada sobre la columna del WHERE
-- -----------------------------------------------------------------------------
-- Envolver la columna en una función inutiliza el índice: MySQL no puede usar
-- un índice sobre `fecha` si lo que se compara es YEAR(fecha). La forma
-- correcta es dejar la columna sola de un lado y armar un rango.
--
-- (MySQL 8.0 permite crear índices funcionales sobre la expresión, pero eso
-- resuelve el síntoma: sigue siendo mejor escribir el rango.)
-- -----------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT count(*)
FROM fact_pedido
WHERE YEAR(fecha) = 2026 AND MONTH(fecha) = 7;

EXPLAIN ANALYZE
SELECT count(*)
FROM fact_pedido
WHERE fecha >= '2026-07-01' AND fecha < '2026-08-01';

-- -----------------------------------------------------------------------------
-- 10.4 Tamaño de los objetos
-- -----------------------------------------------------------------------------
-- Cuánto pesa cada tabla y cuánto pesan sus índices. Si los índices pesan más
-- que la tabla, sobran índices.
-- -----------------------------------------------------------------------------
SELECT
    TABLE_NAME                                              AS objeto,
    ROUND(DATA_LENGTH  / 1024 / 1024, 2)                    AS datos_mb,
    ROUND(INDEX_LENGTH / 1024 / 1024, 2)                    AS indices_mb,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2)    AS total_mb,
    TABLE_ROWS                                              AS filas_aprox
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'mayorista' AND TABLE_TYPE = 'BASE TABLE'
ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC;

-- -----------------------------------------------------------------------------
-- 10.5 Índices declarados
-- -----------------------------------------------------------------------------
-- MySQL no lleva un contador de uso por índice tan accesible como el
-- pg_stat_user_indexes de PostgreSQL. Lo más cercano requiere tener habilitado
-- el Performance Schema:
--
--   SELECT object_name, index_name, count_star
--   FROM performance_schema.table_io_waits_summary_by_index_usage
--   WHERE object_schema = 'mayorista' AND index_name IS NOT NULL
--   ORDER BY count_star;
--
-- Un índice con count_star = 0 después de un tiempo en producción es un índice
-- muerto: ocupa espacio, frena los INSERT y no lo usa nadie.
-- -----------------------------------------------------------------------------
SELECT
    TABLE_NAME  AS tabla,
    INDEX_NAME  AS indice,
    GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columnas,
    CARDINALITY AS cardinalidad
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'mayorista'
GROUP BY TABLE_NAME, INDEX_NAME, CARDINALITY
ORDER BY TABLE_NAME, INDEX_NAME;
