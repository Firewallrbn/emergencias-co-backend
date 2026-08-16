/**
 * Patrón: Retry con backoff exponencial y jitter completo.
 *
 * El jitter no es un adorno. Sin él, N Lambdas que fallan a la vez reintentan a la vez
 * y vuelven a tumbar la dependencia — exactamente el "pico masivo de tráfico concurrente"
 * que describe el enunciado. Con jitter completo el reintento cae en un punto uniforme
 * dentro de la ventana, dispersando la carga.
 *
 * Referencia del algoritmo: "Exponential Backoff and Jitter", AWS Architecture Blog.
 */

export interface OpcionesRetry {
  /** Número máximo de intentos, incluido el primero. */
  intentos?: number;
  /** Retardo base en milisegundos. */
  baseMs?: number;
  /** Techo del retardo, para que el backoff no se dispare. */
  maxMs?: number;
  /** Decide si vale la pena reintentar. Por defecto reintenta cualquier error. */
  esReintentable?: (err: unknown) => boolean;
  /** Se invoca antes de cada espera. Útil para loguear. */
  alReintentar?: (intento: number, esperaMs: number, err: unknown) => void;
}

const dormir = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export async function conReintentos<T>(
  operacion: () => Promise<T>,
  opciones: OpcionesRetry = {},
): Promise<T> {
  const {
    intentos = 3,
    baseMs = 100,
    maxMs = 2000,
    esReintentable = () => true,
    alReintentar,
  } = opciones;

  let ultimoError: unknown;

  for (let intento = 1; intento <= intentos; intento++) {
    try {
      return await operacion();
    } catch (err) {
      ultimoError = err;

      const quedanIntentos = intento < intentos;
      if (!quedanIntentos || !esReintentable(err)) break;

      // Jitter completo: espera uniforme en [0, min(maxMs, base * 2^(intento-1))].
      const techo = Math.min(maxMs, baseMs * 2 ** (intento - 1));
      const esperaMs = Math.random() * techo;

      alReintentar?.(intento, esperaMs, err);
      await dormir(esperaMs);
    }
  }

  throw ultimoError;
}

/**
 * Errores que sí conviene reintentar: fallos de red y transitorios de Postgres.
 * Un 400 o una violación de unicidad no se arreglan reintentando.
 */
export function esErrorTransitorio(err: unknown): boolean {
  const codigo = (err as { code?: string } | null)?.code;
  if (!codigo) return false;

  const redCaida = ['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'EPIPE', 'ENOTFOUND', 'EAI_AGAIN'];
  // 40001 serialization_failure, 40P01 deadlock_detected, 53300 too_many_connections,
  // 57P03 cannot_connect_now, 08006 connection_failure
  const postgresTransitorio = ['40001', '40P01', '53300', '57P03', '08006', '08000'];

  return redCaida.includes(codigo) || postgresTransitorio.includes(codigo);
}
