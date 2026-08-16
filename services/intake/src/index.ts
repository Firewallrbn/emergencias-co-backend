/**
 * Service 1 — Intake & Triage
 *
 * Recibe reportes ciudadanos, calcula el triage de forma determinista y los persiste.
 * Es el único servicio dueño de `intake.emergencias`.
 */

import {
  consultar,
  verificarSalud,
  manejarErrores,
  ok,
  creado,
  errorValidacion,
  noEncontrado,
  esCiudad,
  esTipoSolicitud,
  esCoordenadaValida,
  logger,
} from '@emergencias/shared';
import type { RespuestaHttp } from '@emergencias/shared';
import { calcularTriaje } from './triaje.ts';
import type { DatosTriaje } from './triaje.ts';

/** Forma mínima del evento de API Gateway (REST, integración proxy) que consumimos. */
interface EventoApiGateway {
  httpMethod?: string;
  path?: string;
  resource?: string;
  body?: string | null;
  headers?: Record<string, string | undefined> | null;
  pathParameters?: Record<string, string | undefined> | null;
  requestContext?: { requestId?: string };
}

interface CuerpoEmergencia {
  tipo?: unknown;
  ciudad?: unknown;
  descripcion?: unknown;
  coordenadas?: unknown;
  datos?: unknown;
  contacto?: unknown;
  reportado_por?: unknown;
}

/** Cabeceras HTTP en minúscula: API Gateway no garantiza la caja. */
function cabecera(evento: EventoApiGateway, nombre: string): string | undefined {
  const headers = evento.headers ?? {};
  const clave = Object.keys(headers).find((k) => k.toLowerCase() === nombre.toLowerCase());
  return clave ? headers[clave] : undefined;
}

function parsearCuerpo(evento: EventoApiGateway): CuerpoEmergencia {
  if (!evento.body) throw errorValidacion('El cuerpo de la solicitud esta vacio');
  try {
    const parseado: unknown = JSON.parse(evento.body);
    if (typeof parseado !== 'object' || parseado === null || Array.isArray(parseado)) {
      throw errorValidacion('El cuerpo debe ser un objeto JSON');
    }
    return parseado as CuerpoEmergencia;
  } catch (err) {
    if (err instanceof SyntaxError) throw errorValidacion('El cuerpo no es JSON valido');
    throw err;
  }
}

/**
 * Valida el payload.
 *
 * El API Gateway ya rechaza lo que no cumple el JSON Schema, pero esta validación no
 * sobra: el servicio también se invoca desde pruebas y desde la cola, y un microservicio
 * que confía en que alguien más validó por él es un microservicio acoplado.
 */
function validar(cuerpo: CuerpoEmergencia): {
  tipo: ReturnType<typeof asTipo>;
  ciudad: ReturnType<typeof asCiudad>;
  descripcion: string;
  lon: number;
  lat: number;
  datos: DatosTriaje;
  contacto: string | null;
  reportadoPor: string | null;
} {
  const errores: string[] = [];

  if (!esTipoSolicitud(cuerpo.tipo)) {
    errores.push('tipo debe ser uno de: usar_medica, albergue, suministros, danos');
  }
  if (!esCiudad(cuerpo.ciudad)) {
    errores.push('ciudad debe ser una de: choco, pereira, cali, manizales');
  }
  if (
    typeof cuerpo.descripcion !== 'string' ||
    cuerpo.descripcion.trim().length === 0 ||
    cuerpo.descripcion.length > 2000
  ) {
    errores.push('descripcion es obligatoria y debe tener entre 1 y 2000 caracteres');
  }
  if (!esCoordenadaValida(cuerpo.coordenadas)) {
    errores.push('coordenadas debe ser { lon, lat } con valores geograficos validos');
  }
  if (cuerpo.datos !== undefined && (typeof cuerpo.datos !== 'object' || cuerpo.datos === null)) {
    errores.push('datos debe ser un objeto');
  }

  if (errores.length > 0) throw errorValidacion('Payload invalido', errores);

  const coords = cuerpo.coordenadas as { lon: number; lat: number };
  return {
    tipo: asTipo(cuerpo.tipo),
    ciudad: asCiudad(cuerpo.ciudad),
    descripcion: (cuerpo.descripcion as string).trim(),
    lon: coords.lon,
    lat: coords.lat,
    datos: (cuerpo.datos ?? {}) as DatosTriaje,
    contacto: typeof cuerpo.contacto === 'string' ? cuerpo.contacto : null,
    reportadoPor: typeof cuerpo.reportado_por === 'string' ? cuerpo.reportado_por : null,
  };
}

// Estrechan el tipo tras la validación; nunca se llaman antes de comprobar.
const asTipo = (v: unknown) => v as import('@emergencias/shared').TipoSolicitud;
const asCiudad = (v: unknown) => v as import('@emergencias/shared').Ciudad;

interface FilaEmergencia {
  id: string;
  prioridad: string;
  triage_score: number;
  creado_en: string;
}

async function crearEmergencia(evento: EventoApiGateway): Promise<RespuestaHttp> {
  // Patrón: Idempotency Key. Sin cabecera no hay proteccion contra duplicados, y en una
  // emergencia los reenvios son la norma, no la excepcion: la exigimos.
  const idempotencyKey = cabecera(evento, 'Idempotency-Key');
  if (!idempotencyKey || idempotencyKey.length < 8 || idempotencyKey.length > 200) {
    throw errorValidacion(
      'Falta la cabecera Idempotency-Key (entre 8 y 200 caracteres). ' +
        'Protege contra reportes duplicados cuando el cliente reintenta.',
    );
  }

  const v = validar(parsearCuerpo(evento));
  const triaje = calcularTriaje(v.tipo, v.datos);

  const registro = logger.child({
    requestId: evento.requestContext?.requestId,
    ciudad: v.ciudad,
    tipo: v.tipo,
  });

  // El INSERT resuelve la idempotencia en la propia base, no en el codigo: dos
  // contenedores Lambda concurrentes con la misma clave no pueden crear dos filas.
  // Cuando hay conflicto se hace un UPDATE que no cambia nada, solo para que RETURNING
  // devuelva la fila existente y el cliente reciba su emergencia en vez de un error.
  const sql = `
    insert into intake.emergencias
      (idempotency_key, tipo, ciudad, prioridad, triage_score, geom, descripcion, datos,
       contacto, reportado_por)
    values
      ($1, $2, $3, $4, $5,
       extensions.st_point($6, $7)::extensions.geography,
       $8, $9::jsonb, $10, $11)
    on conflict (idempotency_key) do update
      set idempotency_key = excluded.idempotency_key
    returning id, prioridad, triage_score, creado_en, (xmax = 0) as fue_creada
  `;

  const resultado = await consultar<FilaEmergencia & { fue_creada: boolean }>(
    sql,
    [
      idempotencyKey,
      v.tipo,
      v.ciudad,
      triaje.prioridad,
      triaje.puntaje,
      v.lon,
      v.lat,
      v.descripcion,
      JSON.stringify(v.datos),
      v.contacto,
      v.reportadoPor,
    ],
    // Sin reintentos automaticos: el INSERT ya es idempotente por la clave unica, pero
    // reintentar aqui enmascararia problemas reales de la base.
    { reintentar: false },
  );

  const fila = resultado.rows[0];
  if (!fila) throw new Error('El INSERT no devolvio ninguna fila');

  registro.info(fila.fue_creada ? 'Emergencia registrada' : 'Reporte duplicado descartado', {
    emergenciaId: fila.id,
    prioridad: fila.prioridad,
    triageScore: fila.triage_score,
    factores: triaje.factores,
    duplicado: !fila.fue_creada,
  });

  const cuerpo = {
    id: fila.id,
    prioridad: fila.prioridad,
    triage_score: fila.triage_score,
    creado_en: fila.creado_en,
    duplicado: !fila.fue_creada,
  };

  // 201 si se creo, 200 si ya existia. El cliente distingue sin tener que interpretar.
  return fila.fue_creada ? creado(cuerpo) : ok(cuerpo);
}

async function obtenerEmergencia(evento: EventoApiGateway): Promise<RespuestaHttp> {
  const id = evento.pathParameters?.['id'];
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) throw errorValidacion('id debe ser un UUID');

  const resultado = await consultar<FilaEmergencia & { tipo: string; ciudad: string; descripcion: string }>(
    `select id, tipo, ciudad, prioridad, triage_score, descripcion, creado_en
     from intake.emergencias where id = $1`,
    [id],
  );

  const fila = resultado.rows[0];
  if (!fila) throw noEncontrado('La emergencia');
  return ok(fila);
}

async function salud(): Promise<RespuestaHttp> {
  const bd = await verificarSalud();
  return {
    statusCode: bd.ok ? 200 : 503,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
    body: JSON.stringify({
      servicio: 'intake',
      estado: bd.ok ? 'ok' : 'degradado',
      // Se expone la version desplegada para poder ver, durante el canary, que porcentaje
      // del trafico esta atendiendo cada version.
      version: process.env['AWS_LAMBDA_FUNCTION_VERSION'] ?? 'desconocida',
      baseDatos: bd,
    }),
  };
}

const enrutar = manejarErrores(async (evento: EventoApiGateway): Promise<RespuestaHttp> => {
  const metodo = evento.httpMethod ?? 'GET';
  const ruta = evento.resource ?? evento.path ?? '/';

  if (ruta.endsWith('/health')) return salud();
  if (metodo === 'POST' && ruta.includes('/emergencias')) return crearEmergencia(evento);
  if (metodo === 'GET' && ruta.includes('/emergencias')) return obtenerEmergencia(evento);

  throw noEncontrado(`La ruta ${metodo} ${ruta}`);
});

/**
 * Inyeccion de fallo sintetico para validar el rollback automatico del canary.
 *
 * `__CAOS__` lo sustituye esbuild en tiempo de compilacion (`--define`), no es una
 * variable de entorno. La diferencia importa y costo dos intentos descubrirlo:
 *
 *   - Cambiar una variable de entorno actualiza $LATEST pero NO publica una version
 *     nueva, asi que el alias sigue apuntando a la anterior y CodeDeploy ni se entera.
 *   - `AutoPublishCodeSha256` serviria para forzarlo, pero solo acepta una cadena
 *     literal: no admite !Sub ni !Ref, asi que no se puede atar a un parametro.
 *
 * Sustituyendolo en compilacion, el bundle cambia de verdad y con el su hash, que es lo
 * que SAM mira para publicar una version. Ademas es mas fiel a lo que se quiere simular:
 * un despliegue defectuoso es codigo malo, no una variable mal puesta.
 *
 * Va DELIBERADAMENTE fuera de `manejarErrores`. Dentro, el error se convertiria en una
 * respuesta 500 y la metrica `AWS/Lambda Errors` seguiria en cero; solo se enteraria la
 * alarma de 5xx del gateway. Lanzando aqui, el fallo cuenta como error de Lambda y
 * dispara las dos alarmas, que es justo lo que queremos demostrar.
 */
declare const __CAOS__: boolean;
const fallaAdrede = __CAOS__;

export const handler = async (evento: EventoApiGateway): Promise<RespuestaHttp> => {
  if (fallaAdrede) {
    logger.error('Fallo sintetico inyectado (prueba de rollback del canary)');
    throw new Error(
      'Fallo sintetico inyectado para validar el rollback automatico. ' +
        'Si ves esto en produccion de verdad, revisa el parametro InyectarFallo del stack.',
    );
  }
  return enrutar(evento);
};
