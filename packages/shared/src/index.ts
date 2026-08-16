/** Punto de entrada del paquete compartido. Reexporta lo que consumen los microservicios. */

export { crearLogger, logger } from './logger.ts';
export type { Logger, LogContext, LogLevel } from './logger.ts';

export { conReintentos, esErrorTransitorio } from './retry.ts';
export type { OpcionesRetry } from './retry.ts';

export { CircuitBreaker, CircuitoAbiertoError } from './circuit-breaker.ts';
export type { EstadoBreaker, OpcionesBreaker } from './circuit-breaker.ts';

export { obtenerConfig, _reiniciarConfig } from './config.ts';
export type { Config } from './config.ts';

export { consultar, enTransaccion, verificarSalud } from './db.ts';
export type { OpcionesQuery } from './db.ts';

export {
  responder,
  ok,
  creado,
  ErrorHttp,
  errorValidacion,
  noEncontrado,
  conflicto,
  manejarErrores,
} from './http.ts';
export type { RespuestaHttp } from './http.ts';

export {
  CIUDADES,
  TIPOS_SOLICITUD,
  PRIORIDADES,
  ORGANISMOS,
  ESTADOS_DESPACHO,
  PRIORIDAD_BASE,
  CENTROS,
  esCiudad,
  esTipoSolicitud,
  esCoordenadaValida,
} from './dominio.ts';
export type {
  Ciudad,
  TipoSolicitud,
  Prioridad,
  Organismo,
  EstadoDespacho,
  Coordenadas,
} from './dominio.ts';
