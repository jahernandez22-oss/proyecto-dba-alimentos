// =============================================================================
// 05_auditoria_y_perfilador.js  ·  Fase 2  ·  Responsable: Yuleny
// Verifica la auditoría nativa (auditLog de MongoDB Enterprise), genera eventos de
// prueba y activa el perfilador para saber QUIÉN cambia precios del catálogo web.
//
// Antes: descomentar la sección auditLog de mongod.cfg (y operationProfiling) y reiniciar.
//   mongosh "mongodb://127.0.0.1:37017/admin?directConnection=true" -u dba_yuleny --file 05_auditoria_y_perfilador.js
//
// Dos fuentes que se complementan:
//   - auditLog (archivo C:\BD\MongoDB\log\audit.json): autenticaciones, DDL y cambios de
//     usuarios. Es la bitácora de seguridad; se lee desde Windows (script 09 de Jesús).
//   - Perfilador (colección system.profile): operaciones lentas y, con un filtro, cada
//     update al catálogo con el usuario y la IP que lo hizo. Es la bitácora de datos.
// =============================================================================

const W = db.getSiblingDB("alimentos_web");
const URI = "127.0.0.1:37017";

// 1) ¿Está activa la auditoría?
const opciones = db.adminCommand({ getCmdLineOpts: 1 }).parsed;
if (opciones.auditLog) {
  print(`OK auditLog activo -> ${opciones.auditLog.path} (formato ${opciones.auditLog.format})`);
  print(`   filtro: ${opciones.auditLog.filter || "(sin filtro: registra todo)"}`);
} else {
  print("FALTA: auditLog no está en mongod.cfg (o el servidor no es Enterprise). Revisa la Guía 2.");
}

// 2) Perfilador con filtro: lento (>= 200 ms) O cualquier update al catálogo.
//    Se aplica ya; para que sobreviva reinicios va también en mongod.cfg (operationProfiling).
const filtro = { $or: [{ millis: { $gte: 200 } }, { op: "update", ns: "alimentos_web.catalogo_web" }] };
W.setProfilingLevel(1, { filter: filtro });
printjson(W.getProfilingStatus());

// 3) Eventos de prueba para la evidencia
print("\n--- Generando eventos de prueba ---");
try {   // a) autenticación fallida (queda en audit.json con result 18)
  new Mongo(`mongodb://app_ecommerce:contrasena-incorrecta@${URI}/?authSource=alimentos_web&directConnection=true`)
    .getDB("alimentos_web").catalogo_web.findOne();
} catch (e) { print(`a) Login fallido registrado: ${e.codeName || e.message}`); }

W.createCollection("auditoria_prueba");          // b) DDL: createCollection
W.getCollection("auditoria_prueba").drop();       //    y dropCollection
print("b) createCollection y dropCollection de 'auditoria_prueba' registrados");

print("c) Cambio de precio como gestor_catalogo (lo captura el perfilador). Contraseña de gestor_catalogo:");
const gestor = new Mongo(`mongodb://gestor_catalogo:${encodeURIComponent(passwordPrompt())}@${URI}/?authSource=alimentos_web&directConnection=true&appName=catalogo-admin`);
const cat = gestor.getDB("alimentos_web").catalogo_web;
const prod = cat.findOne({ sku: "ADV-0005" });
cat.updateOne({ _id: prod._id }, { $set: { precio_publico: NumberDecimal("36.00") } });   // "ataque": precio a la mitad
cat.updateOne({ _id: prod._id }, { $set: { precio_publico: prod.precio_publico } });      // se restaura

// 4) ¿Quién cambió los precios del catálogo?
print("\n=== Cambios al catálogo según el perfilador (más recientes primero) ===");
W.system.profile.find({ op: "update", ns: "alimentos_web.catalogo_web" })
  .sort({ ts: -1 }).limit(5)
  .forEach((p) => print(`${p.ts.toISOString()}  usuario=${p.user}  ip=${p.client}  app=${p.appName || "-"}  cambio=${EJSON.stringify(p.command && p.command.u)}`));

print("\nPara ver el auditLog desde Windows: scripts\\windows\\09_recolectar_evidencias.ps1 (Jesús).");
print("Cambio de contraseña auditado (updateUser): como admin_usuarios ejecuta");
print("  db.getSiblingDB('alimentos_web').changeUserPassword('app_logistica', passwordPrompt())");
