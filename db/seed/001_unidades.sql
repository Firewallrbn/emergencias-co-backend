-- Seed — Unidades de respuesta
--
-- Los cuatro organismos del enunciado (Cruz Roja, Bomberos, Defensa Civil, UNGRD)
-- presentes en las cuatro ciudades. Idempotente: `codigo` es único y se ignoran los
-- duplicados, así que se puede volver a ejecutar sin duplicar cuadrillas.

insert into dispatch.unidades (codigo, organismo, ciudad, geom, disponible, capacidad)
values
  -- Chocó (Quibdó)
  ('CHO-CR-01', 'cruz_roja',     'choco',     extensions.st_point(-76.6590, 5.6960)::extensions.geography, true, 4),
  ('CHO-BO-01', 'bomberos',      'choco',     extensions.st_point(-76.6640, 5.6920)::extensions.geography, true, 6),
  ('CHO-DC-01', 'defensa_civil', 'choco',     extensions.st_point(-76.6570, 5.6900)::extensions.geography, true, 3),
  ('CHO-UN-01', 'ungrd',         'choco',     extensions.st_point(-76.6612, 5.6947)::extensions.geography, true, 8),

  -- Pereira
  ('PER-CR-01', 'cruz_roja',     'pereira',   extensions.st_point(-75.6880, 4.8150)::extensions.geography, true, 4),
  ('PER-BO-01', 'bomberos',      'pereira',   extensions.st_point(-75.6930, 4.8110)::extensions.geography, true, 6),
  ('PER-DC-01', 'defensa_civil', 'pereira',   extensions.st_point(-75.6860, 4.8090)::extensions.geography, true, 3),
  ('PER-UN-01', 'ungrd',         'pereira',   extensions.st_point(-75.6906, 4.8133)::extensions.geography, true, 8),

  -- Cali
  ('CAL-CR-01', 'cruz_roja',     'cali',      extensions.st_point(-76.5200, 3.4530)::extensions.geography, true, 5),
  ('CAL-CR-02', 'cruz_roja',     'cali',      extensions.st_point(-76.5310, 3.4460)::extensions.geography, true, 5),
  ('CAL-BO-01', 'bomberos',      'cali',      extensions.st_point(-76.5250, 3.4490)::extensions.geography, true, 7),
  ('CAL-DC-01', 'defensa_civil', 'cali',      extensions.st_point(-76.5180, 3.4550)::extensions.geography, true, 3),
  ('CAL-UN-01', 'ungrd',         'cali',      extensions.st_point(-76.5225, 3.4516)::extensions.geography, true, 10),

  -- Manizales
  ('MAN-CR-01', 'cruz_roja',     'manizales', extensions.st_point(-75.5120, 5.0720)::extensions.geography, true, 4),
  ('MAN-BO-01', 'bomberos',      'manizales', extensions.st_point(-75.5160, 5.0680)::extensions.geography, true, 6),
  ('MAN-DC-01', 'defensa_civil', 'manizales', extensions.st_point(-75.5100, 5.0660)::extensions.geography, true, 3),
  ('MAN-UN-01', 'ungrd',         'manizales', extensions.st_point(-75.5138, 5.0703)::extensions.geography, true, 8)
on conflict (codigo) do nothing;
