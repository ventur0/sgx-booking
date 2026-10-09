-- =====================================================================
-- 9. Исправления после проверки:
--    - услуга и её посты сохраняются одной транзакцией (нет дублей и «потерянных» постов при сбое сети);
--    - приостановка не мешает демо-записям конвейера (admin_insert_demo_booking, consent_version = 'demo').
-- =====================================================================
create or replace function public.owner_save_service(
  p_tenant uuid, p_id uuid, p_name text, p_description text, p_price numeric, p_duration_min integer,
  p_active boolean, p_sort integer, p_resource_ids uuid[]
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := p_id;
begin
  perform public.require_member(p_tenant);
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 80 then raise exception 'config_invalid: name' using errcode = '22023'; end if;
  if p_price is null or p_price < 0 or p_price <> round(p_price, 2) then raise exception 'bad_amount' using errcode = '22023'; end if;
  if v_id is null then
    insert into services (tenant_id, key, name, description, price, duration_min, active, sort)
    values (p_tenant, 's' || replace(left(gen_random_uuid()::text, 13), '-', ''), btrim(p_name), btrim(coalesce(p_description, '')), p_price, p_duration_min, coalesce(p_active, true), coalesce(p_sort, 0))
    returning id into v_id;
  else
    update services set name = btrim(p_name), description = btrim(coalesce(p_description, '')), price = p_price,
                        duration_min = p_duration_min, active = coalesce(p_active, true), sort = coalesce(p_sort, sort)
     where id = v_id and tenant_id = p_tenant;
    if not found then raise exception 'service_not_found' using errcode = 'P0001'; end if;
  end if;
  delete from service_resources where tenant_id = p_tenant and service_id = v_id;
  -- составной FK (tenant_id, resource_id) не даст привязать пост другой студии
  insert into service_resources (tenant_id, service_id, resource_id)
  select p_tenant, v_id, r from unnest(coalesce(p_resource_ids, '{}')) r;
  return v_id;
end $$;
revoke all on function public.owner_save_service(uuid, uuid, text, text, numeric, integer, boolean, integer, uuid[]) from public, anon, authenticated;
grant execute on function public.owner_save_service(uuid, uuid, text, text, numeric, integer, boolean, integer, uuid[]) to authenticated;

create or replace function public.bookings_suspended_guard() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.source = 'client' and new.consent_version is distinct from 'demo' and exists (select 1 from tenants where id = new.tenant_id and suspended) then
    raise exception 'studio_suspended' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.bookings_suspended_guard() from public, anon, authenticated;
