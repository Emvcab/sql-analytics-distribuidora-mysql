-- =============================================================================
-- 90_vistas.sql — Capa semántica para BI (MySQL 8.0)
-- =============================================================================
-- Estas vistas son el contrato entre la base y Power BI / Streamlit / Metabase.
-- La idea: que la herramienta de visualización nunca escriba lógica de negocio.
-- Si el margen se define mal, se corrige acá y se corrige en todos lados.
--
-- DIFERENCIA GRANDE CON POSTGRESQL: **MySQL no tiene vistas materializadas.**
-- La versión PostgreSQL usa MATERIALIZED VIEW con REFRESH CONCURRENTLY. Acá se
-- emula con el patrón estándar: una tabla real + un procedimiento almacenado
-- que la reconstruye. Se pierde el refresh sin bloqueo, así que conviene
-- programarlo de madrugada con el Event Scheduler o con cron.
-- =============================================================================

USE mayorista;

-- -----------------------------------------------------------------------------
-- 9.1 Resumen mensual (VIEW: liviana, siempre actualizada)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_kpi_mensual AS
SELECT
    anio_mes,
    anio,
    mes,
    count(DISTINCT pedido_id)                    AS pedidos,
    count(DISTINCT cliente_id)                   AS clientes_activos,
    SUM(cantidad)                                AS unidades,
    ROUND(SUM(importe_bruto), 2)                 AS facturacion_bruta,
    ROUND(SUM(importe_neto), 2)                  AS facturacion_neta,
    ROUND(SUM(importe_bruto - importe_neto), 2)  AS descuentos_otorgados,
    ROUND(SUM(margen), 2)                        AS margen,
    ROUND(100 * SUM(margen) / NULLIF(SUM(importe_neto), 0), 2) AS margen_pct,
    ROUND(SUM(importe_neto) / count(DISTINCT pedido_id), 2)    AS ticket_promedio
FROM v_ventas
WHERE estado = 'entregado'
GROUP BY anio_mes, anio, mes;

-- -----------------------------------------------------------------------------
-- 9.2 Ficha de cliente (tabla materializada a mano)
-- -----------------------------------------------------------------------------
-- Recorre toda la historia de cada cliente. En un ERP con años de datos esto
-- tarda; materializarla y refrescarla de noche es la diferencia entre un
-- dashboard que abre en 200 ms y uno que abre en 15 segundos.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS mv_ficha_cliente;
CREATE TABLE mv_ficha_cliente (
    cliente_id             INT PRIMARY KEY,
    razon_social           VARCHAR(120),
    canal                  VARCHAR(20),
    localidad              VARCHAR(60),
    zona                   VARCHAR(40),
    primera_compra         DATE,
    ultima_compra          DATE,
    dias_sin_comprar       INT,
    pedidos                INT,
    skus_distintos         INT,
    categorias_compradas   INT,
    unidades               INT,
    facturacion            DECIMAL(16,2),
    margen                 DECIMAL(16,2),
    descuento_promedio     DECIMAL(6,4),
    ticket_promedio        DECIMAL(16,2),
    margen_pct             DECIMAL(6,2),
    dias_entre_compras     DECIMAL(8,1),
    categorias_sin_comprar INT,
    actualizado_en         DATETIME
) COMMENT 'Ficha 360 del cliente. Equivale a una MATERIALIZED VIEW de PostgreSQL: refrescar con sp_refresh_ficha_cliente().';

-- Procedimiento de refresh: reemplaza al REFRESH MATERIALIZED VIEW
DROP PROCEDURE IF EXISTS sp_refresh_ficha_cliente;
DELIMITER $$
CREATE PROCEDURE sp_refresh_ficha_cliente()
BEGIN
    TRUNCATE TABLE mv_ficha_cliente;

    INSERT INTO mv_ficha_cliente
    SELECT
        b.cliente_id, b.razon_social, b.canal, b.localidad, b.zona,
        b.primera_compra, b.ultima_compra, b.dias_sin_comprar,
        b.pedidos, b.skus_distintos, b.categorias_compradas, b.unidades,
        b.facturacion, b.margen, b.descuento_promedio,
        ROUND(b.facturacion / b.pedidos, 2),
        ROUND(100 * b.margen / NULLIF(b.facturacion, 0), 2),
        -- intervalo promedio entre compras: base de las alertas de reactivación
        CASE WHEN b.pedidos > 1
             THEN ROUND(DATEDIFF(b.ultima_compra, b.primera_compra) / (b.pedidos - 1), 1)
        END,
        (SELECT count(DISTINCT categoria) FROM dim_producto) - b.categorias_compradas,
        NOW()
    FROM (
        SELECT
            v.cliente_id,
            v.razon_social,
            v.canal,
            v.localidad,
            v.zona,
            MIN(v.fecha)                    AS primera_compra,
            MAX(v.fecha)                    AS ultima_compra,
            DATEDIFF((SELECT MAX(fecha) FROM fact_pedido WHERE estado = 'entregado'),
                     MAX(v.fecha))          AS dias_sin_comprar,
            count(DISTINCT v.pedido_id)     AS pedidos,
            count(DISTINCT v.producto_id)   AS skus_distintos,
            count(DISTINCT v.categoria)     AS categorias_compradas,
            SUM(v.cantidad)                 AS unidades,
            SUM(v.importe_neto)             AS facturacion,
            SUM(v.margen)                   AS margen,
            AVG(v.descuento_pct)            AS descuento_promedio
        FROM v_ventas v
        WHERE v.estado = 'entregado'
        GROUP BY v.cliente_id, v.razon_social, v.canal, v.localidad, v.zona
    ) b;
END$$
DELIMITER ;

CALL sp_refresh_ficha_cliente();

-- En producción se programa con el Event Scheduler:
--   SET GLOBAL event_scheduler = ON;
--   CREATE EVENT ev_refresh_ficha ON SCHEDULE EVERY 1 DAY
--       STARTS '2026-01-01 03:00:00'
--       DO CALL sp_refresh_ficha_cliente();

-- -----------------------------------------------------------------------------
-- 9.3 Comprobación: la ficha materializada en uso
-- -----------------------------------------------------------------------------
SELECT
    razon_social,
    canal,
    localidad,
    pedidos,
    dias_entre_compras,
    dias_sin_comprar,
    categorias_sin_comprar,
    ROUND(facturacion) AS facturacion,
    margen_pct
FROM mv_ficha_cliente
ORDER BY margen DESC
LIMIT 15;

-- -----------------------------------------------------------------------------
-- 9.4 Vista de alertas lista para conectar a un dashboard
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_alertas AS
SELECT 'Cliente dormido'  AS tipo_alerta,
       'alta'             AS severidad,
       f.razon_social     AS entidad,
       f.canal            AS contexto,
       'Contactar esta semana' AS accion,
       ROUND(f.margen / 24)    AS impacto_mensual
FROM mv_ficha_cliente f
WHERE f.dias_sin_comprar > 75 AND f.margen > 0

UNION ALL

SELECT 'Baja frecuencia de compra', 'media', f.razon_social, f.canal,
       'Revisar cobertura del vendedor', ROUND(f.margen / 24)
FROM mv_ficha_cliente f
WHERE f.dias_entre_compras > 45 AND f.pedidos >= 3

UNION ALL

SELECT 'Descuento por encima de política', 'media', f.razon_social, f.canal,
       'Revisar condición comercial', ROUND(f.facturacion * f.descuento_promedio / 24)
FROM mv_ficha_cliente f
WHERE f.descuento_promedio > 0.09

UNION ALL

SELECT 'Cliente sin zona asignada', 'baja', f.razon_social,
       COALESCE(f.localidad, 'sin dato'), 'Completar ficha en el ERP', 0
FROM mv_ficha_cliente f
WHERE f.zona IS NULL;

-- Resumen del tablero de alertas
SELECT
    tipo_alerta,
    severidad,
    count(*)                    AS casos,
    ROUND(SUM(impacto_mensual)) AS impacto_mensual_total
FROM v_alertas
GROUP BY tipo_alerta, severidad
ORDER BY impacto_mensual_total DESC;
