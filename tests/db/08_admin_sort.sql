-- Порядок студий в панели продавца.
begin;
\ir 00_helpers.sql
insert into auth.users (id, email) values ('d0000000-0000-0000-0000-00000000000d', 'seller@test') on conflict do nothing;
insert into public.platform_admins (user_id) values ('d0000000-0000-0000-0000-00000000000d') on conflict do nothing;

do $$
declare g uuid := pg_temp.tid('graphite'); p uuid := pg_temp.tid('protector'); j jsonb;
begin
  set local role anon;
  perform pg_temp.throws(format($q$select public.admin_set_order(array[%L]::uuid[])$q$, g), 'permission denied', 'anon не меняет порядок');
  perform pg_temp.throws($q$select admin_sort from public.tenants$q$, 'permission denied', 'anon не видит служебный порядок');
  reset role;
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform pg_temp.throws(format($q$select public.admin_set_order(array[%L]::uuid[])$q$, g), 'forbidden', 'владелец студии не меняет порядок');
  perform pg_temp.throws(format($q$update public.tenants set admin_sort = 1 where id = %L$q$, g), 'permission denied', 'владелец не меняет порядок напрямую');

  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform public.admin_set_order(array[p, g]);
  j := public.admin_list_studios();
  perform pg_temp.ok(j -> 0 ->> 'slug' = 'protector' and j -> 1 ->> 'slug' = 'graphite', 'порядок сохраняется: «Протектор» первым');
  perform public.admin_set_order(array[g, p]);
  j := public.admin_list_studios();
  perform pg_temp.ok(j -> 0 ->> 'slug' = 'graphite' and j -> 1 ->> 'slug' = 'protector', 'порядок меняется обратно');
  perform public.admin_set_order(array[p]);
  j := public.admin_list_studios();
  perform pg_temp.ok(j -> 0 ->> 'slug' = 'protector' and (j -> 1 ->> 'sort') is null, 'студии вне списка уходят в конец');
end $$;
rollback;
