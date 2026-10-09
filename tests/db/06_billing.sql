-- Учёт оплат и собственные домены студий.
begin;
\ir 00_helpers.sql

insert into auth.users (id, email) values ('d0000000-0000-0000-0000-00000000000d', 'seller@test') on conflict do nothing;
insert into public.platform_admins (user_id) values ('d0000000-0000-0000-0000-00000000000d') on conflict do nothing;

do $$
declare g uuid := pg_temp.tid('graphite'); p uuid := pg_temp.tid('protector'); d date; j jsonb;
        today date := (now() at time zone 'Europe/Minsk')::date;
begin
  -- посторонние
  set local role anon;
  perform pg_temp.throws($q$select count(*) from public.platform_billing$q$, 'permission denied', 'anon не видит оплаты покупателей');
  perform pg_temp.throws(format($q$select public.admin_set_billing(%L, null, 10, '', 1)$q$, g), 'permission denied', 'anon не меняет оплаты');
  perform pg_temp.ok((select count(*) from public.tenants where custom_domain is null) >= 2, 'anon видит домены студий (нужно для открытия по домену)');
  reset role;
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform pg_temp.throws($q$select count(*) from public.platform_billing$q$, 'permission denied', 'владелец не видит оплаты');
  perform pg_temp.throws(format($q$select public.admin_set_billing(%L, '2099-01-01', 0, '', 0)$q$, g), 'forbidden', 'владелец не продлевает себе оплату');
  perform pg_temp.throws(format($q$select public.admin_set_domain(%L, 'x.by')$q$, g), 'forbidden', 'владелец не меняет домен');
  perform pg_temp.throws($q$update public.tenants set custom_domain = 'hack.by'$q$, 'permission denied', 'домен не меняется прямым запросом');
  perform pg_temp.as_admin();

  -- продавец: оплаты
  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform public.admin_set_suspended(g, true);
  d := public.admin_set_billing(g, null, 49.9, 'Тариф «Студия»', 1);
  perform pg_temp.ok(d = (today + interval '1 month')::date, 'без оплаты продление считается от сегодня');
  perform pg_temp.ok(not (select suspended from public.tenants where id = g), 'продление снимает приостановку');
  d := public.admin_set_billing(g, d, 49.9, 'Тариф «Студия»', 2);
  perform pg_temp.ok(d = (today + interval '3 months')::date, 'продление добавляется к оплаченному сроку');
  d := public.admin_set_billing(g, today - 40, 49.9, '', 1);
  perform pg_temp.ok(d = (today + interval '1 month')::date, 'просроченная оплата продлевается от сегодня');
  perform pg_temp.ok(public.admin_set_billing(p, '2026-12-31', null, 'вручную', 0) = '2026-12-31', 'дату можно задать вручную');
  perform pg_temp.throws(format($q$select public.admin_set_billing(%L, null, 1.005, '', 0)$q$, g), 'bad_amount', 'цена проверяется');
  j := public.admin_list_studios();
  perform pg_temp.ok(j @> jsonb_build_array(jsonb_build_object('slug', 'protector', 'paidUntil', '2026-12-31', 'billingNote', 'вручную')), 'оплаты видны в списке студий');

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

  -- удаление студии удаляет и запись об оплате
  delete from public.tenants where id = p;
  perform pg_temp.ok(not exists (select 1 from public.platform_billing where tenant_id = p), 'оплата удаляется вместе со студией');
end $$;

rollback;
