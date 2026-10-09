-- =====================================================================
-- 5. Права доступа: RLS на всех таблицах и строгие GRANT.
--    anon видит только публичный профиль, услуги, ресурсы (названия), график и фото работ.
--    Записи, занятость, платежи, токены, подписки, outbox — никогда.
-- =====================================================================

alter table public.tenants              enable row level security;
alter table public.tenant_members       enable row level security;
alter table public.resources            enable row level security;
alter table public.services             enable row level security;
alter table public.service_resources    enable row level security;
alter table public.working_hours        enable row level security;
alter table public.schedule_exceptions  enable row level security;
alter table public.works                enable row level security;
alter table public.bookings             enable row level security;
alter table public.resource_occupancies enable row level security;
alter table public.payments             enable row level security;
alter table public.push_subscriptions   enable row level security;
alter table public.notification_jobs    enable row level security;
alter table public.rate_counters        enable row level security;

-- Сначала отзываем всё, что Supabase выдаёт по умолчанию
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- ---------- публичные данные студии ----------
grant select (id, slug, mode, timezone, profile, updated_at) on public.tenants to anon, authenticated;
grant select on public.services, public.resources, public.service_resources, public.working_hours,
                public.schedule_exceptions, public.works to anon, authenticated;

create policy tenants_public on public.tenants for select using (true);
create policy services_public on public.services for select using (active or public.is_member(tenant_id));
create policy resources_public on public.resources for select using (active or public.is_member(tenant_id));
create policy service_resources_public on public.service_resources for select using (true);
create policy hours_public on public.working_hours for select using (true);
create policy exceptions_public on public.schedule_exceptions for select using (true);
create policy works_public on public.works for select using (true);

-- ---------- владелец: настройки своей студии ----------
grant update (profile) on public.tenants to authenticated;
create policy tenants_owner_update on public.tenants for update to authenticated
  using (public.is_member(id)) with check (public.is_member(id));

grant insert, update, delete on public.services, public.resources, public.service_resources,
                                public.working_hours, public.schedule_exceptions, public.works to authenticated;
create policy services_owner on public.services for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy resources_owner on public.resources for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy service_resources_owner on public.service_resources for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy hours_owner on public.working_hours for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy exceptions_owner on public.schedule_exceptions for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));
create policy works_owner on public.works for all to authenticated using (public.is_member(tenant_id)) with check (public.is_member(tenant_id));

-- ---------- владелец: чтение записей, занятости и платежей своей студии ----------
grant select on public.tenant_members to authenticated;
create policy members_self on public.tenant_members for select to authenticated using (user_id = auth.uid());

grant select (id, tenant_id, service_id, resource_id, status, starts_at, ends_at, buffer_min, service_name, price,
              client_name, client_phone, client_car, source, is_demo, consent_at, cancelled_by, cancelled_at,
              anonymized_at, created_at, updated_at)
  on public.bookings to authenticated; -- без access_token_hash и idempotency_key
create policy bookings_owner_read on public.bookings for select to authenticated using (public.is_member(tenant_id));

grant select on public.resource_occupancies to authenticated;
create policy occupancies_owner_read on public.resource_occupancies for select to authenticated using (public.is_member(tenant_id));

grant select on public.payments to authenticated;
create policy payments_owner_read on public.payments for select to authenticated using (public.is_member(tenant_id));

grant select (id, booking_id, kind, run_at, status, attempts, last_error) on public.notification_jobs to authenticated;
create policy jobs_owner_read on public.notification_jobs for select to authenticated using (public.is_member(tenant_id));

-- push_subscriptions и rate_counters: без политик и без грантов — только service role и функции

-- ---------- функции ----------
grant execute on function public.get_availability(text, uuid, date, integer) to anon, authenticated;
grant execute on function public.create_booking(text, uuid, date, time, text, text, text, uuid, text, boolean, text) to anon, authenticated;
grant execute on function public.get_my_booking(uuid, text) to anon, authenticated;
grant execute on function public.cancel_my_booking(uuid, text) to anon, authenticated;
grant execute on function public.save_push_subscription(uuid, text, text, text, text) to anon, authenticated;

grant execute on function public.is_member(uuid) to anon, authenticated;
grant execute on function public.owner_create_booking(uuid, uuid, date, time, text, text, text, uuid, uuid) to authenticated;
grant execute on function public.owner_move_booking(uuid, date, time, uuid) to authenticated;
grant execute on function public.owner_set_status(uuid, text) to authenticated;
grant execute on function public.owner_add_payment(uuid, text, numeric, text) to authenticated;
grant execute on function public.owner_block_resource(uuid, timestamptz, timestamptz, text) to authenticated;
grant execute on function public.owner_unblock(uuid) to authenticated;
grant execute on function public.owner_stats(uuid, date, date) to authenticated;
grant execute on function public.owner_anonymize_booking(uuid) to authenticated;

-- claim/complete/purge и внутренние функции — только service_role (Edge Function и Cron)
grant execute on function public.claim_notification_jobs(integer, integer) to service_role;
grant execute on function public.complete_notification_job(uuid, text, text) to service_role;
grant execute on function public.purge_expired_personal_data() to service_role;

-- Функции, которые используются внутри политик и выражений, должны быть доступны вызывающей роли
grant execute on function public.norm_phone(text) to anon, authenticated;

-- Realtime для кабинета (уважает RLS)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.bookings, public.payments, public.resource_occupancies;
  end if;
end $$;

-- Фото: публичное чтение, запись только участником студии в её папку <tenant_id>/owner/...
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tenant-media', 'tenant-media', true, 8388608, array['image/jpeg', 'image/png', 'image/webp', 'image/svg+xml'])
on conflict (id) do nothing;

create policy media_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'tenant-media' and (storage.foldername(name))[2] = 'owner'
              and public.is_member(((storage.foldername(name))[1])::uuid));
create policy media_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'tenant-media' and (storage.foldername(name))[2] = 'owner'
         and public.is_member(((storage.foldername(name))[1])::uuid));
