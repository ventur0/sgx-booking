/**
 * Функция сайта /api/push (Vercel, Node). Её вызывает база (pg_net) при смене статуса записи:
 * тело { job, nonce }. Функция забирает задание по одноразовому nonce (push_job_claim — без верного nonce
 * задание не выдаётся), отправляет Web Push на все устройства клиента и отмечает результат (push_job_done).
 * Своих секретов у функции нет: ключи VAPID приходят из базы вместе с заданием, адрес и публичный ключ
 * Supabase подставляются при сборке (они и так публичные).
 */
import type { IncomingMessage, ServerResponse } from "node:http";
import webpush from "web-push";

declare const __SUPABASE_URL__: string;
declare const __SUPABASE_KEY__: string;

type Claim = {
  vapidPublic: string; vapidPrivate: string; subject: string; topic: string;
  payload: { title: string; body: string; url: string };
  subscriptions: { endpoint: string; p256dh: string; auth: string }[];
};

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<{ ok: boolean; status: number; data: T | null }> {
  const r = await fetch(`${__SUPABASE_URL__}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: __SUPABASE_KEY__, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const text = await r.text();
  let data: T | null = null;
  try { data = text ? (JSON.parse(text) as T) : null; } catch { /* не JSON */ }
  return { ok: r.ok, status: r.status, data };
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let s = "";
    req.setEncoding("utf8");
    req.on("data", (c: string) => { s += c; if (s.length > 4096) { reject(new Error("too_large")); req.destroy(); } });
    req.on("end", () => resolve(s));
    req.on("error", reject);
  });
}

function send(res: ServerResponse, status: number, body: unknown) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

export default async function handler(req: IncomingMessage, res: ServerResponse) {
  if (req.method !== "POST") return send(res, 405, { error: "method_not_allowed" });
  let job = "", nonce = "";
  try {
    const b = JSON.parse(await readBody(req)) as { job?: unknown; nonce?: unknown };
    job = String(b.job ?? "");
    nonce = String(b.nonce ?? "");
  } catch {
    return send(res, 400, { error: "bad_request" });
  }
  if (!/^[0-9a-f-]{36}$/.test(job) || !/^[a-f0-9]{32}$/.test(nonce)) return send(res, 400, { error: "bad_request" });

  const claim = await rpc<Claim>("push_job_claim", { p_job: job, p_nonce: nonce });
  if (!claim.ok || !claim.data) return send(res, claim.status === 404 || claim.status === 400 ? 404 : 502, { error: "not_found" });
  const c = claim.data;

  webpush.setVapidDetails(c.subject, c.vapidPublic, c.vapidPrivate);
  const payload = JSON.stringify(c.payload);
  const gone: string[] = [];
  let sent = 0;
  let lastError = "";
  await Promise.all(c.subscriptions.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload,
        { TTL: 12 * 3600, urgency: "high", topic: c.topic, timeout: 10_000 });
      sent++;
    } catch (e) {
      const status = (e as { statusCode?: number }).statusCode;
      if (status === 404 || status === 410) gone.push(s.endpoint);
      else lastError = `${status ?? ""} ${(e as Error).message}`.trim().slice(0, 300);
    }
  }));
  // нет живых подписок — отправлять больше некуда, задание закрываем как выполненное
  const ok = sent > 0 || !lastError;
  await rpc("push_job_done", { p_job: job, p_nonce: nonce, p_ok: ok, p_error: ok ? null : lastError, p_gone: gone.length ? gone : null });
  return send(res, 200, { sent, gone: gone.length, ok });
}
