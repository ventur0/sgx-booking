-- =====================================================================
-- 8. Удаление студии продавцом. Безвозвратно: записи, оплаты, услуги, график, фото-карточки, доступы.
--    Для защиты от случайного нажатия нужно повторить адрес студии (slug).
-- =====================================================================
create or replace function public.admin_delete_studio(p_tenant uuid, p_confirm_slug text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_slug text;
begin
  perform public.require_platform_admin();
  select slug into v_slug from tenants where id = p_tenant for update;
  if v_slug is null then raise exception 'tenant_not_found' using errcode = 'P0001'; end if;
  if v_slug is distinct from lower(btrim(coalesce(p_confirm_slug, ''))) then raise exception 'confirm_mismatch' using errcode = 'P0001'; end if;
  delete from bookings where tenant_id = p_tenant; -- вместе с занятостью, оплатами и заданиями (cascade)
  delete from tenants where id = p_tenant;        -- всё остальное студии (cascade)
end $$;

revoke all on function public.admin_delete_studio(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_delete_studio(uuid, text) to authenticated;
