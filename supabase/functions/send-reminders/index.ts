// Supabase Edge Function: отправка напоминаний за сутки из outbox notification_jobs.
// Запускается Supabase Cron каждые 5 минут (SETUP.md). Секреты: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY,
// VAPID_SUBJECT, PUBLIC_SITE_URL, CRON_SECRET. SUPABASE_URL и SUPABASE_SERVICE_ROLE_KEY задаёт платформа.
//
// Надёжность: claim_notification_jobs выдаёт задания с арендой (lease) и FOR UPDATE SKIP LOCKED,
// поэтому параллельные запуски не отправят одно напоминание дважды; упавший воркер вернёт задание
// в очередь по истечении аренды. Перенос/отмена записи отменяют задание в той же транзакции (sync_reminder).
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

type Row = { job_id: string; booking_id: string; tenant_slug: string; tenant_name: string; timezone: string; service_name: string; starts_at: string; address: string; endpoint: string; p256dh: string; auth: string };

Deno.serve(async (req) => {
  if (req.headers.get("authorization") !== `Bearer ${Deno.env.get("CRON_SECRET")}`) return new Response("forbidden", { status: 403 });
  const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY");
  if (!pub || !priv) return Response.json({ error: "VAPID keys are not configured" }, { status: 500 });
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com", pub, priv);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const site = (Deno.env.get("PUBLIC_SITE_URL") ?? "").replace(/\/$/, "");

  const { data, error } = await sb.rpc("claim_notification_jobs", { p_limit: 50, p_lease_seconds: 120 });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const byJob = new Map<string, Row[]>();
  for (const r of (data ?? []) as Row[]) byJob.set(r.job_id, [...(byJob.get(r.job_id) ?? []), r]);

  let sent = 0, failed = 0;
  for (const [jobId, rows] of byJob) {
    const r = rows[0];
    const when = new Intl.DateTimeFormat("ru-BY", { timeZone: r.timezone, day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" }).format(new Date(r.starts_at));
    const payload = JSON.stringify({ title: `Завтра: ${r.service_name}`, body: `${r.tenant_name}, ${when}. ${r.address}`, url: `${site}/s/${r.tenant_slug}/my/${r.booking_id}` });
    let ok = false, lastErr = "";
    for (const s of rows) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 6 * 3600, urgency: "normal", topic: jobId.slice(0, 32) });
        ok = true;
      } catch (e) {
        const status = (e as { statusCode?: number }).statusCode;
        lastErr = `${status ?? ""} ${(e as Error).message}`.trim();
        if (status === 404 || status === 410) await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint); // подписка больше не существует
      }
    }
    await sb.rpc("complete_notification_job", { p_job: jobId, p_status: ok ? "sent" : "pending", p_error: ok ? null : lastErr });
    ok ? sent++ : failed++;
  }
  return Response.json({ claimed: byJob.size, sent, retry_or_failed: failed });
});
