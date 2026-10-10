/**
 * Прокси к Supabase через адрес сайта: браузер обращается к https://<сайт>/sb/..., а не к *.supabase.co.
 * Нужен для сетей, где домен supabase.co недоступен (фильтры провайдеров, рабочие сети).
 * Пропускает только API Supabase (REST, Auth, Storage, Edge Functions, Realtime) одного проекта —
 * адрес берётся из переменной VITE_SUPABASE_URL проекта Cloudflare Pages, а не из запроса.
 * Права по-прежнему проверяет база (RLS, GRANT); прокси ничего не добавляет и не хранит.
 */
type Ctx = { request: Request; env: { VITE_SUPABASE_URL?: string; SUPABASE_URL?: string } };

const ALLOWED = /^\/sb\/(rest|auth|storage|functions|realtime)\/v1(\/|$)/;

export const onRequest = async ({ request, env }: Ctx): Promise<Response> => {
  const upstream = (env.SUPABASE_URL || env.VITE_SUPABASE_URL || "").replace(/\/+$/, "");
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(upstream)) {
    return new Response(JSON.stringify({ error: "proxy_not_configured" }), { status: 500, headers: { "content-type": "application/json" } });
  }
  const url = new URL(request.url);
  if (!ALLOWED.test(url.pathname)) return new Response("Not found", { status: 404 });

  const target = upstream + url.pathname.slice(3) + url.search;
  const headers = new Headers(request.headers);
  for (const h of ["host", "cookie", "cf-connecting-ip", "x-forwarded-host", "x-real-ip"]) headers.delete(h);

  // WebSocket (Realtime) пробрасывается тем же fetch: Cloudflare вернёт 101 с сокетом.
  return fetch(target, {
    method: request.method,
    headers,
    body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
    redirect: "manual",
  });
};
