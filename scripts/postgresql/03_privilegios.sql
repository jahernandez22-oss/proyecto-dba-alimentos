\encoding UTF8
-- =============================================================================
-- 03_privilegios.sql  ·  Fase 1  ·  Responsable: Isaac
-- Otorga a cada rol de grupo SOLO lo que su función necesita (privilegio mínimo).
--
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -f 03_privilegios.sql
--
-- Cómo leerlo: si un permiso no aparece aquí, ese rol NO lo tiene. Por ejemplo,
-- app_ventas no puede borrar facturas (DELETE), ni leer la nómina, ni ver tarjetas,
-- ni crear o borrar tablas. Si la app sufre una inyección SQL, el atacante solo
-- puede hacer lo que app_ventas puede hacer.
-- =============================================================================
\set ON_ERROR_STOP on

-- ---------- Base de datos: solo se conectan los grupos que la usan ----------
REVOKE ALL ON DATABASE alimentos_erp FROM PUBLIC;
GRANT CONNECT ON DATABASE alimentos_erp
    TO rol_app_ventas, rol_reportes, rol_rrhh, rol_auditor, rol_respaldo, rol_dba;

-- ---------- Esquemas: USAGE es la "llave de la puerta" del esquema ----------
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA erp       TO rol_app_ventas, rol_reportes, rol_rrhh;
GRANT USAGE ON SCHEMA nomina    TO rol_rrhh;
GRANT USAGE ON SCHEMA seguridad TO rol_app_ventas;
GRANT USAGE ON SCHEMA auditoria TO rol_auditor;
GRANT USAGE ON SCHEMA reportes  TO rol_reportes;

-- ---------- rol_app_ventas: vender, cobrar y mantener precios e inventario ----------
GRANT SELECT ON erp.sucursales, erp.productos, erp.inventario TO rol_app_ventas;
-- Solo estas columnas se pueden actualizar; todo cambio de precio queda en la bitácora (Fase 2)
GRANT UPDATE (precio_lista, precio_exportacion, activo, actualizado_en) ON erp.productos TO rol_app_ventas;
GRANT UPDATE (existencia) ON erp.inventario TO rol_app_ventas;
-- De clientes ve lo necesario para facturar; teléfono y correo no
GRANT SELECT (id, rfc, razon_social, tipo, ciudad, es_vip) ON erp.clientes TO rol_app_ventas;
GRANT SELECT, INSERT ON erp.facturas, erp.detalle_factura, erp.cuentas_por_cobrar, erp.pagos TO rol_app_ventas;
GRANT UPDATE (estado) ON erp.facturas TO rol_app_ventas;
GRANT UPDATE (saldo, estado) ON erp.cuentas_por_cobrar TO rol_app_ventas;
-- De los usuarios del sistema NO ve la contraseña (en la Fase 2 la valida una función)
GRANT SELECT (id, usuario, nombre, rol_app, activo) ON seguridad.usuarios_sistema TO rol_app_ventas;
-- Nada sobre seguridad.tarjetas_vip ni nomina.*

-- ---------- rol_reportes: solo lectura de ventas, sin datos personales ----------
GRANT SELECT ON erp.facturas, erp.detalle_factura, erp.productos, erp.sucursales TO rol_reportes;

-- ---------- rol_rrhh: nómina (la Fase 2 cambia el acceso directo al salario por funciones) ----------
GRANT SELECT, INSERT, UPDATE ON nomina.empleados TO rol_rrhh;
GRANT SELECT (id, nombre, ciudad) ON erp.sucursales TO rol_rrhh;

-- ---------- Objetos futuros: nacen sin permisos para PUBLIC ----------
ALTER DEFAULT PRIVILEGES FOR ROLE rol_propietario REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE rol_propietario IN SCHEMA reportes  GRANT SELECT ON TABLES TO rol_reportes;
ALTER DEFAULT PRIVILEGES FOR ROLE rol_propietario IN SCHEMA auditoria GRANT SELECT ON TABLES TO rol_auditor;

-- ---------- search_path fijo por rol: evita que un objeto "impostor" se resuelva primero ----------
ALTER ROLE app_ventas   IN DATABASE alimentos_erp SET search_path = erp;
ALTER ROLE app_reportes IN DATABASE alimentos_erp SET search_path = reportes, erp;
ALTER ROLE rrhh_nomina  IN DATABASE alimentos_erp SET search_path = nomina;

-- ---------- Evidencia para la Matriz de Control de Accesos (Sección 2 del reporte) ----------
\echo ''
\echo '=== Privilegios por rol y tabla ==='
SELECT grantee AS rol, table_schema || '.' || table_name AS tabla,
       string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privilegios
FROM information_schema.role_table_grants
WHERE grantee LIKE 'rol\_%' AND grantee <> 'rol_propietario'
  AND table_schema IN ('erp', 'nomina', 'seguridad', 'auditoria', 'reportes')
GROUP BY grantee, table_schema, table_name
ORDER BY rol, tabla;

\echo '=== Privilegios por columna (solo las que tienen permiso parcial) ==='
SELECT grantee AS rol, table_schema || '.' || table_name AS tabla, privilege_type AS privilegio,
       string_agg(column_name, ', ' ORDER BY column_name) AS columnas
FROM information_schema.column_privileges c
WHERE grantee LIKE 'rol\_%' AND table_schema IN ('erp', 'seguridad', 'nomina')
  AND NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants t
                  WHERE t.grantee = c.grantee AND t.table_schema = c.table_schema
                    AND t.table_name = c.table_name AND t.privilege_type = c.privilege_type)
GROUP BY grantee, table_schema, table_name, privilege_type
ORDER BY rol, tabla, privilegio;

\echo '=== Quién pertenece a qué grupo ==='
SELECT m.rolname AS login, string_agg(g.rolname, ', ' ORDER BY g.rolname) AS grupos,
       m.rolsuper AS superusuario, m.rolcreaterole AS crea_roles, m.rolreplication AS replicacion
FROM pg_roles m
JOIN pg_auth_members am ON am.member = m.oid
JOIN pg_roles g ON g.oid = am.roleid
WHERE m.rolcanlogin
GROUP BY m.rolname, m.rolsuper, m.rolcreaterole, m.rolreplication
ORDER BY login;
