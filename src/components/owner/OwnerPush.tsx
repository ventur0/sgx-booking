import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { BellRinging, BellSlash, X } from "@phosphor-icons/react";
import { supabase } from "../../lib/supabase";
import { currentEndpoint, disableOwnerPush, enableOwnerPush, pushSupport } from "../../lib/push";
import { humanError } from "../../lib/errors";

/**
 * Уведомления владельцу на это устройство о новых записях и отменах клиентом — приходят, даже когда кабинет закрыт.
 * compact — строка над записями, пока это устройство не подключено; без compact — блок в «Настройки → Уведомления».
 * Если уведомления в базе ещё не настроены (нет ключей), показывается прежнее разрешение для свёрнутого кабинета.
 */
export const ownerPushFlag = (tenantId: string) => `sgx-owner-push-${tenantId}`;
const store = {
  get: (k: string) => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k: string, v: string | null) => { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch { /* приватный режим */ } },
};
type State = { ready: boolean; thisDevice: boolean; devices: number };

export function OwnerPush({ tenantId, compact = false }: { tenantId: string; compact?: boolean }) {
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  const [hidden, setHidden] = useState(() => store.get(`sgx-owner-push-hide-${tenantId}`) === "1");
  const [perm, setPerm] = useState(typeof Notification !== "undefined" ? Notification.permission : "denied");
  const q = useQuery({
    queryKey: ["owner", tenantId, "push"],
    queryFn: async () => {
      const endpoint = await currentEndpoint();
      const { data, error } = await supabase.rpc("owner_push_state", { p_tenant: tenantId, p_endpoint: endpoint });
      if (error) return { ready: false, thisDevice: false, devices: 0 } as State; // файл 19 ещё не выполнен
      const st = data as State;
      store.set(ownerPushFlag(tenantId), st.thisDevice ? "1" : null);
      return st;
    },
  });
  const refresh = () => qc.invalidateQueries({ queryKey: ["owner", tenantId, "push"] });
  const support = pushSupport();
  const st = q.data;
  if (!st) return null;

  const enable = async () => {
    setBusy(true); setMsg("");
    try {
      const r = await enableOwnerPush(tenantId);
      if (r === "denied") setMsg("Уведомления запрещены в настройках браузера для этого сайта. Разрешите их и нажмите ещё раз.");
      await refresh();
    } catch (e) { setMsg(humanError(e)); } finally { setBusy(false); }
  };
  const disable = async () => {
    setBusy(true); setMsg("");
    try { await disableOwnerPush(tenantId); await refresh(); } catch (e) { setMsg(humanError(e)); } finally { setBusy(false); }
  };
  const hide = () => { store.set(`sgx-owner-push-hide-${tenantId}`, "1"); setHidden(true); };

  // ---------- уведомления на сервере ещё не настроены: прежнее разрешение для свёрнутого кабинета ----------
  if (!st.ready) {
    if (!compact || perm !== "default" || typeof Notification === "undefined") return null;
    return (
      <div className="notify-ask">
        <BellRinging weight="fill" aria-hidden="true" />
        <span>Показывать новые записи уведомлением, когда кабинет свёрнут</span>
        <button className="btn small primary" onClick={() => void Notification.requestPermission().then(setPerm).catch(() => undefined)}>Включить</button>
      </div>
    );
  }

  if (compact) {
    if (st.thisDevice || hidden) return null;
    if (support === "unsupported") return null;
    return (
      <div className="notify-ask">
        <BellRinging weight="fill" aria-hidden="true" />
        {support === "ios-needs-install" ? (
          <span>Чтобы новые записи приходили на iPhone, даже когда кабинет закрыт: «Поделиться» → «На экран „Домой“», откройте кабинет с иконки и включите уведомления.</span>
        ) : (
          <span>Получать новые записи уведомлением на этот телефон, даже когда кабинет закрыт</span>
        )}
        {support === "ok" && <button className="btn small primary" disabled={busy} onClick={() => void enable()}>{busy ? "Включаем…" : "Включить"}</button>}
        <button className="icon-btn" aria-label="Скрыть" onClick={hide}><X /></button>
        {msg && <p className="err" role="alert">{msg}</p>}
      </div>
    );
  }

  return (
    <section className="panel stack">
      <h2>Уведомления о новых записях</h2>
      <p className="muted small">Новая запись клиента и отмена клиентом приходят уведомлением на телефон или компьютер, даже когда кабинет закрыт. Нажатие открывает запись. Можно включить на нескольких устройствах, например у вас и у администратора.</p>
      {support === "ios-needs-install" && <p className="small">На iPhone уведомления работают в приложении: «Поделиться» → «На экран „Домой“», откройте кабинет с иконки и включите здесь.</p>}
      {support === "unsupported" && <p className="small">Этот браузер не поддерживает уведомления. Откройте кабинет в Chrome, Safari (с экрана «Домой») или Edge.</p>}
      <p>{st.thisDevice ? "✓ Включены на этом устройстве." : "На этом устройстве выключены."} Всего устройств: {st.devices}.</p>
      {support === "ok" && (st.thisDevice
        ? <div><button className="btn small ghost" disabled={busy} onClick={() => void disable()}><BellSlash /> Выключить на этом устройстве</button></div>
        : <div><button className="btn small primary" disabled={busy} onClick={() => void enable()}><BellRinging /> {busy ? "Включаем…" : "Включить на этом устройстве"}</button></div>)}
      {msg && <p className="err" role="alert">{msg}</p>}
    </section>
  );
}
