// =============================================================================
// 08_datos_masivos.js  ·  Fase 3  ·  Responsable: Yuleny
// Genera datos masivos para reproducir la búsqueda geográfica lenta del caso.
// Por defecto: 500 mil clientes repartidos en Sinaloa, 2 mil productos con atributos
// variables, 600 mil eventos de lealtad y 50 mil carritos (unos 350 MB).
//
//   mongosh "mongodb://127.0.0.1:37017/admin?directConnection=true" -u dba_yuleny --file 08_datos_masivos.js
//
// Para cambiar el volumen: mongosh ... --eval "var ESCALA = 0.3" --file 08_datos_masivos.js
// Ojo con el RTO: más datos = restauración más lenta (midan en la Fase 4).
// Los documentos cumplen el validador de la Fase 2 (password_hash, sin tarjeta.numero).
// =============================================================================

const ESC = (typeof ESCALA === "number") ? ESCALA : 1;
const W = db.getSiblingDB("alimentos_web");
const LOTE = 10000;
const azar = (a, b) => a + Math.random() * (b - a);
const elegir = (arr) => arr[Math.floor(Math.random() * arr.length)];
// Hash de relleno: válido para el validador, no corresponde a ninguna contraseña real
const HASH_RELLENO = "scrypt$16384$8$1$RELLENO-DATOS-DE-PRUEBA$RELLENO-DATOS-DE-PRUEBA";

// Centros urbanos de Sinaloa [lng, lat] y su peso en la población de clientes
const ciudades = [
  { c: "CLN", lng: -107.3940, lat: 24.8091, peso: 0.40 },   // Culiacán
  { c: "MZT", lng: -106.4111, lat: 23.2494, peso: 0.20 },   // Mazatlán
  { c: "LMM", lng: -108.9886, lat: 25.7904, peso: 0.15 },   // Los Mochis
  { c: "GSV", lng: -108.4669, lat: 25.5677, peso: 0.10 },   // Guasave
  { c: "NAV", lng: -107.7003, lat: 24.7650, peso: 0.10 },   // Navolato
  { c: "GML", lng: -108.0780, lat: 25.4610, peso: 0.05 }    // Guamúchil
];
function ciudadAlAzar() {
  let r = Math.random(), acum = 0;
  for (const x of ciudades) { acum += x.peso; if (r <= acum) return x; }
  return ciudades[0];
}
function insertarEnLotes(col, total, fabrica) {
  const inicio = Date.now();
  for (let i = 0; i < total; i += LOTE) {
    const docs = [];
    for (let j = i; j < Math.min(i + LOTE, total); j++) docs.push(fabrica(j));
    col.insertMany(docs, { ordered: false });
    if ((i / LOTE) % 10 === 0) print(`  ${col.getName()}: ${Math.min(i + LOTE, total)} / ${total}`);
  }
  print(`+ ${col.getName()}: ${total} documentos en ${((Date.now() - inicio) / 1000).toFixed(1)} s`);
}

// ---------- Catálogo: atributos distintos por categoría (el motivo de usar documentos) ----------
const nCat = 2000;
const yaHay = W.catalogo_web.countDocuments({ sku: /^ADV-[0-9]{4}$/ });
insertarEnLotes(W.catalogo_web, nCat - yaHay, (j) => {
  const n = yaHay + j + 1;
  const cat = elegir(["Conservas", "Granos", "Deshidratados", "Salsas", "Harinas", "Refrigerados"]);
  const atributos = cat === "Granos" ? { peso_kg: elegir([1, 5, 25, 50]), calibre: elegir([38, 42, 44]), humedad_max_pct: 14 }
                  : cat === "Refrigerados" ? { peso_g: elegir([300, 500, 1000]), temperatura_c: { min: 1, max: 4 }, vida_anaquel_dias: 30 }
                  : cat === "Deshidratados" ? { peso_g: elegir([100, 250, 500]), certificaciones: [elegir(["Orgánico", "Kosher", "Sin gluten"])] }
                  : { volumen_ml: elegir([250, 500, 1000]), empaque: elegir(["Vidrio", "Lata", "Tetra Pak"]) };
  const nombre = `${elegir(["Mango", "Chile", "Tomate", "Frijol", "Garbanzo", "Elote", "Pepino"])} ${cat.toLowerCase()} ${n}`;
  return { sku: `ADV-${String(5000 + n)}`, nombre, categoria: cat, precio_publico: NumberDecimal(azar(15, 900).toFixed(2)),
           activo: Math.random() > 0.05, atributos, descripcion: `${nombre} producido en Sinaloa, presentación ${JSON.stringify(atributos)}`,
           etiquetas: [cat.toLowerCase(), elegir(["mayoreo", "botana", "cocina", "restaurantes", "exportación"])] };
});

// ---------- Clientes con ubicación (500 mil por defecto) ----------
const nCli = Math.round(500000 * ESC);
insertarEnLotes(W.clientes_web, nCli, (j) => {
  const ciudad = ciudadAlAzar();
  const lng = ciudad.lng + azar(-0.12, 0.12), lat = ciudad.lat + azar(-0.12, 0.12);   // ~±13 km
  const sector = Math.floor((lng - ciudad.lng + 0.12) / 0.06) * 4 + Math.floor((lat - ciudad.lat + 0.12) / 0.06);
  return {
    email: `cliente${j}@correo.example`, nombre: `Cliente ${j}`,
    telefono: "667" + String(Math.floor(Math.random() * 1e7)).padStart(7, "0"),
    password_hash: HASH_RELLENO,
    nivel_lealtad: elegir(["BRONCE", "BRONCE", "BRONCE", "PLATA", "PLATA", "ORO"]),
    puntos: Math.floor(azar(0, 20000)),
    fecha_registro: new Date(Date.now() - azar(0, 3 * 365) * 864e5),
    zona_reparto: `${ciudad.c}-${String(sector).padStart(2, "0")}`,
    ubicacion: { type: "Point", coordinates: [Number(lng.toFixed(6)), Number(lat.toFixed(6))] }
  };
});

// ---------- Eventos de lealtad (600 mil por defecto) ----------
const ids = W.clientes_web.find({}, { _id: 1 }).limit(200000).toArray().map((d) => d._id);
const nEv = Math.round(600000 * ESC);
insertarEnLotes(W.lealtad_eventos, nEv, () => {
  const tipo = elegir(["COMPRA", "COMPRA", "COMPRA", "CANJE", "BONO"]);
  const monto = azar(100, 15000);
  return { cliente_id: elegir(ids), tipo, fecha: new Date(Date.now() - azar(0, 365) * 864e5),
           puntos: tipo === "CANJE" ? -Math.floor(azar(100, 2000)) : Math.floor(monto / 10),
           sucursal: elegir(["Tienda Centro", "Tienda Tres Ríos", "Mayoreo Mazatlán", "Mayoreo Los Mochis", "Web"]),
           monto: NumberDecimal(monto.toFixed(2)) };
});

// ---------- Carritos (para el índice TTL) ----------
insertarEnLotes(W.carritos, Math.round(50000 * ESC), () => ({
  cliente_id: elegir(ids), estado: elegir(["ABIERTO", "ABIERTO", "PAGADO", "ABANDONADO"]),
  actualizado_en: new Date(Date.now() - azar(0, 72) * 36e5),
  items: [{ sku: "ADV-0005", nombre: "Mango deshidratado 250 g", cantidad: 1 + Math.floor(azar(0, 5)), precio: NumberDecimal("72.00") }]
}));

print("\n=== Volumen por colección ===");
for (const c of ["catalogo_web", "clientes_web", "lealtad_eventos", "carritos"]) {
  const s = W.getCollection(c).stats();
  print(`${c.padEnd(16)} ${String(s.count).padStart(9)} docs  ${(s.size / 1048576).toFixed(1).padStart(8)} MB datos  ${(s.totalIndexSize / 1048576).toFixed(1).padStart(7)} MB índices`);
}
