\encoding UTF8
-- =============================================================================
-- 09_reporte_mensual_antes.sql  ·  Fase 3  ·  Responsable: Isaac
-- El "ANTES": el reporte mensual de ventas tal como lo dejó el proveedor, y su plan de
-- ejecución. Es la consulta que dispara la CPU al 100 % y congela las cajas.
--
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -f 09_reporte_mensual_antes.sql
--
-- Cómo leer EXPLAIN (ANALYZE, BUFFERS):
--   - Se lee de ADENTRO hacia AFUERA: los nodos más indentados se ejecutan primero.
--   - Seq Scan = lee la tabla completa. Index Scan / Index Only Scan = usa un índice.
--   - "actual time=a..b": b es cuándo terminó ese nodo (ms). "rows" = filas reales.
--   - "Rows Removed by Filter": filas que leyó para nada. Ese número es el desperdicio.
--   - "Buffers: shared hit/read": páginas de 8 kB leídas de memoria / de disco.
--   - "Workers Launched": procesos en paralelo. Muchos workers = muchos núcleos al 100 %.
-- =============================================================================
\timing on
-- El mes a reportar: el mes anterior al actual
SELECT to_char(date_trunc('month', now()) - interval '1 month', 'YYYY-MM') AS mes \gset
\echo 'Mes del reporte:' :mes

-- Las estadísticas de este script se reinician para medir solo esta consulta
SELECT pg_stat_reset();

\echo ''
\echo '=== ANTES: plan de ejecución del reporte del proveedor ==='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT s.nombre AS sucursal, p.categoria,
       count(DISTINCT f.id) AS facturas, sum(d.cantidad) AS piezas, sum(d.importe) AS venta
FROM erp.facturas f
JOIN erp.detalle_factura d ON d.factura_id = f.id
JOIN erp.productos p ON p.id = d.producto_id
JOIN erp.sucursales s ON s.id = f.sucursal_id
WHERE to_char(f.fecha, 'YYYY-MM') = :'mes'      -- (1) función sobre la columna: ningún índice sirve
  AND f.estado <> 'CANCELADA'
GROUP BY s.nombre, p.categoria
ORDER BY venta DESC;

\echo ''
\echo '=== Resultado (para comparar después que el reporte optimizado da lo mismo) ==='
SELECT s.nombre AS sucursal, p.categoria, count(DISTINCT f.id) AS facturas, sum(d.importe) AS venta
FROM erp.facturas f
JOIN erp.detalle_factura d ON d.factura_id = f.id
JOIN erp.productos p ON p.id = d.producto_id
JOIN erp.sucursales s ON s.id = f.sucursal_id
WHERE to_char(f.fecha, 'YYYY-MM') = :'mes' AND f.estado <> 'CANCELADA'
GROUP BY s.nombre, p.categoria
ORDER BY venta DESC
LIMIT 5;

\echo '=== Lecturas completas de tabla (seq_scan) que provocó el reporte ==='
SELECT relname AS tabla, seq_scan, seq_tup_read AS filas_leidas, idx_scan
FROM pg_stat_user_tables WHERE relname IN ('facturas', 'detalle_factura') ORDER BY relname;

\echo '=== Índices que existen hoy en facturas y detalle_factura ==='
SELECT tablename AS tabla, indexname AS indice, indexdef AS definicion
FROM pg_indexes WHERE schemaname = 'erp' AND tablename IN ('facturas', 'detalle_factura') ORDER BY 1, 2;
-- Diagnóstico para el reporte:
--   (1) to_char(f.fecha, ...) obliga a calcular la función en CADA fila: no es "sargable".
--   (2) detalle_factura.factura_id es llave foránea SIN índice: PostgreSQL no lo crea solo.
--   (3) El reporte recalcula 2 años de historia cada vez que alguien lo pide.
--   (4) app_reportes puede usar todos los núcleos en paralelo y competir con las cajas.
