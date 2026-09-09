-- =============================================================================
-- 01_schema.sql — Modelo dimensional (esquema estrella)
-- Distribuidora mayorista de consumo masivo
-- MySQL 8.0+
-- =============================================================================
-- Diseño: 4 dimensiones + 2 tablas de hechos (cabecera y detalle de pedido).
-- Las métricas de línea (importe neto y margen) se calculan con columnas
-- GENERATED ALWAYS AS ... STORED para garantizar consistencia: no existe forma
-- de que un INSERT deje un importe que no cierre con cantidad x precio.
--
-- Los CHECK constraints se validan a partir de MySQL 8.0.16. En versiones
-- anteriores se aceptan pero se ignoran silenciosamente.
-- =============================================================================

DROP DATABASE IF EXISTS mayorista;
CREATE DATABASE mayorista CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE mayorista;

-- -----------------------------------------------------------------------------
-- DIMENSIONES
-- -----------------------------------------------------------------------------

CREATE TABLE dim_vendedor (
    vendedor_id     SMALLINT      NOT NULL PRIMARY KEY,
    nombre          VARCHAR(80)   NOT NULL,
    zona            VARCHAR(40)   NOT NULL,
    fecha_ingreso   DATE          NOT NULL
) COMMENT 'Fuerza de venta. Un vendedor atiende una zona geográfica.';

CREATE TABLE dim_cliente (
    cliente_id      INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    razon_social    VARCHAR(120)  NOT NULL,
    canal           VARCHAR(20)   NOT NULL,
    zona            VARCHAR(40)   NULL,          -- NULL a propósito en ~2%
    localidad       VARCHAR(60)   NOT NULL,
    fecha_alta      DATE          NOT NULL,
    limite_credito  DECIMAL(12,2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_cliente_canal CHECK (canal IN
        ('Kiosco','Almacén','Autoservicio','Minimercado','Supermercado','Distribuidor'))
) COMMENT 'Cartera de clientes. zona admite NULL: refleja carga incompleta en el ERP.';

CREATE TABLE dim_producto (
    producto_id     INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nombre          VARCHAR(150)  NOT NULL,
    categoria       VARCHAR(40)   NOT NULL,
    subcategoria    VARCHAR(40)   NOT NULL,
    marca           VARCHAR(40)   NOT NULL,
    unidad_bulto    SMALLINT      NOT NULL,
    costo_unitario  DECIMAL(12,2) NOT NULL,
    precio_lista    DECIMAL(12,2) NOT NULL
) COMMENT 'Catálogo. costo_unitario y precio_lista son referencia; el precio real de cada venta va en la línea.';

CREATE TABLE dim_calendario (
    fecha           DATE      NOT NULL PRIMARY KEY,
    anio            SMALLINT  NOT NULL,
    mes             SMALLINT  NOT NULL,
    dia             SMALLINT  NOT NULL,
    trimestre       SMALLINT  NOT NULL,
    anio_mes        CHAR(7)   NOT NULL,
    nombre_mes      VARCHAR(15) NOT NULL,
    dia_semana      SMALLINT  NOT NULL,          -- 0 = domingo (igual que PostgreSQL)
    nombre_dia      VARCHAR(15) NOT NULL,
    es_fin_semana   TINYINT(1) NOT NULL,
    es_feriado      TINYINT(1) NOT NULL DEFAULT 0
) COMMENT 'Dimensión tiempo. Permite analizar períodos sin ventas, que un GROUP BY sobre hechos no puede mostrar.';

-- -----------------------------------------------------------------------------
-- HECHOS
-- -----------------------------------------------------------------------------

CREATE TABLE fact_pedido (
    pedido_id       BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
    fecha           DATE         NOT NULL,
    cliente_id      INT          NOT NULL,
    vendedor_id     SMALLINT     NOT NULL,
    canal_venta     VARCHAR(15)  NOT NULL,
    estado          VARCHAR(12)  NOT NULL,
    CONSTRAINT fk_pedido_fecha    FOREIGN KEY (fecha)       REFERENCES dim_calendario(fecha),
    CONSTRAINT fk_pedido_cliente  FOREIGN KEY (cliente_id)  REFERENCES dim_cliente(cliente_id),
    CONSTRAINT fk_pedido_vendedor FOREIGN KEY (vendedor_id) REFERENCES dim_vendedor(vendedor_id),
    CONSTRAINT chk_pedido_canal   CHECK (canal_venta IN ('Preventa','WhatsApp','Mostrador','Web')),
    CONSTRAINT chk_pedido_estado  CHECK (estado IN ('entregado','cancelado','pendiente'))
) COMMENT 'Cabecera. Incluye cancelados y pendientes: todo análisis de facturación debe filtrar estado.';

CREATE TABLE fact_pedido_item (
    pedido_id       BIGINT        NOT NULL,
    linea           SMALLINT      NOT NULL,
    producto_id     INT           NOT NULL,
    cantidad        INT           NOT NULL,
    precio_unitario DECIMAL(12,2) NOT NULL,
    descuento_pct   DECIMAL(4,3)  NOT NULL DEFAULT 0,
    costo_unitario  DECIMAL(12,2) NOT NULL,

    importe_bruto   DECIMAL(14,2) AS (cantidad * precio_unitario) STORED,
    importe_neto    DECIMAL(14,2) AS (cantidad * precio_unitario * (1 - descuento_pct)) STORED,
    margen          DECIMAL(14,2) AS (cantidad * (precio_unitario * (1 - descuento_pct)
                                                  - costo_unitario)) STORED,

    PRIMARY KEY (pedido_id, linea),
    CONSTRAINT fk_item_pedido   FOREIGN KEY (pedido_id)   REFERENCES fact_pedido(pedido_id) ON DELETE CASCADE,
    CONSTRAINT fk_item_producto FOREIGN KEY (producto_id) REFERENCES dim_producto(producto_id)
) COMMENT 'Detalle, grano = una línea de producto. Importes y margen son columnas generadas.';

-- -----------------------------------------------------------------------------
-- TABLA AUXILIAR DE SECUENCIA
-- -----------------------------------------------------------------------------
-- MySQL no tiene generate_series(). Se genera una tabla de números con una CTE
-- recursiva y se la reutiliza en todo el seed como fuente de filas.
-- -----------------------------------------------------------------------------
CREATE TABLE seq (n INT NOT NULL PRIMARY KEY)
    COMMENT 'Tabla de números 1..2000. Reemplaza a generate_series() de PostgreSQL.';

SET SESSION cte_max_recursion_depth = 5000;

INSERT INTO seq (n)
WITH RECURSIVE numeros (n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM numeros WHERE n < 2000
)
SELECT n FROM numeros;

-- -----------------------------------------------------------------------------
-- VISTA DE CONVENIENCIA
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_ventas AS
SELECT
    i.pedido_id, i.linea,
    p.fecha, cal.anio, cal.mes, cal.nombre_mes, cal.anio_mes, cal.trimestre,
    cal.dia_semana, cal.nombre_dia, cal.es_fin_semana,
    p.cliente_id, c.razon_social, c.canal, c.localidad, c.zona,
    p.vendedor_id, v.nombre AS vendedor, v.zona AS zona_vendedor,
    p.canal_venta, p.estado,
    i.producto_id, pr.nombre AS producto, pr.categoria, pr.subcategoria, pr.marca,
    i.cantidad, i.precio_unitario, i.descuento_pct,
    i.importe_bruto, i.importe_neto, i.margen
FROM fact_pedido_item i
JOIN fact_pedido    p   ON p.pedido_id    = i.pedido_id
JOIN dim_cliente    c   ON c.cliente_id   = p.cliente_id
JOIN dim_producto   pr  ON pr.producto_id = i.producto_id
JOIN dim_vendedor   v   ON v.vendedor_id  = p.vendedor_id
JOIN dim_calendario cal ON cal.fecha      = p.fecha;
