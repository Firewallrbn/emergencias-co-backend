import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { calcularTriaje } from './triaje.ts';
import { TIPOS_SOLICITUD, PRIORIDAD_BASE } from '@emergencias/shared';

describe('calcularTriaje — determinismo', () => {
  test('el mismo payload produce siempre el mismo resultado', () => {
    const datos = { personas_atrapadas: 3, heridos: 2, riesgo_inminente: ['fuga_gas'] };

    const primera = calcularTriaje('usar_medica', datos);
    for (let i = 0; i < 50; i++) {
      const otra = calcularTriaje('usar_medica', datos);
      assert.equal(otra.puntaje, primera.puntaje);
      assert.equal(otra.prioridad, primera.prioridad);
    }
  });

  test('no depende del orden en que se pasen los campos', () => {
    const a = calcularTriaje('albergue', { adultos: 30, ninos: 14, tercera_edad: 8 });
    const b = calcularTriaje('albergue', { tercera_edad: 8, adultos: 30, ninos: 14 });
    assert.deepEqual(a, b);
  });
});

describe('calcularTriaje — cobertura del dominio', () => {
  test('los 4 tipos devuelven una prioridad valida sin datos', () => {
    for (const tipo of TIPOS_SOLICITUD) {
      const r = calcularTriaje(tipo);
      assert.ok(['P1', 'P2', 'P3', 'P4'].includes(r.prioridad), `${tipo} -> ${r.prioridad}`);
      assert.ok(r.puntaje >= 0 && r.puntaje <= 100, `${tipo} puntaje fuera de rango`);
    }
  });

  test('nunca queda por debajo de la prioridad base de su tipo', () => {
    // Un reporte de rescate urbano sin ningun dato adicional sigue siendo P1:
    // la falta de informacion en una emergencia no es evidencia de que sea leve.
    for (const tipo of TIPOS_SOLICITUD) {
      const r = calcularTriaje(tipo, {});
      const base = PRIORIDAD_BASE[tipo];
      assert.ok(
        r.prioridad <= base,
        `${tipo}: ${r.prioridad} es menos urgente que la base ${base}`,
      );
    }
  });
});

describe('calcularTriaje — escalado por gravedad', () => {
  test('mas personas atrapadas nunca baja el puntaje', () => {
    let anterior = -1;
    for (const n of [0, 1, 2, 5, 8, 20]) {
      const r = calcularTriaje('usar_medica', { personas_atrapadas: n });
      assert.ok(r.puntaje >= anterior, `con ${n} atrapadas bajo el puntaje`);
      anterior = r.puntaje;
    }
  });

  test('el riesgo inminente critico pesa mas que uno pasivo', () => {
    const conFuego = calcularTriaje('usar_medica', { riesgo_inminente: ['fuego'] });
    const conColapso = calcularTriaje('usar_medica', { riesgo_inminente: ['colapso'] });
    assert.ok(conFuego.puntaje > conColapso.puntaje);
  });

  test('un dano estructural severo sobre una via escala por encima de P4', () => {
    // Una via bloqueada impide llegar a las demas emergencias: no es solo un dano local.
    const leve = calcularTriaje('danos', { agrietamiento: 'leve' });
    const grave = calcularTriaje('danos', { agrietamiento: 'severo', riesgo_via: true });
    assert.equal(leve.prioridad, 'P4');
    assert.ok(grave.puntaje > leve.puntaje);
  });

  test('los afectados escalan de forma logaritmica, no lineal', () => {
    const pocos = calcularTriaje('suministros', { personas: 10 });
    const muchos = calcularTriaje('suministros', { personas: 100 });
    const muchisimos = calcularTriaje('suministros', { personas: 1000 });

    const salto1 = muchos.puntaje - pocos.puntaje;
    const salto2 = muchisimos.puntaje - muchos.puntaje;
    assert.ok(salto1 > 0, 'de 10 a 100 debe subir');
    assert.ok(salto2 <= salto1, 'de 100 a 1000 no debe subir mas que de 10 a 100');
  });
});

describe('calcularTriaje — robustez ante datos sucios', () => {
  test('acota valores negativos y absurdos sin reventar', () => {
    const r = calcularTriaje('usar_medica', {
      personas_atrapadas: -5,
      heridos: 999999,
      personas: -1,
    });
    assert.ok(r.puntaje >= 0 && r.puntaje <= 100);
    assert.equal(r.prioridad, 'P1');
  });

  test('trunca decimales en lugar de propagarlos al puntaje', () => {
    const entero = calcularTriaje('usar_medica', { personas_atrapadas: 3 });
    const decimal = calcularTriaje('usar_medica', { personas_atrapadas: 3.7 });
    assert.equal(decimal.puntaje, entero.puntaje);
    assert.ok(Number.isInteger(decimal.puntaje));
  });

  test('el puntaje nunca supera 100 por acumulacion de factores', () => {
    const r = calcularTriaje('usar_medica', {
      personas_atrapadas: 50,
      heridos: 50,
      riesgo_inminente: ['fuego', 'fuga_gas', 'colapso', 'deslizamiento'],
      ninos: 100,
      tercera_edad: 100,
      adultos: 10000,
      agrietamiento: 'severo',
      riesgo_via: true,
    });
    assert.equal(r.puntaje, 100);
    assert.equal(r.prioridad, 'P1');
  });

  test('explica siempre como llego al puntaje', () => {
    const r = calcularTriaje('usar_medica', { personas_atrapadas: 3 });
    assert.ok(r.factores.length >= 2);
    assert.ok(r.factores.some((f) => f.includes('atrapadas')));
  });
});
