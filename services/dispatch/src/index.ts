/**
 * Service 2 — Dispatch & Resource Assignment
 *
 * Dos formas de entrada, una sola logica de negocio:
 *
 *   - Cola SQS: es la via principal. Intake publica cada emergencia aceptada y este
 *     servicio la consume a su ritmo. Patron Queue-Based Load Leveling: el pico de
 *     trafico lo absorbe la cola, no la base de datos ni el algoritmo de asignacion.
 *     Con un limite de 10 ejecuciones concurrentes en la cuenta, esto no es un adorno
 *     academico: es lo unico que evita que una avalancha de reportes tumbe el despacho.
 *
 *   - API Gateway: consultas y cambios de estado que hace un operador desde el panel.
 */

import {
  consultar,
  enTransaccion,
  verificarSalud,
  manejarErrores,
  responder,
  ok,
  errorValidacion,
  noEncontrado,
  esCiudad,
  ESTADOS_DESPACHO,
  CIUDADES,
  logger,
} from '@emergencias/shared';
import type { RespuestaHttp, EstadoDespacho } from '@emergencias/shared';

// ---------------------------------------------------------------------------------------
// Tipos de evento
// ---------------------------------------------------------------------------------------
interface RegistroSqs {
  messageId: string;
  body: string;
}
interface EventoSqs {
  Records: RegistroSqs[];
}
interface EventoApiGateway {
  httpMethod?: string;
  resource?: string;
  path?: string;
  body?: string | null;
  pathParameters?: Record<string, string | undefined> | null;
  queryStringParameters?: Record<string, string | undefined> | null;
  requestContext?: { requestId?: string };
}
type Evento = EventoSqs | EventoApiGateway;

const esEventoSqs = (e: Evento): e is EventoSqs =>
  Array.isArray((e as EventoSqs).Records) && (e as EventoSqs).Records.length > 0;

const esUuid = (v: unknown): v is string =>
  typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

// ---------------------------------------------------------------------------------------
// Asignacion por proximidad
// ---------------------------------------------------------------------------------------
interface MensajeEmergencia {
  emergencia_id?: unknown;
  ciudad?: unknown;
}

/**
 * Asigna la unidad disponible mas cercana a una emergencia.
 *
 * Todo ocurre en una transaccion porque hay una condicion de carrera real: entre elegir la
 * unidad y marcarla como ocupada, otro contenedor podria elegir la misma. El `for update`
 * sobre la fila de la unidad serializa a los competidores.
 *
 * Es idempotente: si la emergencia ya tiene un despacho activo, no crea otro. El indice
 * unico parcial de la tabla lo garantiza aunque dos mensajes lleguen a la vez, que en SQS
 * con entrega "al menos una vez" es cuestion de tiempo, no de mala suerte.
 */
async function asignar(emergenciaId: string): Promise<{ despachoId: string; unidad: string | null; yaExistia: boolean }> {
  return enTransaccion(async (cliente) => {
    const existente = await cliente.query<{ id: string; unidad_id: string | null }>(
      `select id, unidad_id from dispatch.despachos
        where emergencia_id = $1 and estado not in ('atendido', 'cancelado')
        limit 1`,
      [emergenciaId],
    );
    if (existente.rows[0]) {
      return { despachoId: existente.rows[0].id, unidad: existente.rows[0].unidad_id, yaExistia: true };
    }

    // La vista es el Anti-Corruption Layer hacia intake: dispatch no consulta esa tabla
    // directamente en ningun punto del codigo.
    const emergencia = await cliente.query<{ id: string; ciudad: string }>(
      `select id, ciudad::text from dispatch.v_emergencias_pendientes where id = $1`,
      [emergenciaId],
    );
    if (!emergencia.rows[0]) {
      throw noEncontrado('La emergencia (o ya tiene despacho activo)');
    }

    const candidata = await cliente.query<{ unidad_id: string; distancia_m: string }>(
      `select d.unidad_id, d.distancia_m
         from dispatch.v_emergencias_pendientes e
         cross join lateral dispatch.unidad_mas_cercana(e.geom, e.ciudad) d
        where e.id = $1`,
      [emergenciaId],
    );

    const unidadId = candidata.rows[0]?.unidad_id ?? null;
    const distancia = candidata.rows[0]?.distancia_m ?? null;

    if (unidadId) {
      // Bloquea la unidad para que otro contenedor no la asigne a la vez.
      await cliente.query('select 1 from dispatch.unidades where id = $1 for update', [unidadId]);
      await cliente.query('update dispatch.unidades set disponible = false where id = $1', [unidadId]);
    }

    const despacho = await cliente.query<{ id: string }>(
      `insert into dispatch.despachos (emergencia_id, unidad_id, estado, distancia_m, notas)
       values ($1, $2, $3, $4, $5)
       returning id`,
      [
        emergenciaId,
        unidadId,
        unidadId ? 'asignado' : 'pendiente',
        distancia,
        unidadId ? null : 'Sin unidades disponibles en el radio de busqueda',
      ],
    );

    return { despachoId: despacho.rows[0]!.id, unidad: unidadId, yaExistia: false };
  });
}

// ---------------------------------------------------------------------------------------
// Entrada por SQS
// ---------------------------------------------------------------------------------------
/**
 * Procesa el lote informando fallos parciales.
 *
 * Sin `batchItemFailures`, un solo mensaje defectuoso haria que SQS reintregara el lote
 * COMPLETO, reprocesando los que ya salieron bien. Devolviendo solo los ids fallidos,
 * los buenos se confirman y unicamente el problematico vuelve a la cola hasta agotar
 * reintentos y caer en la DLQ.
 */
async function procesarCola(evento: EventoSqs): Promise<{ batchItemFailures: { itemIdentifier: string }[] }> {
  const fallidos: { itemIdentifier: string }[] = [];

  for (const registro of evento.Records) {
    const registroLog = logger.child({ messageId: registro.messageId });
    try {
      const mensaje = JSON.parse(registro.body) as MensajeEmergencia;
      if (!esUuid(mensaje.emergencia_id)) {
        // Un mensaje malformado no se arregla reintentandolo: se descarta con constancia
        // en el log en vez de bloquear la cola hasta agotar reintentos.
        registroLog.error('Mensaje descartado: emergencia_id no es un UUID', undefined, {
          cuerpo: registro.body.slice(0, 200),
        });
        continue;
      }

      const resultado = await asignar(mensaje.emergencia_id);
      registroLog.info(resultado.yaExistia ? 'La emergencia ya tenia despacho' : 'Unidad asignada', {
        emergenciaId: mensaje.emergencia_id,
        despachoId: resultado.despachoId,
        unidadId: resultado.unidad,
      });
    } catch (err) {
      registroLog.error('Fallo al despachar el mensaje', err);
      fallidos.push({ itemIdentifier: registro.messageId });
    }
  }

  return { batchItemFailures: fallidos };
}

// ---------------------------------------------------------------------------------------
// Entrada por API Gateway
// ---------------------------------------------------------------------------------------
async function listarDespachos(evento: EventoApiGateway): Promise<RespuestaHttp> {
  const ciudad = evento.queryStringParameters?.['ciudad'];
  if (ciudad !== undefined && !esCiudad(ciudad)) {
    throw errorValidacion(`ciudad debe ser una de: ${CIUDADES.join(', ')}`);
  }

  // La ciudad vive en el agregado de intake, asi que se filtra a traves de la vista ACL.
  // El tipo de la emergencia se trae por JOIN directo (el rol svc_dispatch tiene SELECT
  // en intake.emergencias a traves de la vista ACL ya definida — Patron: Anti-Corruption Layer).
  const r = await consultar(
    `select d.id, d.emergencia_id, d.estado::text, d.distancia_m, d.creado_en,
            u.codigo as unidad, u.organismo::text,
            e.tipo::text as tipo
       from dispatch.despachos d
       left join dispatch.unidades u on u.id = d.unidad_id
       left join intake.emergencias e on e.id = d.emergencia_id
      where ($1::text is null or u.ciudad::text = $1)
      order by d.creado_en desc
      limit 100`,
    [ciudad ?? null],
  );

  return ok({ ciudad: ciudad ?? 'todas', total: r.rowCount, despachos: r.rows });
}

async function actualizarDespacho(evento: EventoApiGateway): Promise<RespuestaHttp> {
  const id = evento.pathParameters?.['id'];
  if (!esUuid(id)) throw errorValidacion('id debe ser un UUID');
  if (!evento.body) throw errorValidacion('El cuerpo de la solicitud esta vacio');

  let nuevoEstado: unknown;
  let notas: unknown;
  try {
    const cuerpo = JSON.parse(evento.body) as { estado?: unknown; notas?: unknown };
    nuevoEstado = cuerpo.estado;
    notas = cuerpo.notas;
  } catch {
    throw errorValidacion('El cuerpo no es JSON valido');
  }

  if (!ESTADOS_DESPACHO.includes(nuevoEstado as EstadoDespacho)) {
    throw errorValidacion(`estado debe ser uno de: ${ESTADOS_DESPACHO.join(', ')}`);
  }

  const cerrado = nuevoEstado === 'atendido' || nuevoEstado === 'cancelado';

  const actualizado = await enTransaccion(async (cliente) => {
    const r = await cliente.query<{ id: string; unidad_id: string | null; estado: string }>(
      `update dispatch.despachos
          set estado = $2, notas = coalesce($3, notas)
        where id = $1
        returning id, unidad_id, estado::text`,
      [id, nuevoEstado, typeof notas === 'string' ? notas : null],
    );
    const fila = r.rows[0];
    if (!fila) return null;

    // Al cerrar el despacho, la unidad vuelve al pool. Si no se liberara, la flota se
    // agotaria sola tras unas cuantas emergencias atendidas.
    if (cerrado && fila.unidad_id) {
      await cliente.query('update dispatch.unidades set disponible = true where id = $1', [fila.unidad_id]);
    }
    return fila;
  });

  if (!actualizado) throw noEncontrado('El despacho');

  logger.info('Despacho actualizado', {
    despachoId: actualizado.id,
    estado: actualizado.estado,
    unidadLiberada: cerrado && Boolean(actualizado.unidad_id),
  });

  return ok(actualizado);
}

async function salud(): Promise<RespuestaHttp> {
  const bd = await verificarSalud();
  // Se usa `responder` en vez de construir el objeto a mano para no saltarse las
  // cabeceras comunes: sin ellas esta respuesta saldria sin CORS.
  return responder(bd.ok ? 200 : 503, {
    servicio: 'dispatch',
    estado: bd.ok ? 'ok' : 'degradado',
    version: process.env['AWS_LAMBDA_FUNCTION_VERSION'] ?? 'desconocida',
    baseDatos: bd,
  });
}

const enrutarHttp = manejarErrores(async (evento: EventoApiGateway): Promise<RespuestaHttp> => {
  const metodo = evento.httpMethod ?? 'GET';
  const ruta = evento.resource ?? evento.path ?? '/';

  if (ruta.endsWith('/health')) return salud();
  if (metodo === 'PATCH' && ruta.includes('/despachos')) return actualizarDespacho(evento);
  if (metodo === 'GET' && ruta.includes('/despachos')) return listarDespachos(evento);

  throw errorValidacion(`Ruta no soportada: ${metodo} ${ruta}`);
});

// Ver services/intake/src/index.ts para la explicacion completa de este mecanismo.
declare const __CAOS__: boolean;
const fallaAdrede = __CAOS__;

export const handler = async (evento: Evento): Promise<unknown> => {
  if (fallaAdrede) {
    logger.error('Fallo sintetico inyectado (prueba de rollback del canary)');
    throw new Error('Fallo sintetico inyectado para validar el rollback automatico');
  }
  return esEventoSqs(evento) ? procesarCola(evento) : enrutarHttp(evento);
};
