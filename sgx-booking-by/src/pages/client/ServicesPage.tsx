import { useStudioCtx } from "./StudioLayout";
import { durationLabel } from "../../lib/time";
import { moneyBYN } from "../../shared/by";
import { Empty } from "../../components/ui/States";

export function ServicesPage() {
  const { studio, openBooking } = useStudioCtx();
  const list = studio.services.filter((s) => s.active);
  return (
    <main className="wrap pad-top">
      <div className="page-h"><span className="eyebrow">{studio.tenant.profile.name}</span><h1>Услуги и цены</h1>
        <p className="muted">Цены в белорусских рублях. Между машинами пост готовят {studio.tenant.profile.booking.bufferMin} мин.</p></div>
      {list.length === 0 ? <Empty>Студия пока не добавила услуги. Позвоните, чтобы записаться.</Empty> : (
        <div className="svc-list">
          {list.map((s) => (
            <button key={s.id} className="svc" onClick={() => openBooking(s.id)}>
              <span className="nm">{s.name}</span><span className="pr">{moneyBYN(s.price)}</span>
              <span className="ds">{s.description}</span><span className="du">{durationLabel(s.duration_min)}</span>
            </button>
          ))}
        </div>
      )}
    </main>
  );
}
