-- Панель продавца и самообслуживание владельца.
begin;
\ir 00_helpers.sql

insert into auth.users (id, email) values
  ('d0000000-0000-0000-0000-00000000000d', 'seller@test'),
  ('e0000000-0000-0000-0000-00000000000e', 'Buyer@Test')
on conflict do nothing;
insert into public.platform_admins (user_id) values ('d0000000-0000-0000-0000-00000000000d');

do $$
declare v uuid; s uuid; d date; b uuid; n int; j jsonb;
begin
  -- ---------- посторонние ----------
  set local role anon;
  perform pg_temp.throws($q$select public.admin_list_studios()$q$, 'permission denied', 'anon не видит панель продавца');
  perform pg_temp.throws($q$select public.admin_create_studio('x-test', 'X')$q$, 'permission denied', 'anon не создаёт студии');
  perform pg_temp.throws($q$select count(*) from public.platform_admins$q$, 'permission denied', 'anon не читает список продавцов');
  reset role;
  perform pg_temp.as_user('a0000000-0000-0000-0000-00000000000a');
  perform pg_temp.throws($q$select public.admin_list_studios()$q$, 'forbidden', 'владелец студии не видит панель продавца');
  perform pg_temp.throws($q$select public.admin_create_studio('x-test', 'X')$q$, 'forbidden', 'владелец студии не создаёт студии');
  perform pg_temp.throws(format($q$select public.admin_set_suspended(%L, true)$q$, pg_temp.tid('protector')), 'forbidden', 'владелец не приостанавливает студии');
  perform pg_temp.throws($q$select count(*) from public.platform_admins$q$, 'permission denied', 'владелец не читает список продавцов');
  perform pg_temp.as_admin();

  -- ---------- продавец ----------
  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform pg_temp.throws($q$select public.admin_create_studio('Bad Slug', 'X')$q$, 'bad_slug', 'адрес студии проверяется');
  perform pg_temp.throws($q$select public.admin_create_studio('admin', 'X')$q$, 'bad_slug', 'служебные адреса заняты');
  perform pg_temp.throws($q$select public.admin_create_studio('graphite', 'X')$q$, 'slug_taken', 'нельзя занять адрес другой студии');
  v := public.admin_create_studio('new-studio', 'Новая студия');
  perform pg_temp.ok(v is not null, 'продавец создаёт студию');
  j := public.admin_list_studios();
  perform pg_temp.ok(jsonb_array_length(j) >= 3 and j @> jsonb_build_array(jsonb_build_object('slug', 'new-studio', 'mode', 'preview')), 'новая студия в списке, режим preview');
  perform pg_temp.ok(public.admin_add_owner(v, 'nobody@test') = 'no_user', 'без аккаунта — no_user');
  perform pg_temp.ok(public.admin_add_owner(v, ' buyer@test ') = 'linked', 'доступ по почте без учёта регистра');
  j := public.admin_list_studios();
  perform pg_temp.ok(j @> jsonb_build_array(jsonb_build_object('slug', 'new-studio', 'owners', jsonb_build_array(jsonb_build_object('email', 'Buyer@Test')))), 'владелец виден в списке');
  perform pg_temp.as_admin();

  -- ---------- заготовка рабочая: есть свободное время, клиент записывается ----------
  s := pg_temp.svc('new-studio', 'example');
  d := pg_temp.open_day('new-studio', 2, '10:00');
  set local role anon;
  select count(*) into n from public.get_availability('new-studio', s, d, 1) where free;
  reset role;
  perform pg_temp.ok(n > 0, 'у новой студии есть свободное время');
  b := pg_temp.book('new-studio', 'example', d, '10:00', 'NEW-1');
  perform pg_temp.ok((select is_demo from public.bookings where id = b), 'запись в preview помечена как демо');

  -- ---------- владелец новой студии ----------
  perform pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
  perform pg_temp.ok((select count(*) from public.bookings) = 1, 'владелец видит только записи своей новой студии');
  update public.services set price = 55, name = 'Мойка' where id = s;
  get diagnostics n = row_count;
  perform pg_temp.ok(n = 1, 'владелец меняет услугу');
  perform pg_temp.ok(public.owner_save_service(v, s, 'Мойка', '', 55, 60, true, 0, array[pg_temp.res('new-studio', 'post-1')]) = s, 'владелец сохраняет услугу вместе с постами');
  perform pg_temp.ok((select count(*) from public.service_resources where service_id = s) = 1, 'пост привязан к услуге');
  perform pg_temp.ok(public.owner_save_service(v, null, 'Полировка', 'кузов', 120.5, 240, true, 1, null) is not null, 'новая услуга создаётся одной функцией');
  perform pg_temp.throws(format($q$select public.owner_save_service(%L, null, 'X2', '', 1, 30, true, 0, array[%L]::uuid[])$q$, v, pg_temp.res('graphite', 'post-1')), 'foreign key', 'чужой пост к услуге не привязать');
  perform pg_temp.throws(format($q$select public.owner_save_service(%L, %L, 'Чужая', '', 1, 30, true, 0, null)$q$, pg_temp.tid('graphite'), pg_temp.svc('graphite', 'wash')), 'forbidden', 'чужую услугу не изменить');
  perform pg_temp.throws(format($q$select public.owner_go_live(%L)$q$, v), 'not_ready_legal', 'без данных оператора ПД запуск запрещён');
  update public.tenants set profile = profile || jsonb_build_object('legal', jsonb_build_object('operator', 'ИП Тест', 'unp', '123456789', 'legalAddress', 'г. Минск, ул. Тест, 1', 'email', 'a@b.by', 'retentionDays', 365)) where id = v;
  perform pg_temp.throws(format($q$select public.owner_go_live(%L)$q$, v), 'not_ready_phone', 'с телефоном-заглушкой запуск запрещён');
  update public.tenants set profile = jsonb_set(profile, '{phone}', '"+375 29 765-43-21"') where id = v;
  perform pg_temp.throws(format($q$select public.owner_go_live(%L)$q$, pg_temp.tid('graphite')), 'forbidden', 'чужую студию запустить нельзя');
  perform pg_temp.ok(public.owner_go_live(v) = 1, 'владелец запускает студию, демо-запись удалена');
  perform pg_temp.ok((select mode from public.tenants where id = v) = 'live', 'студия в live');
  perform pg_temp.as_admin();
  b := pg_temp.book('new-studio', 'example', d, '11:00', 'NEW-2');
  perform pg_temp.ok(not (select is_demo from public.bookings where id = b), 'в live запись настоящая');

  -- ---------- приостановка ----------
  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform public.admin_set_suspended(v, true);
  perform pg_temp.as_admin();
  perform pg_temp.throws(format($q$select pg_temp.book('new-studio', 'example', %L, '13:00', 'NEW-3')$q$, d), 'studio_suspended', 'приостановленная студия не принимает онлайн-записи');
  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform public.admin_set_suspended(v, false);
  perform public.admin_remove_owner(v, 'e0000000-0000-0000-0000-00000000000e');
  perform pg_temp.as_admin();
  perform pg_temp.ok(pg_temp.book('new-studio', 'example', d, '13:00', 'NEW-3') is not null, 'после возобновления запись снова работает');
  perform pg_temp.as_user('e0000000-0000-0000-0000-00000000000e');
  perform pg_temp.ok((select count(*) from public.bookings) = 0, 'после отзыва доступа владелец ничего не видит');
  perform pg_temp.throws(format($q$select public.service_delete_studio(%L)$q$, v), 'permission denied', 'владелец не вызывает служебное удаление напрямую');
  perform pg_temp.as_admin();

  -- ---------- удаление ----------
  perform pg_temp.as_user('d0000000-0000-0000-0000-00000000000d');
  perform pg_temp.throws(format($q$select public.service_delete_studio(%L)$q$, v), 'permission denied', 'даже продавец удаляет только через функцию с подтверждением');
  perform pg_temp.as_admin();
  perform pg_temp.ok(public.service_tenant_owner_emails(pg_temp.tid('graphite')) @> array['owner-graphite@test'], 'служебная функция знает почты владельцев');
  perform pg_temp.ok(public.service_tenant_owner_emails(v) = '{}'::text[], 'у студии без владельцев список почт пуст');
  execute 'set local role service_role';
  perform public.service_delete_studio(v);
  execute 'reset role';

  perform pg_temp.ok(not exists (select 1 from public.tenants where id = v), 'студия удалена');
  perform pg_temp.ok(not exists (select 1 from public.bookings where tenant_id = v) and not exists (select 1 from public.services where tenant_id = v)
                     and not exists (select 1 from public.resource_occupancies where tenant_id = v) and not exists (select 1 from public.payments where tenant_id = v), 'вместе со студией удалены её записи, занятость и оплаты');
  perform pg_temp.ok(exists (select 1 from public.tenants where slug = 'graphite'), 'другие студии не тронуты');
end $$;

rollback;
