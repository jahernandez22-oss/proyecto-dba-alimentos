// =============================================================================
// 09_rendimiento.js  ·  Fase 3  ·  Responsable: Yuleny
// ANTES y DESPUÉS de las consultas lentas de MongoDB con .explain("executionStats"),
// la estrategia de índices y su costo en escritura.
//
//   mongosh "mongodb://127.0.0.1:37017/admin?directConnection=true" -u dba_yuleny --file 09_rendimiento.js
//
// Cómo leer explain("executionStats"):
//   winningPlan: COLLSCAN = recorre toda la colección; IXSCAN = usa un índice;
//                FETCH = trae el documento completo después del índice.
//   totalDocsExamined contra nReturned: cuántos documentos leyó para devolver cuántos.
//   La meta es que se parezcan: leer 500 mil para devolver 3 mil es el problema del caso.
// =============================================================================

const W = db.getSiblingDB("alimentos_web");
const CEDIS = [-107.3940, 24.8091];            // CEDIS Culiacán [lng, lat]
const RADIO_KM = 5, TIERRA_KM = 6378.1;

function etapas(plan) {                        // "FETCH > IXSCAN", "COLLSCAN", ...
  const r = []; let p = plan;
  while (p) { r.push(p.stage); p = p.inputStage || (p.inputStages && p.inputStages[0]); }
  return r.join(" > ");
}
function medir(titulo, explicacion) {
  const ex = explicacion.executionStats || (explicacion.stages && explicacion.stages[0].$cursor.executionStats);
  const plan = explicacion.queryPlanner ? explicacion.queryPlanner.winningPlan
             : explicacion.stages[0].$cursor.queryPlanner.winningPlan;
  const fila = { prueba: titulo, plan: etapas(plan.queryPlan || plan), ms: ex.executionTimeMillis,
                 docs_examinados: ex.totalDocsExamined, llaves_examinadas: ex.totalKeysExamined, devueltos: ex.nReturned };
  print(`${fila.prueba.padEnd(46)} ${fila.plan.padEnd(34)} ${String(fila.ms).padStart(6)} ms  docs=${fila.docs_examinados}  llaves=${fila.llaves_examinadas}  devueltos=${fila.devueltos}`);
  return fila;
}
function quitarIndice(col, nombre) { try { col.dropIndex(nombre); } catch (e) { /* no existía */ } }

// La consulta de asignación de rutas: clientes ORO y PLATA a 5 km del CEDIS
const consultaGeo = {
  ubicacion: { $geoWithin: { $centerSphere: [CEDIS, RADIO_KM / TIERRA_KM] } },
  nivel_lealtad: { $in: ["ORO", "PLATA"] }
};

print("=== 1. Búsqueda geográfica para rutas ===");
quitarIndice(W.clientes_web, "ix_ubicacion_2dsphere");
quitarIndice(W.clientes_web, "ix_lealtad_ubicacion");
const antes = medir("ANTES: sin índice", W.clientes_web.find(consultaGeo).explain("executionStats"));

W.clientes_web.createIndex({ ubicacion: "2dsphere" }, { name: "ix_ubicacion_2dsphere" });
const geo = medir("DESPUÉS: índice 2dsphere", W.clientes_web.find(consultaGeo).explain("executionStats"));

// Compuesto: primero la igualdad (nivel), luego la geografía. Lee menos llaves.
W.clientes_web.createIndex({ nivel_lealtad: 1, ubicacion: "2dsphere" }, { name: "ix_lealtad_ubicacion" });
const comp = medir("DESPUÉS: compuesto nivel + 2dsphere",
  W.clientes_web.find(consultaGeo).hint("ix_lealtad_ubicacion").explain("executionStats"));
print(`Mejora: de ${antes.docs_examinados} a ${comp.docs_examinados} documentos examinados; de ${antes.ms} ms a ${comp.ms} ms.`);
// Nos quedamos con el compuesto: la consulta de rutas siempre filtra por nivel y un segundo índice
// sobre el mismo campo solo duplicaría el costo en cada escritura (ver punto 6).
quitarIndice(W.clientes_web, "ix_ubicacion_2dsphere");

print("\n=== 2. Agregación eficiente: ruta del día agrupada por zona, ordenada por distancia ===");
// $geoNear DEBE ser la primera etapa y usa el índice 2dsphere; después solo se agrupan los cercanos
const ruta = W.clientes_web.aggregate([
  { $geoNear: { near: { type: "Point", coordinates: CEDIS }, key: "ubicacion", distanceField: "distancia_m",
                maxDistance: RADIO_KM * 1000, spherical: true, query: { nivel_lealtad: { $in: ["ORO", "PLATA"] } } } },
  { $group: { _id: "$zona_reparto", clientes: { $sum: 1 }, distancia_media_m: { $avg: "$distancia_m" } } },
  { $sort: { distancia_media_m: 1 } },
  { $limit: 5 }
]).toArray();
ruta.forEach((z) => print(`  zona ${z._id}: ${z.clientes} clientes, ${Math.round(z.distancia_media_m)} m en promedio`));

print("\n=== 3. Historial de lealtad de un cliente (regla ESR: Igualdad, Orden, Rango) ===");
const unCliente = W.lealtad_eventos.findOne({ tipo: "COMPRA" }).cliente_id;
const consultaLealtad = { cliente_id: unCliente, tipo: "COMPRA", fecha: { $gte: new Date(Date.now() - 180 * 864e5) } };
quitarIndice(W.lealtad_eventos, "ix_cliente_tipo_fecha");
medir("ANTES: sin índice", W.lealtad_eventos.find(consultaLealtad).sort({ fecha: -1 }).explain("executionStats"));
// E = cliente_id y tipo (igualdad), S = fecha (orden), R = fecha (rango): el orden sale del índice
W.lealtad_eventos.createIndex({ cliente_id: 1, tipo: 1, fecha: -1 }, { name: "ix_cliente_tipo_fecha" });
medir("DESPUÉS: compuesto ESR", W.lealtad_eventos.find(consultaLealtad).sort({ fecha: -1 }).explain("executionStats"));

print("\n=== 4. Búsqueda de texto en el catálogo ===");
quitarIndice(W.catalogo_web, "ix_texto_catalogo");
medir("ANTES: expresión regular", W.catalogo_web.find({ descripcion: /mango/i }).explain("executionStats"));
W.catalogo_web.createIndex({ nombre: "text", descripcion: "text", etiquetas: "text" },
  { name: "ix_texto_catalogo", default_language: "spanish", weights: { nombre: 10, etiquetas: 5, descripcion: 1 } });
medir("DESPUÉS: índice de texto en español", W.catalogo_web.find({ $text: { $search: "mango" } }).explain("executionStats"));

print("\n=== 5. Carritos abandonados: índice TTL ===");
// MongoDB borra solo los carritos ABIERTOS sin movimiento en 24 h (proceso de fondo cada 60 s)
quitarIndice(W.carritos, "ttl_carritos_abiertos");
W.carritos.createIndex({ actualizado_en: 1 }, { name: "ttl_carritos_abiertos", expireAfterSeconds: 86400,
                                               partialFilterExpression: { estado: "ABIERTO" } });
print(`  Carritos ABIERTOS con más de 24 h que el TTL va a borrar: ${W.carritos.countDocuments({ estado: "ABIERTO", actualizado_en: { $lt: new Date(Date.now() - 864e5) } })}`);

print("\n=== 6. Costo en escritura: insertar 20 mil clientes con y sin índices ===");
const prueba = W.getCollection("banco_escritura");
function medirInsercion(indices) {
  prueba.drop();
  W.createCollection("banco_escritura");
  for (const i of indices) prueba.createIndex(i);
  const docs = W.clientes_web.find({}, { _id: 0 }).limit(20000).toArray();
  const t0 = Date.now();
  for (let k = 0; k < docs.length; k += 1000) prueba.insertMany(docs.slice(k, k + 1000));
  return Date.now() - t0;
}
const sin = medirInsercion([]);
const con1 = medirInsercion([{ ubicacion: "2dsphere" }]);
const con3 = medirInsercion([{ ubicacion: "2dsphere" }, { nivel_lealtad: 1, ubicacion: "2dsphere" }, { email: 1 }]);
print(`  Sin índices: ${sin} ms | 1 índice: ${con1} ms (${(con1 / sin).toFixed(2)}x) | 3 índices: ${con3} ms (${(con3 / sin).toFixed(2)}x)`);
prueba.drop();

print("\n=== Tamaño de cada índice (lo que cuesta en disco y memoria) ===");
for (const c of ["clientes_web", "lealtad_eventos", "catalogo_web", "carritos"]) {
  const tam = W.getCollection(c).stats().indexSizes;
  for (const [nombre, bytes] of Object.entries(tam)) print(`  ${c.padEnd(16)} ${nombre.padEnd(28)} ${(bytes / 1048576).toFixed(1)} MB`);
}
