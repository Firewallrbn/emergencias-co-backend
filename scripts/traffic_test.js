#!/usr/bin/env node
/**
 * Generador de trafico para observar el despliegue Canary.
 *
 * Adaptado del script que ya se uso en un experimento previo de canary, donde el reparto
 * se medía contando la cabecera `x-handled-by`. Aqui la senal es mejor: el endpoint de
 * salud devuelve la VERSION de Lambda que atendio cada peticion, asi que el reparto entre
 * la version estable y la version en pruebas se ve directamente, sin instrumentar nada.
 *
 * Durante un Canary10Percent5Minutes deberia observarse ~90/10 mientras dura la ventana,
 * y volver al 100 % de la version anterior si una alarma dispara el rollback.
 *
 * Uso:
 *   node scripts/traffic_test.js                       # 60 peticiones, 1 por segundo
 *   node scripts/traffic_test.js --n 200 --intervalo 250
 *   node scripts/traffic_test.js --duracion 300        # insistir 5 minutos
 *
 * Ojo con la concurrencia: esta cuenta de AWS tiene un limite de 10 ejecuciones
 * simultaneas, asi que el script va secuencial a proposito. Lanzar rafagas paralelas
 * produciria 429 y throttling que enturbiarian la lectura del reparto.
 */

const BASE = process.env.API_BASE
  ?? 'https://rdrlxnfz59.execute-api.us-east-2.amazonaws.com/prod';

function argumento(nombre, porDefecto) {
  const i = process.argv.indexOf(`--${nombre}`);
  return i !== -1 && process.argv[i + 1] !== undefined ? Number(process.argv[i + 1]) : porDefecto;
}

const intervaloMs = argumento('intervalo', 1000);
const duracionS = argumento('duracion', 0);
const total = duracionS > 0 ? Math.ceil((duracionS * 1000) / intervaloMs) : argumento('n', 60);

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

const porVersion = new Map();
const porEstado = new Map();
const latencias = [];
let errores = 0;

const contar = (mapa, clave) => mapa.set(clave, (mapa.get(clave) ?? 0) + 1);

function barra(n, maximo, ancho = 28) {
  const llenas = maximo > 0 ? Math.round((n / maximo) * ancho) : 0;
  return '#'.repeat(llenas).padEnd(ancho, '.');
}

async function principal() {
  console.log(`Objetivo   : ${BASE}/v1/health`);
  console.log(`Peticiones : ${total} cada ${intervaloMs} ms\n`);

  const inicio = Date.now();

  for (let i = 1; i <= total; i++) {
    const t0 = Date.now();
    let estado = 0;
    let version = 'sin-respuesta';

    try {
      const respuesta = await fetch(`${BASE}/v1/health`, {
        headers: { 'Cache-Control': 'no-cache' },
      });
      estado = respuesta.status;

      // Un 5xx no trae cuerpo util: es justo la senal que buscamos.
      if (respuesta.ok) {
        const cuerpo = await respuesta.json();
        version = `v${cuerpo.version ?? '?'}`;
      } else {
        version = `ERROR ${estado}`;
        errores++;
      }
    } catch (err) {
      version = 'excepcion';
      errores++;
    }

    latencias.push(Date.now() - t0);
    contar(porVersion, version);
    contar(porEstado, estado);

    // Una linea por peticion seria ilegible en 200 iteraciones.
    if (i % 10 === 0 || i === total) {
      const reparto = [...porVersion.entries()]
        .sort((a, b) => b[1] - a[1])
        .map(([v, n]) => `${v}:${n}`)
        .join('  ');
      process.stdout.write(`  ${String(i).padStart(4)}/${total}   ${reparto}\n`);
    }

    if (i < total) await dormir(intervaloMs);
  }

  const segundos = ((Date.now() - inicio) / 1000).toFixed(1);
  latencias.sort((a, b) => a - b);
  const p = (q) => latencias[Math.min(latencias.length - 1, Math.floor(latencias.length * q))];

  console.log(`\n=== Reparto de trafico (${segundos} s) ===`);
  const maximo = Math.max(...porVersion.values());
  for (const [version, n] of [...porVersion.entries()].sort((a, b) => b[1] - a[1])) {
    const pct = ((n / total) * 100).toFixed(1).padStart(5);
    console.log(`  ${version.padEnd(14)} ${barra(n, maximo)} ${String(n).padStart(4)}  ${pct}%`);
  }

  console.log('\n=== Codigos de estado ===');
  for (const [estado, n] of [...porEstado.entries()].sort()) {
    console.log(`  ${estado}: ${n}`);
  }

  console.log('\n=== Latencia ===');
  console.log(`  p50 ${p(0.5)} ms   p95 ${p(0.95)} ms   max ${latencias.at(-1)} ms`);
  console.log(`\n  Errores: ${errores} de ${total} (${((errores / total) * 100).toFixed(1)} %)`);

  // Codigo de salida distinto de cero si hubo errores: util en CI.
  process.exitCode = errores > 0 ? 1 : 0;
}

principal().catch((err) => {
  console.error('El generador de trafico fallo:', err);
  process.exit(2);
});
