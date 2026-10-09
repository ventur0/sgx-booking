import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { App } from "./App";
import { errorCode } from "./lib/errors";
// Шрифты лежат вместе с сайтом: не загружаются с серверов Google и работают без сети.
import "@fontsource/unbounded/500.css";
import "@fontsource/unbounded/600.css";
import "@fontsource/manrope/400.css";
import "@fontsource/manrope/600.css";
import "@fontsource/manrope/700.css";
import "@fontsource/jetbrains-mono/500.css";
import "./styles.css";

// Повторяем только сетевые сбои: «студия не найдена», «нет прав» и т. п. показываем сразу.
const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: (count, error) => count < 1 && errorCode(error) === null, refetchOnWindowFocus: false } },
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
);

/*
 * У каждой студии свой service worker: файл /t/<slug>/sw.js (копия общего), scope /s/<slug>/
 * и свои имена кэшей. Установленное приложение одной студии не перехватывает страницы другой.
 */
// У студий из конфигурации своя оболочка /t/<slug>/ (метка sgx-tenant); студии из панели продавца живут
// только в базе и используют общую копию /t/_default/sw.js. Scope всегда /s/<slug>/, кэши — по студии.
const m = location.pathname.match(/^\/s\/([a-z0-9-]+)\//);
const built = document.querySelector('meta[name="sgx-tenant"]')?.getAttribute("content") === m?.[1];
if (m && "serviceWorker" in navigator && import.meta.env.PROD) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register(`/t/${built ? m[1] : "_default"}/sw.js`, { scope: `/s/${m[1]}/` }).catch(() => {
      /* без service worker сайт работает как обычный */
    });
  });
}
