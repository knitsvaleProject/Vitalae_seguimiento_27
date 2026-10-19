-- =====================================================================
-- VITALÆ · Seguimiento longitudinal MEV + Medicina Cannábica
-- Esquema de base de datos para Supabase (PostgreSQL)
-- ---------------------------------------------------------------------
-- Versión 1.0 · Octubre 2026 · Dra. Valeria Alarcón / Ismael Vásquez
--
-- CÓMO USAR
--   1. Crear el proyecto en Supabase.
--   2. Abrir SQL Editor → New query → pegar este archivo completo → Run.
--   3. Luego correr supabase-seed-pacientes.sql para cargar pacientes.
--
-- PRINCIPIOS DE DISEÑO
--   · Datos de salud identificables protegidos con Row Level Security (RLS):
--     solo personal clínico autenticado y en la lista `staff_autorizado`
--     puede leer o escribir.
--   · Trazabilidad: tabla `auditoria` + columnas creado_en/actualizado_en.
--   · Nada se borra en duro donde importa (recetas, controles, huella):
--     se versiona o se marca estado, conservando el historial clínico.
--   · Los puntajes del sistema son INDICADORES INTERNOS DE SEGUIMIENTO,
--     no instrumentos validados (se calculan en la app, no se persisten
--     como diagnóstico).
-- =====================================================================

-- Extensiones -------------------------------------------------------------
create extension if not exists "pgcrypto";      -- gen_random_uuid()

-- =====================================================================
-- 0. TIPOS ENUMERADOS
-- =====================================================================
do $$ begin
  create type tipo_consulta_enum as enum
    ('medicina_cannabica','medicina_estilo_vida','medicina_integrativa','mixta');
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_paciente_enum as enum ('activo','alta','inasistente','derivado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type pilar_enum as enum
    ('alimentacion','actividad','sueno','estres','social',
     'sustancias','sexual','laboral','espiritual');
exception when duplicate_object then null; end $$;

do $$ begin
  create type nivel_riesgo_enum as enum ('bajo','medio','alto','no_evaluado');
exception when duplicate_object then null; end $$;

do $$ begin
  -- Modelo transteórico (Prochaska y DiClemente)
  create type etapa_cambio_enum as enum
    ('precontemplacion','contemplacion','preparacion','accion','mantenimiento','recaida','no_evaluado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_antecedente_enum as enum
    ('morbido','quirurgico','familiar','farmacologico','habito','alergia','otro');
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_medicamento_enum as enum
    ('activo','desprescripcion','titulacion_baja','suspendido','sos');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_formulacion_enum as enum
    ('sumidades_floridas','solucion_vaporizacion','aceite_oral','trociscos','capsulas','topico','otro');
exception when duplicate_object then null; end $$;

do $$ begin
  create type via_admin_enum as enum
    ('vaporizacion_no_pirolitica','vaporizacion_inhalada','oral','sublingual','topica','otra');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_control_enum as enum ('ingreso','control','seguimiento');
exception when duplicate_object then null; end $$;

do $$ begin
  create type canal_enum as enum ('virtual','presencial','whatsapp','telefonico');
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_meta_enum as enum ('pendiente','en_curso','lograda','en_pausa','abandonada');
exception when duplicate_object then null; end $$;

do $$ begin
  create type estado_receta_enum as enum ('vigente','renovada','suspendida','vencida');
exception when duplicate_object then null; end $$;

-- =====================================================================
-- 1. PERSONAL CLÍNICO AUTORIZADO (control de acceso)
--    Vincula un usuario de Supabase Auth con un rol en la clínica.
--    Solo quienes estén aquí pueden leer/escribir datos clínicos (RLS).
-- =====================================================================
create table if not exists staff_autorizado (
  id          uuid primary key references auth.users(id) on delete cascade,
  nombre      text not null,
  rol         text not null default 'clinico',   -- clinico | biostat | admin
  activo      boolean not null default true,
  creado_en   timestamptz not null default now()
);
comment on table staff_autorizado is
  'Allowlist de usuarios Auth que pueden ver datos clínicos. El RLS depende de esta tabla.';

-- Función auxiliar: ¿el usuario actual es staff activo?
create or replace function es_staff()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from staff_autorizado s
    where s.id = auth.uid() and s.activo = true
  );
$$;

-- =====================================================================
-- 2. PACIENTES (datos identificables — máxima protección)
-- =====================================================================
create table if not exists pacientes (
  id                   uuid primary key default gen_random_uuid(),
  codigo               text unique not null,          -- seudónimo estable, ej. VIT-0001
  -- Identificación
  nombre               text,                          -- nombre completo
  rut                  text,                          -- RUT chileno (formato libre, se valida en app)
  fecha_nacimiento     date,
  sexo_biologico       text,                          -- femenino | masculino | intersex
  genero               text,                          -- identidad de género declarada
  -- Contacto y contexto
  direccion            text,
  comuna               text,
  ciudad               text,
  email                text,
  telefono             text,
  prevision            text,                          -- FONASA | ISAPRE | particular | ...
  ocupacion            text,
  preferencia_atencion text,
  -- Administrativo
  tipo_consulta        tipo_consulta_enum not null default 'medicina_cannabica',
  fecha_ingreso        date,
  profesional          text default 'Dra. Valeria Alarcón Kunakov',
  estado               estado_paciente_enum not null default 'activo',
  proximo_control      date,
  ultimo_registro      date,                          -- último registro en Huella
  -- Clínico-narrativo
  motivo_consulta      text,
  prioridades          text,                          -- en palabras de la persona
  narrativa_clinica    text,
  notas_calidad_dato   text,                          -- discrepancias detectadas en la ficha fuente
  -- Metadatos
  creado_en            timestamptz not null default now(),
  actualizado_en       timestamptz not null default now()
);
create index if not exists idx_pacientes_estado on pacientes(estado);
comment on column pacientes.codigo is 'Seudónimo estable para referencias no identificables (reportes agregados).';
comment on column pacientes.notas_calidad_dato is 'Discrepancias/ambigüedades de la ficha fuente a validar clínicamente.';

-- =====================================================================
-- 3. ANTECEDENTES (mórbidos, quirúrgicos, hábitos, familiares, alergias)
-- =====================================================================
create table if not exists antecedentes (
  id           uuid primary key default gen_random_uuid(),
  paciente_id  uuid not null references pacientes(id) on delete cascade,
  tipo         tipo_antecedente_enum not null,
  descripcion  text not null,
  vigente      boolean not null default true,
  detalle      text,
  creado_en    timestamptz not null default now()
);
create index if not exists idx_antecedentes_paciente on antecedentes(paciente_id);

-- =====================================================================
-- 4. DIAGNÓSTICOS
-- =====================================================================
create table if not exists diagnosticos (
  id           uuid primary key default gen_random_uuid(),
  paciente_id  uuid not null references pacientes(id) on delete cascade,
  diagnostico  text not null,
  cie10        text,                                   -- opcional, fuente oficial a verificar
  fecha        date,
  activo       boolean not null default true,
  origen       text,                                   -- ingreso | control | derivacion
  creado_en    timestamptz not null default now()
);
create index if not exists idx_diagnosticos_paciente on diagnosticos(paciente_id);

-- =====================================================================
-- 5. MEDICAMENTOS CONCOMITANTES (no cannábicos)
-- =====================================================================
create table if not exists medicamentos (
  id           uuid primary key default gen_random_uuid(),
  paciente_id  uuid not null references pacientes(id) on delete cascade,
  nombre       text not null,
  dosis        text,
  frecuencia   text,
  indicacion   text,
  estado       estado_medicamento_enum not null default 'activo',
  notas        text,
  creado_en    timestamptz not null default now()
);
create index if not exists idx_medicamentos_paciente on medicamentos(paciente_id);

-- =====================================================================
-- 6. ANAMNESIS CANNÁBICA
-- =====================================================================
create table if not exists cannabis_anamnesis (
  id                 uuid primary key default gen_random_uuid(),
  paciente_id        uuid not null references pacientes(id) on delete cascade,
  anios_uso          text,                             -- "10 años", "desde los 20"
  inicio_motivo      text,                             -- recreativo | terapeutico | mixto
  uso_actual         text,                             -- descripción del uso actual
  frecuencia         text,                             -- "3-4 veces/semana"
  cantidad           text,                             -- "4 g/semana", "3 g/día no todos los días"
  via_preferente     text,
  usa_aceite         boolean,
  objetivo_terapeutico text,                           -- dolor, sueño, ansiedad...
  notas              text,
  creado_en          timestamptz not null default now()
);
create index if not exists idx_anamnesis_paciente on cannabis_anamnesis(paciente_id);

-- =====================================================================
-- 7. RECETAS MAGISTRALES (prescripciones cannábicas, versionadas)
--    Se conserva el historial: cada emisión/renovación es una fila.
-- =====================================================================
create table if not exists recetas (
  id                uuid primary key default gen_random_uuid(),
  paciente_id       uuid not null references pacientes(id) on delete cascade,
  control_id        uuid,                              -- control que la originó (FK lógica, ver §8)
  fecha             date,
  tipo_formulacion  tipo_formulacion_enum not null,
  descripcion       text,                              -- texto íntegro de la receta
  ratio_thc_cbd     text,                              -- "1:1", "2:1 - 5:1", "1:3 ó 4"
  thc_mg_ml         numeric,
  cbd_mg_ml         numeric,
  via               via_admin_enum,
  posologia         text,
  dosis_diaria      text,                              -- "1,5 g/día", "3 gotas c/12h"
  total_mensual     text,
  duracion_meses    integer,
  total_receta      text,                              -- "270 g para 6 meses"
  fuente            text default 'recemed.cl',
  diagnosticos_asociados text,
  estado            estado_receta_enum not null default 'vigente',
  creado_en         timestamptz not null default now()
);
create index if not exists idx_recetas_paciente on recetas(paciente_id);
create index if not exists idx_recetas_control on recetas(control_id);

-- =====================================================================
-- 8. CONTROLES (ingreso + controles longitudinales)
-- =====================================================================
create table if not exists controles (
  id                 uuid primary key default gen_random_uuid(),
  paciente_id        uuid not null references pacientes(id) on delete cascade,
  fecha              date not null,
  tipo               tipo_control_enum not null default 'control',
  canal              canal_enum not null default 'virtual',
  subjetivo          text,                             -- S (relato de la persona)
  objetivo           text,                             -- O (hallazgos)
  evaluacion         text,                             -- A (análisis clínico)
  acuerdos           text[],                           -- P (plan / acuerdos)
  recaidas           text[],                           -- pilares/áreas en recaída
  facilitadores      text[],
  barreras_nuevas    text[],
  cambios_clinicos   text,
  educacion          text[],                           -- temas educados (legal, alimentación...)
  proxima_accion     text,
  proximo_control    date,
  profesional        text default 'Dra. Valeria Alarcón Kunakov',
  creado_en          timestamptz not null default now()
);
create index if not exists idx_controles_paciente on controles(paciente_id, fecha);

-- =====================================================================
-- 9. EVALUACIÓN POR PILAR (línea base + re-evaluaciones)
--    Una fila por pilar por fecha de evaluación → permite evolución.
-- =====================================================================
create table if not exists pilares_eval (
  id            uuid primary key default gen_random_uuid(),
  paciente_id   uuid not null references pacientes(id) on delete cascade,
  pilar         pilar_enum not null,
  fecha         date not null default current_date,
  linea_base    text,
  nivel_riesgo  nivel_riesgo_enum not null default 'no_evaluado',
  motivacion    smallint check (motivacion between 1 and 10),     -- NULL = NC
  autoeficacia  smallint check (autoeficacia between 1 and 10),   -- NULL = NC
  etapa_cambio  etapa_cambio_enum not null default 'no_evaluado',
  prioridad     smallint,                              -- 1 = más prioritario
  barreras      text[],
  observaciones text,
  creado_en     timestamptz not null default now()
);
create index if not exists idx_pilares_paciente on pilares_eval(paciente_id, pilar, fecha);

-- =====================================================================
-- 10. MICROOBJETIVOS (metas conductuales medibles por pilar)
-- =====================================================================
create table if not exists microobjetivos (
  id           uuid primary key default gen_random_uuid(),
  paciente_id  uuid not null references pacientes(id) on delete cascade,
  pilar        pilar_enum not null,
  texto        text not null,
  activo       boolean not null default true,
  creado_en    timestamptz not null default now()
);
create index if not exists idx_microobjetivos_paciente on microobjetivos(paciente_id);

-- =====================================================================
-- 11. HUELLA VITALÆ (trazabilidad conductual semanal)
--    valor: 2 logrado | 1 parcial | 0 no logrado | -1 recaída
--    La última fila por (paciente, pilar, semana) es la vigente →
--    permite registro diferido y corrección sin perder historial.
-- =====================================================================
create table if not exists huella (
  id              uuid primary key default gen_random_uuid(),
  paciente_id     uuid not null references pacientes(id) on delete cascade,
  pilar           pilar_enum not null,
  microobjetivo_id uuid references microobjetivos(id) on delete set null,
  semana          integer not null,                   -- nº de semana desde el ingreso
  fecha_semana    date,
  valor           smallint not null check (valor between -1 and 2),
  correccion      boolean not null default false,
  registrado_por  text default 'equipo',              -- persona | equipo
  creado_en       timestamptz not null default now()
);
create index if not exists idx_huella_paciente on huella(paciente_id, pilar, semana);

-- =====================================================================
-- 12. METAS SMART (acuerdos terapéuticos de mayor alcance)
-- =====================================================================
create table if not exists metas (
  id            uuid primary key default gen_random_uuid(),
  paciente_id   uuid not null references pacientes(id) on delete cascade,
  pilar         pilar_enum,
  texto         text not null,
  estado        estado_meta_enum not null default 'en_curso',
  avance        smallint not null default 0 check (avance between 0 and 100),
  fecha_acordada date default current_date,
  creado_en     timestamptz not null default now()
);
create index if not exists idx_metas_paciente on metas(paciente_id);

-- =====================================================================
-- 13. PESQUISA ZONAS AZULES (Índice de Proximidad Protectora)
--    valor: 0 ausente | 1 parcial | 2 presente
-- =====================================================================
create table if not exists blue_zones (
  id           uuid primary key default gen_random_uuid(),
  paciente_id  uuid not null references pacientes(id) on delete cascade,
  item         text not null,                          -- proposito, mov_natural, pausa, ...
  valor        smallint not null default 0 check (valor between 0 and 2),
  fecha        date not null default current_date,
  creado_en    timestamptz not null default now(),
  unique (paciente_id, item, fecha)
);
create index if not exists idx_bz_paciente on blue_zones(paciente_id);

-- =====================================================================
-- 14. AUDITORÍA (registro de accesos y cambios — cumplimiento)
-- =====================================================================
create table if not exists auditoria (
  id          bigint generated always as identity primary key,
  actor       uuid,                                   -- auth.uid()
  actor_email text,
  accion      text not null,                          -- insert | update | delete | login | export
  tabla       text,
  registro_id uuid,
  detalle     jsonb,
  creado_en   timestamptz not null default now()
);
create index if not exists idx_auditoria_fecha on auditoria(creado_en);

-- =====================================================================
-- 15. DISPARADORES: mantener actualizado_en y auditar cambios
-- =====================================================================
create or replace function touch_actualizado_en()
returns trigger language plpgsql as $$
begin
  new.actualizado_en = now();
  return new;
end $$;

drop trigger if exists trg_touch_pacientes on pacientes;
create trigger trg_touch_pacientes before update on pacientes
  for each row execute function touch_actualizado_en();

create or replace function auditar_cambio()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  begin v_id := coalesce(new.id, old.id); exception when others then v_id := null; end;
  insert into auditoria(actor, actor_email, accion, tabla, registro_id, detalle)
  values (
    auth.uid(),
    (select email from auth.users where id = auth.uid()),
    lower(tg_op),
    tg_table_name,
    v_id,
    case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end
  );
  return case when tg_op = 'DELETE' then old else new end;
end $$;

-- Auditar las tablas clínicas sensibles
drop trigger if exists trg_audit_pacientes on pacientes;
create trigger trg_audit_pacientes after insert or update or delete on pacientes
  for each row execute function auditar_cambio();
drop trigger if exists trg_audit_recetas on recetas;
create trigger trg_audit_recetas after insert or update or delete on recetas
  for each row execute function auditar_cambio();
drop trigger if exists trg_audit_controles on controles;
create trigger trg_audit_controles after insert or update or delete on controles
  for each row execute function auditar_cambio();

-- =====================================================================
-- 16. ROW LEVEL SECURITY
--    Regla única y simple: solo `staff_autorizado` activo ve/escribe.
--    auth.users y la app anónima NO pueden leer nada clínico.
-- =====================================================================
alter table pacientes          enable row level security;
alter table antecedentes       enable row level security;
alter table diagnosticos       enable row level security;
alter table medicamentos       enable row level security;
alter table cannabis_anamnesis enable row level security;
alter table recetas            enable row level security;
alter table controles          enable row level security;
alter table pilares_eval       enable row level security;
alter table microobjetivos     enable row level security;
alter table huella             enable row level security;
alter table metas              enable row level security;
alter table blue_zones         enable row level security;
alter table auditoria          enable row level security;
alter table staff_autorizado   enable row level security;

-- Política reutilizable para cada tabla clínica: acceso total solo a staff.
do $$
declare t text;
begin
  foreach t in array array[
    'pacientes','antecedentes','diagnosticos','medicamentos','cannabis_anamnesis',
    'recetas','controles','pilares_eval','microobjetivos','huella','metas','blue_zones'
  ] loop
    execute format('drop policy if exists staff_all on %I;', t);
    execute format(
      'create policy staff_all on %I for all to authenticated
         using (es_staff()) with check (es_staff());', t);
  end loop;
end $$;

-- staff_autorizado: cada usuario ve su propia fila; el service_role gestiona el resto.
drop policy if exists staff_self on staff_autorizado;
create policy staff_self on staff_autorizado for select to authenticated
  using (id = auth.uid());

-- auditoría: solo lectura para staff (nadie la edita desde la app).
drop policy if exists auditoria_read on auditoria;
create policy auditoria_read on auditoria for select to authenticated
  using (es_staff());

-- =====================================================================
-- 17. VISTA DE APOYO: resumen por paciente (para el dashboard)
-- =====================================================================
create or replace view v_resumen_paciente as
select
  p.id, p.codigo, p.nombre, p.tipo_consulta, p.estado,
  p.fecha_ingreso, p.proximo_control, p.ultimo_registro,
  (current_date - p.ultimo_registro)                        as dias_sin_registro,
  (select count(*) from diagnosticos d where d.paciente_id = p.id and d.activo) as n_diagnosticos,
  (select count(*) from recetas r where r.paciente_id = p.id and r.estado = 'vigente') as n_recetas_vigentes,
  (select count(*) from controles c where c.paciente_id = p.id) as n_controles
from pacientes p;

-- Fin del esquema. Ejecute a continuación supabase-seed-pacientes.sql
