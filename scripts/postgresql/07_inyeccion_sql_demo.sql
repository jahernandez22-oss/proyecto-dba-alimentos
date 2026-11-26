\encoding UTF8
-- =============================================================================
-- 07_inyeccion_sql_demo.sql  ·  Fase 2  ·  Responsable: Isaac
-- Demostración de inyección SQL: cómo funciona, cómo se previene y cómo el privilegio
-- mínimo contiene el daño aunque una consulta sea vulnerable.
--
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -f 07_inyeccion_sql_demo.sql
--
-- La inyección ocurre cuando el código PEGA texto del usuario dentro de la sentencia SQL.
-- El motor no distingue entre "lo que el programador escribió" y "lo que el usuario tecleó".
-- La defensa es separar el código de los datos: parámetros ($1, USING, %L), nunca concatenar.
-- =============================================================================
\set ON_ERROR_STOP on
SET ROLE rol_propietario;

-- VULNERABLE: arma la consulta concatenando lo que el usuario escribió en la pantalla de búsqueda
CREATE OR REPLACE FUNCTION erp.buscar_cliente_vulnerable(p_rfc text)
RETURNS TABLE (id integer, rfc varchar, razon_social text, ciudad text)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT id, rfc, razon_social, ciudad FROM erp.clientes WHERE rfc = ''' || p_rfc || '''';
END $$;

-- SEGURA (opción 1): SQL estático; el parámetro nunca se interpreta como código
CREATE OR REPLACE FUNCTION erp.buscar_cliente(p_rfc text)
RETURNS TABLE (id integer, rfc varchar, razon_social text, ciudad text)
LANGUAGE sql STABLE AS $$
    SELECT c.id, c.rfc, c.razon_social, c.ciudad FROM erp.clientes c WHERE c.rfc = p_rfc
$$;

-- SEGURA (opción 2): si de verdad se necesita SQL dinámico, el valor va con USING
CREATE OR REPLACE FUNCTION erp.buscar_cliente_dinamico(p_columna text, p_valor text)
RETURNS TABLE (id integer, rfc varchar, razon_social text, ciudad text)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_columna NOT IN ('rfc', 'ciudad', 'razon_social') THEN      -- lista blanca de columnas
        RAISE EXCEPTION 'Columna no permitida: %', p_columna;
    END IF;
    RETURN QUERY EXECUTE format('SELECT id, rfc, razon_social, ciudad FROM erp.clientes WHERE %I = $1', p_columna)
        USING p_valor;
END $$;

RESET ROLE;
GRANT EXECUTE ON FUNCTION erp.buscar_cliente_vulnerable(text), erp.buscar_cliente(text),
                          erp.buscar_cliente_dinamico(text, text) TO rol_app_ventas;

-- Todo lo que sigue se ejecuta COMO LA APLICACIÓN (app_ventas), como pasaría en producción
SET ROLE app_ventas;

\echo ''
\echo '=== 1. Uso normal: buscar un RFC ==='
SELECT * FROM erp.buscar_cliente_vulnerable('ABA850101AB1');

\echo '=== 2. Inyección clásica: el "RFC" es  x'' OR ''1''=''1  -> devuelve TODOS los clientes ==='
SELECT * FROM erp.buscar_cliente_vulnerable($$x' OR '1'='1$$);

\echo '=== 3. Inyección UNION: intenta robar los usuarios del sistema ==='
SELECT * FROM erp.buscar_cliente_vulnerable($$x' UNION SELECT id, usuario::varchar, nombre, rol_app FROM seguridad.usuarios_sistema --$$);

\echo '=== 4. ...y sus contraseñas. El privilegio mínimo lo detiene: app_ventas no puede leer password_hash ==='
\set ON_ERROR_STOP off
SELECT * FROM erp.buscar_cliente_vulnerable($$x' UNION SELECT id, password_hash::varchar, nombre, rol_app FROM seguridad.usuarios_sistema --$$);
\echo '=== 5. ...o intentar con las tarjetas: tampoco ==='
SELECT * FROM erp.buscar_cliente_vulnerable($$x' UNION SELECT id, ultimos4::varchar, titular, marca FROM seguridad.tarjetas_vip --$$);
\set ON_ERROR_STOP on

\echo '=== 6. La misma cadena maliciosa contra la función segura: 0 filas ==='
SELECT * FROM erp.buscar_cliente($$x' OR '1'='1$$);
SELECT * FROM erp.buscar_cliente_dinamico('rfc', $$x' OR '1'='1$$);

\echo '=== 7. Sentencia preparada (lo que hace un driver con parámetros): 0 filas ==='
PREPARE buscar(text) AS SELECT id, rfc, razon_social FROM erp.clientes WHERE rfc = $1;
EXECUTE buscar($$x' OR '1'='1$$);
DEALLOCATE buscar;

RESET ROLE;

-- Lección para el reporte: la función vulnerable se BORRA después de la demostración.
DROP FUNCTION erp.buscar_cliente_vulnerable(text);
\echo 'Función vulnerable eliminada. En la app real, toda consulta usa parámetros.'
