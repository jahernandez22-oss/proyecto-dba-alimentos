\encoding UTF8
-- =============================================================================
-- 10_optimizacion.sql  ·  Fase 3  ·  Responsable: Isaac
-- El "DESPUÉS": cuatro correcciones, cada una medida con EXPLAIN para justificarla.
--   1. Reescribir el filtro de fecha como rango (consulta "sargable").
--   2. Índices: B-tree parcial y de cobertura en facturas, índice para la llave foránea del
--      detalle, y BRIN como alternativa diminuta para datos que llegan en orden de fecha.
--   3. Vista materializada: el reporte lee un resumen ya calculado.
--   4. Límites por rol: el reporte no puede acaparar los núcleos que usan las cajas.
--
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -f 10_optimizacion.sql
-- =============================================================================
\set ON_ERROR_STOP on
\timing on
SELECT to_char(date_trunc('month', now()) - interval '1 month', 'YYYY-MM-DD') AS desde,
       to_char(date_trunc('month', now()), 'YYYY-MM-DD') AS hasta \gset
SET ROLE rol_propietario;

-- -----------------------------------------------------------------------------
-- PASO 1. Solo reescribir el filtro (sin índices todavía): ¿cambia algo?
-- -----------------------------------------------------------------------------
\echo '=== Paso 1: filtro como rango de fechas, aún sin índices ==='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT s.nombre AS sucursal, p.categoria, count(DISTINCT f.id) AS facturas, sum(d.cantidad) AS piezas, sum(d.importe) AS venta
FROM erp.facturas f
JOIN erp.detalle_factura d ON d.factura_id = f.id
JOIN erp.productos p ON p.id = d.producto_id
JOIN erp.sucursales s ON s.id = f.sucursal_id
WHERE f.fecha >= :'desde' AND f.fecha < :'hasta' AND f.estado <> 'CANCELADA'
GROUP BY s.nombre, p.categoria ORDER BY venta DESC;

-- -----------------------------------------------------------------------------
-- PASO 2. Índices justificados (cada uno contesta una parte del plan)
-- -----------------------------------------------------------------------------
-- 2a. Facturas por fecha, solo las vigentes (parcial) y con sucursal incluida (cobertura):
--     encuentra el mes sin tocar la tabla y no indexa las canceladas, que nunca se reportan.
CREATE INDEX ix_facturas_fecha_vigentes ON erp.facturas (fecha) INCLUDE (sucursal_id)
    WHERE estado <> 'CANCELADA';
-- 2b. La llave foránea del detalle: sin este índice, cada factura obliga a recorrer el detalle.
--     INCLUDE permite "Index Only Scan": todo lo que el reporte necesita está en el índice.
CREATE INDEX ix_detalle_factura ON erp.detalle_factura (factura_id) INCLUDE (producto_id, cantidad, importe);
-- 2c. BRIN: guarda el mínimo y máximo de fecha por bloque de páginas. Pesa kilobytes en lugar
--     de megabytes, pero solo sirve si las filas están físicamente en orden de fecha (así se
--     cargaron). Se crea para comparar tamaños y planes; el B-tree parcial es el que se queda.
CREATE INDEX ix_facturas_fecha_brin ON erp.facturas USING brin (fecha);
ANALYZE erp.facturas;
ANALYZE erp.detalle_factura;

\echo '=== Paso 2: misma consulta con los índices ==='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT s.nombre AS sucursal, p.categoria, count(DISTINCT f.id) AS facturas, sum(d.cantidad) AS piezas, sum(d.importe) AS venta
FROM erp.facturas f
JOIN erp.detalle_factura d ON d.factura_id = f.id
JOIN erp.productos p ON p.id = d.producto_id
JOIN erp.sucursales s ON s.id = f.sucursal_id
WHERE f.fecha >= :'desde' AND f.fecha < :'hasta' AND f.estado <> 'CANCELADA'
GROUP BY s.nombre, p.categoria ORDER BY venta DESC;

\echo '=== Tamaño de cada índice (lo que cuesta en disco y en cada INSERT) ==='
SELECT indexrelname AS indice, pg_size_pretty(pg_relation_size(indexrelid)) AS tamano
FROM pg_stat_user_indexes WHERE schemaname = 'erp' AND relname IN ('facturas', 'detalle_factura')
ORDER BY pg_relation_size(indexrelid) DESC;

\echo '=== Comparación B-tree contra BRIN para buscar un mes (forzando cada uno) ==='
BEGIN;
DROP INDEX erp.ix_facturas_fecha_vigentes;     -- dentro de una transacción: se deshace abajo
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM erp.facturas WHERE fecha >= :'desde' AND fecha < :'hasta' AND estado <> 'CANCELADA';
ROLLBACK;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM erp.facturas WHERE fecha >= :'desde' AND fecha < :'hasta' AND estado <> 'CANCELADA';

-- -----------------------------------------------------------------------------
-- PASO 3. Vista materializada: el reporte deja de recalcular dos años de historia
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW reportes.mv_ventas_mensuales AS
SELECT date_trunc('month', f.fecha)::date AS mes, s.nombre AS sucursal, p.categoria,
       count(DISTINCT f.id) AS facturas, sum(d.cantidad) AS piezas, sum(d.importe) AS venta
FROM erp.facturas f
JOIN erp.detalle_factura d ON d.factura_id = f.id
JOIN erp.productos p ON p.id = d.producto_id
JOIN erp.sucursales s ON s.id = f.sucursal_id
WHERE f.estado <> 'CANCELADA'
GROUP BY 1, 2, 3;
-- El índice único permite REFRESH ... CONCURRENTLY: se actualiza sin bloquear a quien la lee
CREATE UNIQUE INDEX ux_mv_ventas_mensuales ON reportes.mv_ventas_mensuales (mes, sucursal, categoria);

\echo '=== Paso 3: el reporte leyendo la vista materializada ==='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT sucursal, categoria, facturas, piezas, venta
FROM reportes.mv_ventas_mensuales WHERE mes = :'desde'::date ORDER BY venta DESC;

-- Refresco: diario a las 02:00 (lo agenda Jesús en el Programador de tareas) o bajo demanda
CREATE FUNCTION reportes.refrescar_ventas() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, reportes AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY reportes.mv_ventas_mensuales;
END $$;
RESET ROLE;
GRANT SELECT ON reportes.mv_ventas_mensuales TO rol_reportes;
GRANT EXECUTE ON FUNCTION reportes.refrescar_ventas() TO rol_reportes;   -- solo puede refrescar, nada más

-- -----------------------------------------------------------------------------
-- PASO 4. Gobierno de recursos: el reporte no puede quitarle CPU a las cajas
-- -----------------------------------------------------------------------------
ALTER ROLE app_reportes SET max_parallel_workers_per_gather = 1;   -- a lo más 2 núcleos (líder + 1)
ALTER ROLE app_reportes SET work_mem = '64MB';                     -- ordenar en memoria, no en disco
ALTER ROLE app_reportes SET statement_timeout = '120s';
ALTER ROLE app_ventas   SET max_parallel_workers_per_gather = 0;   -- las cajas hacen consultas cortas

\echo '=== Reporte final con los datos del mes (debe coincidir con el ANTES) ==='
SELECT sucursal, categoria, facturas, venta FROM reportes.mv_ventas_mensuales
WHERE mes = :'desde'::date ORDER BY venta DESC LIMIT 5;
