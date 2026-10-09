-- =====================================================================
-- 14. Собственные домены студий убраны (по решению владельца сервиса).
-- =====================================================================
drop function if exists public.admin_set_domain(uuid, text);

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

drop index if exists public.tenants_custom_domain_key;
alter table public.tenants drop constraint if exists tenants_custom_domain_check;
alter table public.tenants drop column if exists custom_domain;

revoke all on function public.admin_list_studios() from public, anon, authenticated;
grant execute on function public.admin_list_studios() to authenticated;
