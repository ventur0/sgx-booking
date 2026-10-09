import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { App } from "./App";
// Шрифты лежат вместе с сайтом: не загружаются с серверов Google и работают без сети.
import "@fontsource/unbounded/500.css";
import "@fontsource/unbounded/600.css";
import "@fontsource/manrope/400.css";
import "@fontsource/manrope/600.css";
import "@fontsource/manrope/700.css";
import "@fontsource/jetbrains-mono/500.css";
import "./styles.css";

const queryClient = new QueryClient({ defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } } });

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
const m = location.pathname.match(/^\/s\/([a-z0-9-]+)\//);
if (m && "serviceWorker" in navigator && import.meta.env.PROD) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register(`/t/${m[1]}/sw.js`, { scope: `/s/${m[1]}/` }).catch(() => {
      /* без service worker сайт работает как обычный */
    });
  });
}
