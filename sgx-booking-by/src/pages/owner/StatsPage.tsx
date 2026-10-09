import { useState } from "react";
import { useStudioCtx } from "../client/StudioLayout";
import { useStats } from "../../data/owner";
import { addDays, dayLabel, todayIn, weekStart } from "../../lib/time";
import { moneyBYN } from "../../shared/by";
import { ErrorState, Loading } from "../../components/ui/States";

type Preset = "today" | "week" | "month" | "custom";

/** Итоги считает SQL (owner_stats) в часовом поясе студии. Деньги — только реально полученные. */
export function StatsPage() {
  const { studio } = useStudioCtx();
  const tz = studio.tenant.timezone;
  const today = todayIn(tz);
  const [preset, setPreset] = useState<Preset>("week");
  const [custom, setCustom] = useState({ from: addDays(today, -30), to: today });
  const range =
    preset === "today" ? { from: today, to: today } :
    preset === "week" ? { from: weekStart(today), to: addDays(weekStart(today), 6) } :
    preset === "month" ? { from: `${today.slice(0, 8)}01`, to: addDays(`${addDays(`${today.slice(0, 8)}28`, 4).slice(0, 8)}01`, -1) } : custom;
  const q = useStats(studio.tenant.id, range.from, range.to);

  return (
    <>
      <div className="seg" role="group" aria-label="Период">
        {(["today", "week", "month", "custom"] as Preset[]).map((p) => (
          <button key={p} aria-pressed={preset === p} onClick={() => setPreset(p)}>{{ today: "Сегодня", week: "Неделя", month: "Месяц", custom: "Период" }[p]}</button>
        ))}
      </div>
      {preset === "custom" && (
        <div className="row">
          <input className="input mono" type="date" aria-label="С" value={custom.from} onChange={(e) => e.target.value && setCustom({ ...custom, from: e.target.value })} />
          <input className="input mono" type="date" aria-label="По" value={custom.to} onChange={(e) => e.target.value && setCustom({ ...custom, to: e.target.value })} />
        </div>
      )}
      <p className="muted small">{dayLabel(range.from)} — {dayLabel(range.to)} · время {tz}</p>
      {q.isLoading ? <Loading /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : q.data && (
        <>
          <div className="stats">
            <div className="stat"><div className="v">{q.data.visits}</div><div className="l">Заездов</div></div>
            <div className="stat"><div className="v">{q.data.completed}</div><div className="l">Выполнено заказов</div></div>
            <div className="stat"><div className="v">{q.data.cancelled}</div><div className="l">Отменено</div></div>
          </div>
          <div className="panel">
            <h3>Деньги, полученные за период</h3>
            <dl className="summary">
              <dt>Оплаты</dt><dd className="mono">{moneyBYN(q.data.received)}</dd>
              <dt>Возвраты</dt><dd className="mono">−{moneyBYN(q.data.refunded)}</dd>
              <dt>Итого получено</dt><dd className="mono strong">{moneyBYN(q.data.net)}</dd>
            </dl>
            <p className="muted small">Считаются по дате оплаты, а не по дате записи.</p>
          </div>
          <div className="panel">
            <h3>Ожидаемая стоимость</h3>
            <p className="mono strong">{moneyBYN(q.data.expected)}</p>
            <p className="muted small">Цена ещё не выполненных записей этого периода. Это не выручка: деньги появятся, когда вы внесёте оплату.</p>
          </div>
        </>
      )}
    </>
  );
}
