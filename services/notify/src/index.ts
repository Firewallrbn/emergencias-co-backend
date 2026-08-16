/**
 * Service 4 — Notification & Status Broadcast
 *
 * Emite actualizaciones de estado hacia ciudadanos y organismos.
 *
 * El broadcast reactivo no lo hace este servicio con un bucle de envio: escribe la fila en
 * `notify.notificaciones` y la replicacion logica de Postgres se encarga del resto. Los
 * clientes suscritos por Supabase Realtime la reciben al instante, sin polling, que es lo
 * que pide el enunciado. Insertar ES publicar.
 */

import {
  consultar,
  enTransaccion,
  verificarSalud,
  manejarErrores,
  responder,
  ok,
  creado,
  errorValidacion,
  logger,
} from '@emergencias/shared';
import type { RespuestaHttp } from '@emergencias/shared';

interface EventoApiGateway {
  httpMethod?: string;
  resource?: string;
  path?: string;
  body?: string | null;
  queryStringParameters?: Record<string, string | undefined> | null;
  requestContext?: { requestId?: string };
}

const CANALES = ['webhook', 'realtime', 'email'] as const;
type Canal = (typeof CANALES)[number];

const esUuid = (v: unknown): v is string =>
  typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

interface CuerpoNotificacion {
  emergencia_id?: unknown;
  asunto?: unknown;
  cuerpo?: unknown;
  canal?: unknown;
  destinatario?: unknown;
}

function parsear(evento: EventoApiGateway): CuerpoNotificacion {
  if (!evento.body) throw errorValidacion('El cuerpo de la solicitud esta vacio');
  try {
    const p: unknown = JSON.parse(evento.body);
    if (typeof p !== 'object' || p === null || Array.isArray(p)) {
      throw errorValidacion('El cuerpo debe ser un objeto JSON');
    }
    return p as CuerpoNotificacion;
  } catch (err) {
    if (err instanceof SyntaxError) throw errorValidacion('El cuerpo no es JSON valido');
    throw err;
  }
}

/**
 * Registra una notificacion y, con ella, la difunde.
 *
 * Cuando el canal es `webhook` se resuelven ademas los endpoints activos de los organismos
 * y se crea una fila por cada uno, todo dentro de una misma transaccion: o se registran
 * todos los destinatarios o no se registra ninguno. Media notificacion enviada seria peor
 * que ninguna, porque nadie sabria quien quedo sin avisar.
 */
async function emitir(evento: EventoApiGateway): Promise<RespuestaHttp> {
  const cuerpo = parsear(evento);
  const errores: string[] = [];

  if (!esUuid(cuerpo.emergencia_id)) errores.push('emergencia_id debe ser un UUID');
  if (typeof cuerpo.asunto !== 'string' || cuerpo.asunto.trim().length === 0 || cuerpo.asunto.length > 200) {
    errores.push('asunto es obligatorio y admite hasta 200 caracteres');
  }
  const canal = (cuerpo.canal ?? 'realtime') as Canal;
  if (!CANALES.includes(canal)) errores.push(`canal debe ser uno de: ${CANALES.join(', ')}`);
  if (errores.length > 0) throw errorValidacion('Payload invalido', errores);

  const emergenciaId = cuerpo.emergencia_id as string;
  const asunto = (cuerpo.asunto as string).trim();
  const detalle = JSON.stringify(cuerpo.cuerpo ?? {});

  const registro = logger.child({ requestId: evento.requestContext?.requestId, canal });

  const creadas = await enTransaccion(async (cliente) => {
    const destinos: string[] = [];

    if (canal === 'webhook') {
      const hooks = await cliente.query<{ url: string }>(
        'select url from notify.webhooks where activo order by organismo',
      );
      if (hooks.rowCount === 0) {
        throw errorValidacion('No hay webhooks activos registrados para notificar');
      }
      destinos.push(...hooks.rows.map((h) => h.url));
    } else {
      destinos.push(
        typeof cuerpo.destinatario === 'string' && cuerpo.destinatario.trim()
          ? cuerpo.destinatario.trim()
          : 'panel-de-comando',
      );
    }

    const filas: { id: string; destinatario: string }[] = [];
    for (const destino of destinos) {
      const r = await cliente.query<{ id: string; destinatario: string }>(
        `insert into notify.notificaciones
           (emergencia_id, destinatario, canal, asunto, cuerpo, estado)
         values ($1, $2, $3, $4, $5::jsonb, 'pendiente')
         returning id, destinatario`,
        [emergenciaId, destino, canal, asunto, detalle],
      );
      if (r.rows[0]) filas.push(r.rows[0]);
    }
    return filas;
  });

  registro.info('Notificaciones registradas y difundidas por Realtime', {
    emergenciaId,
    destinatarios: creadas.length,
  });

  return creado({
    emergencia_id: emergenciaId,
    canal,
    notificaciones: creadas,
    // Aclara al cliente que no hay que hacer polling: la fila ya viaja por Realtime.
    difusion: 'Las filas insertadas se replican por Supabase Realtime a los suscriptores',
  });
}

async function listar(evento: EventoApiGateway): Promise<RespuestaHttp> {
  const emergenciaId = evento.queryStringParameters?.['emergencia_id'];
  if (!esUuid(emergenciaId)) {
    throw errorValidacion('Falta el parametro emergencia_id o no es un UUID');
  }

  const r = await consultar(
    `select id, destinatario, canal, asunto, estado, intentos, creado_en
       from notify.notificaciones
      where emergencia_id = $1
      order by creado_en desc
      limit 100`,
    [emergenciaId],
  );

  return ok({ emergencia_id: emergenciaId, total: r.rowCount, notificaciones: r.rows });
}

async function salud(): Promise<RespuestaHttp> {
  const bd = await verificarSalud();
  // Se usa `responder` en vez de construir el objeto a mano para no saltarse las
  // cabeceras comunes: sin ellas esta respuesta saldria sin CORS.
  return responder(bd.ok ? 200 : 503, {
    servicio: 'notify',
    estado: bd.ok ? 'ok' : 'degradado',
    version: process.env['AWS_LAMBDA_FUNCTION_VERSION'] ?? 'desconocida',
    baseDatos: bd,
  });
}

const enrutar = manejarErrores(async (evento: EventoApiGateway): Promise<RespuestaHttp> => {
  const metodo = evento.httpMethod ?? 'GET';
  const ruta = evento.resource ?? evento.path ?? '/';

  if (ruta.endsWith('/health')) return salud();
  if (metodo === 'POST' && ruta.includes('/notificaciones')) return emitir(evento);
  if (metodo === 'GET' && ruta.includes('/notificaciones')) return listar(evento);

  throw errorValidacion(`Ruta no soportada: ${metodo} ${ruta}`);
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
