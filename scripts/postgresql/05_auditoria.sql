\encoding UTF8
-- =============================================================================
-- 05_auditoria.sql  ·  Fase 2  ·  Responsable: Isaac
-- Bitácora de cambios a nivel de fila: quién cambió qué, cuándo, desde dónde y con
-- qué aplicación. Responde la pregunta del caso: "¿quién modificó los precios?".
--
--   psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -f 05_auditoria.sql
--
-- Dos capas de trazabilidad que se complementan:
--   1) La bitácora NATIVA de PostgreSQL (postgresql.conf, Fase 2): conexiones, accesos
--      fallidos y DDL. Dice quién entró y qué estructura cambió.
--   2) Esta tabla (triggers): qué FILAS cambiaron y con qué valores. La bitácora nativa
--      no guarda el valor anterior de un precio; esta sí.
--
-- Diseño:
--   - La función del trigger es SECURITY DEFINER: escribe en la bitácora aunque quien
--     modifica (app_ventas) NO tenga permiso de escribir en ella. Así nadie puede
--     insertar registros falsos ni borrar los reales.
--   - La bitácora es de solo agregar: un trigger impide UPDATE, DELETE y TRUNCATE.
--   - Nunca copia valores sensibles (contraseñas, tarjetas, salarios): registra que la
--     columna cambió, no su contenido. La bitácora no debe ser otra fuga de datos.
--   - session_user es la cuenta que se conectó; alimentos.usuario_app es la persona
--     que la aplicación declara (SET alimentos.usuario_app = 'jlopez').
-- =============================================================================
\set ON_ERROR_STOP on
SET ROLE rol_propietario;

CREATE TABLE auditoria.bitacora_cambios (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    momento             timestamptz NOT NULL DEFAULT clock_timestamp(),
    esquema             text NOT NULL,
    tabla               text NOT NULL,
    operacion           text NOT NULL,
    usuario_bd          text NOT NULL,
    usuario_app         text,
    ip_cliente          inet,
    aplicacion          text,
    transaccion         bigint,
    columnas_cambiadas  text[],
    datos_antes         jsonb,
    datos_despues       jsonb
);
CREATE INDEX ON auditoria.bitacora_cambios (tabla, momento DESC);

CREATE FUNCTION auditoria.registrar_cambio() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, auditoria
AS $$
DECLARE
    -- columnas que jamás se copian a la bitácora
    v_ocultas  text[] := ARRAY['password', 'password_hash', 'numero_tarjeta', 'numero_cifrado',
                               'salario_mensual', 'salario_cifrado'];
    v_antes    jsonb;
    v_despues  jsonb;
    v_cambios  text[];
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_antes   := to_jsonb(OLD); END IF;
    IF TG_OP IN ('UPDATE', 'INSERT') THEN v_despues := to_jsonb(NEW); END IF;
    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(k ORDER BY k) INTO v_cambios
        FROM jsonb_object_keys(v_despues) AS k
        WHERE v_despues -> k IS DISTINCT FROM v_antes -> k;
        IF v_cambios IS NULL THEN RETURN NULL; END IF;     -- UPDATE sin cambios reales: no se registra
    END IF;
    INSERT INTO auditoria.bitacora_cambios
        (esquema, tabla, operacion, usuario_bd, usuario_app, ip_cliente, aplicacion,
         transaccion, columnas_cambiadas, datos_antes, datos_despues)
    VALUES
        (TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, session_user,
         nullif(current_setting('alimentos.usuario_app', true), ''),
         inet_client_addr(), current_setting('application_name'), txid_current(),
         v_cambios, v_antes - v_ocultas, v_despues - v_ocultas);
    RETURN NULL;
END $$;

CREATE FUNCTION auditoria.impedir_cambios() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'La bitácora de auditoría es de solo agregar (% bloqueado)', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END $$;

CREATE TRIGGER bitacora_solo_agregar
    BEFORE UPDATE OR DELETE ON auditoria.bitacora_cambios
    FOR EACH ROW EXECUTE FUNCTION auditoria.impedir_cambios();
CREATE TRIGGER bitacora_sin_truncate
    BEFORE TRUNCATE ON auditoria.bitacora_cambios
    FOR EACH STATEMENT EXECUTE FUNCTION auditoria.impedir_cambios();

-- ---------- Qué se audita ----------
-- Precios: solo cuando realmente cambia un precio (la cláusula WHEN evita ruido)
CREATE TRIGGER auditar_precios
    AFTER UPDATE OF precio_lista, precio_exportacion ON erp.productos
    FOR EACH ROW
    WHEN (OLD.precio_lista IS DISTINCT FROM NEW.precio_lista
          OR OLD.precio_exportacion IS DISTINCT FROM NEW.precio_exportacion)
    EXECUTE FUNCTION auditoria.registrar_cambio();
CREATE TRIGGER auditar_bajas_productos
    AFTER DELETE ON erp.productos FOR EACH ROW EXECUTE FUNCTION auditoria.registrar_cambio();
-- Datos personales y de pago: todo alta, cambio o baja
CREATE TRIGGER auditar_empleados
    AFTER INSERT OR UPDATE OR DELETE ON nomina.empleados FOR EACH ROW EXECUTE FUNCTION auditoria.registrar_cambio();
CREATE TRIGGER auditar_tarjetas
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.tarjetas_vip FOR EACH ROW EXECUTE FUNCTION auditoria.registrar_cambio();
CREATE TRIGGER auditar_usuarios
    AFTER INSERT OR UPDATE OR DELETE ON seguridad.usuarios_sistema FOR EACH ROW EXECUTE FUNCTION auditoria.registrar_cambio();

-- ---------- Vista de lectura para el auditor ----------
CREATE VIEW auditoria.v_cambios_precio AS
SELECT b.momento, b.usuario_bd, b.usuario_app, b.ip_cliente, b.aplicacion,
       b.datos_antes ->> 'sku' AS sku, b.datos_antes ->> 'nombre' AS producto,
       (b.datos_antes ->> 'precio_lista')::numeric         AS lista_antes,
       (b.datos_despues ->> 'precio_lista')::numeric       AS lista_despues,
       (b.datos_antes ->> 'precio_exportacion')::numeric   AS exportacion_antes,
       (b.datos_despues ->> 'precio_exportacion')::numeric AS exportacion_despues
FROM auditoria.bitacora_cambios b
WHERE b.tabla = 'productos';

RESET ROLE;
-- El auditor lee (los privilegios por defecto ya le dan SELECT sobre tablas nuevas de auditoria);
-- nadie más tiene acceso. La función del trigger no se puede llamar directamente.
GRANT SELECT ON auditoria.v_cambios_precio TO rol_auditor;
REVOKE ALL ON FUNCTION auditoria.registrar_cambio() FROM PUBLIC;

-- =============================================================================
-- DEMOSTRACIÓN: el cambio "malicioso" de precios de exportación, ahora con rastro.
-- En la defensa háganlo en vivo desde el anfitrión, conectados como app_ventas.
-- =============================================================================
SET ROLE app_ventas;
SET application_name = 'erp-backoffice';
SET alimentos.usuario_app = 'pginzunza';
UPDATE erp.productos SET precio_exportacion = round(precio_exportacion * 0.5, 2)
WHERE es_exportacion AND sku = 'ADV-0004';
RESET alimentos.usuario_app;
RESET application_name;
RESET ROLE;

\echo ''
\echo '=== ¿Quién cambió los precios? (lo que antes nadie sabía) ==='
SELECT momento, usuario_bd, usuario_app, ip_cliente, aplicacion, sku, exportacion_antes, exportacion_despues
FROM auditoria.v_cambios_precio ORDER BY momento DESC LIMIT 5;

\echo '=== Intento de borrar la evidencia (debe fallar) ==='
\set ON_ERROR_STOP off
DELETE FROM auditoria.bitacora_cambios;
\set ON_ERROR_STOP on

-- Deja el precio como estaba para no ensuciar los datos (también queda en la bitácora)
UPDATE erp.productos SET precio_exportacion = 1150.00 WHERE sku = 'ADV-0004';
