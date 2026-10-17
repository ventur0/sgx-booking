-- =====================================================================
-- 20. Порядок студий в панели продавца задаёт сам продавец (кнопки «выше / ниже / наверх»).
--     Колонка admin_sort не видна и не меняется ни anon, ни владельцами (нет GRANT) — только через функции продавца.
-- =====================================================================
alter table public.tenants add column if not exists admin_sort integer;

create or replace function public.admin_list_studios() returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  perform public.require_platform_admin();
  select coalesce(jsonb_agg(x order by (x ->> 'sort')::int nulls last, x ->> 'createdAt' desc), '[]'::jsonb) into r from (
    select jsonb_build_object(
      'id', t.id, 'slug', t.slug, 'name', t.profile ->> 'name', 'mode', t.mode, 'suspended', t.suspended,
      'createdAt', t.created_at, 'wentLiveAt', t.went_live_at, 'sort', t.admin_sort,
      'owners', coalesce((select jsonb_agg(jsonb_build_object('userId', u.id, 'email', u.email) order by u.email)
                            from tenant_members m join auth.users u on u.id = m.user_id where m.tenant_id = t.id), '[]'::jsonb),
      'bookings30', (select count(*) from bookings b where b.tenant_id = t.id and not b.is_demo and b.created_at > now() - interval '30 days'),
      'lastBookingAt', (select max(b.created_at) from bookings b where b.tenant_id = t.id and not b.is_demo)
    ) x
    from tenants t
  ) s;
  return r;
end $$;

-- Новый порядок: список id студий сверху вниз. Студии, которых нет в списке, уходят в конец (сортировка по дате).
create or replace function public.admin_set_order(p_ids uuid[]) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.require_platform_admin();
  update tenants t set admin_sort = o.pos
    from unnest(coalesce(p_ids, '{}'::uuid[])) with ordinality as o(id, pos)
   where t.id = o.id;
  update tenants set admin_sort = null where not (id = any (coalesce(p_ids, '{}'::uuid[])));
end $$;

revoke all on function public.admin_list_studios() from public, anon, authenticated;
revoke all on function public.admin_set_order(uuid[]) from public, anon, authenticated;
grant execute on function public.admin_list_studios(), public.admin_set_order(uuid[]) to authenticated;
