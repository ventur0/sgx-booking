-- =====================================================================
-- 1. Ядро: студии, участники, ресурсы (посты/боксы), услуги, график.
--    Один Supabase-проект на все студии; tenant_id во всех зависимых таблицах,
--    составные внешние ключи (tenant_id, id) не дают связать данные разных студий.
-- =====================================================================
create extension if not exists btree_gist;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Студии
-- ---------------------------------------------------------------------
create table public.tenants (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9-]{2,40}$'),
  -- preview: только помеченные demo-данные, без реальных уведомлений; live: после проверки настроек
  mode         text not null default 'preview' check (mode in ('preview', 'live')),
  timezone     text not null default 'Europe/Minsk',
  -- публичный профиль: название, тексты, контакты, акцент, карточки, медиа, правила записи, оператор ПД
  profile      jsonb not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  went_live_at timestamptz
);

create table public.tenant_members (
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       text not null default 'owner' check (role in ('owner')),
  created_at timestamptz not null default now(),
  primary key (tenant_id, user_id)
);
create index tenant_members_user_idx on public.tenant_members (user_id);

-- ---------------------------------------------------------------------
-- Ресурсы (посты, боксы, подъёмники) и услуги
-- ---------------------------------------------------------------------
create table public.resources (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  key        text not null check (key ~ '^[a-z0-9_-]{1,40}$'),
  name       text not null check (char_length(name) between 1 and 40),
  active     boolean not null default true,
  sort       integer not null default 0,
  unique (tenant_id, key),
  unique (tenant_id, id)
);

create table public.services (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  key          text not null check (key ~ '^[a-z0-9_-]{1,40}$'),
  name         text not null check (char_length(name) between 2 and 80),
  description  text not null default '' check (char_length(description) <= 200),
  price        numeric(10,2) not null check (price >= 0),
  -- непрерывная длительность занятия ресурса в минутах (многодневные работы — тоже в минутах: 2 дня = 2880)
  duration_min integer not null check (duration_min between 15 and 20160),
  active       boolean not null default true,
  sort         integer not null default 0,
  unique (tenant_id, key),
  unique (tenant_id, id)
);

-- На каких ресурсах можно оказывать услугу (пусто = на любом активном ресурсе студии)
create table public.service_resources (
  tenant_id   uuid not null,
  service_id  uuid not null,
  resource_id uuid not null,
  primary key (service_id, resource_id),
  foreign key (tenant_id, service_id) references public.services (tenant_id, id) on delete cascade,
  foreign key (tenant_id, resource_id) references public.resources (tenant_id, id) on delete cascade
);

-- ---------------------------------------------------------------------
-- График: рабочие часы задают моменты приёма машин
-- ---------------------------------------------------------------------
create table public.working_hours (
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  weekday   smallint not null check (weekday between 0 and 6), -- 0 = воскресенье
  opens     time not null,
  closes    time not null check (closes > opens),
  primary key (tenant_id, weekday)
);

create table public.schedule_exceptions (
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  day       date not null,
  closed    boolean not null default true,
  opens     time,
  closes    time,
  note      text not null default '' check (char_length(note) <= 80),
  source    text not null default 'owner' check (source in ('config', 'owner')),
  primary key (tenant_id, day),
  check (closed or (opens is not null and closes is not null and closes > opens))
);

-- ---------------------------------------------------------------------
-- Фото работ. source = 'owner' — загружено владельцем, переиздание конфига их не трогает
-- ---------------------------------------------------------------------
create table public.works (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  key        text,
  photo_url  text not null,
  caption    text not null check (char_length(caption) between 1 and 120),
  sort       integer not null default 0,
  source     text not null default 'owner' check (source in ('config', 'owner')),
  created_at timestamptz not null default now(),
  unique (tenant_id, key)
);

-- ---------------------------------------------------------------------
-- Членство и общие проверки
-- ---------------------------------------------------------------------
create or replace function public.is_member(p_tenant uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from tenant_members where tenant_id = p_tenant and user_id = auth.uid());
$$;

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
create trigger tenants_touch before update on public.tenants for each row execute function public.touch_updated_at();

create or replace function public.tenants_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'config_invalid: неизвестный часовой пояс' using errcode = '22023';
  end if;
  if new.mode = 'live' and jsonb_typeof(new.profile -> 'legal') is distinct from 'object' then
    raise exception 'config_invalid: для live нужны данные оператора ПД' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and new.mode = 'live' and old.mode = 'preview' then
    new.went_live_at := now();
  end if;
  return new;
end $$;
create trigger tenants_guard before insert or update on public.tenants for each row execute function public.tenants_guard();
