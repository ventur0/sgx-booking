-- Собственные домены студий (учёт оплат убран миграцией 101100).
begin;
\ir 00_helpers.sql

insert into auth.users (id, email) values ('d0000000-0000-0000-0000-00000000000d', 'seller@test') on conflict do nothing;
insert into public.platform_admins (user_id) values ('d0000000-0000-0000-0000-00000000000d') on conflict do nothing;

do $$
declare g uuid := pg_temp.tid('graphite'); p uuid := pg_temp.tid('protector'); j jsonb;
begin
  -- посторонние
  set local role anon;
  perform pg_temp.ok((select count(*) from public.tenants where custom_domain is null) >= 2, 'anon видит домены студий (нужно для открытия по домену)');
  reset role;
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform pg_temp.throws(format($q$select public.admin_set_domain(%L, 'x.by')$q$, g), 'forbidden', 'владелец не меняет домен');
  perform pg_temp.throws($q$update public.tenants set custom_domain = 'hack.by'$q$, 'permission denied', 'домен не меняется прямым запросом');
  perform pg_temp.as_admin();

  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform pg_temp.ok(to_regclass('public.platform_billing') is null, 'таблицы учёта оплат больше нет');
  j := public.admin_list_studios();
  perform pg_temp.ok(not (j -> 0 ? 'paidUntil'), 'в списке студий нет полей оплаты');
  -- продавец: домены
  perform pg_temp.ok(public.admin_set_domain(g, ' https://Zapis.Graphite.by/ ') = 'zapis.graphite.by', 'домен очищается от https:// и регистра');
  perform pg_temp.throws(format($q$select public.admin_set_domain(%L, 'zapis.graphite.by')$q$, p), 'domain_taken', 'один домен — одна студия');
  perform pg_temp.throws(format($q$select public.admin_set_domain(%L, 'not a domain')$q$, p), 'bad_domain', 'неверный домен отклоняется');
  perform pg_temp.throws(format($q$select public.admin_set_domain(%L, 'sgx-booking.pages.dev')$q$, p), 'bad_domain', 'адрес самого сервиса не занять');
  perform pg_temp.ok(public.admin_set_domain(p, '') is null, 'домен можно убрать');
  perform pg_temp.as_admin();

  set local role anon;
  perform pg_temp.ok((select slug from public.tenants where custom_domain = 'zapis.graphite.by') = 'graphite', 'по домену находится студия');
  reset role;

end $$;

rollback;
