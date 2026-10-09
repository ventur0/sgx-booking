-- Общие помощники SQL-тестов (подключаются в начале каждого файла через \ir).
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok  %', msg;
end $$;

-- ожидаем ошибку с кодом-текстом
create or replace function pg_temp.throws(sql text, expected text, msg text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(expected in sqlerrm) > 0 then raise notice 'ok  % (%)', msg, expected; return; end if;
    raise exception 'FAIL: % — ожидали «%», получили «%»', msg, expected, sqlerrm;
  end;
  raise exception 'FAIL: % — ожидали ошибку «%», но запрос прошёл', msg, expected;
end $$;

-- ближайший рабочий день студии не раньше чем через p_offset дней, где p_time попадает в окно
create or replace function pg_temp.open_day(p_slug text, p_offset int, p_time time) returns date language plpgsql as $$
declare t public.tenants; d date; w record; i int := 0;
begin
  select * into t from public.tenants where slug = p_slug;
  d := (now() at time zone t.timezone)::date + p_offset;
  loop
    select * into w from public.day_window(t.id, d);
    exit when found and p_time >= w.opens and p_time < w.closes;
    d := d + 1; i := i + 1;
    if i > 60 then raise exception 'нет рабочего дня'; end if;
  end loop;
  return d;
end $$;

create or replace function pg_temp.svc(p_slug text, p_key text) returns uuid language sql as $$
  select s.id from public.services s join public.tenants t on t.id = s.tenant_id where t.slug = p_slug and s.key = p_key $$;
create or replace function pg_temp.res(p_slug text, p_key text) returns uuid language sql as $$
  select r.id from public.resources r join public.tenants t on t.id = r.tenant_id where t.slug = p_slug and r.key = p_key $$;
create or replace function pg_temp.tid(p_slug text) returns uuid language sql as $$ select id from public.tenants where slug = p_slug $$;

-- запись от имени клиента (anon): токен = 'tok-' || метка, ключ идемпотентности = md5(метка)
create or replace function pg_temp.book(p_slug text, p_service text, p_day date, p_time text, p_label text, p_phone text default '+375 29 111-22-33')
returns uuid language plpgsql as $$
declare id uuid;
begin
  execute 'set local role anon';
  id := public.create_booking(p_slug, pg_temp.svc(p_slug, p_service), p_day, p_time::time, 'Клиент ' || p_label, p_phone, 'Машина ' || p_label,
          md5(p_label)::uuid, rpad('tok-' || p_label, 40, 'x'), true, 'test');
  execute 'reset role';
  return id;
exception when others then
  execute 'reset role';
  raise;
end $$;

-- действовать от имени пользователя
create or replace function pg_temp.as_user(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claim.sub', '', true); end $$;

-- владельцы демо-студий для тестов
insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-00000000000a', 'owner-graphite@test'),
  ('b0000000-0000-0000-0000-00000000000b', 'owner-protector@test'),
  ('c0000000-0000-0000-0000-00000000000c', 'stranger@test')
on conflict do nothing;
insert into public.tenant_members (tenant_id, user_id) values
  (pg_temp.tid('graphite'), 'a0000000-0000-0000-0000-00000000000a'),
  (pg_temp.tid('protector'), 'b0000000-0000-0000-0000-00000000000b')
on conflict do nothing;
