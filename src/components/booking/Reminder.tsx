import { useState } from "react";
import { CalendarPlus } from "@phosphor-icons/react";
import { downloadIcs, type CalEvent } from "../../lib/ics";

/**
 * Напоминание о записи: событие для календаря телефона или компьютера (.ics) с напоминанием за 24 часа.
 * Уведомления с сервера (Web Push) отключены по решению владельца сервиса.
 */
export function Reminder({ event }: { bookingId: string; token: string; event: CalEvent; serverState?: string; onChanged?: () => void }) {
  const [icsDone, setIcsDone] = useState(false);
  return (
    <section className="panel reminder" aria-label="Напоминание">
      <h3>Напоминание за сутки</h3>
      <p className="muted small">Добавьте запись в календарь — в событии уже есть напоминание за 24 часа.</p>
      <div className="row">
        <button className="btn small" onClick={() => { downloadIcs(event); setIcsDone(true); }}>
          <CalendarPlus /> {icsDone ? "Файл календаря скачан" : "Добавить в календарь (.ics)"}
        </button>
      </div>
      {icsDone && <p className="muted small">Откройте скачанный файл, чтобы календарь добавил событие.</p>}
    </section>
  );
}
