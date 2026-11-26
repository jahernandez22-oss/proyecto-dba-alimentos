// =============================================================================
// 04_pruebas_privilegios.js  ·  Fase 1 (se vuelve a correr en cada fase)
// Se conecta como cada usuario de aplicación, intenta acciones permitidas y prohibidas y
// compara contra lo esperado. Las pruebas que escriben limpian lo que crean.
//
//   mongosh --nodb --file 04_pruebas_privilegios.js
//
// Pide la contraseña de cada usuario. La tabla final va a la Sección 2 del reporte.
// =============================================================================

const URI_BASE = "127.0.0.1:37017";
const W = "alimentos_web";
const resultados = [];

function conectar(usuario, baseAuth) {
  print(`\nContraseña de ${usuario}:`);
  const clave = passwordPrompt();
  return new Mongo(`mongodb://${encodeURIComponent(usuario)}:${encodeURIComponent(clave)}@${URI_BASE}/?authSource=${baseAuth}&directConnection=true`);
}

function probar(usuario, conexion, prueba, esperado, accion) {
  let obtenido;
  try {
    accion(conexion.getDB(W), conexion);
    obtenido = "PERMITIDO";
  } catch (e) {
    obtenido = (e.code === 13 || e.codeName === "Unauthorized") ? "DENEGADO" : `ERROR: ${e.message}`;
  }
  resultados.push({ usuario, prueba, esperado, obtenido, veredicto: obtenido === esperado ? "OK" : "REVISAR" });
}

// ---------- app_ecommerce ----------
const app = conectar("app_ecommerce", W);
probar("app_ecommerce", app, "Leer el catálogo", "PERMITIDO", (d) => d.catalogo_web.findOne());
probar("app_ecommerce", app, "Crear y borrar su carrito", "PERMITIDO", (d) => {
  const c = d.clientes_web.findOne({}, { _id: 1 });
  const r = d.carritos.insertOne({ cliente_id: c._id, estado: "ABIERTO", actualizado_en: new Date(), items: [] });
  d.carritos.deleteOne({ _id: r.insertedId });
});
probar("app_ecommerce", app, "Cambiar un precio del catálogo", "DENEGADO", (d) =>
  d.catalogo_web.updateOne({ sku: "ADV-0001" }, { $set: { activo: true } }));
probar("app_ecommerce", app, "Borrar clientes", "DENEGADO", (d) => d.clientes_web.deleteMany({ email: "nadie@nada.example" }));
probar("app_ecommerce", app, "Borrar una colección", "DENEGADO", (d) => d.getCollection("coleccion_de_prueba").drop());
probar("app_ecommerce", app, "Crear una colección", "DENEGADO", (d) => d.createCollection("coleccion_intrusa"));
probar("app_ecommerce", app, "Ver los usuarios de la base", "DENEGADO", (d, c) => c.getDB("admin").getUsers());

// ---------- gestor_catalogo ----------
const gestor = conectar("gestor_catalogo", W);
probar("gestor_catalogo", gestor, "Cambiar un precio (queda auditado)", "PERMITIDO", (d) => {
  const p = d.catalogo_web.findOne({ sku: "ADV-0001" });
  d.catalogo_web.updateOne({ _id: p._id }, { $set: { precio_publico: p.precio_publico } });   // mismo valor: no cambia nada
});
probar("gestor_catalogo", gestor, "Leer clientes", "DENEGADO", (d) => d.clientes_web.findOne());
probar("gestor_catalogo", gestor, "Borrar el catálogo", "DENEGADO", (d) => d.catalogo_web.deleteMany({ sku: "NO-EXISTE" }));

// ---------- analista_lealtad ----------
const analista = conectar("analista_lealtad", W);
probar("analista_lealtad", analista, "Leer eventos de lealtad", "PERMITIDO", (d) => d.lealtad_eventos.findOne());
probar("analista_lealtad", analista, "Leer clientes sin enmascarar", "DENEGADO", (d) => d.clientes_web.findOne());
probar("analista_lealtad", analista, "Leer la vista enmascarada (Fase 2)", "PERMITIDO", (d) => d.v_clientes_enmascarados.findOne());

// ---------- app_logistica ----------
const logistica = conectar("app_logistica", W);
probar("app_logistica", logistica, "Leer clientes sin enmascarar", "DENEGADO", (d) => d.clientes_web.findOne());
probar("app_logistica", logistica, "Leer el catálogo", "DENEGADO", (d) => d.catalogo_web.findOne());
probar("app_logistica", logistica, "Leer la vista de rutas (Fase 2)", "PERMITIDO", (d) => d.v_clientes_rutas.findOne());

// ---------- Resultado ----------
print("\n" + "USUARIO".padEnd(18) + "PRUEBA".padEnd(38) + "ESPERADO".padEnd(11) + "OBTENIDO".padEnd(11) + "VEREDICTO");
for (const r of resultados) {
  print(r.usuario.padEnd(18) + r.prueba.padEnd(38) + r.esperado.padEnd(11) + r.obtenido.slice(0, 10).padEnd(11) + r.veredicto);
}
const revisar = resultados.filter((r) => r.veredicto !== "OK");
print(`\n${resultados.length} pruebas, ${revisar.length} por revisar.`);
revisar.forEach((r) => print(`  ${r.usuario} · ${r.prueba}: ${r.obtenido}`));
