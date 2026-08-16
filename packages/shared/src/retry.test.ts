import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { conReintentos, esErrorTransitorio } from './retry.ts';

function conCodigo(code: string): Error & { code: string } {
  return Object.assign(new Error(code), { code });
}

describe('conReintentos', () => {
  test('devuelve el resultado sin reintentar si la operacion funciona', async () => {
    let llamadas = 0;
    const resultado = await conReintentos(async () => {
      llamadas++;
      return 42;
    });

    assert.equal(resultado, 42);
    assert.equal(llamadas, 1);
  });

  test('reintenta hasta lograrlo', async () => {
    let llamadas = 0;
    const resultado = await conReintentos(
      async () => {
        llamadas++;
        if (llamadas < 3) throw new Error('transitorio');
        return 'listo';
      },
      { baseMs: 1 },
    );

    assert.equal(resultado, 'listo');
    assert.equal(llamadas, 3);
  });

  test('agota los intentos y relanza el ultimo error', async () => {
    let llamadas = 0;
    await assert.rejects(
      conReintentos(
        async () => {
          llamadas++;
          throw new Error(`fallo numero ${llamadas}`);
        },
        { intentos: 4, baseMs: 1 },
      ),
      /fallo numero 4/,
    );
    assert.equal(llamadas, 4);
  });

  test('no reintenta cuando el error no es reintentable', async () => {
    let llamadas = 0;
    await assert.rejects(
      conReintentos(
        async () => {
          llamadas++;
          throw conCodigo('23505'); // violacion de unicidad: reintentar no la arregla
        },
        { intentos: 5, baseMs: 1, esReintentable: esErrorTransitorio },
      ),
    );
    assert.equal(llamadas, 1, 'debio rendirse en el primer intento');
  });

  test('la espera crece y nunca supera el techo', async () => {
    const esperas: number[] = [];
    await conReintentos(
      async () => {
        if (esperas.length < 4) throw new Error('sigue fallando');
        return 'ok';
      },
      {
        intentos: 6,
        baseMs: 100,
        maxMs: 250,
        alReintentar: (_intento, esperaMs) => esperas.push(esperaMs),
      },
    ).catch(() => undefined);

    assert.equal(esperas.length, 4);
    // Jitter completo: cada espera cae en [0, min(maxMs, base * 2^(n-1))].
    const techos = [100, 200, 250, 250];
    esperas.forEach((espera, i) => {
      assert.ok(espera >= 0, `espera ${i} negativa`);
      assert.ok(espera <= techos[i]!, `espera ${i} (${espera}) supera el techo ${techos[i]}`);
    });
  });
});

describe('esErrorTransitorio', () => {
  test('reconoce fallos de red', () => {
    for (const code of ['ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND']) {
      assert.equal(esErrorTransitorio(conCodigo(code)), true, code);
    }
  });

  test('reconoce transitorios de Postgres', () => {
    for (const code of ['40001', '40P01', '53300']) {
      assert.equal(esErrorTransitorio(conCodigo(code)), true, code);
    }
  });

  test('descarta errores permanentes y valores sin codigo', () => {
    assert.equal(esErrorTransitorio(conCodigo('23505')), false, 'unicidad');
    assert.equal(esErrorTransitorio(conCodigo('42P01')), false, 'tabla inexistente');
    assert.equal(esErrorTransitorio(new Error('sin codigo')), false);
    assert.equal(esErrorTransitorio(null), false);
    assert.equal(esErrorTransitorio(undefined), false);
  });
});
