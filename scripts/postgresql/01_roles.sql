\encoding UTF8
-- =============================================================================
-- 01_roles.sql  ·  Fase 1  ·  Responsable: Isaac
-- Estructura de roles con privilegio mínimo para PostgreSQL.
--
-- Ejecutar en la VM como postgres (cuenta de emergencia, solo local):
--   psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -f 01_roles.sql
--
-- Idea central: los PERMISOS se dan a ROLES DE GRUPO (NOLOGIN) y las personas o
-- aplicaciones entran con ROLES DE LOGIN que solo "pertenecen" a un grupo.
-- Así, cambiar lo que puede hacer la app es tocar un grupo, y quitarle el acceso a
-- alguien es revocar una membresía. Nadie hace login como dueño de los objetos.
--
-- Las contraseñas NO van en este archivo: al final se asignan con \password, que
-- manda al servidor el hash SCRAM y no el texto plano (así tampoco queda la
-- contraseña en la bitácora ni en el historial).
-- =============================================================================
\set ON_ERROR_STOP on

-- ---------- Roles de grupo (no pueden iniciar sesión) ----------
CREATE ROLE rol_propietario NOLOGIN;   -- dueño de esquemas y tablas; nadie entra como él
CREATE ROLE rol_app_ventas  NOLOGIN;   -- punto de venta y back-office del ERP
CREATE ROLE rol_reportes    NOLOGIN;   -- herramienta de reportes: solo lectura de ventas
CREATE ROLE rol_rrhh        NOLOGIN;   -- recursos humanos: nómina
CREATE ROLE rol_auditor     NOLOGIN;   -- lectura de la bitácora de auditoría
CREATE ROLE rol_respaldo    NOLOGIN;   -- lectura de todo para pg_dump
CREATE ROLE rol_dba         NOLOGIN;   -- administradores humanos

-- ---------- Roles de login (aplicaciones y servicios) ----------
CREATE ROLE app_ventas   LOGIN CONNECTION LIMIT 50 IN ROLE rol_app_ventas;
CREATE ROLE app_reportes LOGIN CONNECTION LIMIT 5  IN ROLE rol_reportes;
CREATE ROLE rrhh_nomina  LOGIN CONNECTION LIMIT 5  IN ROLE rol_rrhh;
CREATE ROLE auditor_ti   LOGIN CONNECTION LIMIT 3  IN ROLE rol_auditor;
-- REPLICATION hace falta para pg_basebackup (Fase 4). Es un atributo, no se hereda del grupo.
CREATE ROLE respaldo     LOGIN CONNECTION LIMIT 3 REPLICATION IN ROLE rol_respaldo;

-- ---------- Roles de login de las personas (uno por integrante: trazabilidad) ----------
CREATE ROLE dba_isaac  LOGIN IN ROLE rol_dba;
CREATE ROLE dba_jesus  LOGIN IN ROLE rol_dba;
CREATE ROLE dba_yuleny LOGIN IN ROLE rol_dba;

-- Los DBAs administran los objetos porque rol_dba es miembro del dueño.
GRANT rol_propietario TO rol_dba;

-- Roles predefinidos de PostgreSQL: dan exactamente lo necesario y nada más.
GRANT pg_read_all_data TO rol_respaldo;            -- leer todas las tablas (pg_dump)
GRANT pg_monitor       TO rol_dba, rol_auditor;    -- ver pg_stat_* y la configuración
GRANT pg_signal_backend TO rol_dba;                -- cancelar consultas que congelan la caja
DO $$
BEGIN
  -- pg_maintain existe desde PostgreSQL 17: VACUUM, ANALYZE, REINDEX, REFRESH MATERIALIZED VIEW
  IF current_setting('server_version_num')::int >= 170000 THEN
    EXECUTE 'GRANT pg_maintain TO rol_dba';
  END IF;
END $$;

-- ---------- Límites por sesión: una app no puede dejar transacciones abiertas ----------
ALTER ROLE app_ventas   SET statement_timeout = '15s';
ALTER ROLE app_ventas   SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE app_reportes SET statement_timeout = '120s';
ALTER ROLE rrhh_nomina  SET statement_timeout = '30s';

-- ---------- El superusuario conserva su contraseña y solo entra local (pg_hba.conf) ----------
\echo ''
\echo 'Roles creados. Ahora asigna una contraseña a cada login (se pide dos veces):'
\echo '  \\password app_ventas'
\echo '  \\password app_reportes'
\echo '  \\password rrhh_nomina'
\echo '  \\password auditor_ti'
\echo '  \\password respaldo'
\echo '  \\password dba_isaac'
\echo '  \\password dba_jesus'
\echo '  \\password dba_yuleny'
