/**
 * API Gateway local para la demostración con docker compose.
 *
 * Las imágenes base de Lambda traen el Runtime Interface Emulator, que expone cada
 * función en `POST /2015-03-31/functions/function/invocations` esperando un EVENTO, no una
 * petición HTTP normal. Invocarlas así a mano durante una demostración es incómodo y no
 * se parece en nada a lo que ve el sistema real.
 *
 * Este proceso hace de traductor: recibe HTTP corriente, lo convierte al mismo evento que
 * produce API Gateway con integración proxy, se lo pasa al contenedor que corresponde
 * según la ruta, y devuelve la respuesta. Así `curl http://localhost:8080/v1/health`
 * funciona igual que contra producción.
 *
 * Node puro, sin dependencias: añadir express aquí sería meter node_modules en un
 * contenedor que existe solo para reenviar peticiones.
 */

import { createServer } from 'node:http';

const PUERTO = Number(process.env.PUERTO ?? 8080);

/**
 * Tabla de enrutamiento. Refleja las rutas de infra/gateway.yaml; si allí se añade una,
 * hay que añadirla aquí. Es duplicación consciente: la alternativa sería interpretar la
 * especificación OpenAPI en tiempo de ejecución, que para una demostración local es
 * mucha maquinaria para poco beneficio.
 */
const RUTAS = [
  { patron: /^\/v1\/health$/, metodos: ['GET'], destino: 'intake', recurso: '/v1/health' },
  { patron: /^\/v1\/emergencias$/, metodos: ['POST'], destino: 'intake', recurso: '/v1/emergencias' },
  { patron: /^\/v1\/emergencias\/([^/]+)$/, metodos: ['GET'], destino: 'intake', recurso: '/v1/emergencias/{id}', parametros: ['id'] },
  { patron: /^\/v1\/despachos$/, metodos: ['GET'], destino: 'dispatch', recurso: '/v1/despachos' },
  { patron: /^\/v1\/despachos\/([^/]+)$/, metodos: ['PATCH'], destino: 'dispatch', recurso: '/v1/despachos/{id}', parametros: ['id'] },
  { patron: /^\/v1\/zonas\/([^/]+)\/clusters$/, metodos: ['GET'], destino: 'geo', recurso: '/v1/zonas/{ciudad}/clusters', parametros: ['ciudad'] },
  { patron: /^\/v1\/zonas\/([^/]+)\/aisladas$/, metodos: ['GET'], destino: 'geo', recurso: '/v1/zonas/{ciudad}/aisladas', parametros: ['ciudad'] },
  { patron: /^\/v1\/notificaciones$/, metodos: ['POST', 'GET'], destino: 'notify', recurso: '/v1/notificaciones' },
];

// Dentro de la red de compose, cada servicio se resuelve por su nombre.
const PUERTO_RIE = 8080;
const urlInvocacion = (servicio) =>
  `http://${servicio}:${PUERTO_RIE}/2015-03-31/functions/function/invocations`;

function leerCuerpo(peticion) {
  return new Promise((resolver, rechazar) => {
    const trozos = [];
    peticion.on('data', (t) => trozos.push(t));
    peticion.on('end', () => resolver(Buffer.concat(trozos).toString('utf8') || null));
    peticion.on('error', rechazar);
  });
}

const servidor = createServer(async (peticion, respuesta) => {
  const url = new URL(peticion.url, `http://${peticion.headers.host}`);

  // CORS: en producción lo resuelven el gateway y las propias funciones. Aquí se abre
  // para cualquier origen porque es un entorno local de demostración y lo contrario
  // obligaría a levantar el frontend en un puerto concreto.
  respuesta.setHeader('Access-Control-Allow-Origin', '*');
  respuesta.setHeader('Access-Control-Allow-Headers', 'Content-Type,Idempotency-Key,Authorization');
  respuesta.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,OPTIONS');
  if (peticion.method === 'OPTIONS') {
    respuesta.writeHead(204).end();
    return;
  }

  const ruta = RUTAS.find(
    (r) => r.patron.test(url.pathname) && r.metodos.includes(peticion.method),
  );

  if (!ruta) {
    respuesta.writeHead(404, { 'Content-Type': 'application/json' });
    respuesta.end(JSON.stringify({ error: 'NO_ENCONTRADO', mensaje: `Sin ruta para ${peticion.method} ${url.pathname}` }));
    return;
  }

  const coincidencia = url.pathname.match(ruta.patron);
  const pathParameters = {};
  (ruta.parametros ?? []).forEach((nombre, i) => {
    pathParameters[nombre] = decodeURIComponent(coincidencia[i + 1]);
  });

  // Mismo formato que emite API Gateway con integración proxy, para que el handler no
  // necesite saber si corre en local o en la nube.
  const evento = {
    httpMethod: peticion.method,
    path: url.pathname,
    resource: ruta.recurso,
    headers: peticion.headers,
    pathParameters: Object.keys(pathParameters).length ? pathParameters : null,
    queryStringParameters: Object.fromEntries(url.searchParams) ,
    body: await leerCuerpo(peticion),
    isBase64Encoded: false,
    requestContext: { requestId: `local-${Date.now()}` },
  };
  if (Object.keys(evento.queryStringParameters).length === 0) evento.queryStringParameters = null;

  const inicio = Date.now();
  try {
    const r = await fetch(urlInvocacion(ruta.destino), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(evento),
    });

    const resultado = await r.json();

    // Un error no controlado dentro de la función llega como objeto de error del RIE,
    // no como respuesta HTTP. Se traduce a 502, que es lo que haría API Gateway.
    if (resultado?.errorType || resultado?.errorMessage) {
      console.error(`${peticion.method} ${url.pathname} -> ${ruta.destino}: ${resultado.errorMessage}`);
      respuesta.writeHead(502, { 'Content-Type': 'application/json' });
      respuesta.end(JSON.stringify({ error: 'ERROR_FUNCION', mensaje: resultado.errorMessage }));
      return;
    }

    const cabeceras = { 'Content-Type': 'application/json', ...(resultado.headers ?? {}) };
    // La cabecera CORS local manda sobre la que traiga la función, que apunta al dominio
    // de Vercel y aquí no serviría de nada.
    cabeceras['Access-Control-Allow-Origin'] = '*';

    console.log(`${peticion.method} ${url.pathname} -> ${ruta.destino} ${resultado.statusCode} (${Date.now() - inicio} ms)`);
    respuesta.writeHead(resultado.statusCode ?? 200, cabeceras);
    respuesta.end(resultado.body ?? '');
  } catch (err) {
    console.error(`${peticion.method} ${url.pathname} -> ${ruta.destino}: ${err.message}`);
    respuesta.writeHead(503, { 'Content-Type': 'application/json' });
    respuesta.end(JSON.stringify({ error: 'SERVICIO_NO_DISPONIBLE', mensaje: err.message }));
  }
});

servidor.listen(PUERTO, () => {
  console.log(`API Gateway local escuchando en http://localhost:${PUERTO}`);
  console.log('Rutas:');
  for (const r of RUTAS) console.log(`  ${r.metodos.join(',').padEnd(11)} ${r.recurso}  ->  ${r.destino}`);
});
