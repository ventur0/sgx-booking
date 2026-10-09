-- Изоляция студий, RLS, GRANT: anon не видит персональные данные, платежи и токены;
-- владелец видит и меняет только свою студию.
begin;
\ir 00_helpers.sql

do $$
declare d date := pg_temp.open_day('graphite', 7, '11:00');
        g uuid; p uuid; n int; foreign_res uuid := pg_temp.res('protector', 'lift-1');
begin
  g := pg_temp.book('graphite', 'wash', d, '11:00', 'RLS-G');
  p := pg_temp.book('protector', 'balance', pg_temp.open_day('protector', 7, '11:00'), '11:00', 'RLS-P');

  -- ---------- anon ----------
  set local role anon;
  perform pg_temp.ok((select count(*) from public.tenants) >= 2, 'anon видит публичные профили студий');
  perform pg_temp.ok((select count(*) from public.services) > 0, 'anon видит услуги и цены');
  perform pg_temp.throws('select count(*) from public.bookings', 'permission denied', 'anon не читает записи');
  perform pg_temp.throws('select count(*) from public.resource_occupancies', 'permission denied', 'anon не читает занятость');
  perform pg_temp.throws('select count(*) from public.payments', 'permission denied', 'anon не читает платежи');
  perform pg_temp.throws('select count(*) from public.push_subscriptions', 'permission denied', 'anon не читает подписки');
  perform pg_temp.throws('select count(*) from public.notification_jobs', 'permission denied', 'anon не читает outbox');
  perform pg_temp.throws('select count(*) from public.rate_counters', 'permission denied', 'anon не читает счётчики');
  perform pg_temp.throws('select count(*) from public.tenant_members', 'permission denied', 'anon не видит владельцев');
  perform pg_temp.throws('update public.services set price = 1', 'permission denied', 'anon не меняет цены');
  perform pg_temp.throws($q$select public.claim_notification_jobs(10, 60)$q$, 'permission denied', 'anon не забирает задания outbox');
  perform pg_temp.throws($q$select public.owner_stats(gen_random_uuid(), current_date, current_date)$q$, 'permission denied', 'anon не вызывает функции владельца');
  perform pg_temp.throws($q$select public.resolve_interval(t, current_date, '10:00', 60, 'owner') from public.tenants t limit 1$q$, 'permission denied', 'внутренние функции закрыты');
  reset role;

  -- ---------- владелец GRAPHITE ----------
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  select count(*) into n from public.bookings;
  perform pg_temp.ok(n > 0 and not exists (select 1 from public.bookings where tenant_id <> pg_temp.tid('graphite')), 'владелец видит только записи своей студии');
  perform pg_temp.ok(not exists (select 1 from public.bookings where id = p), 'запись другой студии не видна');
  perform pg_temp.throws('select access_token_hash from public.bookings limit 1', 'permission denied', 'даже владелец не читает хэши токенов');
  perform pg_temp.throws(format($q$select public.owner_set_status(%L, 'accepted')$q$, p), 'forbidden', 'нельзя менять статус чужой записи');
  perform pg_temp.throws(format($q$select public.owner_add_payment(%L, 'pay', 10)$q$, p), 'forbidden', 'нельзя внести оплату в чужую запись');
  perform pg_temp.throws(format($q$select public.owner_move_booking(%L, current_date + 3, '10:00')$q$, p), 'forbidden', 'нельзя перенести чужую запись');
  perform pg_temp.throws(format($q$select public.owner_stats(%L, current_date, current_date)$q$, pg_temp.tid('protector')), 'forbidden', 'нельзя смотреть статистику чужой студии');
  perform pg_temp.throws(format($q$select public.owner_block_resource(%L, now() + interval '3 days', now() + interval '3 days 1 hour')$q$, foreign_res), 'forbidden', 'нельзя блокировать чужой пост');
  update public.services set price = 1 where tenant_id = pg_temp.tid('protector');
  get diagnostics n = row_count;
  perform pg_temp.ok(n = 0, 'цены чужой студии не меняются (RLS)');
  update public.services set price = 47 where id = pg_temp.svc('graphite', 'wash');
  get diagnostics n = row_count;
  perform pg_temp.ok(n = 1, 'свою цену владелец меняет');
  perform pg_temp.throws($q$update public.tenants set mode = 'live'$q$, 'permission denied', 'режим preview/live меняет только конвейер');
  perform pg_temp.throws($q$update public.tenants set slug = 'hack'$q$, 'permission denied', 'адрес студии владелец не меняет');
  perform pg_temp.throws(format($q$insert into public.service_resources (tenant_id, service_id, resource_id) values (%L, %L, %L)$q$,
           pg_temp.tid('graphite'), pg_temp.svc('graphite', 'wash'), foreign_res), 'foreign key', 'составной FK не даёт привязать чужой ресурс');
  perform pg_temp.throws(format($q$insert into public.services (tenant_id, key, name, price, duration_min) values (%L, 'x', 'Чужая', 1, 30)$q$,
           pg_temp.tid('protector')), 'row-level security', 'нельзя добавить услугу в чужую студию');
  perform pg_temp.ok((select count(*) from public.tenant_members) = 1, 'владелец видит только своё членство');
  perform pg_temp.as_admin();

  -- ---------- посторонний пользователь ----------
  perform pg_temp.as_user('c0000000-0000-0000-0000-00000000000c');
  perform pg_temp.ok((select count(*) from public.bookings) = 0, 'вошедший без членства не видит ни одной записи');
  perform pg_temp.throws(format($q$select public.owner_create_booking(%L, %L, %L, '12:00', 'X', '+375291234567', 'Car', gen_random_uuid())$q$,
           pg_temp.tid('graphite'), pg_temp.svc('graphite', 'wash'), d), 'forbidden', 'без членства нельзя создавать записи от имени студии');
  perform pg_temp.as_admin();
end $$;

rollback;
