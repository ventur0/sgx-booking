import { useState } from "react";
import { BellRinging, CalendarPlus } from "@phosphor-icons/react";
import { enableReminder, pushSupport } from "../../lib/push";
import { downloadIcs, type CalEvent } from "../../lib/ics";
import { humanError } from "../../lib/errors";

const LABEL: Record<string, string> = {
  pending: "Напоминание за сутки включено: пришлём уведомление на это устройство.",
  processing: "Напоминание отправляется.",
  sent: "Напоминание отправлено.",
  skipped: "Это студия-образец: настоящие уведомления не отправляются. Календарь работает.",
  cancelled: "Напоминание отменено.",
  failed: "Уведомление не удалось доставить. Добавьте запись в календарь.",
};

/**
 * Напоминание за сутки. Состояние берётся с сервера (outbox), а не предполагается.
 * На iPhone в обычной вкладке Safari push недоступен — говорим об этом прямо и предлагаем календарь.
 */
export function Reminder({ bookingId, token, event, serverState, onChanged }: {
  bookingId: string; token: string; event: CalEvent; serverState?: string; onChanged?: () => void;
}) {
  const support = pushSupport();
  const [state, setState] = useState<string | undefined>(serverState);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [icsDone, setIcsDone] = useState(false);
  const active = state && state !== "none";

  return (
    <section className="panel reminder" aria-label="Напоминание">
      <h3>Напоминание за сутки</h3>
      {active && <p className={`notice ${state === "failed" ? "warn" : state === "skipped" ? "info" : "ok"}`}>{LABEL[state] ?? state}</p>}
      {!active && support === "ok" && (
        <button className="btn primary small" disabled={busy} onClick={async () => {
          setBusy(true); setErr("");
          try {
            const r = await enableReminder(bookingId, token);
            if (r === "denied") setErr("Уведомления запрещены в настройках браузера. Добавьте запись в календарь.");
            else { setState(r); onChanged?.(); }
          } catch (e) { setErr(humanError(e)); }
          finally { setBusy(false); }
        }}>
          <BellRinging weight="fill" /> {busy ? "Включаем…" : "Включить напоминание"}
        </button>
      )}
      {!active && support === "ios-needs-install" && (
        <p className="muted small">На iPhone уведомления работают только у приложения на экране «Домой»: нажмите «Поделиться» → «На экран „Домой“», откройте запись оттуда. Или добавьте запись в календарь.</p>
      )}
      {!active && (support === "unsupported" || support === "no-key") && (
        <p className="muted small">На этом устройстве уведомления недоступны. Добавьте запись в календарь — в нём уже есть напоминание за 24 часа.</p>
      )}
      {err && <p className="err">{err}</p>}
      <div className="row">
        <button className="btn small" onClick={() => { downloadIcs(event); setIcsDone(true); }}>
          <CalendarPlus /> {icsDone ? "Файл календаря скачан" : "Добавить в календарь (.ics)"}
        </button>
      </div>
      {icsDone && <p className="muted small">Откройте скачанный файл, чтобы календарь добавил событие. Мы не видим, сохранили ли вы его.</p>}
    </section>
  );
}
