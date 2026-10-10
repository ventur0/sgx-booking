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

/** Фото из хранилища Supabase, сохранённые с прямым адресом *.supabase.co, открываем тоже через прокси. */
const directOrigin = direct.replace(/\/+$/, "");
export function mediaUrl(u: string | undefined | null): string | undefined {
  if (!u) return undefined;
  return useProxy && u.startsWith(directOrigin + "/storage/") ? supabaseUrl + u.slice(directOrigin.length) : u;
}

/** Публичный адрес файла в хранилище — всегда прямой (*.supabase.co), чтобы в базе не было адреса сайта. */
export const storagePublicUrl = (bucket: string, path: string) => `${directOrigin}/storage/v1/object/public/${bucket}/${path}`;
