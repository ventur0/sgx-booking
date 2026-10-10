import { createClient } from "@supabase/supabase-js";

const direct = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
if (!direct || !anon) throw new Error("Не заданы VITE_SUPABASE_URL и VITE_SUPABASE_ANON_KEY (см. .env.example)");

/**
 * На опубликованном сайте браузер ходит в Supabase через адрес самого сайта (/sb, functions/sb):
 * в некоторых сетях домен supabase.co недоступен, а адрес сайта — открыт.
 * В разработке (vite dev) — напрямую. VITE_SUPABASE_PROXY=off отключает прокси.
 */
const useProxy = import.meta.env.PROD && import.meta.env.VITE_SUPABASE_PROXY !== "off" && typeof location !== "undefined";
export const supabaseUrl = useProxy ? `${location.origin}/sb` : direct.replace(/\/+$/, "");

/** В браузер попадает только публичный ключ. Права проверяют RLS, GRANT и функции базы. */
export const supabase = createClient(supabaseUrl, anon, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: "sgx-owner-auth" },
});

/**
 * Realtime (живые обновления в кабинете) работает по WebSocket. Cloudflare пропускает его через /sb,
 * а Vercel — нет, поэтому сборка для Vercel (__REALTIME_VIA_PROXY__ = false) подключает Realtime
 * напрямую к *.supabase.co. Отдельный клиент без своей сессии: токен владельца передаём из основного.
 * Если supabase.co в сети недоступен, кабинет всё равно обновляется периодическим запросом (owner.ts).
 */
const realtimeDirect = useProxy && !__REALTIME_VIA_PROXY__;
export const realtime = realtimeDirect
  ? createClient(direct.replace(/\/+$/, ""), anon, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, storageKey: "sgx-realtime" } })
  : supabase;
if (realtimeDirect) {
  const setToken = (token: string | undefined) => void realtime.realtime.setAuth(token ?? null);
  void supabase.auth.getSession().then(({ data }) => setToken(data.session?.access_token));
  supabase.auth.onAuthStateChange((_e, session) => setToken(session?.access_token));
}

/** Фото из хранилища Supabase, сохранённые с прямым адресом *.supabase.co, открываем тоже через прокси. */
const directOrigin = direct.replace(/\/+$/, "");
export function mediaUrl(u: string | undefined | null): string | undefined {
  if (!u) return undefined;
  return useProxy && u.startsWith(directOrigin + "/storage/") ? supabaseUrl + u.slice(directOrigin.length) : u;
}

/** Публичный адрес файла в хранилище — всегда прямой (*.supabase.co), чтобы в базе не было адреса сайта. */
export const storagePublicUrl = (bucket: string, path: string) => `${directOrigin}/storage/v1/object/public/${bucket}/${path}`;
