/**
 * Vocabulario del dominio, compartido por los cuatro microservicios.
 *
 * La rúbrica exige cobertura completa de 4 tipos de solicitud × 4 ciudades. Fijarlos aquí
 * como constantes tipadas hace que el compilador detecte cualquier `switch` incompleto,
 * en vez de descubrirlo en la demo.
 */

/** Los cuatro nodos afectados por el sismo. */
export const CIUDADES = ['choco', 'pereira', 'cali', 'manizales'] as const;
export type Ciudad = (typeof CIUDADES)[number];

/** Los cuatro tipos de solicitud del enunciado, en orden de prioridad. */
export const TIPOS_SOLICITUD = ['usar_medica', 'albergue', 'suministros', 'danos'] as const;
export type TipoSolicitud = (typeof TIPOS_SOLICITUD)[number];

/** Niveles de triage. P1 es la máxima urgencia. */
export const PRIORIDADES = ['P1', 'P2', 'P3', 'P4'] as const;
export type Prioridad = (typeof PRIORIDADES)[number];

/** Organismos de socorro que operan en la respuesta. */
export const ORGANISMOS = ['cruz_roja', 'bomberos', 'defensa_civil', 'ungrd'] as const;
export type Organismo = (typeof ORGANISMOS)[number];

export const ESTADOS_DESPACHO = ['pendiente', 'asignado', 'en_ruta', 'atendido', 'cancelado'] as const;
export type EstadoDespacho = (typeof ESTADOS_DESPACHO)[number];

/** Prioridad base por tipo, antes de aplicar los escaladores de triage. */
export const PRIORIDAD_BASE: Readonly<Record<TipoSolicitud, Prioridad>> = {
  usar_medica: 'P1',
  albergue: 'P2',
  suministros: 'P3',
  danos: 'P4',
};

/**
 * Centros aproximados de cada nodo, en [longitud, latitud].
 * Se usan para sembrar datos de prueba y para encuadrar el mapa del panel de comando.
 */
export const CENTROS: Readonly<Record<Ciudad, readonly [number, number]>> = {
  choco: [-76.6612, 5.6947], // Quibdó
  pereira: [-75.6906, 4.8133],
  cali: [-76.5225, 3.4516],
  manizales: [-75.5138, 5.0703],
};

export function esCiudad(valor: unknown): valor is Ciudad {
  return typeof valor === 'string' && (CIUDADES as readonly string[]).includes(valor);
}

export function esTipoSolicitud(valor: unknown): valor is TipoSolicitud {
  return typeof valor === 'string' && (TIPOS_SOLICITUD as readonly string[]).includes(valor);
}

/** Coordenada geográfica validada. */
export interface Coordenadas {
  lon: number;
  lat: number;
}

export function esCoordenadaValida(c: unknown): c is Coordenadas {
  if (typeof c !== 'object' || c === null) return false;
  const { lon, lat } = c as Partial<Coordenadas>;
  return (
    typeof lon === 'number' &&
    typeof lat === 'number' &&
    Number.isFinite(lon) &&
    Number.isFinite(lat) &&
    lon >= -180 &&
    lon <= 180 &&
    lat >= -90 &&
    lat <= 90
  );
}
