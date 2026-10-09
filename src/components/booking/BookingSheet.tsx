import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { CheckCircle } from "@phosphor-icons/react";
import { z } from "zod";
import { Sheet } from "../ui/Sheet";
import { ErrorState, Field, Loading, Notice } from "../ui/States";
import { Reminder } from "./Reminder";
import { useAvailability, useCreateBooking, type Studio } from "../../data/public";
import { addDays, dayLabel, dayNum, durationLabel, rangeLabel, todayIn, trimTime, weekdayShort } from "../../lib/time";
import { errorCode, humanError, isRetryable } from "../../lib/errors";
import { attemptFor, clearAttempt, rememberBooking } from "../../lib/token";
import { CONSENT_VERSION, moneyBYN, normalizeBYPhone } from "../../shared/by";

type Step = "service" | "day" | "time" | "contacts" | "done";
const STEP_TITLE: Record<Step, string> = { service: "Услуга", day: "Дата", time: "Время", contacts: "Ваши данные", done: "Вы записаны" };

const ContactsSchema = z.object({
  name: z.string().trim().min(2, "Имя: хотя бы 2 буквы").max(80),
  phone: z.string().refine((p) => normalizeBYPhone(p) !== null, "Номер вида +375 29 123-45-67 или 8 029 123-45-67"),
  car: z.string().trim().min(2, "Марка и модель, например Geely Coolray").max(80),
  consent: z.literal(true, { errorMap: () => ({ message: "Нужно согласие на обработку персональных данных" }) }),
});

/** Последовательная запись: услуга → дата → время → контакты → подтверждение. */
export function BookingSheet({ studio, open, onClose, initialServiceId }: { studio: Studio; open: boolean; onClose: () => void; initialServiceId?: string | null }) {
  const { tenant, services } = studio;
  const tz = tenant.timezone;
  const active = services.filter((s) => s.active);
  const [step, setStep] = useState<Step>("service");
  const [serviceId, setServiceId] = useState<string | null>(null);
  const [day, setDay] = useState<string | null>(null);
  const [time, setTime] = useState<string | null>(null);
  const [form, setForm] = useState({ name: "", phone: "", car: "", consent: false });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState<{ text: string; retry?: boolean } | null>(null);
  const [done, setDone] = useState<{ id: string; token: string; startsAt: string; endsAt: string } | null>(null);
  const firstInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!open) return;
    setDone(null); setMsg(null); setErrors({}); setDay(null); setTime(null);
    if (initialServiceId && active.some((s) => s.id === initialServiceId)) { setServiceId(initialServiceId); setStep("day"); }
    else { setServiceId(null); setStep("service"); }
  }, [open, initialServiceId]); // eslint-disable-line react-hooks/exhaustive-deps

  const svc = active.find((s) => s.id === serviceId) ?? null;
  const from = todayIn(tz);
  const avail = useAvailability(tenant.slug, open ? serviceId : null, from, Math.min(tenant.profile.booking.horizonDays, 31));
  const byDay = useMemo(() => {
    const m = new Map<string, { closed: boolean; slots: { time: string; free: boolean; startsAt: string }[] }>();
    for (const r of avail.data ?? []) {
      const e = m.get(r.day) ?? { closed: r.closed, slots: [] };
      if (r.slot_time && r.starts_at) e.slots.push({ time: trimTime(r.slot_time), free: r.free, startsAt: r.starts_at });
      m.set(r.day, e);
    }
    return m;
  }, [avail.data]);
  const days = useMemo(() => Array.from({ length: Math.min(tenant.profile.booking.horizonDays, 31) }, (_, i) => addDays(from, i)), [from, tenant.profile.booking.horizonDays]);
  const slot = day && time ? byDay.get(day)?.slots.find((s) => s.time === time) : undefined;

  // если выбранное время заняли, пока человек заполнял форму, — сообщаем и возвращаем к выбору
  const create = useCreateBooking(tenant.slug);
  useEffect(() => {
    if (create.isPending) return; // во время своей записи слот закономерно становится занятым
    if (step === "contacts" && slot && !slot.free) {
      setMsg({ text: "Это время только что заняли. Выберите другое — ваши данные сохранились." });
      setTime(null);
      setStep("time");
    }
  }, [slot, step, create.isPending]);

  const submit = async (e?: FormEvent) => {
    e?.preventDefault();
    if (!svc || !day || !time || create.isPending) return;
    const p = ContactsSchema.safeParse(form);
    if (!p.success) {
      const errs: Record<string, string> = {};
      p.error.issues.forEach((i) => (errs[String(i.path[0])] = i.message));
      setErrors(errs);
      document.getElementById(`bk-${Object.keys(errs)[0]}`)?.focus();
      return;
    }
    setErrors({}); setMsg(null);
    const payload = JSON.stringify({ s: svc.id, day, time, n: p.data.name, ph: normalizeBYPhone(p.data.phone), c: p.data.car });
    const attempt = attemptFor(tenant.slug, payload); // тот же ключ и токен при повторе
    try {
      const id = await create.mutateAsync({ serviceId: svc.id, day, time, name: p.data.name, phone: p.data.phone, car: p.data.car, key: attempt.key, token: attempt.token, consentVersion: CONSENT_VERSION });
      rememberBooking(tenant.slug, { id, token: attempt.token, createdAt: new Date().toISOString() });
      clearAttempt(tenant.slug);
      const startsAt = slot?.startsAt ?? new Date().toISOString();
      setDone({ id, token: attempt.token, startsAt, endsAt: new Date(new Date(startsAt).getTime() + svc.duration_min * 60000).toISOString() });
      setStep("done");
    } catch (err) {
      const code = errorCode(err);
      if (code === "slot_taken" || code === "too_soon") {
        clearAttempt(tenant.slug);
        setTime(null); setStep("time");
        setMsg({ text: humanError(err) });
        void avail.refetch();
      } else {
        setMsg({ text: humanError(err), retry: isRetryable(err) });
      }
    }
  };

  const back = () => setStep(step === "contacts" ? "time" : step === "time" ? "day" : "service");
  const title = step === "done" ? STEP_TITLE.done : `Запись · ${STEP_TITLE[step]}`;

  return (
    <Sheet open={open} onClose={onClose} title={title}
      footer={step !== "service" && step !== "done" ? (
        <div className="row between">
          <button className="btn ghost" onClick={back}>Назад</button>
          {step === "contacts" && <button className="btn primary" form="bk-form" type="submit" disabled={create.isPending}>{create.isPending ? "Записываем…" : "Подтвердить запись"}</button>}
        </div>) : undefined}>
      {step !== "done" && (
        <ol className="steps" aria-label="Шаги записи">
          {(["service", "day", "time", "contacts"] as Step[]).map((s, i) => (
            <li key={s} aria-current={s === step ? "step" : undefined} className={s === step ? "on" : ""}>{i + 1}. {STEP_TITLE[s]}</li>
          ))}
        </ol>
      )}
      {msg && step !== "done" && (
        <Notice kind="bad">{msg.text} {msg.retry && <button className="link" onClick={() => submit()}>Повторить отправку</button>}</Notice>
      )}

      {step === "service" && (
        <div className="choice-list" role="list">
          {active.map((s) => (
            <button key={s.id} role="listitem" className="choice" aria-pressed={s.id === serviceId} data-autofocus={s === active[0] ? true : undefined}
              onClick={() => { setServiceId(s.id); setDay(null); setTime(null); setMsg(null); setStep("day"); }}>
              <span className="t">{s.name}<small>{s.description}</small></span>
              <span className="s">{moneyBYN(s.price)}<small>{durationLabel(s.duration_min)}</small></span>
            </button>
          ))}
        </div>
      )}

      {(step === "day" || step === "time") && svc && (
        <p className="muted small">{svc.name} · {moneyBYN(svc.price)} · {durationLabel(svc.duration_min)}{svc.duration_min > 720 ? " — машина остаётся у нас, пост занят всё это время" : ""}</p>
      )}

      {step === "day" && (avail.isLoading ? <Loading label="Ищем свободные дни" /> : avail.error ? <ErrorState error={avail.error} onRetry={() => avail.refetch()} /> : (
        <div className="dates" role="group" aria-label="Дата">
          {days.map((d) => {
            const info = byDay.get(d);
            const closed = !info || info.closed;
            const free = !!info?.slots.some((s) => s.free);
            return (
              <button key={d} className="date" aria-pressed={d === day} disabled={closed || !free}
                aria-label={`${dayLabel(d)}${closed ? ", закрыто" : !free ? ", мест нет" : ""}`}
                onClick={() => { setDay(d); setTime(null); setMsg(null); setStep("time"); }}>
                <span className="w">{weekdayShort(d)}</span><span className="d">{dayNum(d)}</span>
                <span className="f">{closed ? "закрыто" : !free ? "мест нет" : d === from ? "сегодня" : ""}</span>
              </button>
            );
          })}
        </div>
      ))}

      {step === "time" && day && (
        <>
          <h3 className="sub">{dayLabel(day)}</h3>
          {avail.isFetching && !avail.data ? <Loading /> : (
            <>
              <div className="times" role="group" aria-label="Время">
                {(byDay.get(day)?.slots ?? []).map((s) => (
                  <button key={s.time} className={`time${s.free ? "" : " busy"}`} disabled={!s.free} aria-pressed={s.time === time}
                    aria-label={`${s.time}${s.free ? "" : ", занято"}`}
                    onClick={() => { setTime(s.time); setMsg(null); setStep("contacts"); setTimeout(() => firstInput.current?.focus(), 60); }}>
                    <span>{s.time}</span>{!s.free && <small>занято</small>}
                  </button>
                ))}
              </div>
              <div className="legend"><span><i />свободно</span><span><i className="b" />занято</span>
                {tenant.profile.booking.bufferMin > 0 && <span>+{tenant.profile.booking.bufferMin} мин на подготовку поста</span>}</div>
            </>
          )}
        </>
      )}

      {step === "contacts" && svc && day && time && (
        <form id="bk-form" className="stack" onSubmit={submit} noValidate>
          <dl className="summary">
            <dt>Услуга</dt><dd>{svc.name}</dd>
            <dt>Когда</dt><dd>{slot ? rangeLabel(slot.startsAt, new Date(new Date(slot.startsAt).getTime() + svc.duration_min * 60000).toISOString(), tz) : `${dayLabel(day)}, ${time}`}</dd>
            <dt>Стоимость</dt><dd className="mono">{moneyBYN(svc.price)}</dd>
          </dl>
          <div className="fields">
            <Field id="bk-name" label="Имя" error={errors.name}>
              <input ref={firstInput} className="input" id="bk-name" autoComplete="name" enterKeyHint="next" value={form.name} aria-invalid={!!errors.name}
                aria-describedby={errors.name ? "bk-name-err" : undefined} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            </Field>
            <Field id="bk-phone" label="Телефон" error={errors.phone}>
              <input className="input" id="bk-phone" type="tel" inputMode="tel" autoComplete="tel" enterKeyHint="next" placeholder="+375 29 123-45-67" value={form.phone}
                aria-invalid={!!errors.phone} aria-describedby={errors.phone ? "bk-phone-err" : undefined} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
            </Field>
            <Field id="bk-car" label="Автомобиль" error={errors.car} full>
              <input className="input" id="bk-car" placeholder="Марка, модель, цвет" enterKeyHint="done" value={form.car} aria-invalid={!!errors.car}
                aria-describedby={errors.car ? "bk-car-err" : undefined} onChange={(e) => setForm({ ...form, car: e.target.value })} />
            </Field>
          </div>
          <label className="consent">
            <input id="bk-consent" type="checkbox" checked={form.consent} aria-invalid={!!errors.consent} onChange={(e) => setForm({ ...form, consent: e.target.checked })} />
            <span>
              Согласен(на) на обработку моих имени, телефона и данных автомобиля {tenant.profile.legal ? tenant.profile.legal.operator : "студией"} для записи и связи по ней,
              срок — {tenant.profile.legal?.retentionDays ?? 365} дней. <Link to={`/s/${tenant.slug}/privacy`} target="_blank">Политика обработки данных</Link>
            </span>
          </label>
          {errors.consent && <span className="err">{errors.consent}</span>}
          <p className="muted small">Отменить онлайн можно не позже чем за {tenant.profile.booking.cancelHours} ч до начала.</p>
          {tenant.mode === "preview" && <Notice kind="info">Это студия-образец: запись будет помечена как демонстрационная.</Notice>}
        </form>
      )}

      {step === "done" && done && svc && (
        <div className="stack">
          <Notice kind="ok"><CheckCircle weight="fill" /> Ждём вас: {rangeLabel(done.startsAt, done.endsAt, tz)}.</Notice>
          <dl className="summary">
            <dt>Услуга</dt><dd>{svc.name}</dd>
            <dt>Стоимость</dt><dd className="mono">{moneyBYN(svc.price)}</dd>
            <dt>Адрес</dt><dd>{tenant.profile.address}</dd>
          </dl>
          <Reminder bookingId={done.id} token={done.token}
            event={{ id: done.id, title: `${svc.name} — ${tenant.profile.name}`, startsAt: done.startsAt, endsAt: done.endsAt, location: tenant.profile.address, details: `Телефон студии: ${tenant.profile.phone}` }} />
          <div className="row">
            <Link className="btn primary" to={`/s/${tenant.slug}/my/${done.id}`} onClick={onClose}>Открыть мою запись</Link>
            <button className="btn ghost" onClick={() => { setDone(null); setTime(null); setStep("service"); }}>Записать ещё машину</button>
          </div>
        </div>
      )}
    </Sheet>
  );
}
