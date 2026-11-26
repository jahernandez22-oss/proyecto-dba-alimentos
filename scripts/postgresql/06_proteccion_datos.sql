\encoding UTF8
-- =============================================================================
-- 06_proteccion_datos.sql  ·  Fase 2  ·  Responsable: Isaac
-- Corrige los "datos expuestos" del caso:
--   - Contraseñas  -> hash bcrypt (no se pueden descifrar; solo comparar).
--   - Salarios     -> cifrado simétrico AES-256 con pgcrypto (se descifran con llave).
--   - Tarjetas VIP -> cifrado AES-256 + últimos 4 dígitos en claro para mostrar.
--   - Vistas enmascaradas para quien solo necesita ver una parte (teléfono, RFC, PAN).
--
-- LA LLAVE NO VIVE EN LA BASE. Se pasa por sesión y viene del gestor de contraseñas
-- (en la aplicación sería: SET alimentos.llave = '...' al abrir la conexión).
-- Si la llave estuviera en una tabla, quien robe un respaldo tendría datos y llave juntos.
--
-- Léanla primero en la misma consola de PowerShell, sin que se vea en pantalla ni quede
-- escrita en el historial (el historial guarda "$llave", no su valor). Solo letras y números:
--   $llave = (New-Object System.Management.Automation.PSCredential('x', (Read-Host 'Llave' -AsSecureString))).GetNetworkCredential().Password
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -v llave=$llave -f 06_proteccion_datos.sql
--   Remove-Variable llave
-- =============================================================================
\set ON_ERROR_STOP on
\if :{?llave}
\else
    \echo 'Falta la llave: leela con Read-Host -AsSecureString y agrega  -v llave=$llave  al comando de psql (minimo 16 caracteres).'
    \quit
\endif
SET alimentos.llave = :'llave';

-- pgcrypto es una extensión "confiable": la instala el dueño de la base en su propio esquema
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA seguridad;

SET ROLE rol_propietario;

-- ---------- Funciones internas de cifrado (nadie más que el dueño las puede llamar) ----------
CREATE FUNCTION seguridad.llave_sesion() RETURNS text
LANGUAGE plpgsql STABLE SET search_path = pg_catalog AS $$
DECLARE v text := current_setting('alimentos.llave', true);
BEGIN
    IF v IS NULL OR length(v) < 16 THEN
        RAISE EXCEPTION 'No hay llave de cifrado en esta sesión (SET alimentos.llave = ...)';
    END IF;
    RETURN v;
END $$;

CREATE FUNCTION seguridad.cifrar(p_texto text) RETURNS bytea
LANGUAGE sql VOLATILE SET search_path = pg_catalog, seguridad AS $$
    SELECT seguridad.pgp_sym_encrypt(p_texto, seguridad.llave_sesion(), 'cipher-algo=aes256')
$$;

CREATE FUNCTION seguridad.descifrar(p_dato bytea) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, seguridad AS $$
    SELECT seguridad.pgp_sym_decrypt(p_dato, seguridad.llave_sesion())
$$;

-- =============================================================================
-- 1) CONTRASEÑAS: de texto plano a hash bcrypt
-- =============================================================================
ALTER TABLE seguridad.usuarios_sistema ADD COLUMN password_hash text;
UPDATE seguridad.usuarios_sistema SET password_hash = seguridad.crypt(password, seguridad.gen_salt('bf', 10));
ALTER TABLE seguridad.usuarios_sistema ALTER COLUMN password_hash SET NOT NULL;
ALTER TABLE seguridad.usuarios_sistema DROP COLUMN password;

-- La app ya no lee contraseñas: le pregunta a la base si la contraseña es correcta
CREATE FUNCTION seguridad.validar_login(p_usuario text, p_password text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, seguridad AS $$
    SELECT coalesce((SELECT u.password_hash = seguridad.crypt(p_password, u.password_hash)
                     FROM seguridad.usuarios_sistema u
                     WHERE u.usuario = p_usuario AND u.activo), false)
$$;
CREATE FUNCTION seguridad.cambiar_password(p_usuario text, p_nueva text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, seguridad AS $$
BEGIN
    IF length(p_nueva) < 12 THEN RAISE EXCEPTION 'La contraseña debe tener al menos 12 caracteres'; END IF;
    UPDATE seguridad.usuarios_sistema SET password_hash = seguridad.crypt(p_nueva, seguridad.gen_salt('bf', 10))
    WHERE usuario = p_usuario;
END $$;

-- =============================================================================
-- 2) SALARIOS: cifrados; RRHH los consulta y cambia solo mediante funciones
-- =============================================================================
ALTER TABLE nomina.empleados ADD COLUMN salario_cifrado bytea;
UPDATE nomina.empleados SET salario_cifrado = seguridad.cifrar(salario_mensual::text);
ALTER TABLE nomina.empleados ALTER COLUMN salario_cifrado SET NOT NULL;
ALTER TABLE nomina.empleados DROP COLUMN salario_mensual;

CREATE FUNCTION nomina.consultar_salario(p_num_empleado text) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, nomina, seguridad AS $$
    SELECT seguridad.descifrar(e.salario_cifrado)::numeric FROM nomina.empleados e WHERE e.num_empleado = p_num_empleado
$$;
CREATE FUNCTION nomina.actualizar_salario(p_num_empleado text, p_nuevo numeric) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, nomina, seguridad AS $$
BEGIN
    IF p_nuevo <= 0 THEN RAISE EXCEPTION 'Salario inválido'; END IF;
    UPDATE nomina.empleados SET salario_cifrado = seguridad.cifrar(p_nuevo::text) WHERE num_empleado = p_num_empleado;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe el empleado %', p_num_empleado; END IF;
END $$;

-- =============================================================================
-- 3) TARJETAS VIP: número cifrado; solo últimos 4 y marca en claro (PCI DSS 3.4.1 y 3.5.1)
-- =============================================================================
ALTER TABLE seguridad.tarjetas_vip
    ADD COLUMN numero_cifrado bytea,
    ADD COLUMN ultimos4 char(4),
    ADD COLUMN marca text;
UPDATE seguridad.tarjetas_vip SET
    numero_cifrado = seguridad.cifrar(numero_tarjeta),
    ultimos4 = right(numero_tarjeta, 4),
    marca = CASE WHEN numero_tarjeta ~ '^4' THEN 'VISA'
                 WHEN numero_tarjeta ~ '^(5[1-5]|2[2-7])' THEN 'MASTERCARD'
                 WHEN numero_tarjeta ~ '^3[47]' THEN 'AMEX'
                 ELSE 'OTRA' END;
ALTER TABLE seguridad.tarjetas_vip
    ALTER COLUMN numero_cifrado SET NOT NULL,
    ALTER COLUMN ultimos4 SET NOT NULL,
    DROP COLUMN numero_tarjeta;

-- =============================================================================
-- 4) VISTAS ENMASCARADAS: cada rol ve solo lo que su función necesita
-- =============================================================================
CREATE VIEW seguridad.v_tarjetas_vip_enmascaradas AS
SELECT t.id, t.cliente_id, t.titular, t.marca,
       CASE WHEN t.marca = 'AMEX' THEN '**** ****** *' || t.ultimos4
            ELSE '**** **** **** ' || t.ultimos4 END AS tarjeta,
       t.vencimiento
FROM seguridad.tarjetas_vip t;

CREATE VIEW erp.v_clientes_enmascarados AS
SELECT c.id, c.razon_social, c.tipo, c.ciudad, c.es_vip,
       left(c.rfc, 4) || repeat('*', greatest(length(c.rfc) - 7, 0)) || right(c.rfc, 3) AS rfc,
       repeat('*', 6) || right(c.telefono, 4) AS telefono,
       left(c.email, 1) || '***@' || split_part(c.email, '@', 2) AS email
FROM erp.clientes c;

RESET ROLE;

-- ---------- Permisos nuevos ----------
GRANT EXECUTE ON FUNCTION seguridad.validar_login(text, text) TO rol_app_ventas;
GRANT SELECT ON seguridad.v_tarjetas_vip_enmascaradas TO rol_app_ventas;
GRANT SELECT ON erp.v_clientes_enmascarados TO rol_app_ventas, rol_reportes;
REVOKE SELECT, INSERT, UPDATE ON nomina.empleados FROM rol_rrhh;
GRANT SELECT (id, num_empleado, nombre, puesto, sucursal_id, rfc, telefono, fecha_ingreso) ON nomina.empleados TO rol_rrhh;
GRANT EXECUTE ON FUNCTION nomina.consultar_salario(text), nomina.actualizar_salario(text, numeric) TO rol_rrhh;
-- seguridad.cifrar / descifrar / cambiar_password quedan solo para el dueño (y los DBAs)

-- Las columnas borradas siguen físicamente en disco hasta que la tabla se reescribe
VACUUM FULL seguridad.usuarios_sistema;
VACUUM FULL nomina.empleados;
VACUUM FULL seguridad.tarjetas_vip;

-- =============================================================================
-- EVIDENCIA (Sección 3 del reporte: manipulación de datos sensibles)
-- =============================================================================
\echo ''
\echo '=== Así se ven ahora en disco (nadie puede leerlos sin la llave) ==='
SELECT num_empleado, nombre, left(encode(salario_cifrado, 'hex'), 40) || '...' AS salario_en_disco FROM nomina.empleados LIMIT 3;
SELECT usuario, left(password_hash, 29) || '...' AS hash_bcrypt FROM seguridad.usuarios_sistema;

\echo '=== Lo que ve la app de ventas: tarjetas y clientes enmascarados ==='
SET ROLE app_ventas;
SELECT titular, marca, tarjeta, vencimiento FROM seguridad.v_tarjetas_vip_enmascaradas;
SELECT razon_social, rfc, telefono, email FROM erp.v_clientes_enmascarados LIMIT 4;
SELECT seguridad.validar_login('jabeltran', 'caja123') AS login_correcto,
       seguridad.validar_login('jabeltran', 'otra')    AS login_incorrecto;
RESET ROLE;

\echo '=== RRHH consulta un salario con la llave de su sesión ==='
SET ROLE rrhh_nomina;
SELECT num_empleado, nombre, nomina.consultar_salario(num_empleado) AS salario
FROM nomina.empleados ORDER BY num_empleado LIMIT 3;
RESET ROLE;

\echo '=== Sin la llave, ni RRHH puede ver un salario (debe fallar) ==='
RESET alimentos.llave;
SET ROLE rrhh_nomina;
\set ON_ERROR_STOP off
SELECT nomina.consultar_salario('E-0001');
\set ON_ERROR_STOP on
RESET ROLE;
