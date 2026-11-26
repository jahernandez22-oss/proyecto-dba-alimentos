\encoding UTF8
-- =============================================================================
-- 02_base_y_esquema.sql  ·  Fase 1  ·  Responsable: Isaac
-- Crea la base alimentos_erp y el esquema del núcleo transaccional.
--
-- Ejecutar como postgres DESPUÉS de 01_roles.sql:
--   psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -f 02_base_y_esquema.sql
--
-- OJO: este script reproduce A PROPÓSITO el prototipo inseguro (salarios, tarjetas y
-- contraseñas en texto plano) para poder mostrar el "antes". La Guía 2 lo corrige con
-- 05_proteccion_datos.sql. No uses estos datos fuera del proyecto: son ficticios y las
-- tarjetas son números de prueba públicos de las marcas.
-- =============================================================================
\set ON_ERROR_STOP on

CREATE DATABASE alimentos_erp OWNER rol_propietario TEMPLATE template0;
\connect alimentos_erp

-- Nadie tiene permisos "por defecto": se otorgan uno por uno en 03_privilegios.sql
REVOKE ALL ON DATABASE alimentos_erp FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Todo lo que sigue lo crea el dueño, no el superusuario
SET ROLE rol_propietario;

CREATE SCHEMA erp;        -- ventas, inventario y cuentas por cobrar
CREATE SCHEMA nomina;     -- empleados y salarios
CREATE SCHEMA seguridad;  -- usuarios del sistema y tarjetas VIP
CREATE SCHEMA auditoria;  -- bitácora de cambios (Fase 2)
CREATE SCHEMA reportes;   -- vistas y vistas materializadas (Fase 3)

-- ---------------------------------------------------------------- erp
CREATE TABLE erp.sucursales (
    id      smallint PRIMARY KEY,
    nombre  text NOT NULL,
    ciudad  text NOT NULL,
    tipo    text NOT NULL CHECK (tipo IN ('CEDIS', 'TIENDA', 'MAYOREO'))
);

CREATE TABLE erp.productos (
    id                  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku                 text NOT NULL UNIQUE,
    nombre              text NOT NULL,
    categoria           text NOT NULL,
    unidad              text NOT NULL DEFAULT 'PZA',
    precio_lista        numeric(12,2) NOT NULL CHECK (precio_lista >= 0),
    precio_exportacion  numeric(12,2) CHECK (precio_exportacion >= 0),
    es_exportacion      boolean NOT NULL DEFAULT false,
    activo              boolean NOT NULL DEFAULT true,
    actualizado_en      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE erp.clientes (
    id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rfc           varchar(13) NOT NULL UNIQUE,
    razon_social  text NOT NULL,
    tipo          text NOT NULL CHECK (tipo IN ('MAYORISTA', 'MINORISTA', 'EXPORTACION')),
    telefono      text,
    email         text,
    ciudad        text,
    es_vip        boolean NOT NULL DEFAULT false,
    creado_en     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE erp.inventario (
    sucursal_id  smallint REFERENCES erp.sucursales (id),
    producto_id  integer  REFERENCES erp.productos (id),
    existencia   integer NOT NULL DEFAULT 0 CHECK (existencia >= 0),
    PRIMARY KEY (sucursal_id, producto_id)
);

CREATE TABLE erp.facturas (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    folio        text NOT NULL UNIQUE,
    cliente_id   integer  NOT NULL REFERENCES erp.clientes (id),
    sucursal_id  smallint NOT NULL REFERENCES erp.sucursales (id),
    fecha        timestamptz NOT NULL DEFAULT now(),
    estado       text NOT NULL DEFAULT 'PAGADA' CHECK (estado IN ('PAGADA', 'PENDIENTE', 'CANCELADA')),
    subtotal     numeric(14,2) NOT NULL DEFAULT 0,
    iva          numeric(14,2) NOT NULL DEFAULT 0,
    total        numeric(14,2) NOT NULL DEFAULT 0
);

CREATE TABLE erp.detalle_factura (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    factura_id       bigint  NOT NULL REFERENCES erp.facturas (id),
    producto_id      integer NOT NULL REFERENCES erp.productos (id),
    cantidad         integer NOT NULL CHECK (cantidad > 0),
    precio_unitario  numeric(12,2) NOT NULL,
    importe          numeric(14,2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED
);

CREATE TABLE erp.cuentas_por_cobrar (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    factura_id   bigint  NOT NULL UNIQUE REFERENCES erp.facturas (id),
    cliente_id   integer NOT NULL REFERENCES erp.clientes (id),
    vencimiento  date NOT NULL,
    saldo        numeric(14,2) NOT NULL,
    estado       text NOT NULL DEFAULT 'ABIERTA' CHECK (estado IN ('ABIERTA', 'PAGADA', 'VENCIDA'))
);

CREATE TABLE erp.pagos (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cxc_id  bigint NOT NULL REFERENCES erp.cuentas_por_cobrar (id),
    fecha   timestamptz NOT NULL DEFAULT now(),
    monto   numeric(14,2) NOT NULL CHECK (monto > 0),
    metodo  text NOT NULL CHECK (metodo IN ('TRANSFERENCIA', 'TARJETA', 'EFECTIVO'))
);

-- ---------------------------------------------------------------- nómina
CREATE TABLE nomina.empleados (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    num_empleado     text NOT NULL UNIQUE,
    nombre           text NOT NULL,
    puesto           text NOT NULL,
    sucursal_id      smallint REFERENCES erp.sucursales (id),
    rfc              varchar(13),
    telefono         text,
    fecha_ingreso    date NOT NULL,
    salario_mensual  numeric(12,2) NOT NULL          -- PROTOTIPO: texto plano (Fase 2 lo cifra)
);

-- ---------------------------------------------------------------- seguridad
CREATE TABLE seguridad.usuarios_sistema (
    id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario   text NOT NULL UNIQUE,
    nombre    text NOT NULL,
    password  text NOT NULL,                         -- PROTOTIPO: texto plano (Fase 2: hash bcrypt)
    rol_app   text NOT NULL,
    activo    boolean NOT NULL DEFAULT true
);

CREATE TABLE seguridad.tarjetas_vip (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id      integer NOT NULL REFERENCES erp.clientes (id),
    titular         text NOT NULL,
    numero_tarjeta  text NOT NULL,                   -- PROTOTIPO: PAN completo (Fase 2: cifrado)
    vencimiento     char(5) NOT NULL,                -- MM/AA
    creada_en       timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- datos de muestra
INSERT INTO erp.sucursales VALUES
    (1, 'CEDIS Culiacán',       'Culiacán',   'CEDIS'),
    (2, 'Tienda Centro',        'Culiacán',   'TIENDA'),
    (3, 'Tienda Tres Ríos',     'Culiacán',   'TIENDA'),
    (4, 'Mayoreo Los Mochis',   'Los Mochis', 'MAYOREO'),
    (5, 'Mayoreo Mazatlán',     'Mazatlán',   'MAYOREO'),
    (6, 'Tienda Navolato',      'Navolato',   'TIENDA');

INSERT INTO erp.productos (sku, nombre, categoria, unidad, precio_lista, precio_exportacion, es_exportacion) VALUES
    ('ADV-0001', 'Puré de tomate saladet 1 L',         'Conservas',   'PZA',  32.50, NULL,   false),
    ('ADV-0002', 'Chile chipotle adobado 220 g',       'Conservas',   'PZA',  24.90, NULL,   false),
    ('ADV-0003', 'Frijol azufrado 1 kg',               'Granos',      'PZA',  42.00, NULL,   false),
    ('ADV-0004', 'Garbanzo blanco calibre 42 25 kg',   'Granos',      'BULTO', 980.00, 1150.00, true),
    ('ADV-0005', 'Mango deshidratado 250 g',           'Deshidratados','PZA', 68.00,  85.00, true),
    ('ADV-0006', 'Elote dulce en grano 400 g',         'Conservas',   'PZA',  21.50, NULL,   false),
    ('ADV-0007', 'Chile jalapeño en escabeche 2.8 kg', 'Conservas',   'PZA', 115.00, 138.00, true),
    ('ADV-0008', 'Harina de maíz nixtamalizado 1 kg',  'Harinas',     'PZA',  23.00, NULL,   false),
    ('ADV-0009', 'Salsa de tomate con chile 500 g',    'Salsas',      'PZA',  29.90,  36.00, true),
    ('ADV-0010', 'Pepino en conserva 680 g',           'Conservas',   'PZA',  45.00, NULL,   false),
    ('ADV-0011', 'Guacamole refrigerado 300 g',        'Refrigerados','PZA',  59.00,  72.00, true),
    ('ADV-0012', 'Tomate deshidratado en aceite 250 g','Deshidratados','PZA', 74.00,  92.00, true);

INSERT INTO erp.clientes (rfc, razon_social, tipo, telefono, email, ciudad, es_vip) VALUES
    ('ABA850101AB1', 'Abarrotes La Lomita SA de CV',      'MAYORISTA',   '6670000101', 'compras@lalomita.example',   'Culiacán',   true),
    ('DPA900215CD2', 'Distribuidora del Pacífico SA',     'MAYORISTA',   '6680000202', 'pedidos@dpacifico.example',  'Los Mochis', true),
    ('SUP010320EF3', 'Súper Mercados del Valle SA',       'MAYORISTA',   '6690000303', 'compras@smvalle.example',    'Mazatlán',   false),
    ('EXP120410GH4', 'Export Foods Sinaloa SA de CV',     'EXPORTACION', '6670000404', 'trade@expfoods.example',     'Culiacán',   true),
    ('TAQ150505IJ5', 'Taquería El Güero',                 'MINORISTA',   '6670000505', 'elguero@correo.example',     'Culiacán',   false),
    ('RES180612KL6', 'Restaurante Mar de Cortés',         'MINORISTA',   '6690000606', 'gerencia@mardecortes.example','Mazatlán',  false),
    ('CAD200715MN7', 'Cadena Comercial Navolato SA',      'MAYORISTA',   '6720000707', 'compras@ccnavolato.example', 'Navolato',   false),
    ('USA210820OP8', 'Border Produce Imports LLC',        'EXPORTACION', '5200000808', 'buyer@borderproduce.example','Nogales',    true);

INSERT INTO erp.inventario (sucursal_id, producto_id, existencia)
SELECT s.id, p.id, 50 + (s.id * 7 + p.id * 13) % 400
FROM erp.sucursales s CROSS JOIN erp.productos p;

INSERT INTO nomina.empleados (num_empleado, nombre, puesto, sucursal_id, rfc, telefono, fecha_ingreso, salario_mensual) VALUES
    ('E-0001', 'María Fernanda López Ruiz',   'Gerente de sistemas',  1, 'LORM850301AA1', '6671110001', '2015-03-01', 48500.00),
    ('E-0002', 'José Antonio Beltrán Soto',   'Cajero',               2, 'BESJ920714BB2', '6671110002', '2019-07-15',  9800.00),
    ('E-0003', 'Ana Karen Félix Valenzuela',  'Contadora',            1, 'FEVA880921CC3', '6671110003', '2017-09-21', 27600.00),
    ('E-0004', 'Luis Alberto Quintero Gil',   'Jefe de almacén',      4, 'QUGL900110DD4', '6681110004', '2016-01-10', 21400.00),
    ('E-0005', 'Paola Guadalupe Inzunza Lara','Ejecutiva de ventas',  5, 'INLP950505EE5', '6691110005', '2021-05-05', 15200.00),
    ('E-0006', 'Ricardo Ernesto Gastélum Paz','Director comercial',   1, 'GAPR800812FF6', '6671110006', '2012-08-12', 86000.00);

INSERT INTO seguridad.usuarios_sistema (usuario, nombre, password, rol_app) VALUES
    ('mflopez',  'María Fernanda López Ruiz',  'Sistemas2024',  'ADMIN'),
    ('jabeltran','José Antonio Beltrán Soto',  'caja123',       'CAJERO'),
    ('akfelix',  'Ana Karen Félix Valenzuela', 'Conta#2023',    'CONTABILIDAD'),
    ('pginzunza','Paola Guadalupe Inzunza Lara','ventas2025',   'VENTAS');

-- Números de prueba públicos de Visa, Mastercard y American Express (no son tarjetas reales)
INSERT INTO seguridad.tarjetas_vip (cliente_id, titular, numero_tarjeta, vencimiento) VALUES
    (1, 'ABARROTES LA LOMITA',     '4111111111111111', '08/28'),
    (2, 'DISTRIBUIDORA DEL PACIF', '5555555555554444', '11/27'),
    (4, 'EXPORT FOODS SINALOA',    '378282246310005',  '03/29'),
    (8, 'BORDER PRODUCE IMPORTS',  '4012888888881881', '06/28');

-- Unas facturas para probar privilegios (la Fase 3 genera millones)
INSERT INTO erp.facturas (folio, cliente_id, sucursal_id, fecha, estado)
VALUES ('A-000001', 1, 2, now() - interval '3 days', 'PAGADA'),
       ('A-000002', 3, 5, now() - interval '2 days', 'PENDIENTE'),
       ('A-000003', 4, 1, now() - interval '1 day',  'PAGADA');
INSERT INTO erp.detalle_factura (factura_id, producto_id, cantidad, precio_unitario)
VALUES (1, 1, 24, 32.50), (1, 3, 10, 42.00),
       (2, 6, 48, 21.50),
       (3, 4,  8, 1150.00), (3, 5, 60, 85.00);
UPDATE erp.facturas f SET subtotal = d.s, iva = round(d.s * 0.16, 2), total = round(d.s * 1.16, 2)
FROM (SELECT factura_id, sum(importe) AS s FROM erp.detalle_factura GROUP BY factura_id) d
WHERE d.factura_id = f.id;
INSERT INTO erp.cuentas_por_cobrar (factura_id, cliente_id, vencimiento, saldo)
SELECT id, cliente_id, (fecha + interval '30 days')::date, total FROM erp.facturas WHERE estado = 'PENDIENTE';

RESET ROLE;

\echo ''
\echo 'Base alimentos_erp creada con el esquema del prototipo (datos sensibles en texto plano a propósito).'
\echo 'Siguiente: 03_privilegios.sql'
