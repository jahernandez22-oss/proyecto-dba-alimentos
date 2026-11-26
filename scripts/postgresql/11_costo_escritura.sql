\encoding UTF8
-- =============================================================================
-- 11_costo_escritura.sql  ·  Fase 3  ·  Responsable: Isaac
-- La otra cara de los índices: cada INSERT, UPDATE o DELETE también actualiza cada índice.
-- Mide cuánto tarda insertar 200 mil renglones de detalle con 0, 1, 2 y 3 índices, y
-- cuánto pesa cada configuración. Con estos números se justifica "lectura contra escritura".
--
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -f 11_costo_escritura.sql
-- Usa tablas temporales: no toca los datos reales.
-- =============================================================================
\set ON_ERROR_STOP on
CREATE TEMP TABLE resultados (escenario text, indices int, ms numeric, tamano_total text);

CREATE FUNCTION pg_temp.medir(p_escenario text, p_indices text[]) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    t0 timestamptz;
    i  text;
BEGIN
    DROP TABLE IF EXISTS pg_temp.banco;
    CREATE TEMP TABLE banco (factura_id bigint, producto_id int, cantidad int, importe numeric(14,2), fecha timestamptz);
    FOREACH i IN ARRAY p_indices LOOP
        EXECUTE format('CREATE INDEX ON pg_temp.banco %s', i);
    END LOOP;
    t0 := clock_timestamp();
    INSERT INTO pg_temp.banco
    SELECT g, 1 + g % 2000, 1 + g % 24, (g % 997) * 1.5, now() - (g % 730) * interval '1 day'
    FROM generate_series(1, 200000) AS g;
    INSERT INTO resultados VALUES (p_escenario, coalesce(array_length(p_indices, 1), 0),
        round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 0),
        pg_size_pretty(pg_total_relation_size('pg_temp.banco')));
END $$;

SELECT pg_temp.medir('Sin índices', ARRAY[]::text[]);
SELECT pg_temp.medir('+ B-tree factura_id', ARRAY['(factura_id)']);
SELECT pg_temp.medir('+ B-tree de cobertura', ARRAY['(factura_id)', '(factura_id) INCLUDE (producto_id, cantidad, importe)']);
SELECT pg_temp.medir('+ BRIN de fecha', ARRAY['(factura_id)', '(factura_id) INCLUDE (producto_id, cantidad, importe)', 'USING brin (fecha)']);
SELECT pg_temp.medir('+ B-tree de fecha (en vez de BRIN)', ARRAY['(factura_id)', '(factura_id) INCLUDE (producto_id, cantidad, importe)', '(fecha)']);

\echo '=== Costo en escritura de 200 mil INSERT según los índices ==='
SELECT escenario, indices, ms AS milisegundos,
       round(ms / NULLIF(first_value(ms) OVER (ORDER BY indices, ms), 0), 2) AS veces_mas_lento,
       tamano_total
FROM resultados ORDER BY indices, ms;

\echo '=== ¿Los índices reales se usan? (idx_scan = veces que el planificador los eligió) ==='
SELECT relname AS tabla, indexrelname AS indice, idx_scan AS usos,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamano
FROM pg_stat_user_indexes WHERE schemaname IN ('erp', 'reportes') ORDER BY idx_scan DESC, tabla;
-- Un índice con 0 usos durante semanas solo cuesta: se borra. Esa revisión es "mantenimiento".
