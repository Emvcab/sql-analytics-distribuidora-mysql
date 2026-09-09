# Análisis de ventas de una distribuidora mayorista — SQL sobre MySQL 8.0

Modelo dimensional y análisis completo de la operación comercial de una distribuidora mayorista de consumo masivo: 850 clientes, 320 productos y 27.576 pedidos a lo largo de 24 meses.

Todo está resuelto en SQL. No hay pandas, no hay notebooks, no hay CSV: desde la generación del dataset hasta el motor de alertas, la base hace el trabajo.

Probado sobre **MySQL 8.0.46**, compatible con MySQL Workbench 8.0.

## Qué responde este proyecto

| Pregunta del negocio | Dónde |
|---|---|
| ¿Cuánto de lo que reporto es dato confiable? | `10_calidad_datos.sql` |
| ¿Crecemos de verdad o solo por inflación? | `20_kpis_temporales.sql` |
| ¿Qué productos sostienen la facturación y cuáles no rinden? | `30_ranking_productos.sql` |
| ¿Qué parte de la cartera me da el 80% del margen? | `40_pareto_abc.sql` |
| ¿A qué clientes llamo primero el lunes? | `50_rfm_segmentacion.sql` |
| ¿Los clientes nuevos se quedan o se van? | `60_cohortes_retencion.sql` |
| ¿Qué hago mañana con esta información? | `70_alertas.sql` |
| ¿Qué productos se piden juntos? | `80_cross_sell.sql` |
| ¿Cómo lo conecto a Power BI sin duplicar lógica? | `90_vistas.sql` |
| ¿Por qué esta consulta tarda 200 ms y no 15 s? | `95_optimizacion.sql` |

## Cuatro hallazgos

**El Pareto de esta empresa es 41/80, no 20/80.** Hacen falta 346 clientes de los 850 para llegar al 80% del margen. Una estrategia de "atender bien a los 20 más grandes" dejaría afuera más de la mitad de la rentabilidad, y eso justifica sostener una fuerza de venta amplia en vez de una estructura de key accounts.

**Un 4,4% de la facturación no es facturación.** Son pedidos cancelados y pendientes. Cualquier reporte que no filtre por estado sobreestima las ventas en unos 79,5 millones de pesos sobre el período.

**42 clientes de alto valor están en riesgo.** Compraban seguido, gastaban por encima del promedio y hace más de 100 días que no aparecen. Concentran el 6,6% del margen histórico. La segmentación RFM los separa del ruido de los 219 clientes dormidos que nunca valieron mucho.

**152 de 320 SKUs explican el 80% de la facturación.** Los 66 productos de clase C aportan el 5% y ocupan depósito, capital y espacio en la lista de preventa.

Los números completos están en [`docs/hallazgos.md`](docs/hallazgos.md).

## Cómo correrlo

### Desde MySQL Workbench 8.0

1. Abrí Workbench y conectate a tu instancia local.
2. `File > Open SQL Script...` y cargá `sql/01_schema.sql`. Ejecutalo con el rayo (⚡) o `Ctrl+Shift+Enter`.
3. Repetí con `02_seed.sql`, `03_indices.sql` y `90_vistas.sql`, **en ese orden**.
4. Listo. Ya podés abrir cualquier script de análisis.

> **Workbench no soporta el comando `SOURCE`**, así que `00_run_all.sql` no funciona desde ahí. Hay que cargar los cuatro archivos uno por uno. Desde la consola `mysql` sí anda.

Dos cosas que conviene saber de Workbench:

- Cada script tiene varias consultas. Si ejecutás todo junto, se abre una pestaña de resultados por cada una. Para ver una sola, seleccionala con el mouse y apretá `Ctrl+Enter`.
- Por defecto Workbench limita los resultados a 1000 filas. Se cambia en `Edit > Preferences > SQL Execution`.

### Desde la consola

```bash
mysql -u root -p
```
```sql
SOURCE /ruta/completa/sql/00_run_all.sql;
```

### Con Docker

```bash
docker compose up -d
docker compose exec -T db mysql -u root -panalista < sql/01_schema.sql
docker compose exec -T db mysql -u root -panalista < sql/02_seed.sql
docker compose exec -T db mysql -u root -panalista < sql/03_indices.sql
docker compose exec -T db mysql -u root -panalista < sql/90_vistas.sql
```

La carga tarda entre 20 y 60 segundos.

## Reproducibilidad

MySQL no tiene `setseed()`. En lugar de `RAND()`, toda la aleatoriedad del generador se deriva de forma **determinística** del identificador de cada fila:

```sql
(CRC32(CONCAT(id, 'sal')) % 10000) / 10000   -- pseudo-aleatorio en [0,1)
```

Cada "sal" produce una secuencia distinta e independiente, y el resultado es idéntico en cualquier máquina y en cualquier corrida. Es más robusto que `RAND(semilla)`, que en MySQL devuelve el mismo valor al llamarlo repetidamente con una semilla constante dentro de la misma sentencia.

Consecuencia práctica: cualquiera que clone el repo obtiene exactamente los números de `docs/hallazgos.md`.

## Modelo de datos

Esquema estrella. Dos tablas de hechos (cabecera y detalle de pedido) y cuatro dimensiones.

```
                        dim_calendario
                              |
   dim_cliente ------- fact_pedido ------- dim_vendedor
                              |
                     fact_pedido_item ------- dim_producto
```

El grano de `fact_pedido_item` es una línea de producto dentro de un pedido. `importe_neto` y `margen` son columnas `GENERATED ALWAYS AS ... STORED`: las calcula el motor, no se pueden insertar a mano, y no existe forma de que una fila tenga un importe que no cierre con la aritmética.

Diccionario completo en [`docs/diccionario_datos.md`](docs/diccionario_datos.md).

## Sobre los datos

Son sintéticos y se generan con SQL puro, sin dependencias externas. Están construidos para que los análisis tengan algo real que encontrar:

- **Estacionalidad**: diciembre índice 130 y noviembre 125 sobre una base 100
- **Deriva de precios**: 1,2% mensual, para poder separar crecimiento nominal de crecimiento real
- **Pareto en productos**: la elección de SKU está sesgada con `POW(u, 2.2)`
- **Churn**: un 10% de la cartera deja de comprar en algún punto del período
- **Problemas de calidad inyectados a propósito**: 20 clientes sin zona, 4,5% de pedidos no entregados, 488 líneas con precio en cero, razones sociales duplicadas

Ese último punto es deliberado. Un dataset perfecto haría que el script de auditoría no encontrara nada, y auditar antes de reportar es parte del trabajo.

## Técnicas de SQL cubiertas

`WINDOW FUNCTIONS` (`ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE`, `LAG`, `LEAD`) · frames explícitos `ROWS BETWEEN` · CTEs simples y encadenadas · CTE recursiva · agregados condicionales con `SUM(CASE WHEN ...)` · anti-joins con `NOT EXISTS` · self-joins para análisis de canasta · columnas `GENERATED` · índices compuestos · procedimiento almacenado para emular vistas materializadas · lectura de `EXPLAIN ANALYZE` · gaps and islands · cálculo de mediana sin función de percentil

## Diferencias con la versión PostgreSQL

Este proyecto existe también en PostgreSQL. Portarlo a MySQL obligó a resolver varias cosas que MySQL no tiene, y esas soluciones son parte de lo que el proyecto demuestra:

| PostgreSQL | MySQL 8.0 | Cómo se resolvió |
|---|---|---|
| `generate_series()` | no existe | Tabla `seq` con números 1..2000, generada con CTE recursiva |
| `setseed()` | no existe | Pseudo-aleatorio determinístico con `CRC32` |
| `FILTER (WHERE ...)` | no existe | `SUM(CASE WHEN ... THEN ... END)` |
| `MATERIALIZED VIEW` | no existe | Tabla real + `sp_refresh_ficha_cliente()` |
| Índices parciales | no existen | Índice compuesto que arranca por `estado` |
| `PERCENTILE_CONT` | no existe | `ROW_NUMBER` + `COUNT` sobre la partición |
| `DISTINCT ON` | no existe | `ROW_NUMBER()` filtrado por `rn = 1` |
| `array_agg()` | no existe | `GROUP_CONCAT()` |
| `date_trunc('month', x)` | — | `DATE_FORMAT(x, '%Y-%m-01')` |
| `age()` + `EXTRACT` | — | `TIMESTAMPDIFF(MONTH, a, b)` |
| CTE dentro de una vista | no permitido | Subconsultas anidadas |
| Se puede borrar el índice de una FK | no | InnoDB exige un índice por cada FK y no deja borrarlo |

## Estructura

```
sql/
├── 00_run_all.sql               carga completa (solo desde consola, no Workbench)
├── 01_schema.sql                DDL del modelo estrella + tabla seq
├── 02_seed.sql                  generador de datos reproducible
├── 03_indices.sql               estrategia de índices, con su justificación
├── 10_calidad_datos.sql         auditoría previa al análisis
├── 20_kpis_temporales.sql       evolución mensual, MoM, YoY, media móvil
├── 30_ranking_productos.sql     top N por grupo, márgenes por producto
├── 40_pareto_abc.sql            concentración de facturación, curva ABC
├── 50_rfm_segmentacion.sql      segmentación de cartera con NTILE
├── 60_cohortes_retencion.sql    matriz de retención por cohorte
├── 70_alertas.sql               motor de alertas priorizadas
├── 80_cross_sell.sql            market basket con soporte, confianza y lift
├── 90_vistas.sql                capa semántica + vista materializada emulada
├── 95_optimizacion.sql          planes de ejecución e índices medidos
└── 99_practica_entrevista.sql   12 ejercicios tipo prueba técnica, resueltos
docs/
├── diccionario_datos.md
└── hallazgos.md
docker-compose.yml
```

## Licencia

MIT.
