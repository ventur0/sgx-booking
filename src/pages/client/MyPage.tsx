import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { useStudioCtx } from "./StudioLayout";
import { useCancelMyBooking, useMyBooking } from "../../data/public";
import { forgetBooking, myBookings, type MyRef } from "../../lib/token";
import { rangeLabel } from "../../lib/time";
import { humanError } from "../../lib/errors";
import { formatBYPhone, moneyBYN, normalizeBYPhone } from "../../shared/by";
import { Empty, ErrorState, Loading, Notice } from "../../components/ui/States";
import { Reminder } from "../../components/booking/Reminder";

const STATUS: Record<string, string> = { new: "Ждём вас", accepted: "Машина принята", ready: "Готова, можно забирать", done: "Завершена", cancelled: "Отменена" };

/** Список записей с этого устройства. */
export function MyListPage() {
  const { studio, openBooking } = useStudioCtx();
  const [refs, setRefs] = useState(() => myBookings(studio.tenant.slug));
  return (
    <main className="wrap pad-top">
      <div className="page-h"><span className="eyebrow">{studio.tenant.profile.name}</span><h1>Моя запись</h1></div>
      {refs.length === 0 ? (
        <Empty action={<button className="btn primary" onClick={() => openBooking(null)}>Записаться</button>}>
          Здесь появятся записи, сделанные с этого устройства. Регистрация не нужна.
        </Empty>
      ) : refs.map((r) => <MyCard key={r.id} r={r} compact onForget={() => { forgetBooking(studio.tenant.slug, r.id); setRefs(myBookings(studio.tenant.slug)); }} />)}
    </main>
  );
}

/** Одна запись по ссылке /s/<slug>/my/<id> (токен хранится на устройстве). */
export function MyDetailPage() {
  const { id = "" } = useParams();
  const { studio } = useStudioCtx();
  const nav = useNavigate();
  const ref = myBookings(studio.tenant.slug).find((r) => r.id === id);
  return (
    <main className="wrap pad-top">
      <div className="page-h"><Link className="link" to={`/s/${studio.tenant.slug}/my`}>← Все мои записи</Link><h1>Запись</h1></div>
      {ref ? <MyCard r={ref} onForget={() => { forgetBooking(studio.tenant.slug, id); nav(`/s/${studio.tenant.slug}/my`); }} /> : (
        <Empty>Доступ к этой записи хранится на устройстве, с которого вы записывались. Откройте ссылку там или позвоните в студию.</Empty>
      )}
    </main>
  );
}

function MyCard({ r, compact, onForget }: { r: MyRef; compact?: boolean; onForget: () => void }) {
  const { studio } = useStudioCtx();
  const p = studio.tenant.profile;
  const q = useMyBooking(r.id, r.token);
  const cancel = useCancelMyBooking();
  const [confirm, setConfirm] = useState(false);

  if (q.isPending) return <article className="bk"><Loading rows={2} /></article>;
  if (q.error) {
    const gone = String((q.error as Error).message).includes("not_found");
    return (
      <article className="bk">
        {gone ? <p className="muted">Запись больше недоступна: её данные удалены.</p> : <ErrorState error={q.error} onRetry={() => q.refetch()} />}
        {gone && <button className="btn small" onClick={onForget}>Убрать из списка</button>}
      </article>
    );
  }
  const b = q.data!;
  const when = rangeLabel(b.startsAt, b.endsAt, b.timezone);
  return (
    <article className="bk">
      <div className="bk-top"><h2>{b.serviceName}</h2><span className={`status st-${b.status}`}>{STATUS[b.status]}</span></div>
      {b.isDemo && <Notice kind="info">Демонстрационная запись студии-образца.</Notice>}
      <dl className="summary">
        <dt>Когда</dt><dd>{when}</dd>
        <dt>Пост</dt><dd>{b.resourceName}</dd>
        <dt>Авто</dt><dd>{b.clientCar}</dd>
        <dt>Стоимость</dt><dd className="mono">{moneyBYN(b.price)}</dd>
        <dt>Адрес</dt><dd>{p.address}</dd>
      </dl>
      {compact ? (
        <Link className="btn small" to={`/s/${studio.tenant.slug}/my/${b.id}`}>Подробнее</Link>
      ) : (
        <>
          {b.status !== "cancelled" && b.status !== "done" && (
            <Reminder bookingId={b.id} token={r.token} serverState={b.reminder} onChanged={() => q.refetch()}
              event={{ id: b.id, title: `${b.serviceName} — ${p.name}`, startsAt: b.startsAt, endsAt: b.endsAt, location: p.address, details: `Телефон студии: ${p.phone}` }} />
          )}
          {b.canCancel && !confirm && <button className="btn danger" onClick={() => setConfirm(true)}>Отменить запись</button>}
          {confirm && (
            <div className="confirm" role="group" aria-label="Подтверждение отмены">
              <p>Отменить запись на {when}?</p>
              <div className="row">
                <button className="btn danger" disabled={cancel.isPending} onClick={() => cancel.mutate({ id: b.id, token: r.token }, { onSettled: () => setConfirm(false) })}>
                  {cancel.isPending ? "Отменяем…" : "Да, отменить"}
                </button>
                <button className="btn ghost" onClick={() => setConfirm(false)}>Нет</button>
              </div>
            </div>
          )}
          {cancel.isSuccess && <Notice kind="ok">Запись отменена, время освобождено.</Notice>}
          {cancel.error && <Notice kind="bad">{humanError(cancel.error)}</Notice>}
          {b.status === "new" && !b.canCancel && (
            <p className="muted small">Онлайн-отмена возможна не позже чем за {b.cancelHours} ч. Позвоните: <span className="mono">{formatBYPhone(normalizeBYPhone(p.phone) ?? p.phone)}</span></p>
          )}
        </>
      )}
    </article>
  );
}
