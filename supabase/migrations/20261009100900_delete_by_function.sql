-- =====================================================================
-- 10. Удаление студий и аккаунтов идёт через Edge Function admin-users:
--     продавец подтверждает почтой владельца, владелец — своим паролем (пароль проверяет только Auth).
--     Здесь — служебные функции только для service role.
-- =====================================================================
drop function if exists public.admin_delete_studio(uuid, text);

create or replace function public.service_delete_studio(p_tenant uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform 1 from tenants where id = p_tenant for update;
  if not found then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  delete from bookings where tenant_id = p_tenant; -- вместе с занятостью, оплатами и заданиями (cascade)
  delete from tenants where id = p_tenant;        -- услуги, посты, график, фото-карточки, доступы (cascade)
end $$;

create or replace function public.service_tenant_owner_emails(p_tenant uuid) returns text[]
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(array_agg(u.email order by u.email), '{}') from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = p_tenant;
$$;

revoke all on function public.service_delete_studio(uuid) from public, anon, authenticated;
revoke all on function public.service_tenant_owner_emails(uuid) from public, anon, authenticated;
grant execute on function public.service_delete_studio(uuid) to service_role;
grant execute on function public.service_tenant_owner_emails(uuid) to service_role;
