import { supabase } from "./supabase";

export type PushSupport = "ok" | "unsupported" | "ios-needs-install";

/** На iPhone Web Push работает только в приложении, добавленном на экран «Домой» (iOS 16.4+). */
export function pushSupport(): PushSupport {
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const standalone = matchMedia("(display-mode: standalone)").matches || (navigator as { standalone?: boolean }).standalone === true;
  if (ios && !standalone) return "ios-needs-install";
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) return "unsupported";
  return "ok";
}

function b64ToBytes(b64: string) {
  const pad = "=".repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

/** Разрешение браузера → подписка этого устройства (с ключом сервиса). Общая для клиента и владельца. */
async function subscribeDevice(): Promise<{ endpoint: string; keys: { p256dh: string; auth: string } } | "denied" | "not_configured"> {
  const { data: key, error: keyErr } = await supabase.rpc("get_push_key");
  if (keyErr) throw keyErr;
  if (!key) return "not_configured";
  const perm = await Notification.requestPermission();
  if (perm !== "granted") return "denied";
  const reg = await navigator.serviceWorker.ready;
  let sub = await reg.pushManager.getSubscription();
  // подписка от другого ключа (например, после смены ключей) не подойдёт — пересоздаём
  const cur = sub?.options.applicationServerKey ? new Uint8Array(sub.options.applicationServerKey) : null;
  const want = b64ToBytes(key as string);
  if (sub && (!cur || cur.length !== want.length || cur.some((v, i) => v !== want[i]))) { await sub.unsubscribe(); sub = null; }
  sub ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: want });
  return sub.toJSON() as { endpoint: string; keys: { p256dh: string; auth: string } };
}

/** Адрес подписки этого устройства, если она уже есть (без запроса разрешения). */
export async function currentEndpoint(): Promise<string | null> {
  try {
    if (!("serviceWorker" in navigator)) return null;
    const reg = await navigator.serviceWorker.getRegistration();
    return (await reg?.pushManager.getSubscription())?.endpoint ?? null;
  } catch {
    return null;
  }
}

export async function enableStatusPush(bookingId: string, token: string): Promise<"ok" | "denied" | "not_configured"> {
  const j = await subscribeDevice();
  if (typeof j === "string") return j;
  const { error } = await supabase.rpc("subscribe_status_push", { p_booking: bookingId, p_token: token, p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth });
  if (error) throw error;
  return "ok";
}

/** Владелец: уведомления о новых записях студии на это устройство. */
export async function enableOwnerPush(tenantId: string): Promise<"ok" | "denied" | "not_configured"> {
  const j = await subscribeDevice();
  if (typeof j === "string") return j;
  const { error } = await supabase.rpc("owner_push_subscribe", { p_tenant: tenantId, p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth });
  if (error) throw error;
  return "ok";
}

export async function disableOwnerPush(tenantId: string) {
  const endpoint = await currentEndpoint();
  if (!endpoint) return;
  const { error } = await supabase.rpc("owner_push_unsubscribe", { p_tenant: tenantId, p_endpoint: endpoint });
  if (error) throw error;
}

export async function disableStatusPush(bookingId: string, token: string) {
  const { error } = await supabase.rpc("unsubscribe_status_push", { p_booking: bookingId, p_token: token });
  if (error) throw error;
}
