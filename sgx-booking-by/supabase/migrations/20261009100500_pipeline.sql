-- =====================================================================
-- 6. Функции конвейера (только service_role): демо-записи и переход в live.
-- =====================================================================

-- Ближайший рабочий день от смещения, в который время попадает в окно приёма
create or replace function public.admin_open_day(p_tenant uuid, p_offset integer, p_time time) returns date
language plpgsql stable security definer set search_path = public as $$
declare tz text; d date; i int := 0; w record;
begin
  select timezone into tz from tenants where id = p_tenant;
  d := (now() at time zone tz)::date + p_offset;
  loop
    select * into w from public.day_window(p_tenant, d);
    exit when found and p_time >= w.opens and p_time < w.closes;
    d := d + case when p_offset < 0 then -1 else 1 end; i := i + 1;
    if i > 60 then raise exception 'no_open_day' using errcode = 'P0001'; end if;
  end loop;
  return d;
end $$;

/*
  Демо-запись для preview: помечена is_demo, с занятостью и оплатами.
  Идемпотентна по p_label (повторная публикация не плодит копии).
*/
create or replace function public.admin_insert_demo_booking(
  p_tenant uuid, p_label text, p_service_key text, p_resource_key text, p_day_offset integer, p_time time,
  p_name text, p_phone text, p_car text, p_status text, p_payments jsonb default '[]'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare t tenants; s services; r uuid; d date; st timestamptz; bid uuid; p jsonb; v_key uuid := md5(p_tenant || ':' || p_label)::uuid;
begin
  select * into t from tenants where id = p_tenant;
  if t.mode <> 'preview' then raise exception 'demo_only_in_preview' using errcode = 'P0001'; end if;
  select id into bid from bookings where tenant_id = t.id and idempotency_key = v_key;
  if found then return bid; end if;
  select * into s from services where tenant_id = t.id and key = p_service_key;
  if not found then raise exception 'service_not_found' using errcode = 'P0001'; end if;
  select id into r from resources where tenant_id = t.id and key = p_resource_key;
  if r is null then select x into r from public.eligible_resources(t.id, s.id) x limit 1; end if;
  d := public.admin_open_day(t.id, p_day_offset, p_time);
  st := (d + p_time) at time zone t.timezone;
  insert into bookings (tenant_id, service_id, resource_id, status, starts_at, ends_at, buffer_min, service_name, price,
                        client_name, client_phone, client_car, access_token_hash, idempotency_key, source, is_demo, consent_at, consent_version)
  values (t.id, s.id, r, p_status, st, st + make_interval(mins => s.duration_min), public.rule_int(t, 'bufferMin', 0), s.name, s.price,
          p_name, public.norm_phone(p_phone), p_car, digest(gen_random_uuid()::text, 'sha256'), v_key, 'client', true, now(), 'demo')
  returning id into bid;
  if p_status <> 'cancelled' then
    begin
      insert into resource_occupancies (tenant_id, resource_id, kind, booking_id, period)
      values (t.id, r, 'booking', bid, tstzrange(st, st + make_interval(mins => s.duration_min + public.rule_int(t, 'bufferMin', 0)), '[)'));
    exception when exclusion_violation then
      delete from bookings where id = bid; -- демо не должно ломать настоящую занятость
      return null;
    end;
  end if;
  for p in select * from jsonb_array_elements(coalesce(p_payments, '[]')) loop
    insert into payments (tenant_id, booking_id, kind, amount, method, paid_at)
    values (t.id, bid, p ->> 'kind', (p ->> 'amount')::numeric, coalesce(p ->> 'method', 'cash'), least(st + interval '1 hour', now()));
  end loop;
  return bid;
end $$;

-- Перевод в live: удаляет демо-данные и включает режим. Записи клиентов не трогает.
create or replace function public.admin_go_live(p_tenant uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from bookings where tenant_id = p_tenant and is_demo;
  get diagnostics n = row_count;
  update tenants set mode = 'live' where id = p_tenant;
  return n;
end $$;

revoke all on function public.admin_open_day(uuid, integer, time) from public, anon, authenticated;
revoke all on function public.admin_insert_demo_booking(uuid, text, text, text, integer, time, text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.admin_go_live(uuid) from public, anon, authenticated;
grant execute on function public.admin_open_day(uuid, integer, time) to service_role;
grant execute on function public.admin_insert_demo_booking(uuid, text, text, text, integer, time, text, text, text, text, jsonb) to service_role;
grant execute on function public.admin_go_live(uuid) to service_role;
