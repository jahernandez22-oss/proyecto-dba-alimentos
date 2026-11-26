// =============================================================================
// 01_inicializar_replica_y_admin.js  ·  Fase 1  ·  Responsable: Yuleny
// Inicia el conjunto de réplicas de un nodo y crea el PRIMER usuario (administrador
// de usuarios) usando la "excepción de localhost".
//
// Cuándo: justo después de arrancar MongoDB con el mongod.cfg endurecido (authorization
// enabled + keyFile + replSetName). Ejecutar EN LA VM:
//   mongosh "mongodb://127.0.0.1:37017/?directConnection=true" --file 01_inicializar_replica_y_admin.js
//
// Excepción de localhost: con la autorización activa y CERO usuarios, MongoDB deja que una
// conexión desde la propia máquina inicie la réplica y cree el primer usuario. En cuanto
// existe ese usuario, la excepción se cierra y todo exige autenticarse.
// =============================================================================

const IP_SERVIDOR = "192.168.56.10";
const PUERTO = 37017;
const REPLICA = "rs_alimentos";

// 1) Iniciar el conjunto de réplicas (si ya estaba iniciado, solo lo informa)
try {
  const r = rs.initiate({ _id: REPLICA, members: [{ _id: 0, host: `${IP_SERVIDOR}:${PUERTO}` }] });
  print(`rs.initiate: ok=${r.ok}`);
} catch (e) {
  print(`rs.initiate: ${e.message}`);
}

// 2) Esperar a que el nodo sea PRIMARY (unos segundos)
let espera = 0;
while (!db.hello().isWritablePrimary && espera < 30) { sleep(1000); espera++; }
print(`Nodo primario: ${db.hello().isWritablePrimary} (esperé ${espera} s)`);

// 3) Primer usuario: solo administra usuarios y roles; no lee ni escribe datos
const admin = db.getSiblingDB("admin");
print("Contraseña para admin_usuarios (guárdenla en el gestor de contraseñas):");
admin.createUser({
  user: "admin_usuarios",
  pwd: passwordPrompt(),
  roles: [{ role: "userAdminAnyDatabase", db: "admin" }],
  mechanisms: ["SCRAM-SHA-256"]
});
print("admin_usuarios creado. La excepción de localhost quedó cerrada.");
print("Siguiente: 02_usuarios_y_roles.js autenticado como admin_usuarios.");
