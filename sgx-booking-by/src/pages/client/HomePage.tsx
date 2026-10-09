import { useState } from "react";
import { Link } from "react-router-dom";
import { Copy, MapPin, Phone } from "@phosphor-icons/react";
import { useStudioCtx } from "./StudioLayout";
import { Reveal } from "../../components/Reveal";
import { durationLabel, dayLabel, todayIn, trimTime } from "../../lib/time";
import { formatBYPhone, moneyBYN, normalizeBYPhone } from "../../shared/by";

const WD = ["Воскресенье", "Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота"];

export function HomePage() {
  const { studio, openBooking } = useStudioCtx();
  const { tenant, services, works, hours, exceptions } = studio;
  const p = tenant.profile;
  const phone = normalizeBYPhone(p.phone) ?? p.phone;
  const today = todayIn(tenant.timezone);
  const todayWd = new Date(`${today}T12:00:00Z`).getUTCDay();
  const [copied, setCopied] = useState<"idle" | "ok" | "select">("idle");
  const upcomingOff = exceptions.filter((e) => e.day >= today).slice(0, 4);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(phone);
      setCopied("ok");
    } catch {
      const el = document.getElementById("phone-text");
      if (el) getSelection()?.selectAllChildren(el);
      setCopied("select");
    }
  };

  return (
    <main className="wrap">
      <header className="hero">
        <img className="hero-img" src={p.media?.hero} alt={`${p.name}: главное фото`} fetchPriority="high" />
        <div className="hero-top">
          <div className="brand glass"><img src={p.media?.logo} alt="" /><b>{p.name}</b></div>
        </div>
        <div className="hero-body">
          <span className="kind">{p.kind}</span>
          <h1>{p.name}</h1>
          <p>{p.tagline}</p>
          {/* кнопка внутри фото: движется вместе с ним; размывает только фото под собой */}
          <button className="cta-glass glass" onClick={() => openBooking(null)}><span className="dot" aria-hidden="true" />Записаться</button>
        </div>
      </header>

      <Reveal className="sec" label="О студии">
        <p className="lead">{p.description}</p>
        <div className="info-grid">
          {p.cards.map((c, i) => (
            <article className="info" key={i}><h3>{c.title}</h3><p>{c.text}</p></article>
          ))}
        </div>
      </Reveal>

      <Reveal className="sec">
        <div className="sec-head"><h2>Услуги и цены</h2><Link className="link" to={`/s/${tenant.slug}/services`}>Все услуги</Link></div>
        <div className="svc-list">
          {services.filter((s) => s.active).slice(0, 5).map((s) => (
            <button key={s.id} className="svc" onClick={() => openBooking(s.id)}>
              <span className="nm">{s.name}</span><span className="pr">{moneyBYN(s.price)}</span>
              <span className="ds">{s.description}</span><span className="du">{durationLabel(s.duration_min)}</span>
            </button>
          ))}
        </div>
        <button className="btn primary block" onClick={() => openBooking(null)}>Выбрать время</button>
      </Reveal>

      {works.length > 0 && (
        <Reveal className="sec">
          <h2>Наши работы</h2>
          <div className="works">
            {works.map((w) => (
              <figure className="work" key={w.id}><img loading="lazy" src={w.photo_url} alt={w.caption} /><figcaption>{w.caption}</figcaption></figure>
            ))}
          </div>
        </Reveal>
      )}

      <Reveal className="sec" label="Контакты">
        <h2>Как нас найти</h2>
        <div className="contact">
          <div className="panel">
            <span className="label">Адрес</span>
            <p className="strong">{p.address}</p>
            <a className="btn small" href={`https://yandex.by/maps/?text=${encodeURIComponent(p.address)}`} target="_blank" rel="noopener noreferrer"><MapPin weight="fill" /> Открыть на карте</a>
            <span className="label">Телефон</span>
            <div className="row">
              <span className="copyable" id="phone-text">{formatBYPhone(phone)}</span>
              <button className="btn small" onClick={copy}><Copy /> {copied === "ok" ? "Скопировано" : copied === "select" ? "Выделено — скопируйте" : "Скопировать"}</button>
              <a className="btn small ghost" href={`tel:${phone}`}><Phone weight="fill" /> Позвонить</a>
            </div>
          </div>
          <div className="panel">
            <span className="label">Время приёма машин · {tenant.timezone}</span>
            <table className="hours"><tbody>
              {[1, 2, 3, 4, 5, 6, 0].map((wd) => {
                const h = hours.find((x) => x.weekday === wd);
                return <tr key={wd} className={wd === todayWd ? "today" : ""}><td>{WD[wd]}</td><td>{h ? `${trimTime(h.opens)}–${trimTime(h.closes)}` : "выходной"}</td></tr>;
              })}
            </tbody></table>
            {upcomingOff.length > 0 && (
              <p className="muted small">Особые дни: {upcomingOff.map((e) => `${dayLabel(e.day)} — ${e.closed ? "выходной" : `${trimTime(e.opens!)}–${trimTime(e.closes!)}`}${e.note ? ` (${e.note})` : ""}`).join("; ")}</p>
            )}
          </div>
        </div>
      </Reveal>

      <footer className="footer">
        <Link className="link" to={`/s/${tenant.slug}/privacy`}>Политика обработки персональных данных</Link>
        {p.legal && <span>{p.legal.operator}, УНП {p.legal.unp}</span>}
        <Link className="link" to={`/s/${tenant.slug}/owner/`}>Кабинет владельца</Link>
      </footer>
    </main>
  );
}
