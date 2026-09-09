-- =============================================================================
-- 03_indices.sql — Estrategia de índices (MySQL 8.0)
-- =============================================================================
-- Regla aplicada: se indexa lo que aparece en JOIN, en WHERE selectivo o en
-- ORDER BY de consultas frecuentes. No se indexa "por las dudas": cada índice
-- ocupa espacio y penaliza cada INSERT.
--
-- DIFERENCIA CON POSTGRESQL: MySQL NO soporta índices parciales
-- (CREATE INDEX ... WHERE condicion). La versión PostgreSQL de este proyecto
-- usa uno sobre `estado = 'entregado'`, que cubre el 93% de las consultas con
-- un índice más chico. Acá se reemplaza por un índice compuesto que arranca
-- con `estado`: no es lo mismo, porque incluye también los cancelados y
-- pendientes, pero permite que el optimizador filtre por estado y fecha en una
-- sola pasada del índice.
--
-- InnoDB crea automáticamente un índice por cada FOREIGN KEY, así que los
-- índices sobre cliente_id, vendedor_id y producto_id ya existen. Crearlos de
-- nuevo sería duplicar.
-- =============================================================================

USE mayorista;

-- Filtro temporal: es el WHERE más usado del modelo.
CREATE INDEX idx_pedido_fecha ON fact_pedido (fecha);

-- Sustituto del índice parcial de PostgreSQL.
CREATE INDEX idx_pedido_estado_fecha ON fact_pedido (estado, fecha, cliente_id);

-- Patrón "última compra por cliente", base del RFM y de las alertas.
-- El orden importa: cliente_id primero porque es por lo que se agrupa.
CREATE INDEX idx_pedido_cliente_fecha ON fact_pedido (cliente_id, fecha DESC);

-- Búsqueda de productos por categoría.
CREATE INDEX idx_producto_categoria ON dim_producto (categoria, subcategoria);

-- Canal de venta. Se usa en 95_optimizacion.sql para medir el impacto de un
-- índice: es una de las pocas columnas selectivas que NO participa de una FK,
-- y por lo tanto se puede borrar y recrear libremente.
CREATE INDEX idx_pedido_canal ON fact_pedido (canal_venta);

ANALYZE TABLE fact_pedido, fact_pedido_item, dim_producto;

-- Índices existentes, incluidos los que creó InnoDB por las FK
SELECT
    TABLE_NAME   AS tabla,
    INDEX_NAME   AS indice,
    GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columnas,
    NON_UNIQUE   AS no_unico
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'mayorista'
GROUP BY TABLE_NAME, INDEX_NAME, NON_UNIQUE
ORDER BY TABLE_NAME, INDEX_NAME;
