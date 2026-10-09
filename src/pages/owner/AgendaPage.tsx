import { useMemo, useRef, useState, type FormEvent } from "react";
import { Plus } from "@phosphor-icons/react";
import { useStudioCtx } from "../client/StudioLayout";
import { useOwnerActions, useOwnerBookings, type BookingStatus, type OwnerBooking } from "../../data/owner";
import { useAvailability, type Studio } from "../../data/public";
import { addDays, dayLabel, dayLong, dayStart, durationLabel, localDate, localTime, rangeLabel, todayIn, trimTime, weekStart } from "../../lib/time";
import { humanError } from "../../lib/errors";
import { formatBYPhone, moneyBYN, normalizeBYPhone, toKop } from "../../shared/by";
import { Empty, ErrorState, Field, Loading, Notice } from "../../components/ui/States";
import { Sheet } from "../../components/ui/Sheet";

const STATUS: Record<BookingStatus, string> = { new: "Новая", accepted: "Машина принята", ready: "Готова", done: "Выполнена", cancelled: "Отменена" };
const NEXT: Partial<Record<BookingStatus, [BookingStatus, string]>> = { new: ["accepted", "Принять машину"], accepted: ["ready", "Машина готова"], ready: ["done", "Выдана, завершить"] };
const paid = (b: OwnerBooking) => b.payments.reduce((a, p) => a + (p.kind === "pay" ? 1 : -1) * toKop(p.amount), 0) / 100;

export function AgendaPage() {
  const { studio } = useStudioCtx();
  const { tenant, resources } = studio;
  const tz = tenant.timezone;
  const today = todayIn(tz);
  const [view, setView] = useState<"day" | "week">("day");
  const [date, setDate] = useState(today);
  const [openId, setOpenId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);

  const days = useMemo(() => (view === "day" ? [date] : Array.from({ length: 7 }, (_, i) => addDays(weekStart(date), i))), [view, date]);
  const fromIso = dayStart(days[0], tz).toISOString();
  const toIso = dayStart(addDays(days[days.length - 1], 1), tz).toISOString();
  const q = useOwnerBookings(tenant.id, fromIso, toIso);
  const list = q.data ?? [];
  const open = list.find((b) => b.id === openId) ?? null;
  const resName = (id: string) => resources.find((r) => r.id === id)?.name ?? "—";

  return (
    <>
      <div className="toolbar">
        <div className="seg" role="group" aria-label="Период">
          <button aria-pressed={view === "day"} onClick={() => setView("day")}>День</button>
          <button aria-pressed={view === "week"} onClick={() => setView("week")}>Неделя</button>
        </div>
        <div className="row">
          <button className="btn small" aria-label="Назад" onClick={() => setDate(addDays(date, view === "week" ? -7 : -1))}>‹</button>
          <button className="btn small" onClick={() => setDate(today)}>Сегодня</button>
          <button className="btn small" aria-label="Вперёд" onClick={() => setDate(addDays(date, view === "week" ? 7 : 1))}>›</button>
        </div>
      </div>
      <div className="row between">
        <h2 className="period">{view === "day" ? dayLong(date) : `${dayLabel(days[0])} — ${dayLabel(days[6])}`}</h2>
        <button className="btn primary small" onClick={() => setAdding(true)}><Plus weight="bold" /> Запись</button>
      </div>
      <p className="muted small">Итоги периода с деньгами — на вкладке «Итоги».</p>

      {q.isLoading ? <Loading /> : q.error ? <ErrorState error={q.error} onRetry={() => q.refetch()} /> : (
        days.map((d) => {
          const items = list.filter((b) => localDate(b.starts_at, tz) <= d && localDate(b.ends_at, tz) >= d && (b.ends_at > dayStart(d, tz).toISOString()));
          if (view === "week" && !items.length) return null;
          return (
            <section key={d} className="daygroup" aria-label={dayLabel(d)}>
              {view === "week" && <h3>{dayLabel(d)}</h3>}
              {items.length === 0 ? <Empty action={<button className="btn small" onClick={() => setAdding(true)}>Добавить запись</button>}>На этот день записей нет.</Empty> :
                items.map((b) => (
                  <button key={b.id + d} className={`abk${b.status === "cancelled" ? " dim" : ""}`} onClick={() => setOpenId(b.id)}>
                    <span className="when">{localDate(b.starts_at, tz) === d ? localTime(b.starts_at, tz) : "весь день"} · {resName(b.resource_id)}</span>
                    <span className={`status st-${b.status}`}>{STATUS[b.status]}</span>
                    <span className="what">{b.service_name}</span>
                    <span className="who">{b.anonymized_at ? "данные удалены" : `${b.client_name} · ${b.client_car}`}{b.is_demo ? " · демо" : ""}</span>
                  </button>
                ))}
            </section>
          );
        })
      )}
      {view === "week" && !q.isLoading && !list.length && <Empty>На этой неделе записей нет.</Empty>}

      {open && <BookingDetail studio={studio} b={open} onClose={() => setOpenId(null)} />}
      <NewBooking studio={studio} open={adding} initialDay={date} onClose={() => setAdding(false)} onCreated={(d) => { setAdding(false); setDate(d); setView("day"); }} />
    </>
  );
}

function BookingDetail({ studio, b, onClose }: { studio: Studio; b: OwnerBooking; onClose: () => void }) {
  const { tenant, resources } = studio;
  const tz = tenant.timezone;
  const act = useOwnerActions(tenant.id, tenant.slug);
  const [mode, setMode] = useState<"view" | "pay" | "move" | "cancel" | "erase">("view");
  const next = NEXT[b.status];
  const p = paid(b);
  const left = Math.max(0, (toKop(b.price) - toKop(p)) / 100);
  const anyErr = act.status.error ?? act.anonymize.error;

  return (
    <Sheet open onClose={onClose} title={b.service_name}>
      <div className="stack">
        <span className={`status st-${b.status}`}>{STATUS[b.status]}</span>
        <dl className="summary">
          <dt>Когда</dt><dd>{rangeLabel(b.starts_at, b.ends_at, tz)}</dd>
          <dt>Пост</dt><dd>{resources.find((r) => r.id === b.resource_id)?.name}</dd>
          <dt>Клиент</dt><dd>{b.anonymized_at ? "данные удалены" : b.client_name}</dd>
          {!b.anonymized_at && <><dt>Телефон</dt><dd><a href={`tel:${b.client_phone}`} className="mono">{formatBYPhone(b.client_phone)}</a></dd><dt>Авто</dt><dd>{b.client_car}</dd></>}
          <dt>Цена</dt><dd className="mono">{moneyBYN(b.price)} <small className="muted">(на момент записи)</small></dd>
          <dt>Оплачено</dt><dd className="mono">{moneyBYN(p)}{left > 0 && b.status !== "cancelled" ? ` · осталось ${moneyBYN(left)}` : ""}</dd>
          <dt>Источник</dt><dd>{b.source === "owner" ? "добавлена вручную" : b.consent_at ? "онлайн, согласие на обработку ПД получено" : "онлайн"}{b.is_demo ? " · демо" : ""}</dd>
        </dl>
        {b.payments.length > 0 && (
          <ul className="plain small">{b.payments.map((x) => <li key={x.id}>{x.kind === "pay" ? "Оплата" : "Возврат"} {moneyBYN(x.amount)} · {x.method} · {dayLabel(localDate(x.paid_at, tz))} {localTime(x.paid_at, tz)}</li>)}</ul>
        )}
        {anyErr && <Notice kind="bad">{humanError(anyErr)}</Notice>}

        {mode === "view" && (
          <div className="row wrap-gap">
            {next && <button className="btn primary" disabled={act.status.isPending} onClick={() => act.status.mutate({ id: b.id, status: next[0] })}>{next[1]}</button>}
            <button className="btn" onClick={() => setMode("pay")}>Оплата / возврат</button>
            {b.status !== "done" && b.status !== "cancelled" && <button className="btn" onClick={() => setMode("move")}>Перенести</button>}
            {b.status !== "done" && b.status !== "cancelled" && <button className="btn danger" onClick={() => setMode("cancel")}>Отменить</button>}
            {(b.status === "done" || b.status === "cancelled") && !b.anonymized_at && <button className="btn ghost" onClick={() => setMode("erase")}>Удалить данные клиента</button>}
          </div>
        )}
        {mode === "pay" && <PayForm b={b} paidNow={p} onDone={() => setMode("view")} />}
        {mode === "move" && <MoveForm studio={studio} b={b} onDone={() => setMode("view")} />}
        {mode === "cancel" && (
          <div className="confirm"><p>Отменить запись? Время на посту освободится сразу, напоминание клиенту отменится.</p>
            <div className="row"><button className="btn danger" disabled={act.status.isPending} onClick={() => act.status.mutate({ id: b.id, status: "cancelled" }, { onSuccess: () => setMode("view") })}>Да, отменить</button>
              <button className="btn ghost" onClick={() => setMode("view")}>Нет</button></div></div>
        )}
        {mode === "erase" && (
          <div className="confirm"><p>Удалить имя, телефон и машину клиента? Дата, услуга и суммы останутся для учёта. Действие необратимо.</p>
            <div className="row"><button className="btn danger" disabled={act.anonymize.isPending} onClick={() => act.anonymize.mutate(b.id, { onSuccess: () => setMode("view") })}>Удалить данные</button>
              <button className="btn ghost" onClick={() => setMode("view")}>Нет</button></div></div>
        )}
      </div>
    </Sheet>
  );
}

function PayForm({ b, paidNow, onDone }: { b: OwnerBooking; paidNow: number; onDone: () => void }) {
  const { studio } = useStudioCtx();
  const act = useOwnerActions(studio.tenant.id, studio.tenant.slug);
  const [amount, setAmount] = useState(String(Math.max(0, (toKop(b.price) - toKop(paidNow)) / 100)).replace(".", ","));
  const [method, setMethod] = useState("cash");
  const [err, setErr] = useState("");
  const go = (kind: "pay" | "refund") => {
    const n = Number(amount.replace(/\s/g, "").replace(",", "."));
    if (!(n > 0) || Math.abs(n * 100 - Math.round(n * 100)) > 1e-6) return setErr("Введите сумму больше нуля, например 45,50");
    if (kind === "refund" && toKop(n) > toKop(paidNow)) return setErr(`Возврат не может быть больше оплаченного (${moneyBYN(paidNow)})`);
    setErr("");
    act.pay.mutate({ id: b.id, kind, amount: n, method }, { onSuccess: onDone, onError: (e) => setErr(humanError(e)) });
  };
  return (
    <div className="stack">
      <div className="fields">
        <Field id="pay-sum" label="Сумма, BYN"><input className="input mono" id="pay-sum" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} data-autofocus /></Field>
        <Field id="pay-m" label="Способ"><select className="input" id="pay-m" value={method} onChange={(e) => setMethod(e.target.value)}>
          <option value="cash">Наличные</option><option value="card">Карта</option><option value="erip">ЕРИП</option><option value="other">Другое</option></select></Field>
      </div>
      {err && <p className="err" role="alert">{err}</p>}
      <div className="row"><button className="btn primary" disabled={act.pay.isPending} onClick={() => go("pay")}>Внести оплату</button>
        <button className="btn" disabled={act.pay.isPending} onClick={() => go("refund")}>Оформить возврат</button>
        <button className="btn ghost" onClick={onDone}>Назад</button></div>
    </div>
  );
}

function TimePicker({ studio, serviceId, day, time, onDay, onTime }: { studio: Studio; serviceId: string; day: string; time: string | null; onDay: (d: string) => void; onTime: (t: string) => void }) {
  const av = useAvailability(studio.tenant.slug, serviceId, day, 1);
  const slots = (av.data ?? []).filter((s) => s.slot_time);
  return (
    <div className="stack">
      <Field id="tp-day" label="Дата"><input className="input mono" type="date" id="tp-day" min={todayIn(studio.tenant.timezone)} value={day} onChange={(e) => e.target.value && onDay(e.target.value)} /></Field>
      {av.isLoading ? <Loading rows={1} /> : av.error ? <ErrorState error={av.error} onRetry={() => av.refetch()} /> :
        slots.length === 0 ? <p className="muted">В этот день приёма нет или время уже прошло.</p> : (
          <div className="times">{slots.map((s) => (
            <button key={s.slot_time} type="button" className={`time${s.free ? "" : " busy"}`} disabled={!s.free} aria-pressed={time === trimTime(s.slot_time!)} onClick={() => onTime(trimTime(s.slot_time!))}>
              <span>{trimTime(s.slot_time!)}</span>{!s.free && <small>занято</small>}</button>))}</div>
        )}
    </div>
  );
}

function MoveForm({ studio, b, onDone }: { studio: Studio; b: OwnerBooking; onDone: () => void }) {
  const act = useOwnerActions(studio.tenant.id, studio.tenant.slug);
  const [day, setDay] = useState(localDate(b.starts_at, studio.tenant.timezone));
  const [time, setTime] = useState<string | null>(null);
  const [res, setRes] = useState<string>("");
  return (
    <div className="stack">
      <TimePicker studio={studio} serviceId={b.service_id} day={day} time={time} onDay={(d) => { setDay(d); setTime(null); }} onTime={setTime} />
      <Field id="mv-res" label="Пост"><select className="input" id="mv-res" value={res} onChange={(e) => setRes(e.target.value)}>
        <option value="">Любой подходящий (сначала текущий)</option>{studio.resources.filter((r) => r.active).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></Field>
      <p className="muted small">Перенос выполняется одной операцией: если время займут раньше, исходная запись останется без изменений.</p>
      {act.move.error && <Notice kind="bad">{humanError(act.move.error)}</Notice>}
      <div className="row"><button className="btn primary" disabled={!time || act.move.isPending} onClick={() => act.move.mutate({ id: b.id, day, time: time!, resourceId: res || null }, { onSuccess: onDone, onError: () => setTime(null) })}>Перенести</button>
        <button className="btn ghost" onClick={onDone}>Назад</button></div>
    </div>
  );
}

function NewBooking({ studio, open, initialDay, onClose, onCreated }: { studio: Studio; open: boolean; initialDay: string; onClose: () => void; onCreated: (day: string) => void }) {
  const act = useOwnerActions(studio.tenant.id, studio.tenant.slug);
  const services = studio.services.filter((s) => s.active);
  const [serviceId, setServiceId] = useState(services[0]?.id ?? "");
  const [day, setDay] = useState(initialDay);
  const [time, setTime] = useState<string | null>(null);
  const [form, setForm] = useState({ name: "", phone: "", car: "" });
  const [err, setErr] = useState("");
  const key = useRef<string | null>(null);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!time) return setErr("Выберите время");
    if (form.name.trim().length < 2 || form.car.trim().length < 2) return setErr("Укажите имя и автомобиль");
    if (!normalizeBYPhone(form.phone)) return setErr("Телефон: например +375 29 123-45-67");
    setErr("");
    key.current ??= crypto.randomUUID();
    act.create.mutate({ serviceId, day, time, ...form, key: key.current, resourceId: null }, {
      onSuccess: () => { key.current = null; setForm({ name: "", phone: "", car: "" }); setTime(null); onCreated(day); },
      onError: (x) => { setErr(humanError(x)); setTime(null); key.current = null; },
    });
  };
  return (
    <Sheet open={open} onClose={onClose} title="Новая запись" footer={<button className="btn primary block" form="nb-form" disabled={act.create.isPending}>{act.create.isPending ? "Записываем…" : "Записать клиента"}</button>}>
      <form id="nb-form" className="stack" onSubmit={submit} noValidate>
        <Field id="nb-svc" label="Услуга"><select className="input" id="nb-svc" data-autofocus value={serviceId} onChange={(e) => { setServiceId(e.target.value); setTime(null); }}>
          {services.map((s) => <option key={s.id} value={s.id}>{s.name} · {moneyBYN(s.price)} · {durationLabel(s.duration_min)}</option>)}</select></Field>
        {serviceId && <TimePicker studio={studio} serviceId={serviceId} day={day} time={time} onDay={(d) => { setDay(d); setTime(null); }} onTime={setTime} />}
        <div className="fields">
          <Field id="nb-name" label="Имя клиента"><input className="input" id="nb-name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></Field>
          <Field id="nb-phone" label="Телефон"><input className="input" id="nb-phone" type="tel" inputMode="tel" placeholder="+375 29 123-45-67" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} /></Field>
          <Field id="nb-car" label="Автомобиль" full><input className="input" id="nb-car" value={form.car} onChange={(e) => setForm({ ...form, car: e.target.value })} /></Field>
        </div>
        {err && <p className="err" role="alert">{err}</p>}
      </form>
    </Sheet>
  );
}
