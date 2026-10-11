-- =====================================================================
-- 17. Уведомления в Telegram убраны. Если файл 16-telegram.sql уже выполняли — удаляем всё, что он создал.
-- Если не выполняли — этот файл ничего не меняет.
-- =====================================================================
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'sgx-telegram';
  end if;
exception when others then null;
end $$;

drop trigger if exists bookings_tg_notify on public.bookings;
drop function if exists public.tg_booking_notify();
drop function if exists public.tg_tick();
drop function if exists public.tg_handle_updates(jsonb);
drop function if exists public.tg_send(bigint, text);
drop function if exists public.tg_when(timestamptz, text);
drop function if exists public.admin_tg_get();
drop function if exists public.admin_tg_set(text, text, text);
drop function if exists public.owner_tg_link(uuid);
drop function if exists public.owner_tg_list(uuid);
drop function if exists public.owner_tg_remove(uuid, uuid);
drop table if exists public.tg_chats;
drop table if exists public.tg_link_codes;
drop table if exists public.tg_config;
