-- =============================================================================
-- 02_seed.sql — Generación de datos sintéticos, 100% SQL
-- MySQL 8.0+
-- =============================================================================
-- Sin Python, sin CSV: el dataset se genera desde la tabla `seq`.
--
-- REPRODUCIBILIDAD: MySQL no tiene setseed(). En lugar de RAND(), toda la
-- aleatoriedad se deriva de forma DETERMINÍSTICA del identificador de cada fila
-- mediante CRC32 sobre una cadena con "sal" distinta por atributo:
--
--     (CRC32(CONCAT(id, 'sal')) % 10000) / 10000  ->  pseudo-aleatorio en [0,1)
--
-- Cada sal produce una secuencia distinta e independiente, y el resultado es
-- idéntico en cualquier máquina y en cualquier corrida. Es más robusto que
-- RAND(semilla), que en MySQL devuelve el mismo valor cuando se lo llama
-- repetidamente con una semilla constante dentro de la misma sentencia.
--
-- Se inyectan a propósito problemas de calidad que existen en cualquier ERP
-- real (zonas sin cargar, pedidos cancelados, precios en cero, razones
-- sociales duplicadas). El script 10_calidad_datos.sql los detecta.
-- =============================================================================

USE mayorista;
SET SESSION cte_max_recursion_depth = 5000;

-- -----------------------------------------------------------------------------
-- CALENDARIO: 2024-09-01 a 2026-08-31
-- -----------------------------------------------------------------------------
INSERT INTO dim_calendario
    (fecha, anio, mes, dia, trimestre, anio_mes, nombre_mes,
     dia_semana, nombre_dia, es_fin_semana, es_feriado)
SELECT
    d.fecha,
    YEAR(d.fecha),
    MONTH(d.fecha),
    DAY(d.fecha),
    QUARTER(d.fecha),
    DATE_FORMAT(d.fecha, '%Y-%m'),
    ELT(MONTH(d.fecha), 'enero','febrero','marzo','abril','mayo','junio',
        'julio','agosto','septiembre','octubre','noviembre','diciembre'),
    -- DAYOFWEEK() devuelve 1=domingo; se resta 1 para igualar el 0=domingo
    -- que usa EXTRACT(dow) en PostgreSQL y mantener la misma semántica.
    DAYOFWEEK(d.fecha) - 1,
    ELT(DAYOFWEEK(d.fecha), 'domingo','lunes','martes','miércoles',
        'jueves','viernes','sábado'),
    DAYOFWEEK(d.fecha) IN (1, 7),
    DATE_FORMAT(d.fecha, '%m-%d') IN ('01-01','03-24','04-02','05-01','05-25',
                                      '06-20','07-09','08-17','10-12','11-20',
                                      '12-08','12-25')
FROM (
    SELECT DATE_ADD('2024-09-01', INTERVAL n - 1 DAY) AS fecha
    FROM seq
    WHERE n <= DATEDIFF('2026-08-31', '2024-09-01') + 1
) d;

-- -----------------------------------------------------------------------------
-- VENDEDORES
-- -----------------------------------------------------------------------------
INSERT INTO dim_vendedor (vendedor_id, nombre, zona, fecha_ingreso) VALUES
    (1, 'Ramírez, Julio',    'Capital Norte',  '2019-03-04'),
    (2, 'Coronel, Marisa',   'Capital Sur',    '2020-07-15'),
    (3, 'Juárez, Sebastián', 'La Banda',       '2018-01-22'),
    (4, 'Sosa, Antonella',   'Interior Norte', '2021-09-06'),
    (5, 'Barraza, Ricardo',  'Interior Sur',   '2017-05-11'),
    (6, 'Ledesma, Gabriel',  'Capital Centro', '2022-02-14'),
    (7, 'Ibáñez, Rocío',     'La Banda',       '2023-04-03'),
    (8, 'Paz, Hernán',       'Interior Norte', '2022-11-28');

-- -----------------------------------------------------------------------------
-- PRODUCTOS (320 SKUs = producto base x marca, subconjunto determinístico)
-- -----------------------------------------------------------------------------
-- El ORDER BY sobre un CRC32 reemplaza al ORDER BY random() de PostgreSQL:
-- desordena el catálogo de forma reproducible antes de recortar a 320.
-- -----------------------------------------------------------------------------
INSERT INTO dim_producto
    (nombre, categoria, subcategoria, marca, unidad_bulto, costo_unitario, precio_lista)
SELECT
    nombre, categoria, subcategoria, marca, unidad_bulto,
    costo,
    ROUND(costo * (1.18 + r_markup * 0.27), 2)
FROM (
    SELECT
        CONCAT(b.base, ' ', m.marca) AS nombre,
        b.categoria,
        b.subcategoria,
        m.marca,
        ELT(1 + (CRC32(CONCAT(b.base, m.marca, 'bulto')) % 3), 6, 12, 24) AS unidad_bulto,
        ROUND(b.costo_min + (CRC32(CONCAT(b.base, m.marca, 'costo')) % 10000) / 10000
                            * (b.costo_max - b.costo_min), 2) AS costo,
        (CRC32(CONCAT(b.base, m.marca, 'mkp')) % 10000) / 10000 AS r_markup,
        CRC32(CONCAT(b.base, m.marca, 'orden')) AS orden
    FROM (
        SELECT 'Bebidas' AS categoria, 'Gaseosas' AS subcategoria, 'Gaseosa Cola 2.25L' AS base, 1450 AS costo_min, 2100 AS costo_max
        UNION ALL SELECT 'Bebidas','Gaseosas','Gaseosa Lima Limón 2.25L',1380,1980
        UNION ALL SELECT 'Bebidas','Gaseosas','Gaseosa Naranja 1.5L',1020,1460
        UNION ALL SELECT 'Bebidas','Aguas','Agua Mineral s/gas 2L',680,1010
        UNION ALL SELECT 'Bebidas','Aguas','Agua Saborizada 1.5L',890,1290
        UNION ALL SELECT 'Bebidas','Cervezas','Cerveza Rubia 1L retornable',1720,2340
        UNION ALL SELECT 'Bebidas','Cervezas','Cerveza Lata 473cc',1090,1520
        UNION ALL SELECT 'Bebidas','Vinos','Vino Tinto Malbec 750cc',2850,4400
        UNION ALL SELECT 'Bebidas','Jugos','Jugo en Polvo sobre 20g',210,340
        UNION ALL SELECT 'Bebidas','Energizantes','Bebida Energizante 250cc',1560,2280
        UNION ALL SELECT 'Almacén','Fideos','Fideos Guiseros 500g',780,1150
        UNION ALL SELECT 'Almacén','Fideos','Fideos Spaghetti 500g',810,1190
        UNION ALL SELECT 'Almacén','Arroz','Arroz Largo Fino 1kg',1240,1780
        UNION ALL SELECT 'Almacén','Harinas','Harina 000 1kg',690,1020
        UNION ALL SELECT 'Almacén','Aceites','Aceite Girasol 900ml',2180,3050
        UNION ALL SELECT 'Almacén','Aceites','Aceite Mezcla 1.5L',3120,4380
        UNION ALL SELECT 'Almacén','Conservas','Tomate Triturado 520g',740,1090
        UNION ALL SELECT 'Almacén','Conservas','Arvejas Lata 300g',620,920
        UNION ALL SELECT 'Almacén','Conservas','Atún al Natural 170g',1890,2680
        UNION ALL SELECT 'Almacén','Azúcar','Azúcar Común 1kg',1150,1620
        UNION ALL SELECT 'Almacén','Yerba','Yerba Mate 1kg',3450,4980
        UNION ALL SELECT 'Almacén','Infusiones','Té en Saquitos x25',980,1440
        UNION ALL SELECT 'Almacén','Legumbres','Lentejas 400g',890,1310
        UNION ALL SELECT 'Almacén','Panificados','Pan Rallado 500g',560,830
        UNION ALL SELECT 'Lácteos','Leche','Leche Larga Vida 1L',1080,1520
        UNION ALL SELECT 'Lácteos','Yogur','Yogur Bebible 1L',1620,2290
        UNION ALL SELECT 'Lácteos','Quesos','Queso Cremoso x kg',6800,9450
        UNION ALL SELECT 'Lácteos','Manteca','Manteca 200g',1980,2790
        UNION ALL SELECT 'Lácteos','Dulce de Leche','Dulce de Leche 400g',1740,2480
        UNION ALL SELECT 'Limpieza','Lavandina','Lavandina 1L',520,790
        UNION ALL SELECT 'Limpieza','Detergente','Detergente 750ml',1340,1920
        UNION ALL SELECT 'Limpieza','Jabón en Polvo','Jabón en Polvo 800g',2260,3180
        UNION ALL SELECT 'Limpieza','Suavizante','Suavizante 900ml',1580,2240
        UNION ALL SELECT 'Limpieza','Limpiadores','Limpiador Cremoso 750ml',980,1430
        UNION ALL SELECT 'Limpieza','Papel','Papel Higiénico x4 rollos',1420,2050
        UNION ALL SELECT 'Limpieza','Papel','Rollo de Cocina x2',1180,1690
        UNION ALL SELECT 'Perfumería','Higiene','Jabón de Tocador 90g',480,720
        UNION ALL SELECT 'Perfumería','Higiene','Shampoo 400ml',2340,3320
        UNION ALL SELECT 'Perfumería','Higiene','Desodorante Aerosol 150ml',2680,3790
        UNION ALL SELECT 'Perfumería','Bucal','Pasta Dental 90g',1520,2170
        UNION ALL SELECT 'Golosinas','Chocolates','Chocolate en Barra 100g',1280,1840
        UNION ALL SELECT 'Golosinas','Caramelos','Caramelos Bolsa 500g',1640,2340
        UNION ALL SELECT 'Golosinas','Alfajores','Alfajor Triple 70g',620,920
        UNION ALL SELECT 'Golosinas','Chicles','Chicle Pack x10',390,590
        UNION ALL SELECT 'Snacks','Papas Fritas','Papas Fritas 120g',1180,1690
        UNION ALL SELECT 'Snacks','Palitos','Palitos Salados 100g',740,1090
        UNION ALL SELECT 'Snacks','Galletitas','Galletitas Dulces 300g',980,1420
        UNION ALL SELECT 'Snacks','Galletitas','Galletitas Crackers 250g',860,1260
    ) b
    CROSS JOIN (
        SELECT 'Norteña' AS marca
        UNION ALL SELECT 'Del Valle'  UNION ALL SELECT 'La Rioja'
        UNION ALL SELECT 'Sanavirón'  UNION ALL SELECT 'Doña Rosa'
        UNION ALL SELECT 'Pampa'      UNION ALL SELECT 'Vicuña'
        UNION ALL SELECT 'Salta Sur'  UNION ALL SELECT 'El Ceibo'
        UNION ALL SELECT 'Mistol'     UNION ALL SELECT 'Quebracho'
        UNION ALL SELECT 'Río Dulce'  UNION ALL SELECT 'Guasuncho'
        UNION ALL SELECT 'Yaguar'
    ) m
) x
ORDER BY orden
LIMIT 320;

-- -----------------------------------------------------------------------------
-- CLIENTES (850 comercios)
-- -----------------------------------------------------------------------------
INSERT INTO dim_cliente (razon_social, canal, zona, localidad, fecha_alta, limite_credito)
SELECT
    CONCAT(canal, ' ', apellido),
    canal,
    -- ~2% de zonas sin cargar: dato faltante inyectado a propósito
    CASE WHEN r_null < 0.02 THEN NULL
         ELSE ELT(idx_zona,
                  'Capital Norte','Capital Norte','Capital Sur','Capital Sur',
                  'Capital Centro','Capital Centro','La Banda','La Banda',
                  'La Banda','Interior Norte','Interior Norte','Interior Sur',
                  'Interior Sur','Interior Norte')
    END,
    ELT(idx_zona,
        'Santiago del Estero','Santiago del Estero','Santiago del Estero',
        'Santiago del Estero','Santiago del Estero','Santiago del Estero',
        'La Banda','La Banda','La Banda','Termas de Río Hondo','Fernández',
        'Añatuya','Frías','Loreto'),
    DATE_ADD('2022-01-01', INTERVAL FLOOR(r_alta * 1600) DAY),
    ROUND((150000 + r_credito * 2500000) / 1000) * 1000
FROM (
    SELECT
        CASE
            WHEN (CRC32(CONCAT(n, 'canal')) % 10000) / 10000 < 0.34 THEN 'Kiosco'
            WHEN (CRC32(CONCAT(n, 'canal')) % 10000) / 10000 < 0.58 THEN 'Almacén'
            WHEN (CRC32(CONCAT(n, 'canal')) % 10000) / 10000 < 0.76 THEN 'Autoservicio'
            WHEN (CRC32(CONCAT(n, 'canal')) % 10000) / 10000 < 0.90 THEN 'Minimercado'
            WHEN (CRC32(CONCAT(n, 'canal')) % 10000) / 10000 < 0.97 THEN 'Supermercado'
            ELSE 'Distribuidor'
        END AS canal,
        ELT(1 + (CRC32(CONCAT(n, 'apellido')) % 50),
            'Gómez','Coronel','Juárez','Sosa','Ledesma','Paz','Barraza',
            'Ibáñez','Ruiz','Herrera','Salvatierra','Corvalán','Díaz',
            'Figueroa','Moreno','Acuña','Bravo','Chávez','Lugones',
            'Santillán','Verón','Abregú','Cáceres','Nieva','Roldán',
            'Taboada','Zurita','Olivera','Farías','Maldonado','Suárez',
            'Vera','Palavecino','Argañaraz','Banegas','Carabajal',
            'Dorado','Escobar','Fernández','Gallo','Hoyos','Iturre',
            'Jiménez','Kairuz','Leguizamón','Miranda','Núñez','Ovejero',
            'Pereyra','Quiroga') AS apellido,
        1 + (CRC32(CONCAT(n, 'zona')) % 14)              AS idx_zona,
        (CRC32(CONCAT(n, 'null')) % 10000) / 10000       AS r_null,
        (CRC32(CONCAT(n, 'alta')) % 10000) / 10000       AS r_alta,
        (CRC32(CONCAT(n, 'credito')) % 10000) / 10000    AS r_credito
    FROM seq
    WHERE n <= 850
) c;

-- -----------------------------------------------------------------------------
-- PERFIL DE COMPRA POR CLIENTE
-- -----------------------------------------------------------------------------
-- Tres poblaciones: alta rotación (12%), media (33%) y baja (55%). Un 10% de
-- la cartera "se duerme" en algún punto del período: deja de comprar. Eso hace
-- que el análisis de churn y las alertas tengan algo real que encontrar.
-- -----------------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS perfil_cliente;
CREATE TEMPORARY TABLE perfil_cliente (
    cliente_id  INT PRIMARY KEY,
    inicio      DATE,
    fin         DATE,
    pedidos_mes DECIMAL(6,3),
    vendedor_id SMALLINT,
    n_pedidos   INT
);

INSERT INTO perfil_cliente
SELECT
    cliente_id, inicio, fin, pedidos_mes, vendedor_id,
    GREATEST(1, ROUND(pedidos_mes * DATEDIFF(fin, inicio) / 30.0))
FROM (
    SELECT
        c.cliente_id,
        GREATEST(c.fecha_alta, '2024-09-01') AS inicio,
        LEAST(
            CASE WHEN (CRC32(CONCAT(c.cliente_id, 'churn')) % 10000) / 10000 < 0.10
                 THEN DATE_ADD('2025-01-01', INTERVAL
                        FLOOR((CRC32(CONCAT(c.cliente_id, 'churnd')) % 10000) / 10000 * 520) DAY)
                 ELSE DATE '2026-08-31'
            END,
            DATE '2026-08-31'
        ) AS fin,
        CASE
            WHEN (CRC32(CONCAT(c.cliente_id, 'freq')) % 10000) / 10000 < 0.12
                THEN 4.0 + (CRC32(CONCAT(c.cliente_id, 'f1')) % 10000) / 10000 * 4.0
            WHEN (CRC32(CONCAT(c.cliente_id, 'freq')) % 10000) / 10000 < 0.45
                THEN 1.2 + (CRC32(CONCAT(c.cliente_id, 'f2')) % 10000) / 10000 * 1.6
            ELSE     0.2 + (CRC32(CONCAT(c.cliente_id, 'f3')) % 10000) / 10000 * 0.7
        END AS pedidos_mes,
        1 + (CRC32(CONCAT(c.cliente_id, 'vend')) % 8) AS vendedor_id
    FROM dim_cliente c
) p
WHERE fin > inicio;

-- -----------------------------------------------------------------------------
-- PEDIDOS
-- -----------------------------------------------------------------------------
-- El JOIN contra `seq` expande cada cliente en tantas filas como pedidos tenga.
-- La fecha se sortea combinando cliente_id y número de pedido, para que cada
-- pedido caiga en un día distinto dentro de la ventana activa del cliente.
-- -----------------------------------------------------------------------------
INSERT INTO fact_pedido (fecha, cliente_id, vendedor_id, canal_venta, estado)
SELECT
    -- se corren los domingos al lunes: la distribuidora no reparte domingo
    CASE WHEN DAYOFWEEK(f) = 1 THEN DATE_ADD(f, INTERVAL 1 DAY) ELSE f END,
    cliente_id,
    vendedor_id,
    CASE
        WHEN r_canal < 0.46 THEN 'Preventa'
        WHEN r_canal < 0.78 THEN 'WhatsApp'
        WHEN r_canal < 0.94 THEN 'Mostrador'
        ELSE 'Web'
    END,
    CASE
        WHEN r_estado < 0.031 THEN 'cancelado'
        WHEN r_estado < 0.045 THEN 'pendiente'
        ELSE 'entregado'
    END
FROM (
    SELECT
        p.cliente_id,
        p.vendedor_id,
        DATE_ADD(p.inicio, INTERVAL FLOOR(
            (CRC32(CONCAT(p.cliente_id, '-', s.n, '-fecha')) % 10000) / 10000
            * DATEDIFF(p.fin, p.inicio)) DAY) AS f,
        (CRC32(CONCAT(p.cliente_id, '-', s.n, '-canal'))  % 10000) / 10000 AS r_canal,
        (CRC32(CONCAT(p.cliente_id, '-', s.n, '-estado')) % 10000) / 10000 AS r_estado
    FROM perfil_cliente p
    JOIN seq s ON s.n <= p.n_pedidos
) x;

-- Estacionalidad: refuerzo de pedidos entre el 5 de noviembre y fin de año.
-- Sin esto la serie mensual sería plana y no habría nada interesante que
-- encontrar en el análisis temporal.
INSERT INTO fact_pedido (fecha, cliente_id, vendedor_id, canal_venta, estado)
SELECT
    f, cliente_id, vendedor_id,
    CASE WHEN r_canal < 0.5 THEN 'Preventa' ELSE 'WhatsApp' END,
    CASE WHEN r_estado < 0.03 THEN 'cancelado' ELSE 'entregado' END
FROM (
    SELECT
        p.cliente_id,
        p.vendedor_id,
        DATE_ADD(t.arranque, INTERVAL FLOOR(
            (CRC32(CONCAT(p.cliente_id, '-', s.n, '-', t.arranque, '-fest')) % 10000)
            / 10000 * 50) DAY) AS f,
        (CRC32(CONCAT(p.cliente_id, '-', s.n, '-', t.arranque, '-c')) % 10000) / 10000 AS r_canal,
        (CRC32(CONCAT(p.cliente_id, '-', s.n, '-', t.arranque, '-e')) % 10000) / 10000 AS r_estado
    FROM perfil_cliente p
    CROSS JOIN (SELECT DATE '2024-11-05' AS arranque
                UNION ALL SELECT DATE '2025-11-05') t
    JOIN seq s ON s.n <= GREATEST(1, ROUND(p.pedidos_mes * 0.9))
    WHERE p.inicio <= t.arranque                          -- el cliente ya estaba activo
      AND p.fin    >  DATE_ADD(t.arranque, INTERVAL 50 DAY)
) x;

-- -----------------------------------------------------------------------------
-- LÍNEAS DE PEDIDO
-- -----------------------------------------------------------------------------
-- La cantidad de líneas se deriva del pedido_id: entre 1 y 9, sesgada hacia
-- pedidos chicos con POW(u, 1.4). La elección de SKU usa POW(u, 2.2) para que
-- unos pocos productos concentren la mayor parte del volumen (Pareto realista).
--
-- Los precios arrastran una deriva mensual del 1,2% (contexto inflacionario):
-- por eso el análisis temporal separa crecimiento en pesos de crecimiento en
-- unidades.
-- -----------------------------------------------------------------------------
INSERT INTO fact_pedido_item
    (pedido_id, linea, producto_id, cantidad, precio_unitario, descuento_pct, costo_unitario)
SELECT
    pedido_id,
    ROW_NUMBER() OVER (PARTITION BY pedido_id ORDER BY producto_id) AS linea,
    producto_id,
    cantidad,
    -- 0,4% de precios en cero: error de carga inyectado a propósito
    CASE WHEN r_cero < 0.004 THEN 0
         ELSE ROUND(precio_lista * infl * (0.97 + r_ruido * 0.06), 2)
    END,
    descuento,
    ROUND(costo_base * infl * (0.98 + r_ruido2 * 0.04), 2)
FROM (
    SELECT DISTINCT
        l.pedido_id,
        l.producto_id,
        l.cantidad,
        l.descuento,
        l.infl,
        l.r_cero,
        l.r_ruido,
        l.r_ruido2,
        pr.precio_lista,
        pr.costo_unitario AS costo_base
    FROM (
        SELECT
            p.pedido_id,
            1 + FLOOR(POW((CRC32(CONCAT(p.pedido_id, '-', s.n, '-prod')) % 10000) / 10000,
                          2.2) * 320) AS producto_id,
            1 + FLOOR(POW((CRC32(CONCAT(p.pedido_id, '-', s.n, '-cant')) % 10000) / 10000,
                          1.8) * 15)  AS cantidad,
            CASE
                WHEN (CRC32(CONCAT(p.pedido_id, '-', s.n, '-desc')) % 10000) / 10000 < 0.58 THEN 0.000
                WHEN (CRC32(CONCAT(p.pedido_id, '-', s.n, '-desc')) % 10000) / 10000 < 0.80 THEN 0.050
                WHEN (CRC32(CONCAT(p.pedido_id, '-', s.n, '-desc')) % 10000) / 10000 < 0.93 THEN 0.100
                ELSE 0.150
            END AS descuento,
            POW(1.012, TIMESTAMPDIFF(MONTH, '2024-09-01', p.fecha)) AS infl,
            (CRC32(CONCAT(p.pedido_id, '-', s.n, '-cero'))  % 10000) / 10000 AS r_cero,
            (CRC32(CONCAT(p.pedido_id, '-', s.n, '-ruido')) % 10000) / 10000 AS r_ruido,
            (CRC32(CONCAT(p.pedido_id, '-', s.n, '-ruid2')) % 10000) / 10000 AS r_ruido2
        FROM fact_pedido p
        JOIN seq s
          ON s.n <= 1 + FLOOR(POW(((p.pedido_id * 7919) % 1000) / 1000.0, 1.4) * 9)
    ) l
    JOIN dim_producto pr ON pr.producto_id = l.producto_id
) d;

ANALYZE TABLE dim_cliente, dim_producto, fact_pedido, fact_pedido_item;
