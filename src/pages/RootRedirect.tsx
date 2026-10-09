import { useEffect, useState } from "react";
import { Navigate } from "react-router-dom";
import { supabase } from "../lib/supabase";
import { Empty, Loading } from "../components/ui/States";

/**
 * Корень сайта. На собственном домене студии (zapis.studio.by) открывает эту студию,
 * на основном адресе сервиса — студию по умолчанию.
 */
export function RootRedirect() {
  const [to, setTo] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    const host = location.hostname.toLowerCase();
    const fallback = __DEFAULT_TENANT__ ? `/s/${__DEFAULT_TENANT__}/` : "";
    if (host === "localhost" || host.endsWith(".pages.dev") || /^[\d.]+$/.test(host)) {
      setTo(fallback);
      return;
    }
    void supabase.from("tenants").select("slug").eq("custom_domain", host.replace(/^www\./, "")).maybeSingle()
      .then(({ data }) => alive && setTo(data?.slug ? `/s/${data.slug}/` : fallback), () => alive && setTo(fallback));
    return () => { alive = false; };
  }, []);
  if (to === null) return <main className="wrap pad-top"><Loading label="Открываем студию" /></main>;
  if (!to) return <main className="wrap pad-top"><Empty>Откройте ссылку студии вида /s/название/, которую вам прислали.</Empty></main>;
  return <Navigate to={to} replace />;
}
