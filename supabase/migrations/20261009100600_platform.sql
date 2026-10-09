-- =====================================================================
-- 7. Платформа: панель продавца (/admin) и самообслуживание владельцев.
--    Продавец (platform_admins) создаёт студии, выдаёт доступ владельцам, приостанавливает студии.
--    Владелец сам настраивает студию и сам запускает приём записей (owner_go_live).
--    Аккаунты (почта/пароль) создаёт Edge Function admin-users с service role.
-- =====================================================================

create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;
revoke all on public.platform_admins from anon, authenticated;
grant all on public.platform_admins to service_role;

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select auth.uid() is not null and exists (select 1 from platform_admins where user_id = auth.uid());
$$;

create or replace function public.require_platform_admin() returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not public.is_platform_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
end $$;

-- Приостановленная студия: сайт открывается, но новые онлайн-записи не принимаются.
alter table public.tenants add column if not exists suspended boolean not null default false;
grant select (suspended) on public.tenants to anon, authenticated;

create or replace function public.bookings_suspended_guard() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.source = 'client' and exists (select 1 from tenants where id = new.tenant_id and suspended) then
    raise exception 'studio_suspended' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists bookings_suspended_guard on public.bookings;
create trigger bookings_suspended_guard before insert on public.bookings
  for each row execute function public.bookings_suspended_guard();

-- ---------------------------------------------------------------------
-- Панель продавца
-- ---------------------------------------------------------------------
create or replace function public.admin_list_studios() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform public.require_platform_admin();
  select coalesce(jsonb_agg(x order by x ->> 'createdAt' desc), '[]'::jsonb) into r from (
    select jsonb_build_object(
      'id', t.id, 'slug', t.slug, 'name', t.profile ->> 'name', 'mode', t.mode, 'suspended', t.suspended,
      'createdAt', t.created_at, 'wentLiveAt', t.went_live_at,
      'owners', coalesce((select jsonb_agg(jsonb_build_object('userId', u.id, 'email', u.email) order by u.email)
                            from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = t.id), '[]'::jsonb),
      'bookings30', (select count(*) from bookings b where b.tenant_id = t.id and not b.is_demo and b.created_at > now() - interval '30 days'),
      'lastBookingAt', (select max(b.created_at) from bookings b where b.tenant_id = t.id and not b.is_demo)
    ) x
    from tenants t
  ) s;
  return r;
end $$;

/*
  Новая студия-заготовка: профиль с подсказками, один пост, одна услуга-пример, график пн–сб.
  Всё это владелец меняет сам в кабинете. Студия создаётся в режиме preview.
*/
create or replace function public.admin_create_studio(p_slug text, p_name text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_slug text := lower(btrim(coalesce(p_slug, ''))); v_name text := btrim(coalesce(p_name, '')); v_id uuid; wd int;
begin
  perform public.require_platform_admin();
  if v_slug !~ '^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$' or v_slug in ('admin', 'api', 'assets', 'owner', 's', 't') then
    raise exception 'bad_slug' using errcode = 'P0001';
  end if;
  if char_length(v_name) not between 1 and 60 then raise exception 'bad_name' using errcode = 'P0001'; end if;
  if exists (select 1 from tenants where slug = v_slug) then raise exception 'slug_taken' using errcode = 'P0001'; end if;

  insert into tenants (slug, mode, timezone, profile) values (v_slug, 'preview', 'Europe/Minsk', jsonb_build_object(
    'name', v_name,
    'shortName', btrim(left(v_name, 12)),
    'kind', 'Автосервис · Беларусь',
    'tagline', 'Онлайн-запись без звонков и ожидания',
    'description', 'Расскажите о студии: опыт, оборудование, гарантия. Этот текст меняется в кабинете → Настройки.',
    'address', 'Укажите адрес в кабинете',
    'phone', '+375 29 000-00-00',
    'accent', '#4690FF',
    'cards', jsonb_build_array(
      jsonb_build_object('title', 'Запись онлайн', 'text', 'Выберите услугу и время — без звонков.'),
      jsonb_build_object('title', 'Точно ко времени', 'text', 'Пост закреплён за вами, очереди нет.'),
      jsonb_build_object('title', 'Оплата на месте', 'text', 'Наличные, карта или ЕРИП.')),
    'booking', jsonb_build_object('bufferMin', 15, 'stepMin', 30, 'leadMin', 60, 'cancelHours', 4, 'horizonDays', 30),
    'media', jsonb_build_object('hero', '/t/_default/media/hero.svg', 'logo', '/t/_default/media/logo.svg')
  )) returning id into v_id;

  insert into resources (tenant_id, key, name, sort) values (v_id, 'post-1', 'Пост 1', 0);
  insert into services (tenant_id, key, name, description, price, duration_min, sort)
  values (v_id, 'example', 'Комплексная мойка (пример)', 'Измените или скройте в кабинете', 30, 60, 0);
  for wd in 1..5 loop insert into working_hours (tenant_id, weekday, opens, closes) values (v_id, wd, '09:00', '19:00'); end loop;
  insert into working_hours (tenant_id, weekday, opens, closes) values (v_id, 6, '10:00', '16:00');
  return v_id;
end $$;

-- Выдать доступ существующему пользователю по почте. 'linked' — готово, 'no_user' — аккаунта ещё нет.
create or replace function public.admin_add_owner(p_tenant uuid, p_email text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_user uuid;
begin
  perform public.require_platform_admin();
  if not exists (select 1 from tenants where id = p_tenant) then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  select id into v_user from auth.users where lower(email) = lower(btrim(p_email));
  if v_user is null then return 'no_user'; end if;
  insert into tenant_members (tenant_id, user_id) values (p_tenant, v_user) on conflict do nothing;
  return 'linked';
end $$;

create or replace function public.admin_remove_owner(p_tenant uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.require_platform_admin();
  delete from tenant_members where tenant_id = p_tenant and user_id = p_user;
end $$;

create or replace function public.admin_set_suspended(p_tenant uuid, p_suspended boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.require_platform_admin();
  update tenants set suspended = coalesce(p_suspended, false) where id = p_tenant;
  if not found then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Владелец сам запускает приём записей: демо-записи удаляются, уведомления включаются.
-- Нужны данные оператора ПД (проверяет tenants_guard) и настоящий телефон.
-- ---------------------------------------------------------------------
create or replace function public.owner_go_live(p_tenant uuid) returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare t tenants; n int;
begin
  if not (public.is_member(p_tenant) or public.is_platform_admin()) then raise exception 'forbidden' using errcode = '42501'; end if;
  select * into t from tenants where id = p_tenant for update;
  if t.mode = 'live' then return 0; end if;
  if jsonb_typeof(t.profile -> 'legal') is distinct from 'object' then raise exception 'not_ready_legal' using errcode = 'P0001'; end if;
  if (t.profile ->> 'phone') ~ '000-?00-?00' then raise exception 'not_ready_phone' using errcode = 'P0001'; end if;
  delete from bookings where tenant_id = p_tenant and is_demo;
  get diagnostics n = row_count;
  update tenants set mode = 'live' where id = p_tenant;
  return n;
end $$;

revoke all on function public.is_platform_admin() from public, anon, authenticated;
revoke all on function public.require_platform_admin() from public, anon, authenticated;
revoke all on function public.bookings_suspended_guard() from public, anon, authenticated;
revoke all on function public.admin_list_studios() from public, anon, authenticated;
revoke all on function public.admin_create_studio(text, text) from public, anon, authenticated;
revoke all on function public.admin_add_owner(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_remove_owner(uuid, uuid) from public, anon, authenticated;
revoke all on function public.admin_set_suspended(uuid, boolean) from public, anon, authenticated;
revoke all on function public.owner_go_live(uuid) from public, anon, authenticated;

grant execute on function public.is_platform_admin() to authenticated, service_role;
grant execute on function public.admin_list_studios() to authenticated;
grant execute on function public.admin_create_studio(text, text) to authenticated;
grant execute on function public.admin_add_owner(uuid, text) to authenticated;
grant execute on function public.admin_remove_owner(uuid, uuid) to authenticated;
grant execute on function public.admin_set_suspended(uuid, boolean) to authenticated;
grant execute on function public.owner_go_live(uuid) to authenticated;

-- Для Edge Function admin-users (service role): найти пользователя по почте.
create or replace function public.service_user_id_by_email(p_email text) returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select id from auth.users where lower(email) = lower(btrim(p_email)) limit 1;
$$;
revoke all on function public.service_user_id_by_email(text) from public, anon, authenticated;
grant execute on function public.service_user_id_by_email(text) to service_role;
