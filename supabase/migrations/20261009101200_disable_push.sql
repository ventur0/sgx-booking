-- =====================================================================
-- 13. Напоминания через Web Push отключены (по решению владельца сервиса).
--     Клиенту остаётся событие календаря (.ics) с напоминанием за 24 часа.
--     Расписание отправки снимается, ожидающие задания помечаются как пропущенные, подписки удаляются.
--     (Новые задания outbox по-прежнему создаются, но их никто не отправляет — это безопасно.)
--     Ежедневная очистка персональных данных (sgx-purge-personal-data) остаётся.
-- =====================================================================
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'sgx-send-reminders';
  end if;
end $$;

update public.notification_jobs set status = 'skipped', last_error = 'push disabled'
 where status in ('pending', 'processing');

delete from public.push_subscriptions;
