/**
 * Ayudas para respuestas de API Gateway (proxy integration) y manejo uniforme de errores.
 *
 * El CORS restrictivo se configura en el API Gateway, no aquí. Estas cabeceras son las que
 * el gateway no puede poner por sí solo en respuestas de integración proxy.
 */

import { logger } from './logger.ts';

export interface RespuestaHttp {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

/**
 * Origen autorizado por CORS. Lo inyecta el template de cada servicio; debe coincidir con
 * el del API Gateway. No es un secreto: es el dominio público del frontend.
 */
const ORIGEN = process.env['ORIGEN_PERMITIDO'];

const CABECERAS_BASE: Record<string, string> = {
  'Content-Type': 'application/json; charset=utf-8',
  // Un cliente que reintenta con la misma Idempotency-Key no debe recibir una respuesta cacheada.
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',

  // CORS en TODAS las respuestas, no solo en el preflight.
  //
  // Con integración AWS_PROXY, API Gateway no añade cabeceras CORS a la respuesta real: la
  // propiedad `Cors` de SAM únicamente genera el método OPTIONS simulado. El resultado es
  // engañoso — el preflight responde 200 con las cabeceras correctas y el GET siguiente
  // llega sin ellas, así que el navegador lo bloquea y el frontend solo ve un
  // "Failed to fetch" sin más pistas. La cabecera tiene que ponerla la propia función.
  ...(ORIGEN ? { 'Access-Control-Allow-Origin': ORIGEN, Vary: 'Origin' } : {}),
};

export function responder(
  statusCode: number,
  cuerpo: unknown,
  cabeceras: Record<string, string> = {},
): RespuestaHttp {
  return {
    statusCode,
    headers: { ...CABECERAS_BASE, ...cabeceras },
    body: JSON.stringify(cuerpo),
  };
}

export const ok = (cuerpo: unknown, cabeceras?: Record<string, string>): RespuestaHttp =>
  responder(200, cuerpo, cabeceras);

export const creado = (cuerpo: unknown, cabeceras?: Record<string, string>): RespuestaHttp =>
  responder(201, cuerpo, cabeceras);

/**
 * Error de negocio con código HTTP asociado. Lo que no sea esto se trata como 500.
 *
 * Los campos se declaran y asignan a mano en lugar de usar parameter properties: estas
 * últimas no son sintaxis borrable y romperían `node --test --experimental-strip-types`.
 */
export class ErrorHttp extends Error {
  readonly statusCode: number;
  readonly codigo: string;
  readonly detalles?: unknown;

  constructor(statusCode: number, codigo: string, mensaje: string, detalles?: unknown) {
    super(mensaje);
    this.name = 'ErrorHttp';
    this.statusCode = statusCode;
    this.codigo = codigo;
    this.detalles = detalles;
  }
}

export const errorValidacion = (mensaje: string, detalles?: unknown): ErrorHttp =>
  new ErrorHttp(400, 'VALIDACION', mensaje, detalles);

export const noEncontrado = (recurso: string): ErrorHttp =>
  new ErrorHttp(404, 'NO_ENCONTRADO', `${recurso} no existe`);

export const conflicto = (mensaje: string): ErrorHttp =>
  new ErrorHttp(409, 'CONFLICTO', mensaje);

/**
 * Envuelve un handler para que ningún error se escape sin formato.
 *
 * Consecuencia para el canary, que hay que tener presente: como aquí **no se relanza nada**,
 * la métrica `AWS/Lambda Errors` se queda en cero incluso ante un fallo interno. Quien detecta
 * ese fallo es la alarma sobre `AWS/ApiGateway 5XXError`, porque sí devolvemos un 500.
 * Por eso el `DeploymentPreference` de cada servicio incluye las dos alarmas y no solo la de
 * Lambda: si se quitara la de API Gateway, un servicio roto pasaría el despliegue sin rollback.
 */
export function manejarErrores<E>(
  handler: (evento: E) => Promise<RespuestaHttp>,
): (evento: E) => Promise<RespuestaHttp> {
  return async (evento: E): Promise<RespuestaHttp> => {
    try {
      return await handler(evento);
    } catch (err) {
      if (err instanceof ErrorHttp) {
        logger.warn('Solicitud rechazada', {
          statusCode: err.statusCode,
          codigo: err.codigo,
          mensaje: err.message,
        });
        return responder(err.statusCode, {
          error: err.codigo,
          mensaje: err.message,
          detalles: err.detalles,
        });
      }

      logger.error('Fallo no controlado', err);
      return responder(500, {
        error: 'ERROR_INTERNO',
        mensaje: 'Ocurrió un error procesando la solicitud',
      });
    }
  };
}
