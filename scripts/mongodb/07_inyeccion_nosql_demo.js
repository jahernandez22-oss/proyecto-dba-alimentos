// =============================================================================
// 07_inyeccion_nosql_demo.js  ·  Fase 2  ·  Responsable: Yuleny
// Demostración de inyección NoSQL por OPERADORES y por JAVASCRIPT, y sus defensas.
//
//   mongosh "mongodb://127.0.0.1:37017/admin?directConnection=true" -u dba_yuleny --file 07_inyeccion_nosql_demo.js
//
// Cómo ocurre: la app recibe JSON del navegador y lo pasa tal cual al filtro de la consulta.
// Si el atacante manda {"password": {"$ne": ""}} en lugar de un texto, MongoDB lo lee como
// el OPERADOR "distinto de vacío" y la condición se cumple para cualquier contraseña.
// Usa una colección temporal (demo_login) que imita el prototipo y se borra al final.
// =============================================================================

const W = db.getSiblingDB("alimentos_web");
const demo = W.getCollection("demo_login");
demo.drop();
demo.insertMany([
  { email: "compras@lalomita.example", password: "lomita2024", rol: "cliente" },
  { email: "admin@alimentosdelvalle.example", password: "S3cret0-Admin", rol: "admin" }
]);
const mostrar = (titulo, u) => print(`${titulo.padEnd(58)} -> ${u ? "ACCESO CONCEDIDO como " + u.email + " (" + u.rol + ")" : "acceso denegado"}`);

// Lo que llega en el cuerpo de la petición (JSON.parse es justo lo que hace un servidor web)
const normal  = JSON.parse('{"email": "compras@lalomita.example", "password": "lomita2024"}');
const ataque1 = JSON.parse('{"email": "admin@alimentosdelvalle.example", "password": {"$ne": ""}}');
const ataque2 = JSON.parse('{"email": {"$gt": ""}, "password": {"$gt": ""}}');

// ---------- VULNERABLE ----------
function loginVulnerable(cuerpo) { return demo.findOne({ email: cuerpo.email, password: cuerpo.password }); }
print("\n=== Código vulnerable ===");
mostrar("Login normal", loginVulnerable(normal));
mostrar("Ataque: password = {$ne: ''} contra el admin", loginVulnerable(ataque1));
mostrar("Ataque: email y password = {$gt: ''}", loginVulnerable(ataque2));

// ---------- DEFENSA 1: validar tipos (lo que debería venir es texto) ----------
function loginTipos(cuerpo) {
  if (typeof cuerpo.email !== "string" || typeof cuerpo.password !== "string") return null;   // se rechaza la petición
  return demo.findOne({ email: cuerpo.email, password: cuerpo.password });
}
// ---------- DEFENSA 2: $eq fuerza a comparar como valor literal ----------
function loginEq(cuerpo) {
  try { return demo.findOne({ email: { $eq: cuerpo.email }, password: { $eq: cuerpo.password } }); }
  catch (e) { return null; }
}
// ---------- DEFENSA 3: limpiar claves que empiezan con $ o tienen punto ----------
function sanear(o) {
  if (o && typeof o === "object") for (const k of Object.keys(o)) { if (k.startsWith("$") || k.includes(".")) delete o[k]; else sanear(o[k]); }
  return o;
}
function loginSaneado(cuerpo) {
  const c = sanear(JSON.parse(JSON.stringify(cuerpo)));
  return demo.findOne({ email: c.email, password: c.password });
}
print("\n=== Código defendido ===");
mostrar("Defensa 1 (tipos), login normal", loginTipos(normal));
mostrar("Defensa 1 (tipos), ataque {$ne}", loginTipos(ataque1));
mostrar("Defensa 2 ($eq), ataque {$ne}", loginEq(ataque1));
mostrar("Defensa 2 ($eq), ataque {$gt}", loginEq(ataque2));
mostrar("Defensa 3 (sanear), ataque {$ne}", loginSaneado(ataque1));

// ---------- Inyección con JavaScript del lado del servidor ----------
print("\n=== Inyección con $where (JavaScript en el servidor) ===");
const entrada = "x' || '1'=='1";
try {
  const r = demo.find({ $where: "this.email == '" + entrada + "'" }).toArray();
  print(`REVISAR: $where se ejecutó y devolvió ${r.length} documentos (JavaScript sigue activo)`);
} catch (e) {
  print(`BLOQUEADO por javascriptEnabled: false -> ${e.codeName || ""} ${e.message}`);
}

print("\nLa forma correcta en la app real: buscar por email con $eq y verificar el hash scrypt en el código;");
print("además, app_ecommerce solo tiene los permisos de rolAppWeb: aunque una inyección pase, no puede");
print("borrar colecciones, leer usuarios ni tocar precios (privilegio mínimo).");
demo.drop();
