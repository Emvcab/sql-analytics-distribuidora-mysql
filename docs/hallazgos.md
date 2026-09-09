# Hallazgos

Resultados obtenidos al correr los scripts de análisis sobre el dataset generado por `02_seed.sql` en MySQL 8.0. Los números son reproducibles: el generador es determinístico, así que una carga nueva devuelve exactamente estos valores.

Período analizado: septiembre 2024 a agosto 2026 (24 meses).

---

## Volumen de la operación

| Métrica | Valor |
|---|---|
| Clientes en cartera | 850 |
| SKUs en catálogo | 320 |
| Pedidos registrados | 27.576 |
| Líneas de pedido | 117.693 |
| Facturación neta (entregados) | $1.725.779.154 |
| Margen bruto | 20,9% |
| Ticket promedio | $65.507 |

---

## 1. Calidad de datos: el 4,4% de la facturación no existe

El 4,5% de los pedidos está en estado cancelado o pendiente. Si un reporte no filtra por estado, sobreestima las ventas en **$79.513.394** sobre el período.

Otros problemas detectados antes de analizar nada:

| Problema | Casos | Efecto |
|---|---|---|
| Líneas con precio en cero | 488 | Hunden el ticket promedio y generan margen negativo falso |
| Clientes sin zona asignada | 20 (2,35%) | Quedan fuera de cualquier análisis territorial |
| Razones sociales duplicadas | varias | Un mismo comercio cuenta como dos clientes chicos en el RFM |

Las 488 líneas con precio en cero explican casi $6 millones de margen negativo. El script las separa del margen negativo por descuento excesivo, que es un problema comercial distinto: uno lo arregla sistemas, el otro el jefe de ventas.

**Implicancia:** todo análisis posterior filtra `estado = 'entregado'`. Esa decisión está documentada, no implícita.

---

## 2. Crecimiento real, no solo inflacionario

La facturación en pesos crece con fuerza, pero eso solo no dice nada en un contexto de precios en alza. La comparación contra unidades vendidas confirma que el crecimiento es genuino: en los 24 meses no aparece ningún período de crecimiento puramente nominal. El volumen físico acompaña al de pesos en todos los meses con base comparable.

---

## 3. Estacionalidad marcada en fin de año

Índice de estacionalidad sobre base 100 (mes promedio):

| Mes | Índice |
|---|---|
| Diciembre | 130 |
| Noviembre | 125 |

Noviembre y diciembre concentran el 21% de la facturación anual. Es información operativa concreta: define cuándo reforzar stock, cuándo pedir capital de trabajo y cuándo no tomar vacaciones en el depósito.

---

## 4. El Pareto real es 41/80

El hallazgo que más cambia la estrategia comercial.

| Objetivo de margen acumulado | Clientes necesarios | % de la cartera |
|---|---|---|
| 50% | 132 | 15,8% |
| 80% | 346 | **41,4%** |
| 90% | 497 | 59,4% |
| 95% | 604 | 72,2% |

La regla 80/20 no aplica acá. Para llegar al 80% del margen hacen falta 346 clientes, más del 40% de la cartera.

**Por qué importa:** una estrategia de "concentrarse en los 20 grandes" —que suele proponerse por defecto— dejaría fuera más de la mitad de la rentabilidad. La distribución de esta empresa es más plana que el promedio del rubro, y eso justifica sostener una fuerza de venta amplia en vez de una estructura de key accounts.

### Curva ABC de productos

| Clase | SKUs | % del catálogo | % de facturación |
|---|---|---|---|
| A | 152 | 47,5% | 79,8% |
| B | 102 | 31,9% | 15,1% |
| C | 66 | 20,6% | 5,0% |

Los 66 SKUs de clase C aportan el 5% de la facturación. Cada uno ocupa espacio de depósito, capital inmovilizado y un renglón en la lista de preventa. Son los primeros candidatos a revisión de catálogo.

---

## 5. Segmentación RFM: 42 clientes que hay que llamar

| Segmento | Clientes | Recencia prom. | Pedidos prom. | % del margen |
|---|---|---|---|---|
| Campeones | 221 | 7 días | 72,8 | 61,3% |
| Leales | 144 | 20 días | 28,9 | 15,9% |
| Dormidos | 219 | 161 días | 7,9 | 6,6% |
| **En riesgo (alto valor)** | **42** | **143 días** | **42,8** | **6,6%** |
| En riesgo | 74 | 100 días | 18,3 | 4,9% |
| Ocasionales | 77 | 23 días | 9,9 | 2,7% |
| Nuevos / Prometedores | 59 | 8 días | 7,7 | 1,9% |

El valor de la segmentación está en la comparación entre dos filas. Los 42 clientes en riesgo de alto valor promedian 42,8 pedidos históricos: son clientes que compraban mucho. Los 219 dormidos promedian 7,9: nunca compraron demasiado. Los dos grupos llevan meses sin aparecer y aportan el mismo 6,6% del margen, pero solo uno justifica que el jefe de ventas levante el teléfono esta semana.

Un ranking por facturación no permite distinguirlos, porque cruza el monto sin mirar la recencia ni la frecuencia.

---

## 6. Retención: 58% al primer mes

Retención promedio en el mes 1 a lo largo de todas las cohortes: **58,3%**.

La matriz completa está en `60_cohortes_retencion.sql`. Un detalle de implementación que vale la pena: las cohortes jóvenes devuelven `NULL` en las columnas de 6 y 12 meses en lugar de 0%. Mostrar 0% ahí sería un error de lectura grave —un cliente que entró el mes pasado no "perdió" la retención a 12 meses, todavía no llegó— y llevaría a promediar datos que no existen.

---

## 7. Concentración de la venta por categoría

| Categoría | % de facturación |
|---|---|
| Almacén | 27,3% |
| Bebidas | 21,0% |
| Lácteos | 18,0% |
| Limpieza | 17,1% |
| Perfumería | 9,0% |
| Golosinas | 4,9% |
| Snacks | 2,9% |

Almacén y Bebidas explican casi la mitad de la facturación.

---

## 8. Alertas operativas

El motor consolidado devuelve, priorizado por impacto mensual en pesos:

| Tipo de alerta | Severidad | Casos | Impacto mensual |
|---|---|---|---|
| Cliente dormido | Alta | 188 | $1.387.009 |
| Baja frecuencia de compra | Media | 210 | $1.141.086 |
| Descuento por encima de política | Media | 2 | $216 |
| Cliente sin zona asignada | Baja | 20 | — |

Un criterio de diseño que diferencia esto de una alerta genérica: los clientes dormidos no se detectan con un umbral fijo de días. Se compara los días sin comprar contra el **intervalo habitual de ese cliente en particular**. Un comercio que compra dos veces al año no está dormido a los 60 días; está comprando normal. Uno que compraba cada 5 días y lleva 20 sin aparecer sí lo está.

---

## 9. Rendimiento

Mediciones con `EXPLAIN ANALYZE` sobre esta base:

| Consulta | Sin optimizar | Optimizada | Mejora |
|---|---|---|---|
| Agregado por cliente (vista vs tabla materializada) | 244 ms | 0,20 ms | ~1.200x |
| Filtro por canal de venta (sin índice vs con índice) | 6,25 ms | 2,06 ms | 3x |
| Filtro de fecha con `YEAR()` vs rango | 4,43 ms | 0,34 ms | 13x |

El tercer caso es el más importante de los tres porque es un error de escritura, no de infraestructura: envolver la columna en una función inutiliza el índice. `WHERE YEAR(fecha) = 2026` obliga a recorrer las 27.576 filas; `WHERE fecha >= '2026-07-01' AND fecha < '2026-08-01'` usa el índice, lee 1.269 y devuelve lo mismo.

El script también incluye un caso donde el índice **no** sirve —un agregado sobre toda la tabla, donde MySQL elige correctamente ignorarlo— porque saber cuándo no indexar es parte del criterio.

---

## Nota sobre las diferencias con la versión PostgreSQL

Este mismo proyecto existe en PostgreSQL y sus números no son idénticos a estos. La razón es que la fuente de aleatoriedad es distinta: PostgreSQL usa `random()` con `setseed()`, y MySQL usa un pseudo-aleatorio derivado de `CRC32` porque no tiene equivalente a `setseed()`.

Los dos datasets tienen la misma estructura, los mismos sesgos programados y los mismos fenómenos a descubrir, pero las cifras exactas difieren. Las conclusiones no: el Pareto sigue siendo mucho más plano que 20/80, la curva ABC de productos concentra el 80% en menos de la mitad del catálogo, y el grupo de clientes en riesgo de alto valor aparece en ambos.

---

## Limitaciones

Los datos son sintéticos. Las relaciones entre variables son las que se programaron en el generador, así que los hallazgos demuestran capacidad analítica, no descubren nada sobre el mercado real de consumo masivo.

Lo que sí es real: el modelo dimensional, las consultas, las decisiones de diseño y los tiempos de ejecución medidos.
