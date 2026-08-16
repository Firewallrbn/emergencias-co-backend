-- Seed — Emergencias de demostración
--
-- Cobertura obligatoria de la rúbrica: los 4 tipos de solicitud × las 4 ciudades = 16 casos.
-- Se añade además un racimo de reportes P1 en Cali para que ST_ClusterDBSCAN detecte un
-- punto caliente real en la demo (con reportes dispersos no habría nada que agrupar).
--
-- Idempotente por `idempotency_key`, que es justamente el mecanismo que el servicio usa
-- en producción para descartar duplicados.

insert into intake.emergencias
  (idempotency_key, tipo, ciudad, prioridad, triage_score, geom, descripcion, datos)
values
  -- ---------- Chocó ----------
  ('seed-cho-usar',  'usar_medica', 'choco', 'P1', 95,
   extensions.st_point(-76.6600, 5.6955)::extensions.geography,
   'Vivienda de dos pisos colapsada, se escuchan voces bajo los escombros',
   '{"personas_atrapadas": 3, "heridos": 2, "riesgo_inminente": ["fuga_gas"]}'),
  ('seed-cho-alb',   'albergue', 'choco', 'P2', 60,
   extensions.st_point(-76.6650, 5.6910)::extensions.geography,
   'Familias sin techo tras el sismo, requieren refugio inmediato',
   '{"adultos": 12, "ninos": 7, "tercera_edad": 3, "accesibilidad": true}'),
  ('seed-cho-sum',   'suministros', 'choco', 'P3', 40,
   extensions.st_point(-76.6560, 5.6890)::extensions.geography,
   'Comunidad aislada sin agua potable desde hace 48 horas',
   '{"categoria": "agua_potable", "personas": 80}'),
  ('seed-cho-dan',   'danos', 'choco', 'P4', 25,
   extensions.st_point(-76.6580, 5.6980)::extensions.geography,
   'Agrietamiento visible en puente peatonal sobre via principal',
   '{"tipo_edificacion": "infraestructura", "agrietamiento": "severo", "riesgo_via": true}'),

  -- ---------- Pereira ----------
  ('seed-per-usar',  'usar_medica', 'pereira', 'P1', 90,
   extensions.st_point(-75.6890, 4.8145)::extensions.geography,
   'Persona atrapada en ascensor de edificio con estructura comprometida',
   '{"personas_atrapadas": 1, "heridos": 0, "riesgo_inminente": ["colapso"]}'),
  ('seed-per-alb',   'albergue', 'pereira', 'P2', 55,
   extensions.st_point(-75.6940, 4.8100)::extensions.geography,
   'Conjunto residencial evacuado, vivienda declarada no habitable',
   '{"adultos": 30, "ninos": 14, "tercera_edad": 8, "accesibilidad": true}'),
  ('seed-per-sum',   'suministros', 'pereira', 'P3', 38,
   extensions.st_point(-75.6870, 4.8080)::extensions.geography,
   'Albergue temporal requiere raciones de campana y medicamentos cronicos',
   '{"categoria": "medicamentos_cronicos", "personas": 45}'),
  ('seed-per-dan',   'danos', 'pereira', 'P4', 20,
   extensions.st_point(-75.6920, 4.8170)::extensions.geography,
   'Asentamiento diferencial en edificacion de tres pisos',
   '{"tipo_edificacion": "residencial", "agrietamiento": "moderado", "riesgo_via": false}'),

  -- ---------- Cali: racimo P1 para que DBSCAN encuentre un punto caliente ----------
  ('seed-cal-usar-1', 'usar_medica', 'cali', 'P1', 98,
   extensions.st_point(-76.5230, 3.4520)::extensions.geography,
   'Colapso parcial de edificio de apartamentos, multiples atrapados',
   '{"personas_atrapadas": 8, "heridos": 5, "riesgo_inminente": ["fuego", "fuga_gas"]}'),
  ('seed-cal-usar-2', 'usar_medica', 'cali', 'P1', 92,
   extensions.st_point(-76.5238, 3.4527)::extensions.geography,
   'Vivienda contigua afectada, se reporta persona inconsciente',
   '{"personas_atrapadas": 1, "heridos": 1, "riesgo_inminente": ["colapso"]}'),
  ('seed-cal-usar-3', 'usar_medica', 'cali', 'P1', 88,
   extensions.st_point(-76.5222, 3.4531)::extensions.geography,
   'Local comercial derrumbado sobre anden, posibles atrapados',
   '{"personas_atrapadas": 2, "heridos": 3, "riesgo_inminente": ["colapso"]}'),
  ('seed-cal-usar-4', 'usar_medica', 'cali', 'P1', 85,
   extensions.st_point(-76.5244, 3.4514)::extensions.geography,
   'Muro perimetral caido sobre vehiculo con ocupantes',
   '{"personas_atrapadas": 2, "heridos": 2, "riesgo_inminente": []}'),
  ('seed-cal-alb',   'albergue', 'cali', 'P2', 62,
   extensions.st_point(-76.5300, 3.4450)::extensions.geography,
   'Barrio evacuado preventivamente, se requiere albergue para damnificados',
   '{"adultos": 65, "ninos": 40, "tercera_edad": 15, "accesibilidad": true}'),
  ('seed-cal-sum',   'suministros', 'cali', 'P3', 42,
   extensions.st_point(-76.5150, 3.4570)::extensions.geography,
   'Punto de atencion sin kits de primeros auxilios',
   '{"categoria": "kits_primeros_auxilios", "personas": 120}'),
  ('seed-cal-dan',   'danos', 'cali', 'P4', 22,
   extensions.st_point(-76.5190, 3.4480)::extensions.geography,
   'Fisuras en columnas de parqueadero subterraneo',
   '{"tipo_edificacion": "comercial", "agrietamiento": "leve", "riesgo_via": false}'),

  -- ---------- Manizales ----------
  ('seed-man-usar',  'usar_medica', 'manizales', 'P1', 93,
   extensions.st_point(-75.5130, 5.0710)::extensions.geography,
   'Deslizamiento sepulto vivienda en ladera, familia atrapada',
   '{"personas_atrapadas": 4, "heridos": 2, "riesgo_inminente": ["deslizamiento"]}'),
  ('seed-man-alb',   'albergue', 'manizales', 'P2', 58,
   extensions.st_point(-75.5170, 5.0670)::extensions.geography,
   'Viviendas en zona de ladera evacuadas por riesgo de nuevo deslizamiento',
   '{"adultos": 22, "ninos": 11, "tercera_edad": 6, "accesibilidad": false}'),
  ('seed-man-sum',   'suministros', 'manizales', 'P3', 36,
   extensions.st_point(-75.5090, 5.0650)::extensions.geography,
   'Se agotaron las raciones de campana en el punto de acopio',
   '{"categoria": "raciones_campana", "personas": 95}'),
  ('seed-man-dan',   'danos', 'manizales', 'P4', 28,
   extensions.st_point(-75.5150, 5.0740)::extensions.geography,
   'Muro de contencion con desplazamiento visible sobre via de acceso',
   '{"tipo_edificacion": "infraestructura", "agrietamiento": "severo", "riesgo_via": true}')
on conflict (idempotency_key) do nothing;

-- Verificación de cobertura: debe devolver 16 combinaciones distintas de tipo x ciudad.
do $$
declare
  combinaciones integer;
begin
  select count(distinct (tipo, ciudad)) into combinaciones from intake.emergencias;
  if combinaciones < 16 then
    raise exception
      'Cobertura incompleta: % de 16 combinaciones tipo x ciudad. La rubrica exige las 16.',
      combinaciones;
  end if;
  raise notice 'Cobertura verificada: % combinaciones tipo x ciudad.', combinaciones;
end
$$;
