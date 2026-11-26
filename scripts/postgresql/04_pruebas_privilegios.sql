\encoding UTF8
-- =============================================================================
-- 04_pruebas_privilegios.sql  ·  Fase 1 (se vuelve a correr en cada fase)
-- Prueba automática del privilegio mínimo: cada fila intenta una acción con un rol
-- y compara lo que pasó con lo esperado. Todo cambio de prueba se deshace solo.
--
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -f 04_pruebas_privilegios.sql
--
-- Cómo funciona: postgres hace "SET ROLE <rol>" dentro de una subtransacción, ejecuta la
-- sentencia y la revierte. Mide PERMISOS (GRANT/REVOKE). Lo que filtra pg_hba.conf (IP,
-- TLS, contraseña) se prueba aparte conectándose desde el anfitrión, como dice la Guía 1.
-- La captura de esta tabla va en la Sección 2 del reporte.
-- =============================================================================
\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.probar(p_rol text, p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_resultado text;
BEGIN
    BEGIN
        EXECUTE format('SET LOCAL ROLE %I', p_rol);
        EXECUTE p_sql;
        v_resultado := 'PERMITIDO';
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'deshacer prueba';
    EXCEPTION
        WHEN insufficient_privilege THEN v_resultado := 'DENEGADO';
        WHEN raise_exception THEN
            IF v_resultado IS NULL THEN v_resultado := 'ERROR: ' || SQLERRM; END IF;
        WHEN OTHERS THEN v_resultado := 'ERROR: ' || SQLERRM;
    END;
    RETURN v_resultado;
END $$;

SELECT t.rol, t.prueba, t.esperado, x.obtenido,
       CASE WHEN x.obtenido = t.esperado THEN 'OK' ELSE 'REVISAR' END AS veredicto
FROM (VALUES
    (1,  'app_ventas',   'Consultar productos',                 'SELECT count(*) FROM erp.productos',                                              'PERMITIDO'),
    (2,  'app_ventas',   'Registrar una factura',               'INSERT INTO erp.facturas (folio, cliente_id, sucursal_id) VALUES (''T-1'', 1, 1)', 'PERMITIDO'),
    (3,  'app_ventas',   'Actualizar un precio (se audita)',    'UPDATE erp.productos SET precio_lista = precio_lista WHERE id = 1',               'PERMITIDO'),
    (4,  'app_ventas',   'Borrar facturas',                     'DELETE FROM erp.facturas',                                                         'DENEGADO'),
    (5,  'app_ventas',   'Vaciar facturas (TRUNCATE)',          'TRUNCATE erp.facturas CASCADE',                                                    'DENEGADO'),
    (6,  'app_ventas',   'Leer la nómina',                      'SELECT * FROM nomina.empleados',                                                   'DENEGADO'),
    (7,  'app_ventas',   'Leer tarjetas VIP',                   'SELECT * FROM seguridad.tarjetas_vip',                                             'DENEGADO'),
    (8,  'app_ventas',   'Leer usuarios con contraseña',        'SELECT * FROM seguridad.usuarios_sistema',                                         'DENEGADO'),
    (9,  'app_ventas',   'Leer teléfono y correo de clientes',  'SELECT telefono, email FROM erp.clientes',                                         'DENEGADO'),
    (10, 'app_ventas',   'Crear una tabla',                     'CREATE TABLE erp.tabla_intrusa (id int)',                                          'DENEGADO'),
    (11, 'app_ventas',   'Borrar una tabla',                    'DROP TABLE erp.pagos',                                                             'DENEGADO'),
    (12, 'app_ventas',   'Ejecutar comandos de Windows',        'COPY (SELECT 1) TO PROGRAM ''whoami''',                                            'DENEGADO'),
    (13, 'app_reportes', 'Leer ventas',                         'SELECT count(*) FROM erp.detalle_factura',                                         'PERMITIDO'),
    (14, 'app_reportes', 'Modificar una factura',               'UPDATE erp.facturas SET estado = ''CANCELADA''',                                   'DENEGADO'),
    (15, 'app_reportes', 'Leer datos de clientes',              'SELECT * FROM erp.clientes',                                                       'DENEGADO'),
    (16, 'rrhh_nomina',  'Consultar empleados',                 'SELECT num_empleado, nombre FROM nomina.empleados',                                'PERMITIDO'),
    (17, 'rrhh_nomina',  'Leer facturas',                       'SELECT * FROM erp.facturas',                                                       'DENEGADO'),
    (18, 'respaldo',     'Leer todo para pg_dump',              'SELECT count(*) FROM nomina.empleados',                                            'PERMITIDO'),
    (19, 'respaldo',     'Modificar datos',                     'UPDATE erp.productos SET precio_lista = 0',                                        'DENEGADO'),
    (20, 'auditor_ti',   'Leer facturas',                       'SELECT * FROM erp.facturas',                                                       'DENEGADO'),
    (21, 'dba_isaac',    'Crear un índice (vía rol_propietario)','CREATE INDEX ON erp.clientes (ciudad)',                                           'PERMITIDO')
) AS t(n, rol, prueba, sentencia, esperado)
CROSS JOIN LATERAL (SELECT pg_temp.probar(t.rol, t.sentencia) AS obtenido) x
ORDER BY t.n;

-- ---------- Pruebas que existen a partir de la Fase 2 (auditoría, cifrado y vistas) ----------
SELECT to_regclass('auditoria.bitacora_cambios') IS NOT NULL AS hay_fase2 \gset
\if :hay_fase2
SELECT t.rol, t.prueba, t.esperado, x.obtenido,
       CASE WHEN x.obtenido = t.esperado THEN 'OK' ELSE 'REVISAR' END AS veredicto
FROM (VALUES
    (22, 'auditor_ti',   'Leer la bitácora de auditoría',       'SELECT count(*) FROM auditoria.bitacora_cambios',                                  'PERMITIDO'),
    (23, 'app_ventas',   'Leer la bitácora de auditoría',       'SELECT * FROM auditoria.bitacora_cambios',                                         'DENEGADO'),
    (24, 'app_ventas',   'Validar un login (función)',          'SELECT seguridad.validar_login(''x'', ''y'')',                                     'PERMITIDO'),
    (25, 'app_ventas',   'Descifrar datos directamente',        'SELECT seguridad.descifrar(''\x00''::bytea)',                                      'DENEGADO'),
    (26, 'app_ventas',   'Consultar un salario',                'SELECT nomina.consultar_salario(''E-0001'')',                                      'DENEGADO'),
    (27, 'app_ventas',   'Ver tarjetas enmascaradas',           'SELECT * FROM seguridad.v_tarjetas_vip_enmascaradas',                              'PERMITIDO'),
    (28, 'rrhh_nomina',  'Leer el salario cifrado en crudo',    'SELECT salario_cifrado FROM nomina.empleados',                                     'DENEGADO'),
    (29, 'app_reportes', 'Ver clientes enmascarados',           'SELECT * FROM erp.v_clientes_enmascarados',                                        'PERMITIDO')
) AS t(n, rol, prueba, sentencia, esperado)
CROSS JOIN LATERAL (SELECT pg_temp.probar(t.rol, t.sentencia) AS obtenido) x
ORDER BY t.n;
\endif
