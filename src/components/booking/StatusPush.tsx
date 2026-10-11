import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import { BellRinging, BellSlash } from "@phosphor-icons/react";
import { disableStatusPush, enableStatusPush, pushSupport } from "../../lib/push";
import { humanError } from "../../lib/errors";

/**
 * «Сообщить, когда машина будет готова»: уведомление на телефон клиента, когда студия принимает машину,
 * отмечает её готовой, переносит или отменяет запись. Работает, даже если сайт закрыт.
 */
export function StatusPush({ bookingId, token, on: onProp, ready: readyProp, onChanged }: { bookingId: string; token: string; on?: boolean; ready?: boolean; onChanged?: () => void }) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  const [localOn, setLocalOn] = useState<boolean | null>(null);
  // на экране «Записано» данных записи с сервера ещё нет — узнаём, настроены ли уведомления, по публичному ключу
  const key = useQuery({
    queryKey: ["push-key"],
    enabled: readyProp === undefined,
    staleTime: 10 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("get_push_key");
      if (error) throw error;
      return (data as string | null) ?? null;
    },
  });
  const ready = readyProp ?? !!key.data;
  const on = localOn ?? !!onProp;
  if (!ready) return null;
  const support = pushSupport();

  const enable = async () => {
    setBusy(true); setMsg("");
    try {
      const r = await enableStatusPush(bookingId, token);
      if (r === "denied") setMsg("Уведомления запрещены в настройках браузера. Разрешите их для этого сайта и нажмите ещё раз.");
      else if (r === "not_configured") setMsg("Уведомления пока недоступны.");
      else setLocalOn(true);
      onChanged?.();
    } catch (e) {
      setMsg(humanError(e));
    } finally {
      setBusy(false);
    }
  };
  const disable = async () => {
    setBusy(true); setMsg("");
    try { await disableStatusPush(bookingId, token); setLocalOn(false); onChanged?.(); } catch (e) { setMsg(humanError(e)); } finally { setBusy(false); }
  };

  return (
    <section className="panel reminder" aria-label="Уведомления о машине">
      <h3>Уведомления о машине</h3>
      {on ? (
        <>
          <p className="small"><BellRinging weight="fill" aria-hidden="true" /> Включены: сообщим, когда машину примут и когда она будет готова.</p>
          <button className="btn small ghost" disabled={busy} onClick={() => void disable()}><BellSlash /> Отключить</button>
        </>
      ) : support === "ios-needs-install" ? (
        <p className="muted small">На iPhone уведомления работают в приложении: нажмите «Поделиться» → «На экран „Домой“», откройте сайт с иконки и включите уведомления в «Моя запись».</p>
      ) : support === "unsupported" ? (
        <p className="muted small">Этот браузер не поддерживает уведомления. Статус обновляется на этой странице автоматически.</p>
      ) : (
        <>
          <p className="muted small">Пришлём уведомление на телефон, когда машину примут и когда она будет готова, даже если сайт закрыт.</p>
          <button className="btn small primary" disabled={busy} onClick={() => void enable()}><BellRinging /> {busy ? "Включаем…" : "Сообщить о готовности"}</button>
        </>
      )}
      {msg && <p className="err" role="alert">{msg}</p>}
    </section>
  );
}
