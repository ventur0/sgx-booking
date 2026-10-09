import { useState, type FormEvent } from "react";
import { useStudioCtx } from "../client/StudioLayout";
import { parseRange, useBlocks, useOwnerActions } from "../../data/owner";
import { addDays, atLocal, dayLabel, dayStart, localDate, localTime, todayIn } from "../../lib/time";
import { humanError } from "../../lib/errors";
import { Empty, ErrorState, Field, Loading, Notice } from "../../components/ui/States";

/** Блокировка поста (ремонт, личные дела). Использует ту же таблицу занятости, что и записи. */
export function BlocksPage() {
  const { studio } = useStudioCtx();
  const { tenant, resources } = studio;
  const tz = tenant.timezone;
  const today = todayIn(tz);
  const q = useBlocks(tenant.id, dayStart(today, tz).toISOString(), dayStart(addDays(today, 90), tz).toISOString());
  const act = useOwnerActions(tenant.id, tenant.slug);
  const active = resources.filter((r) => r.active);
  const [f, setF] = useState({ resourceId: active[0]?.id ?? "", fromDay: today, fromTime: "09:00", toDay: today, toTime: "18:00", note: "" });
  const [err, setErr] = useState("");

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const from = atLocal(f.fromDay, f.fromTime, tz), to = atLocal(f.toDay, f.toTime, tz);
    if (!(to > from)) return setErr("Конец должен быть позже начала");
    setErr("");
    act.block.mutate({ resourceId: f.resourceId, from: from.toISOString(), to: to.toISOString(), note: f.note }, { onError: (x) => setErr(humanError(x)), onSuccess: () => setF({ ...f, note: "" }) });
  };

  return (
    <>
      <form className="panel stack" onSubmit={submit} noValidate>
        <h2>Заблокировать пост</h2>
        <p className="muted small">На это время онлайн-запись на пост будет недоступна. Блок нельзя поставить поверх существующей записи. Закрыть весь день — в «Настройки → График».</p>
        <Field id="bl-res" label="Пост"><select className="input" id="bl-res" value={f.resourceId} onChange={(e) => setF({ ...f, resourceId: e.target.value })}>
          {active.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></Field>
        <div className="fields">
          <Field id="bl-fd" label="С (дата)"><input className="input mono" type="date" id="bl-fd" value={f.fromDay} onChange={(e) => setF({ ...f, fromDay: e.target.value, toDay: e.target.value > f.toDay ? e.target.value : f.toDay })} /></Field>
          <Field id="bl-ft" label="С (время)"><input className="input mono" type="time" id="bl-ft" value={f.fromTime} onChange={(e) => setF({ ...f, fromTime: e.target.value })} /></Field>
          <Field id="bl-td" label="По (дата)"><input className="input mono" type="date" id="bl-td" value={f.toDay} onChange={(e) => setF({ ...f, toDay: e.target.value })} /></Field>
          <Field id="bl-tt" label="По (время)"><input className="input mono" type="time" id="bl-tt" value={f.toTime} onChange={(e) => setF({ ...f, toTime: e.target.value })} /></Field>
          <Field id="bl-note" label="Причина" full><input className="input" id="bl-note" maxLength={120} placeholder="Ремонт подъёмника" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
        </div>
        {err && <Notice kind="bad">{err}</Notice>}
        {act.block.isSuccess && <Notice kind="ok">Пост заблокирован.</Notice>}
        <button className="btn primary" disabled={act.block.isPending || !f.resourceId}>{act.block.isPending ? "Сохраняем…" : "Заблокировать"}</button>
      </form>

      <h2>Блокировки на 90 дней</h2>
      {q.isLoading ? <Loading /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : !q.data?.length ? <Empty>Блокировок нет.</Empty> : (
        <ul className="plain stack">
          {q.data.map((b) => {
            const r = parseRange(b.period);
            return (
              <li key={b.id} className="abk static">
                <span className="when">{resources.find((x) => x.id === b.resource_id)?.name}</span>
                <span className="what">{r ? `${dayLabel(localDate(r.from, tz))} ${localTime(r.from, tz)} — ${dayLabel(localDate(r.to, tz))} ${localTime(r.to, tz)}` : b.period}</span>
                {b.note && <span className="who">{b.note}</span>}
                <button className="btn small" disabled={act.unblock.isPending} onClick={() => act.unblock.mutate(b.id)}>Снять блокировку</button>
              </li>
            );
          })}
        </ul>
      )}
      {act.unblock.error && <Notice kind="bad">{humanError(act.unblock.error)}</Notice>}
    </>
  );
}
