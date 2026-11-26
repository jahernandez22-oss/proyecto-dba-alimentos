// =============================================================================
// 02_usuarios_y_roles.js  ·  Fase 1  ·  Responsable: Yuleny
// RBAC de MongoDB con privilegio mínimo: roles a la medida por colección y un usuario
// por aplicación, con restricción de IP de origen (authenticationRestrictions).
//
//   mongosh "mongodb://127.0.0.1:37017/admin?directConnection=true" -u admin_usuarios --file 02_usuarios_y_roles.js
//
// Por qué roles propios: los roles integrados (readWrite, dbOwner, root) dan permiso sobre
// TODA una base. La app web no necesita borrar el catálogo ni crear índices; con un rol a
// la medida, una inyección solo alcanza las acciones de ese rol.
// Pide una contraseña por cada usuario nuevo; si el usuario ya existe, lo deja igual.
// =============================================================================

const W = "alimentos_web";
const IP_APP = "192.168.56.1";      // servidor de aplicaciones (anfitrión)
const LOCAL = "127.0.0.1";
const ns = (c) => ({ db: W, collection: c });

function crearRol(base, rol, privilegios) {
  const d = db.getSiblingDB(base);
  if (d.getRole(rol)) {
    d.updateRole(rol, { privileges: privilegios, roles: [] });
    print(`~ rol ${rol} actualizado`);
  } else {
    d.createRole({ role: rol, privileges: privilegios, roles: [] });
    print(`+ rol ${rol} creado`);
  }
}

function crearUsuario(base, usuario, roles, ipsPermitidas) {
  const d = db.getSiblingDB(base);
  if (d.getUser(usuario)) { print(`= ${usuario}@${base} ya existe`); return; }
  print(`Contraseña para ${usuario} (base de autenticación: ${base}):`);
  const doc = { user: usuario, pwd: passwordPrompt(), roles: roles, mechanisms: ["SCRAM-SHA-256"] };
  if (ipsPermitidas) doc.authenticationRestrictions = [{ clientSource: ipsPermitidas }];
  d.createUser(doc);
  print(`+ ${usuario}@${base} creado`);
}

// ---------- Roles a la medida (base alimentos_web) ----------
crearRol(W, "rolAppWeb", [
  { resource: ns("catalogo_web"),    actions: ["find"] },
  { resource: ns("carritos"),        actions: ["find", "insert", "update", "remove"] },
  { resource: ns("clientes_web"),    actions: ["find", "insert", "update"] },
  { resource: ns("lealtad_eventos"), actions: ["find", "insert"] }
]);
crearRol(W, "rolGestorCatalogo", [
  { resource: ns("catalogo_web"),    actions: ["find", "insert", "update"] }
]);
// Estos dos solo ven VISTAS (se crean en la Fase 2): nunca la colección con datos personales
crearRol(W, "rolLogistica", [
  { resource: ns("v_clientes_rutas"), actions: ["find"] }
]);
crearRol(W, "rolAnalistaLealtad", [
  { resource: ns("v_clientes_enmascarados"), actions: ["find"] },
  { resource: ns("lealtad_eventos"),          actions: ["find"] }
]);
// Mantenimiento de bitácoras: solo puede pedir que se roten los logs
crearRol("admin", "rolMantenimientoLogs", [
  { resource: { cluster: true }, actions: ["logRotate"] }
]);

// ---------- Personas y servicios (base admin) ----------
crearUsuario("admin", "root_emergencia", [{ role: "root", db: "admin" }], [LOCAL]);
for (const persona of ["dba_isaac", "dba_jesus", "dba_yuleny"]) {
  crearUsuario("admin", persona, [
    { role: "dbAdmin", db: W }, { role: "readWrite", db: W }, { role: "clusterMonitor", db: "admin" }
  ], [LOCAL, IP_APP]);
}
crearUsuario("admin", "respaldo",      [{ role: "backup",  db: "admin" }], [LOCAL]);
crearUsuario("admin", "restaurador",   [{ role: "restore", db: "admin" }], [LOCAL]);
crearUsuario("admin", "mantenimiento", [{ role: "rolMantenimientoLogs", db: "admin" }], [LOCAL]);

// ---------- Aplicaciones (base alimentos_web) ----------
crearUsuario(W, "app_ecommerce",    [{ role: "rolAppWeb",          db: W }], [LOCAL, IP_APP]);
crearUsuario(W, "gestor_catalogo",  [{ role: "rolGestorCatalogo",  db: W }], [LOCAL, IP_APP]);
crearUsuario(W, "app_logistica",    [{ role: "rolLogistica",       db: W }], [LOCAL, IP_APP]);
crearUsuario(W, "analista_lealtad", [{ role: "rolAnalistaLealtad", db: W }], [LOCAL, IP_APP]);

// ---------- Evidencia para la Matriz de Control de Accesos ----------
print("\n=== Roles a la medida y sus privilegios ===");
const lista = (res, campo) => (Array.isArray(res) ? res : res[campo]);   // mongosh devuelve {roles:[...]} o un arreglo
for (const r of lista(db.getSiblingDB(W).getRoles({ showPrivileges: true }), "roles")) {
  for (const p of r.privileges) {
    const recurso = p.resource.cluster ? "cluster" : `${p.resource.db}.${p.resource.collection}`;
    print(`${r.role.padEnd(20)} ${recurso.padEnd(40)} ${p.actions.join(", ")}`);
  }
}
print("\n=== Usuarios, roles e IPs permitidas ===");
for (const base of ["admin", W]) {
  for (const u of lista(db.getSiblingDB(base).getUsers({ showAuthenticationRestrictions: true }), "users")) {
    const roles = u.roles.map((x) => `${x.role}@${x.db}`).join(", ");
    const ips = (u.authenticationRestrictions || []).flatMap((a) => a.clientSource || []).join(", ") || "cualquiera";
    print(`${(u.user + "@" + base).padEnd(28)} ${roles.padEnd(60)} IPs: ${ips}`);
  }
}
