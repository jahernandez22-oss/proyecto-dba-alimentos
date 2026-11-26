// =============================================================================
// 06_proteccion_datos.js  ·  Fase 2  ·  Responsable: Yuleny
// Corrige los datos expuestos de MongoDB y crea las vistas enmascaradas.
//   - Contraseñas: de texto plano a hash scrypt (función de derivación lenta, con sal).
//   - Tarjetas: MongoDB no necesita el número completo (el cobro lo hace el ERP). Se
//     guarda solo marca, últimos 4 y un token HMAC que permite reconocer la misma tarjeta
//     sin poder reconstruirla (tokenización, PCI DSS 3.5.1).
//   - El validador $jsonSchema PROHÍBE volver a guardar password o tarjeta.numero.
//   - Vistas: v_clientes_enmascarados (analista) y v_clientes_rutas (logística).
//
//   mongosh "mongodb://127.0.0.1:37017/admin?directConnection=true" -u dba_yuleny --file 06_proteccion_datos.js
// Pide la llave del token (guárdenla en el gestor; sin ella no se pueden comparar tokens).
// =============================================================================

const crypto = require("crypto");
const W = db.getSiblingDB("alimentos_web");

function hashScrypt(clave) {
  const sal = crypto.randomBytes(16);
  const h = crypto.scryptSync(clave, sal, 32, { N: 16384, r: 8, p: 1 });
  return `scrypt$16384$8$1$${sal.toString("base64")}$${h.toString("base64")}`;
}
function marcaDe(numero) {
  if (/^4/.test(numero)) return "VISA";
  if (/^(5[1-5]|2[2-7])/.test(numero)) return "MASTERCARD";
  if (/^3[47]/.test(numero)) return "AMEX";
  return "OTRA";
}

print("Llave para el token de tarjetas (mínimo 16 caracteres):");
const llave = passwordPrompt();
if (llave.length < 16) { throw new Error("La llave es demasiado corta"); }

// ---------- 1) Migración de documentos del prototipo ----------
let migrados = 0;
W.clientes_web.find({ $or: [{ password: { $exists: true } }, { "tarjeta.numero": { $exists: true } }] }).forEach((d) => {
  const set = {}, unset = {};
  if (typeof d.password === "string") { set.password_hash = hashScrypt(d.password); unset.password = ""; }
  if (d.tarjeta && d.tarjeta.numero) {
    const n = String(d.tarjeta.numero);
    set["tarjeta.marca"] = marcaDe(n);
    set["tarjeta.ultimos4"] = n.slice(-4);
    set["tarjeta.token"] = crypto.createHmac("sha256", llave).update(n).digest("hex");
    unset["tarjeta.numero"] = "";
  }
  W.clientes_web.updateOne({ _id: d._id }, { $set: set, $unset: unset });
  migrados++;
});
print(`Documentos migrados: ${migrados}`);
// Los clientes sin contraseña (alta por teléfono) quedan con un hash que nunca coincide
W.clientes_web.updateMany({ password_hash: { $exists: false } },
  [{ $set: { password_hash: "scrypt$16384$8$1$SIN-CONTRASENA$SIN-CONTRASENA" } }]);

// ---------- 2) El validador prohíbe volver al estado inseguro ----------
const info = W.getCollectionInfos({ name: "clientes_web" })[0];
const esquema = info.options.validator.$jsonSchema;
esquema.properties.password = { not: {} };   // "nunca debe existir"
esquema.properties.password_hash = { bsonType: "string", pattern: "^scrypt\\$" };
esquema.properties.tarjeta = {
  bsonType: "object",
  properties: {
    numero:   { not: {} },
    ultimos4: { bsonType: "string", pattern: "^[0-9]{4}$" },
    marca:    { enum: ["VISA", "MASTERCARD", "AMEX", "OTRA"] },
    token:    { bsonType: "string", pattern: "^[0-9a-f]{64}$" }
  }
};
if (!esquema.required.includes("password_hash")) esquema.required.push("password_hash");
W.runCommand({ collMod: "clientes_web", validator: { $jsonSchema: esquema }, validationLevel: "strict", validationAction: "error" });
print("Validador actualizado: password y tarjeta.numero quedan prohibidos");

// ---------- 3) Vistas enmascaradas ----------
for (const v of ["v_clientes_enmascarados", "v_clientes_rutas"]) { W.getCollection(v).drop(); }
W.createView("v_clientes_enmascarados", "clientes_web", [
  { $project: {
      _id: 1, nombre: 1, nivel_lealtad: 1, puntos: 1, zona_reparto: 1,
      email: { $concat: [{ $substrCP: ["$email", 0, 1] }, "***@", { $arrayElemAt: [{ $split: ["$email", "@"] }, 1] }] },
      telefono: { $concat: ["******", { $substrCP: ["$telefono", 6, 4] }] },
      tarjeta: { $cond: [{ $ifNull: ["$tarjeta.ultimos4", false] }, { $concat: ["**** **** **** ", "$tarjeta.ultimos4"] }, "$$REMOVE"] },
      // anonimización: la ubicación se redondea a 2 decimales (~1 km), suficiente para análisis por zona
      ubicacion_aprox: { type: { $literal: "Point" },
                         coordinates: { $map: { input: "$ubicacion.coordinates", as: "c", in: { $round: ["$$c", 2] } } } }
  } }
]);
W.createView("v_clientes_rutas", "clientes_web", [
  { $project: { _id: 1, nombre: 1, telefono: 1, zona_reparto: 1, ubicacion: 1, direcciones: 1 } }
]);
print("Vistas creadas: v_clientes_enmascarados y v_clientes_rutas");

// ---------- 4) Evidencia ----------
print("\n=== Documento en la colección (lo que queda guardado) ===");
printjson(W.clientes_web.findOne({ email: "compras@lalomita.example" }, { _id: 0, email: 1, password_hash: 1, tarjeta: 1 }));
print("=== Lo que ve el analista de lealtad (vista enmascarada) ===");
printjson(W.v_clientes_enmascarados.find({}, { _id: 0 }).limit(2).toArray());
print("=== Intento de guardar una contraseña en texto plano (debe fallar) ===");
try {
  W.clientes_web.insertOne({ email: "nuevo@cliente.example", nombre: "Nuevo", telefono: "6670009999", password: "123456",
    password_hash: hashScrypt("123456"), nivel_lealtad: "BRONCE", fecha_registro: new Date(),
    ubicacion: { type: "Point", coordinates: [-107.39, 24.80] } });
  print("REVISAR: se aceptó una contraseña en texto plano");
} catch (e) { print(`OK: rechazado por el validador (${e.codeName || e.code})`); }
