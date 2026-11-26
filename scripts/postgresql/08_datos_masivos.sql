\encoding UTF8
-- =============================================================================
-- 08_datos_masivos.sql  ·  Fase 3  ·  Responsable: Isaac
-- Genera un set de datos de prueba masivo para reproducir la crisis de temporada alta.
-- Con escala 1: 50 mil clientes, 2 mil productos, ~1 millón de facturas en 24 meses y
-- ~3 millones de renglones de detalle (unos 600 MB con índices).
--
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -v escala=1 -f 08_datos_masivos.sql
--
-- Tarda de 3 a 8 minutos según la máquina. Si la VM es lenta usen escala=0.3.
-- OJO con el RTO: más datos = restauración más lenta. Midan el tiempo de restauración en la
-- Fase 4 y, si pasa de 3 minutos, bajen la escala. Ese equilibrio va en el reporte.
--
-- Las facturas se insertan en orden de fecha, como pasa en la vida real (se agregan al final).
-- Eso importa para el índice BRIN de la Fase 3.
-- =============================================================================
\set ON_ERROR_STOP on
\if :{?escala}
\else
    \set escala 1
\endif
\timing on
SET ROLE rol_propietario;
SET synchronous_commit = off;           -- solo para esta carga: acelera los INSERT masivos

-- ---------- Productos (hasta 2,000) ----------
INSERT INTO erp.productos (sku, nombre, categoria, unidad, precio_lista, precio_exportacion, es_exportacion)
SELECT 'ADV-' || lpad(g::text, 4, '0'),
       (ARRAY['Salsa', 'Conserva', 'Frijol', 'Garbanzo', 'Mango', 'Chile', 'Harina', 'Tomate', 'Elote', 'Pepino'])[1 + g % 10]
           || ' línea ' || (g % 37) || ' presentación ' || (1 + g % 5),
       (ARRAY['Conservas', 'Granos', 'Deshidratados', 'Salsas', 'Harinas', 'Refrigerados'])[1 + g % 6],
       CASE WHEN g % 9 = 0 THEN 'BULTO' ELSE 'PZA' END,
       round((15 + (g % 97) * 7.3)::numeric, 2),
       CASE WHEN g % 4 = 0 THEN round((20 + (g % 97) * 8.9)::numeric, 2) END,
       g % 4 = 0
FROM generate_series((SELECT count(*) FROM erp.productos)::int + 1, 2000) AS g;

-- ---------- Clientes ----------
INSERT INTO erp.clientes (rfc, razon_social, tipo, telefono, email, ciudad, es_vip, creado_en)
SELECT 'GEN' || lpad(g::text, 9, '0') || '1',
       'Cliente mayorista ' || g,
       (ARRAY['MAYORISTA', 'MAYORISTA', 'MINORISTA', 'EXPORTACION'])[1 + g % 4],
       '667' || lpad((g % 10000000)::text, 7, '0'),
       'cliente' || g || '@correo.example',
       (ARRAY['Culiacán', 'Mazatlán', 'Los Mochis', 'Guasave', 'Navolato', 'Guamúchil'])[1 + g % 6],
       g % 50 = 0,
       now() - (g % 1500) * interval '1 day'
FROM generate_series(1, (50000 * :escala)::int) AS g;

-- ---------- Facturas: 24 meses, en orden cronológico ----------
INSERT INTO erp.facturas (folio, cliente_id, sucursal_id, fecha, estado)
SELECT 'F-' || lpad(n::text, 8, '0'),
       1 + floor(random() * (SELECT max(id) FROM erp.clientes))::int,
       1 + floor(random() * 6)::int,
       fecha,
       CASE WHEN r < 0.85 THEN 'PAGADA' WHEN r < 0.95 THEN 'PENDIENTE' ELSE 'CANCELADA' END
FROM (
    SELECT row_number() OVER (ORDER BY fecha) AS n, fecha, random() AS r
    FROM (SELECT date_trunc('second', now() - interval '730 days' + random() * interval '730 days') AS fecha
          FROM generate_series(1, (1000000 * :escala)::int)) x
) y
ORDER BY fecha;

-- ---------- Detalle: de 1 a 5 renglones por factura (promedio 3) ----------
-- Los productos más vendidos salen más seguido (random() al cuadrado sesga hacia los primeros).
INSERT INTO erp.detalle_factura (factura_id, producto_id, cantidad, precio_unitario)
SELECT f.id, x.producto_id, 1 + floor(random() * 24)::int, round((15 + (x.producto_id % 97) * 7.3)::numeric, 2)
FROM (SELECT array_agg(id ORDER BY id) AS ids FROM erp.productos) pr
CROSS JOIN erp.facturas f
CROSS JOIN LATERAL generate_series(1, 1 + (f.id % 5)::int) AS g
CROSS JOIN LATERAL (SELECT pr.ids[1 + floor(power(random(), 2) * (array_length(pr.ids, 1) - 1))::int + (g * 0)] AS producto_id) x
WHERE f.folio LIKE 'F-%';

-- ---------- Totales de cada factura ----------
UPDATE erp.facturas f SET subtotal = d.s, iva = round(d.s * 0.16, 2), total = round(d.s * 1.16, 2)
FROM (SELECT factura_id, sum(importe) AS s FROM erp.detalle_factura GROUP BY factura_id) d
WHERE d.factura_id = f.id AND f.folio LIKE 'F-%';

-- ---------- Cuentas por cobrar de las facturas pendientes ----------
INSERT INTO erp.cuentas_por_cobrar (factura_id, cliente_id, vencimiento, saldo)
SELECT id, cliente_id, (fecha + interval '30 days')::date, total
FROM erp.facturas WHERE estado = 'PENDIENTE' AND folio LIKE 'F-%';

RESET ROLE;
VACUUM (ANALYZE) erp.facturas;
VACUUM (ANALYZE) erp.detalle_factura;
ANALYZE erp.clientes;
ANALYZE erp.productos;
ANALYZE erp.cuentas_por_cobrar;

\echo ''
\echo '=== Volumen generado ==='
SELECT relname AS tabla, n_live_tup AS filas,
       pg_size_pretty(pg_total_relation_size(relid)) AS tamano_con_indices
FROM pg_stat_user_tables WHERE schemaname = 'erp' ORDER BY n_live_tup DESC;
