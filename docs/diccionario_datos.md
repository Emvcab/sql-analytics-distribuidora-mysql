# Diccionario de datos

Base `mayorista`. MySQL 8.0, motor InnoDB, charset `utf8mb4`.

## Modelo

Esquema estrella con dos tablas de hechos a distinto grano.

```
                        dim_calendario
                              |
   dim_cliente ------- fact_pedido ------- dim_vendedor
                              |
                     fact_pedido_item ------- dim_producto
```

`fact_pedido` guarda la cabecera (un pedido). `fact_pedido_item` guarda el detalle (una línea de producto dentro de un pedido). Separarlos evita repetir los datos de cabecera en cada línea y permite contar pedidos sin `DISTINCT` en la mayoría de los casos.

---

## dim_cliente

Comercios minoristas que compran a la distribuidora.

| Columna | Tipo | Descripción |
|---|---|---|
| `cliente_id` | INT PK AUTO_INCREMENT | Identidad |
| `razon_social` | VARCHAR(120) | Nombre del comercio. **Admite duplicados**: refleja carga imperfecta del ERP |
| `canal` | VARCHAR(20) | Kiosco, Almacén, Autoservicio, Minimercado, Supermercado, Distribuidor |
| `zona` | VARCHAR(40) | Zona comercial. **Admite NULL** (~2%): campo incompleto en origen |
| `localidad` | VARCHAR(60) | Localidad de Santiago del Estero |
| `fecha_alta` | DATE | Alta en el sistema. Puede ser anterior al inicio del período analizado |
| `limite_credito` | DECIMAL(12,2) | Cupo de cuenta corriente |

## dim_producto

| Columna | Tipo | Descripción |
|---|---|---|
| `producto_id` | INT PK AUTO_INCREMENT | Identidad |
| `nombre` | VARCHAR(150) | Descripción más marca |
| `categoria` | VARCHAR(40) | Almacén, Bebidas, Lácteos, Limpieza, Perfumería, Golosinas, Snacks |
| `subcategoria` | VARCHAR(40) | Desagregación dentro de la categoría |
| `marca` | VARCHAR(40) | 14 marcas ficticias |
| `unidad_bulto` | SMALLINT | Unidades por bulto (6, 12 o 24) |
| `costo_unitario` | DECIMAL(12,2) | Costo **de referencia** |
| `precio_lista` | DECIMAL(12,2) | Precio **de referencia**, sin descuentos |

> Los valores de referencia no sirven para calcular facturación. Siempre usar los de `fact_pedido_item`, que reflejan el precio vigente al momento de la venta.

## dim_vendedor

| Columna | Tipo | Descripción |
|---|---|---|
| `vendedor_id` | SMALLINT PK | 8 vendedores |
| `nombre` | VARCHAR(80) | Apellido y nombre |
| `zona` | VARCHAR(40) | Zona a cargo |
| `fecha_ingreso` | DATE | Ingreso a la empresa |

## dim_calendario

Un registro por día entre 2024-09-01 y 2026-08-31 (730 filas).

| Columna | Tipo | Descripción |
|---|---|---|
| `fecha` | DATE PK | Fecha |
| `anio`, `mes`, `dia`, `trimestre` | SMALLINT | Partes de la fecha |
| `anio_mes` | CHAR(7) | `'YYYY-MM'`, para agrupar y ordenar como texto |
| `nombre_mes`, `nombre_dia` | VARCHAR | En español |
| `dia_semana` | SMALLINT | **0 = domingo.** `DAYOFWEEK()` de MySQL devuelve 1 para domingo; se le resta 1 al cargar para mantener la misma semántica que `EXTRACT(dow)` de PostgreSQL |
| `es_fin_semana` | TINYINT(1) | Sábado o domingo. MySQL no tiene tipo booleano real |
| `es_feriado` | TINYINT(1) | Feriados nacionales argentinos de fecha fija |

> Existe para poder detectar períodos **sin** actividad. Un `GROUP BY` sobre la tabla de hechos nunca puede mostrar un día que no tiene filas.

## fact_pedido

Cabecera. Grano: un pedido.

| Columna | Tipo | Descripción |
|---|---|---|
| `pedido_id` | BIGINT PK AUTO_INCREMENT | Identidad |
| `fecha` | DATE FK | → `dim_calendario` |
| `cliente_id` | INT FK | → `dim_cliente` |
| `vendedor_id` | SMALLINT FK | → `dim_vendedor` |
| `canal_venta` | VARCHAR(15) | Preventa, WhatsApp, Mostrador, Web |
| `estado` | VARCHAR(12) | entregado, cancelado, pendiente |

> **`estado` es el filtro más importante del modelo.** Un 4,5% de los pedidos no está entregado. Todo análisis de facturación debe incluir `WHERE estado = 'entregado'`; omitirlo infla las ventas un 4,4%.

## fact_pedido_item

Detalle. Grano: una línea de producto dentro de un pedido.

| Columna | Tipo | Descripción |
|---|---|---|
| `pedido_id` | BIGINT PK/FK | → `fact_pedido` |
| `linea` | SMALLINT PK | Número de línea dentro del pedido |
| `producto_id` | INT FK | → `dim_producto` |
| `cantidad` | INT | Unidades vendidas |
| `precio_unitario` | DECIMAL(12,2) | Precio efectivo al momento de la venta. **488 líneas tienen 0**: error de carga |
| `descuento_pct` | DECIMAL(4,3) | Descuento aplicado, de 0 a 0,150 |
| `costo_unitario` | DECIMAL(12,2) | Costo efectivo al momento de la venta |
| `importe_bruto` | DECIMAL(14,2) | **Generada**: `cantidad * precio_unitario` |
| `importe_neto` | DECIMAL(14,2) | **Generada**: `cantidad * precio_unitario * (1 - descuento_pct)` |
| `margen` | DECIMAL(14,2) | **Generada**: `cantidad * (precio_unitario * (1 - descuento_pct) - costo_unitario)` |

Las tres últimas son columnas `GENERATED ALWAYS AS ... STORED`: las calcula el motor, no se pueden insertar ni actualizar a mano. Garantiza que ninguna fila tenga un importe que no cierre con la aritmética.

## seq

| Columna | Tipo | Descripción |
|---|---|---|
| `n` | INT PK | Números del 1 al 2000 |

Tabla auxiliar. MySQL no tiene `generate_series()`, así que el generador de datos usa esta tabla como fuente de filas. Se carga con una CTE recursiva en `01_schema.sql`.

---

## Vistas y objetos derivados

| Objeto | Tipo | Uso |
|---|---|---|
| `v_ventas` | Vista | Denormalización de todo el modelo. El join que se repite en el 90% de las consultas. **No filtra estado**: cada consulta decide |
| `v_kpi_mensual` | Vista | KPIs mensuales. Fuente única para BI |
| `v_rfm` | Vista | Puntajes RFM y segmento por cliente. La crea `50_rfm_segmentacion.sql` |
| `mv_ficha_cliente` | **Tabla** | Ficha 360 por cliente. Emula una vista materializada |
| `sp_refresh_ficha_cliente()` | Procedimiento | Reconstruye `mv_ficha_cliente`. Reemplaza al `REFRESH MATERIALIZED VIEW` de PostgreSQL |
| `v_alertas` | Vista | Alertas operativas listas para dashboard |

MySQL no tiene vistas materializadas. El patrón estándar es tabla real más procedimiento de refresh, programado con el Event Scheduler:

```sql
SET GLOBAL event_scheduler = ON;
CREATE EVENT ev_refresh_ficha ON SCHEDULE EVERY 1 DAY
    STARTS '2026-01-01 03:00:00'
    DO CALL sp_refresh_ficha_cliente();
```

A diferencia del `REFRESH CONCURRENTLY` de PostgreSQL, este refresh bloquea la tabla mientras corre. Por eso se programa de madrugada.

---

## Índices

| Índice | Tabla | Para qué |
|---|---|---|
| `idx_pedido_fecha` | fact_pedido | Filtro temporal, el más usado |
| `idx_pedido_estado_fecha` | fact_pedido | Sustituto del índice parcial de PostgreSQL |
| `idx_pedido_cliente_fecha` | fact_pedido | Patrón "última compra por cliente" (RFM, alertas) |
| `idx_pedido_canal` | fact_pedido | Demostración de impacto en `95_optimizacion.sql` |
| `idx_producto_categoria` | dim_producto | Filtros por categoría |

**InnoDB crea automáticamente un índice por cada FOREIGN KEY**, así que `cliente_id`, `vendedor_id` y `producto_id` ya están indexados sin declararlo. Y no se pueden borrar mientras exista la FK: MySQL devuelve `ERROR 1553: Cannot drop index ... needed in a foreign key constraint`. Es una diferencia concreta con PostgreSQL, donde las FK no exigen índice del lado que referencia.

MySQL **no soporta índices parciales** (`CREATE INDEX ... WHERE condicion`). La versión PostgreSQL de este proyecto usa uno sobre `estado = 'entregado'`, que cubre el 95% de las consultas con un índice más chico. Acá se reemplaza por un compuesto que arranca con `estado`: permite filtrar por estado y fecha en una sola pasada, pero incluye también cancelados y pendientes.

---

## Convenciones

- Prefijo `dim_` para dimensiones, `fact_` para hechos, `v_` para vistas, `mv_` para materializadas, `sp_` para procedimientos
- Los importes son `DECIMAL`, nunca `FLOAT` ni `DOUBLE`: con dinero, el redondeo binario acumula error
- Fechas en `DATE`, sin hora: el grano del negocio es diario
- Nombres en español, en minúscula y con guión bajo
