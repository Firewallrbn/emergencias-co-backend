/**
 * Service 3 — Geospatial & Zone Aggregation
 *
 * Detecta puntos calientes de colapso agrupando emergencias por cercania, y localiza
 * zonas aisladas. Solo LEE del dominio de intake: es dueno unicamente de `geo.clusters`.
 */

import {
  consultar,
  verificarSalud,
  manejarErrores,
  ok,
  errorValidacion,
  esCiudad,
  CIUDADES,
  logger,
} from '@emergencias/shared';
import type { RespuestaHttp, Ciudad } from '@emergencias/shared';

interface EventoApiGateway {
  httpMethod?: string;
  resource?: string;
  path?: string;
  pathParameters?: Record<string, string | undefined> | null;
  queryStringParameters?: Record<string, string | undefined> | null;
  requestContext?: { requestId?: string };
}

interface FilaCluster {
  centroide_lon: number;
  centroide_lat: number;
  densidad: number;
  prioridad_max: string;
  radio_m: string;
}

/** Convierte un parametro de query a entero dentro de un rango, o devuelve el defecto. */
function entero(valor: string | undefined, porDefecto: number, min: number, max: number): number {
  if (valor === undefined) return porDefecto;
  const n = Number.parseInt(valor, 10);
  if (!Number.isFinite(n)) throw errorValidacion(`"${valor}" no es un numero entero`);
  if (n < min || n > max) throw errorValidacion(`el valor debe estar entre ${min} y ${max}`);
  return n;
}

function ciudadDeRuta(evento: EventoApiGateway): Ciudad {
  const ciudad = evento.pathParameters?.['ciudad'];
  if (!esCiudad(ciudad)) {
    throw errorValidacion(`ciudad debe ser una de: ${CIUDADES.join(', ')}`);
  }
  return ciudad;
}

/**
 * Puntos calientes de una ciudad.
 *
 * El calculo se delega a `geo.calcular_clusters`, que corre DBSCAN dentro de Postgres.
 * Traer los puntos a la Lambda para agruparlos aqui seria mover datos sin necesidad y
 * perder los indices geoespaciales.
 */
async function clusters(evento: EventoApiGateway): Promise<RespuestaHttp> {
  const ciudad = ciudadDeRuta(evento);
  const q = evento.queryStringParameters ?? {};

  const epsM = entero(q['eps'], 800, 100, 10_000);
  const minPuntos = entero(q['min_puntos'], 3, 2, 50);
  const horas = entero(q['horas'], 24, 1, 720);

  const registro = logger.child({ requestId: evento.requestContext?.requestId, ciudad });
  const inicio = Date.now();

  const resultado = await consultar<FilaCluster>(
    `select
       extensions.st_x(centroide::extensions.geometry) as centroide_lon,
       extensions.st_y(centroide::extensions.geometry) as centroide_lat,
       densidad,
       prioridad_max,
       radio_m
     from geo.calcular_clusters($1, $2, $3, make_interval(hours => $4))
     order by densidad desc, prioridad_max`,
    [ciudad, epsM, minPuntos, horas],
  );

  registro.info('Clusters calculados', {
    clusters: resultado.rowCount,
    epsM,
    minPuntos,
    horas,
    latencyMs: Date.now() - inicio,
  });

  return ok({
    ciudad,
    parametros: { eps_m: epsM, min_puntos: minPuntos, ventana_horas: horas },
    clusters: resultado.rows.map((f) => ({
      centroide: { lon: f.centroide_lon, lat: f.centroide_lat },
      densidad: f.densidad,
      prioridad_max: f.prioridad_max,
      radio_m: Number(f.radio_m),
    })),
  });
}

/**
 * Zonas aisladas: emergencias que no tienen ninguna otra cerca.
 *
 * Es el complemento del clustering. Un reporte solo en mitad de la nada es "ruido" para
 * DBSCAN, pero operativamente es lo contrario de ignorable: significa una comunidad
 * incomunicada, que es justo lo que el enunciado pide detectar.
 */
async function aisladas(evento: EventoApiGateway): Promise<RespuestaHttp> {
  const ciudad = ciudadDeRuta(evento);
  const radioM = entero(evento.queryStringParameters?.['radio'], 2000, 200, 50_000);

  const resultado = await consultar<{
    id: string;
    tipo: string;
    prioridad: string;
    lon: number;
    lat: number;
    vecinos: number;
  }>(
    `select
       e.id,
       e.tipo::text,
       e.prioridad::text,
       extensions.st_x(e.geom::extensions.geometry) as lon,
       extensions.st_y(e.geom::extensions.geometry) as lat,
       (select count(*)
          from intake.emergencias o
         where o.id <> e.id
           and o.ciudad = e.ciudad
           and extensions.st_dwithin(o.geom, e.geom, $2)
       )::int as vecinos
     from intake.emergencias e
     where e.ciudad = $1
     order by vecinos asc, e.prioridad asc
     limit 50`,
    [ciudad, radioM],
  );

  const solas = resultado.rows.filter((f) => f.vecinos === 0);

  return ok({
    ciudad,
    radio_m: radioM,
    total_aisladas: solas.length,
    zonas: solas.map((f) => ({
      emergencia_id: f.id,
      tipo: f.tipo,
      prioridad: f.prioridad,
      ubicacion: { lon: f.lon, lat: f.lat },
    })),
  });
}

async function salud(): Promise<RespuestaHttp> {
  const bd = await verificarSalud();
  return {
    statusCode: bd.ok ? 200 : 503,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    body: JSON.stringify({
      servicio: 'geo',
      estado: bd.ok ? 'ok' : 'degradado',
      version: process.env['AWS_LAMBDA_FUNCTION_VERSION'] ?? 'desconocida',
      baseDatos: bd,
    }),
  };
}

const enrutar = manejarErrores(async (evento: EventoApiGateway): Promise<RespuestaHttp> => {
  const ruta = evento.resource ?? evento.path ?? '/';

  if (ruta.endsWith('/health')) return salud();
  if (ruta.includes('/aisladas')) return aisladas(evento);
  if (ruta.includes('/clusters')) return clusters(evento);

  throw errorValidacion(`Ruta no soportada: ${ruta}`);
});

// Ver services/intake/src/index.ts para la explicacion completa de este mecanismo.
declare const __CAOS__: boolean;
const fallaAdrede = __CAOS__;

export const handler = async (evento: EventoApiGateway): Promise<RespuestaHttp> => {
  if (fallaAdrede) {
    logger.error('Fallo sintetico inyectado (prueba de rollback del canary)');
    throw new Error('Fallo sintetico inyectado para validar el rollback automatico');
  }
  return enrutar(evento);
};
