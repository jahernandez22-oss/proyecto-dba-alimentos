// =============================================================================
// 03_esquema_y_datos.js  ·  Fase 1  ·  Responsable: Yuleny
// Crea las colecciones de alimentos_web con validación de esquema ($jsonSchema) y carga
// datos de muestra del PROTOTIPO (contraseñas y tarjetas en texto plano, a propósito,
// para el "antes"; la Guía 2 los corrige).
//
//   mongosh "mongodb://127.0.0.1:37017/admin?directConnection=true" -u dba_yuleny --file 03_esquema_y_datos.js
//
// Diseño desnormalizado (por qué): en un e-commerce se lee mucho más de lo que se escribe.
// Cada documento guarda junto lo que la pantalla necesita: el cliente trae sus direcciones,
// su ubicación y su nivel de lealtad; el carrito trae una copia de nombre y precio de cada
// producto. Así una página se arma con UNA lectura, sin uniones. El costo: si cambia el
// nombre de un producto, los carritos viejos conservan el anterior (aceptable: es una foto
// del momento de la compra).
// =============================================================================

const W = db.getSiblingDB("alimentos_web");
const numero = ["double", "int", "long", "decimal"];

function crearColeccion(nombre, esquema) {
  if (W.getCollectionNames().includes(nombre)) {
    W.runCommand({ collMod: nombre, validator: { $jsonSchema: esquema }, validationLevel: "strict", validationAction: "error" });
    print(`~ ${nombre}: validador actualizado`);
  } else {
    W.createCollection(nombre, { validator: { $jsonSchema: esquema }, validationLevel: "strict", validationAction: "error" });
    print(`+ ${nombre} creada con validador`);
  }
}

// ---------- catalogo_web: atributos variables por tipo de producto ----------
crearColeccion("catalogo_web", {
  bsonType: "object",
  required: ["sku", "nombre", "categoria", "precio_publico", "activo"],
  properties: {
    sku:            { bsonType: "string", pattern: "^ADV-[0-9]{4,}$" },
    nombre:         { bsonType: "string", minLength: 3 },
    categoria:      { bsonType: "string" },
    precio_publico: { bsonType: numero, minimum: 0 },
    activo:         { bsonType: "bool" },
    atributos:      { bsonType: "object" },
    descripcion:    { bsonType: "string" },
    etiquetas:      { bsonType: "array", items: { bsonType: "string" } }
  }
});

// ---------- clientes_web: ubicación GeoJSON para asignar rutas ----------
crearColeccion("clientes_web", {
  bsonType: "object",
  required: ["email", "nombre", "telefono", "ubicacion", "nivel_lealtad", "fecha_registro"],
  properties: {
    email:          { bsonType: "string", pattern: "^[^@\\s]+@[^@\\s]+$" },
    nombre:         { bsonType: "string" },
    telefono:       { bsonType: "string", pattern: "^[0-9]{10}$" },
    nivel_lealtad:  { enum: ["BRONCE", "PLATA", "ORO"] },
    puntos:         { bsonType: numero, minimum: 0 },
    fecha_registro: { bsonType: "date" },
    zona_reparto:   { bsonType: "string" },
    ubicacion: {
      bsonType: "object", required: ["type", "coordinates"],
      properties: {
        type:        { enum: ["Point"] },
        coordinates: { bsonType: "array", minItems: 2, maxItems: 2, items: { bsonType: numero } }
      }
    },
    direcciones:    { bsonType: "array" }
  }
});

// ---------- carritos: sesiones de compra (se vencen con un índice TTL en la Fase 3) ----------
crearColeccion("carritos", {
  bsonType: "object",
  required: ["cliente_id", "estado", "items", "actualizado_en"],
  properties: {
    cliente_id:     { bsonType: "objectId" },
    estado:         { enum: ["ABIERTO", "PAGADO", "ABANDONADO"] },
    actualizado_en: { bsonType: "date" },
    items: {
      bsonType: "array",
      items: {
        bsonType: "object", required: ["sku", "nombre", "cantidad", "precio"],
        properties: {
          sku: { bsonType: "string" }, nombre: { bsonType: "string" },
          cantidad: { bsonType: numero, minimum: 1 }, precio: { bsonType: numero, minimum: 0 }
        }
      }
    }
  }
});

// ---------- lealtad_eventos: interacciones del programa de lealtad ----------
crearColeccion("lealtad_eventos", {
  bsonType: "object",
  required: ["cliente_id", "tipo", "puntos", "fecha"],
  properties: {
    cliente_id: { bsonType: "objectId" },
    tipo:       { enum: ["COMPRA", "CANJE", "BONO", "AJUSTE"] },
    puntos:     { bsonType: numero },
    fecha:      { bsonType: "date" },
    sucursal:   { bsonType: "string" },
    monto:      { bsonType: numero }
  }
});

// ---------- Datos de muestra ----------
if (W.catalogo_web.countDocuments() === 0) {
  W.catalogo_web.insertMany([
    { sku: "ADV-0001", nombre: "Puré de tomate saladet 1 L", categoria: "Conservas", precio_publico: NumberDecimal("34.90"), activo: true,
      atributos: { volumen_ml: 1000, empaque: "Tetra Pak", origen: "Guasave, Sinaloa" }, etiquetas: ["tomate", "cocina"] },
    { sku: "ADV-0004", nombre: "Garbanzo blanco calibre 42 25 kg", categoria: "Granos", precio_publico: NumberDecimal("1049.00"), activo: true,
      atributos: { peso_kg: 25, calibre: 42, mercado: "Exportación", humedad_max_pct: 14 }, etiquetas: ["garbanzo", "mayoreo"] },
    { sku: "ADV-0005", nombre: "Mango deshidratado 250 g", categoria: "Deshidratados", precio_publico: NumberDecimal("72.00"), activo: true,
      atributos: { peso_g: 250, origen: "El Rosario, Sinaloa", certificaciones: ["Orgánico", "Kosher"], vida_anaquel_dias: 365 },
      descripcion: "Mango Ataulfo deshidratado sin azúcar añadida", etiquetas: ["mango", "botana", "saludable"] },
    { sku: "ADV-0007", nombre: "Chile jalapeño en escabeche 2.8 kg", categoria: "Conservas", precio_publico: NumberDecimal("124.00"), activo: true,
      atributos: { peso_kg: 2.8, picor_scoville: 5000, presentacion: "Lata institucional" }, etiquetas: ["chile", "restaurantes"] },
    { sku: "ADV-0011", nombre: "Guacamole refrigerado 300 g", categoria: "Refrigerados", precio_publico: NumberDecimal("62.00"), activo: true,
      atributos: { peso_g: 300, temperatura_c: { min: 1, max: 4 }, vida_anaquel_dias: 30 }, etiquetas: ["aguacate", "refrigerado"] }
  ]);
  print("+ catálogo de muestra");
}

if (W.clientes_web.countDocuments() === 0) {
  const ahora = new Date();
  const r = W.clientes_web.insertMany([
    // PROTOTIPO: password y tarjeta en texto plano (se corrige en la Guía 2)
    { email: "compras@lalomita.example", nombre: "Abarrotes La Lomita", telefono: "6670000101", password: "lomita2024",
      tarjeta: { numero: "4111111111111111", vencimiento: "08/28" }, nivel_lealtad: "ORO", puntos: 18250,
      zona_reparto: "CLN-CENTRO", fecha_registro: ahora,
      ubicacion: { type: "Point", coordinates: [-107.3940, 24.8091] },
      direcciones: [{ alias: "Bodega", calle: "Blvd. Francisco I. Madero 100", ciudad: "Culiacán" }] },
    { email: "pedidos@dpacifico.example", nombre: "Distribuidora del Pacífico", telefono: "6680000202", password: "pacifico1",
      tarjeta: { numero: "5555555555554444", vencimiento: "11/27" }, nivel_lealtad: "PLATA", puntos: 7400,
      zona_reparto: "MOCHIS", fecha_registro: ahora,
      ubicacion: { type: "Point", coordinates: [-108.9886, 25.7904] } },
    { email: "elguero@correo.example", nombre: "Taquería El Güero", telefono: "6670000505", password: "guero",
      nivel_lealtad: "BRONCE", puntos: 320, zona_reparto: "CLN-TRESRIOS", fecha_registro: ahora,
      ubicacion: { type: "Point", coordinates: [-107.3897, 24.8257] } },
    { email: "gerencia@mardecortes.example", nombre: "Restaurante Mar de Cortés", telefono: "6690000606", password: "mazatlan2023",
      nivel_lealtad: "PLATA", puntos: 5100, zona_reparto: "MAZATLAN", fecha_registro: ahora,
      ubicacion: { type: "Point", coordinates: [-106.4111, 23.2494] } }
  ]);
  const ids = Object.values(r.insertedIds);
  W.carritos.insertOne({ cliente_id: ids[2], estado: "ABIERTO", actualizado_en: ahora,
    items: [{ sku: "ADV-0007", nombre: "Chile jalapeño en escabeche 2.8 kg", cantidad: 2, precio: NumberDecimal("124.00") }] });
  W.lealtad_eventos.insertMany([
    { cliente_id: ids[0], tipo: "COMPRA", puntos: 1250, fecha: ahora, sucursal: "Tienda Centro", monto: NumberDecimal("12500.00") },
    { cliente_id: ids[0], tipo: "CANJE",  puntos: -500, fecha: ahora, sucursal: "Tienda Centro" },
    { cliente_id: ids[3], tipo: "BONO",   puntos: 200,  fecha: ahora }
  ]);
  print("+ clientes, carrito y eventos de muestra");
}

// ---------- Evidencia: el validador rechaza un documento mal formado ----------
try {
  W.clientes_web.insertOne({ email: "no-es-correo", nombre: "Prueba", telefono: "123" });
  print("REVISAR: el validador aceptó un documento inválido");
} catch (e) {
  print(`OK: el validador rechazó el documento inválido (${e.codeName || e.code})`);
}
printjson(W.getCollectionInfos({}, { nameOnly: false }).map((c) => ({ coleccion: c.name, validacion: c.options.validationLevel })));
