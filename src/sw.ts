/// <reference lib="webworker" />
import { setCacheNameDetails } from "workbox-core";
import { precacheAndRoute, cleanupOutdatedCaches } from "workbox-precaching";
import { registerRoute, NavigationRoute } from "workbox-routing";
import { CacheFirst, NetworkFirst, StaleWhileRevalidate } from "workbox-strategies";
import { ExpirationPlugin } from "workbox-expiration";

declare const self: ServiceWorkerGlobalScope;

// Студия определяется по scope: /s/<slug>/. Кэши называются по студии.
const slug = new URL(self.registration.scope).pathname.split("/")[2] || "default";
setCacheNameDetails({ prefix: `sgx-${slug}`, suffix: "v1" });
const SHELL = `/t/${slug}/`;
const SHELL_CACHE = `sgx-${slug}-shell`;

// Общий бандл. Пути в манифесте относительны корню сайта, а файл SW лежит в /t/<slug>/ — делаем их абсолютными.
precacheAndRoute(self.__WB_MANIFEST.map((e) => (typeof e === "string" ? new URL(e, self.location.origin + "/").href : { ...e, url: new URL(e.url, self.location.origin + "/").href })));
cleanupOutdatedCaches();

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(SHELL_CACHE).then((c) => c.addAll([SHELL, `/t/${slug}/manifest.webmanifest`, `/t/${slug}/icon-192.png`])));
});
self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

// Любая страница студии (глубокие ссылки тоже) — оболочка этой студии: из сети, без сети — из кэша.
registerRoute(new NavigationRoute(async ({ request }) => {
  try {
    const res = await fetch(request);
    // переадресация на другой адрес сайта (старый адрес → новый) — отдаём браузеру, а не кэш
    if (res.ok || res.type === "opaqueredirect") return res;
    throw new Error(String(res.status));
  } catch {
    const cached = await caches.match(SHELL, { cacheName: SHELL_CACHE });
    return cached ?? Response.error();
  }
}, { allowlist: [new RegExp(`^/s/${slug}/`)] }));

// Публичные данные студии (профиль, услуги, график, фото работ) — последняя версия без сети.
// Записи, оплаты, токены и всё, что видит владелец, НЕ кэшируются.
const PUBLIC_TABLES = /\/rest\/v1\/(tenants|services|resources|working_hours|schedule_exceptions|works)\b/;
registerRoute(
  ({ url, request }) => request.method === "GET" && PUBLIC_TABLES.test(url.pathname) && isAnonRequest(request),
  new StaleWhileRevalidate({ cacheName: `sgx-${slug}-public`, plugins: [new ExpirationPlugin({ maxEntries: 40, maxAgeSeconds: 7 * 86400 })] }),
);
function isAnonRequest(req: Request) {
  // запросы владельца идут с JWT пользователя; их не кэшируем, чтобы после выхода ничего не осталось
  const auth = req.headers.get("authorization") ?? "";
  const apikey = req.headers.get("apikey") ?? "";
  return !auth || auth === `Bearer ${apikey}`;
}

// Фото студии и работ.
registerRoute(
  ({ url, request }) => request.destination === "image" && (url.pathname.startsWith(`/t/${slug}/`) || url.pathname.includes("/storage/v1/object/public/tenant-media/")),
  new CacheFirst({ cacheName: `sgx-${slug}-images`, plugins: [new ExpirationPlugin({ maxEntries: 120, maxAgeSeconds: 30 * 86400 })] }),
);

// Свободное время — только из сети (устаревшее расписание опаснее, чем «нет связи»).
registerRoute(({ url }) => url.pathname.endsWith("/rpc/get_availability"), new NetworkFirst({ cacheName: `sgx-${slug}-noop`, networkTimeoutSeconds: 8, plugins: [{ cacheWillUpdate: async () => null }] }), "POST");

// Уведомления (Web Push) сейчас отключены; обработчик оставлен на случай, если их снова включат.
self.addEventListener("push", (event) => {
  let data = { title: "Напоминание о записи", body: "", url: `/s/${slug}/my` };
  try {
    data = { ...data, ...(event.data?.json() as object) };
  } catch {
    data.body = event.data?.text() ?? "";
  }
  event.waitUntil(self.registration.showNotification(data.title, { body: data.body, data: { url: data.url }, icon: `/t/${slug}/icon-192.png`, badge: `/t/${slug}/icon-192.png`, tag: data.url }));
});
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data as { url?: string })?.url ?? `/s/${slug}/`;
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      const same = list.find((c) => c.url.startsWith(self.registration.scope));
      return same ? same.navigate(url).then((c) => c?.focus()) : self.clients.openWindow(url);
    }),
  );
});

