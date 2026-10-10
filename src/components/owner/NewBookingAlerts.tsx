import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { BellRinging, X } from "@phosphor-icons/react";
import { realtime, supabase } from "../../lib/supabase";
import { dayLabel, localDate, localTime } from "../../lib/time";

/**
 * Новые записи клиентов в кабинете владельца: всплывающая карточка, короткий звук, счётчик в заголовке вкладки,
 * а если вкладка свёрнута и уведомления разрешены — системное уведомление.
 * Источник: Realtime (INSERT в bookings) и, на случай если Realtime недоступен, проверка раз в 30 секунд
 * и при возвращении на вкладку. Записи, созданные самим владельцем, не показываются.
 * Работает, пока кабинет открыт (вкладка или приложение на телефоне). Web Push при закрытом кабинете отключён.
 */
type Fresh = { id: string; service_name: string; client_name: string; client_car: string; starts_at: string; created_at: string };

const seenKey = (tenantId: string) => `sgx-seen-${tenantId}`;
const store = {
  get(k: string): string | null {
    try { return localStorage.getItem(k); } catch { return null; }
  },
  set(k: string, v: string) {
    try { localStorage.setItem(k, v); } catch { /* приватный режим — живём без памяти */ }
  },
};

function beep() {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    const ctx = new Ctx();
    const tone = (freq: number, at: number) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.type = "sine";
      o.frequency.value = freq;
      g.gain.setValueAtTime(0.0001, ctx.currentTime + at);
      g.gain.exponentialRampToValueAtTime(0.25, ctx.currentTime + at + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + at + 0.25);
      o.connect(g).connect(ctx.destination);
      o.start(ctx.currentTime + at);
      o.stop(ctx.currentTime + at + 0.3);
    };
    tone(880, 0);
    tone(1320, 0.18);
    setTimeout(() => void ctx.close(), 800);
  } catch { /* браузер не дал проиграть звук до первого нажатия — не страшно */ }
}

const canNotify = () => typeof window !== "undefined" && "Notification" in window;

export function NewBookingAlerts({ tenantId, tz, base, studioName }: { tenantId: string; tz: string; base: string; studioName: string }) {
  const navigate = useNavigate();
  const [items, setItems] = useState<Fresh[]>([]);
  const [perm, setPerm] = useState<NotificationPermission | "unsupported">(canNotify() ? Notification.permission : "unsupported");
  const seen = useRef<string>(store.get(seenKey(tenantId)) ?? new Date().toISOString());
  const shown = useRef(new Set<string>());
  const busy = useRef(false);
  const baseTitle = useRef(document.title);

  const when = (b: Fresh) => `${dayLabel(localDate(b.starts_at, tz))}, ${localTime(b.starts_at, tz)}`;
  const link = (b: Fresh) => `${base}/?d=${localDate(b.starts_at, tz)}&b=${b.id}`;

  // первая отметка «просмотрено до»: записи, пришедшие пока кабинет был закрыт, покажем при следующем входе
  useEffect(() => {
    if (!store.get(seenKey(tenantId))) store.set(seenKey(tenantId), seen.current);
  }, [tenantId]);

  const check = useCallback(async () => {
    const when = (b: Fresh) => `${dayLabel(localDate(b.starts_at, tz))}, ${localTime(b.starts_at, tz)}`;
    const link = (b: Fresh) => `${base}/?d=${localDate(b.starts_at, tz)}&b=${b.id}`;
    if (busy.current) return;
    busy.current = true;
    try {
      const { data, error } = await supabase
        .from("bookings")
        .select("id, service_name, client_name, client_car, starts_at, created_at")
        .eq("tenant_id", tenantId)
        .eq("source", "client")
        .gt("created_at", seen.current)
        .order("created_at", { ascending: true })
        .limit(20);
      if (error || !data?.length) return;
      const fresh = (data as Fresh[]).filter((b) => !shown.current.has(b.id));
      if (!fresh.length) return;
      fresh.forEach((b) => shown.current.add(b.id));
      seen.current = fresh[fresh.length - 1].created_at;
      store.set(seenKey(tenantId), seen.current);
      setItems((prev) => [...fresh.reverse(), ...prev].slice(0, 5));
      beep();
      try { navigator.vibrate?.([120, 60, 120]); } catch { /* нет вибрации */ }
      if (document.hidden && canNotify() && Notification.permission === "granted") {
        for (const b of fresh.slice(0, 3)) {
          const title = `Новая запись — ${studioName}`;
          const opts: NotificationOptions = { body: `${b.client_name}: ${b.service_name}\n${when(b)} · ${b.client_car}`, tag: b.id, data: { url: link(b) } };
          const reg = await navigator.serviceWorker?.getRegistration?.().catch(() => undefined);
          if (reg) await reg.showNotification(title, opts).catch(() => undefined);
          else new Notification(title, opts);
        }
      }
    } finally {
      busy.current = false;
    }
  }, [tenantId, studioName, tz, base]);

  // Realtime + запасной опрос + проверка при возвращении на вкладку
  useEffect(() => {
    void check();
    const ch = realtime
      .channel(`owner-alerts-${tenantId}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "bookings", filter: `tenant_id=eq.${tenantId}` }, () => void check())
      .subscribe();
    const timer = window.setInterval(() => void check(), 30_000);
    const onVisible = () => { if (!document.hidden) void check(); };
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      void realtime.removeChannel(ch);
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [tenantId, check]);

  // счётчик новых записей в заголовке вкладки
  useEffect(() => {
    const t = baseTitle.current;
    document.title = items.length ? `(${items.length}) Новая запись · ${t}` : t;
    return () => { document.title = t; };
  }, [items.length]);

  const dismiss = (id: string) => setItems((prev) => prev.filter((b) => b.id !== id));
  const openOne = (b: Fresh) => { dismiss(b.id); navigate(link(b)); };
  const askPermission = async () => {
    if (!canNotify()) return;
    try { setPerm(await Notification.requestPermission()); } catch { /* старый Safari */ }
  };

  return (
    <>
      {perm === "default" && (
        <div className="notify-ask">
          <BellRinging weight="fill" aria-hidden="true" />
          <span>Показывать новые записи уведомлением, даже когда кабинет свёрнут</span>
          <button className="btn small primary" onClick={() => void askPermission()}>Включить</button>
        </div>
      )}
      <div className="alerts" aria-live="assertive" aria-atomic="false">
        {items.map((b) => (
          <div className="alert-card" role="alert" key={b.id}>
            <div className="alert-ico"><BellRinging weight="fill" aria-hidden="true" /></div>
            <div className="alert-body">
              <b>Новая запись</b>
              <span>{b.client_name} · {b.service_name}</span>
              <span className="muted">{when(b)} · {b.client_car}</span>
            </div>
            <div className="alert-actions">
              <button className="btn small primary" onClick={() => openOne(b)}>Открыть</button>
              <button className="icon-btn" aria-label="Скрыть" onClick={() => dismiss(b.id)}><X /></button>
            </div>
          </div>
        ))}
      </div>
    </>
  );
}
