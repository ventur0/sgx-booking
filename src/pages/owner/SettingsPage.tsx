import { useState, type ChangeEvent, type FormEvent } from "react";
import { NavLink, Route, Routes } from "react-router-dom";
import { useStudioCtx } from "../client/StudioLayout";
import { changeOwnEmail, changeOwnPassword, deleteOwnAccount, deleteOwnStudio, signOut, useSession, useSettingsActions } from "../../data/owner";
import { ProfileSchema, type Profile } from "../../shared/business";
import { moneyBYN, upcomingHolidays } from "../../shared/by";
import { compressImage } from "../../lib/media";
import { dayLabel, durationLabel, todayIn, trimTime } from "../../lib/time";
import { humanError } from "../../lib/errors";
import { Empty, Field, Notice } from "../../components/ui/States";
import { mediaUrl } from "../../lib/supabase";
import { TelegramConnect } from "../../components/owner/TelegramConnect";

export function SettingsPage() {
  const { studio } = useStudioCtx();
  const base = `/s/${studio.tenant.slug}/owner/settings`;
  return (
    <>
      <nav className="subtabs" aria-label="Настройки">
        <NavLink end to={base}>Студия</NavLink>
        <NavLink to={`${base}/services`}>Услуги</NavLink>
        <NavLink to={`${base}/posts`}>Посты</NavLink>
        <NavLink to={`${base}/schedule`}>График</NavLink>
        <NavLink to={`${base}/photos`}>Фото</NavLink>
        {studio.tenant.mode === "preview" && <NavLink to={`${base}/launch`}>Запуск</NavLink>}
        <NavLink to={`${base}/telegram`}>Telegram</NavLink>
        <NavLink to={`${base}/account`}>Аккаунт</NavLink>
      </nav>
      <Routes>
        <Route index element={<ProfileForm />} />
        <Route path="services" element={<ServicesForm />} />
        <Route path="posts" element={<PostsForm />} />
        <Route path="schedule" element={<ScheduleForm />} />
        <Route path="photos" element={<PhotosForm />} />
        <Route path="launch" element={<LaunchForm />} />
        <Route path="telegram" element={<TelegramConnect tenantId={studio.tenant.id} />} />
        <Route path="account" element={<AccountForm />} />
      </Routes>
    </>
  );
}

function Result({ error, ok, okText }: { error: unknown; ok: boolean; okText: string }) {
  if (error) return <Notice kind="bad">{humanError(error)}</Notice>;
  if (ok) return <Notice kind="ok">{okText}</Notice>;
  return null;
}

/* ------------------------------ профиль ------------------------------ */
function ProfileForm() {
  const { studio } = useStudioCtx();
  const act = useSettingsActions(studio.tenant.id, studio.tenant.slug);
  const [p, setP] = useState<Profile>(() => structuredClone(studio.tenant.profile));
  const [errs, setErrs] = useState<string[]>([]);
  const set = <K extends keyof Profile>(k: K, v: Profile[K]) => setP({ ...p, [k]: v });
  const legal = p.legal ?? { operator: "", unp: "", legalAddress: "", email: "", retentionDays: 365, dataLocation: "Германия (ЕС), Supabase, регион Frankfurt" };
  const submit = (e: FormEvent) => {
    e.preventDefault();
    const r = ProfileSchema.safeParse(p);
    if (!r.success) return setErrs(r.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`));
    setErrs([]);
    act.saveProfile.mutate(r.data);
  };
  const text = (k: "name" | "kind" | "tagline" | "address" | "phone", label: string, full = false) => (
    <Field id={`p-${k}`} label={label} full={full}><input className="input" id={`p-${k}`} value={p[k] ?? ""} onChange={(e) => set(k, e.target.value)} /></Field>
  );
  const rule = (k: keyof Profile["booking"], label: string) => (
    <Field id={`r-${k}`} label={label}><input className="input mono" id={`r-${k}`} inputMode="numeric" value={p.booking[k]} onChange={(e) => set("booking", { ...p.booking, [k]: Number(e.target.value.replace(/\D/g, "")) || 0 })} /></Field>
  );
  return (
    <form className="stack" onSubmit={submit} noValidate>
      <section className="panel stack"><h2>Основное</h2>
        <div className="fields">
          {text("name", "Название")}
          <Field id="p-short" label="Подпись под иконкой (до 12 символов)"><input className="input" id="p-short" maxLength={12} value={p.shortName ?? ""} onChange={(e) => set("shortName", e.target.value || undefined)} /></Field>
          {text("kind", "Строка над названием")}
          {text("tagline", "Коротко на главном фото", true)}
          <Field id="p-desc" label="Описание" full><textarea className="input" id="p-desc" rows={3} value={p.description} onChange={(e) => set("description", e.target.value)} /></Field>
          {text("address", "Адрес", true)}
          {text("phone", "Телефон")}
          <Field id="p-accent" label="Акцентный цвет"><input className="input" id="p-accent" type="color" value={p.accent} onChange={(e) => set("accent", e.target.value.toUpperCase())} /></Field>
        </div>
      </section>
      <section className="panel stack"><h2>Три карточки на главной</h2>
        {p.cards.map((c, i) => (
          <div className="fields" key={i}>
            <Field id={`c-t-${i}`} label={`Заголовок ${i + 1}`}><input className="input" id={`c-t-${i}`} value={c.title} onChange={(e) => set("cards", p.cards.map((x, j) => (j === i ? { ...x, title: e.target.value } : x)))} /></Field>
            <Field id={`c-x-${i}`} label={`Текст ${i + 1}`}><input className="input" id={`c-x-${i}`} value={c.text} onChange={(e) => set("cards", p.cards.map((x, j) => (j === i ? { ...x, text: e.target.value } : x)))} /></Field>
          </div>
        ))}
      </section>
      <section className="panel stack"><h2>Правила записи</h2>
        <div className="fields">
          {rule("bufferMin", "Подготовка поста между машинами, мин")}
          <Field id="r-step" label="Шаг времени, мин"><select className="input" id="r-step" value={p.booking.stepMin} onChange={(e) => set("booking", { ...p.booking, stepMin: Number(e.target.value) as 15 | 30 | 60 })}>
            {[15, 30, 60].map((v) => <option key={v} value={v}>{v}</option>)}</select></Field>
          {rule("leadMin", "Запись не раньше чем через, мин")}
          {rule("cancelHours", "Онлайн-отмена не позже чем за, ч")}
          {rule("horizonDays", "Запись открыта на, дней вперёд")}
        </div>
      </section>
      <section className="panel stack"><h2>Персональные данные (Закон РБ № 99-З)</h2>
        <p className="muted small">Попадают в политику обработки данных и текст согласия в форме записи.</p>
        <div className="fields">
          <Field id="lg-op" label="Оператор: ИП или организация" full><input className="input" id="lg-op" value={legal.operator} onChange={(e) => set("legal", { ...legal, operator: e.target.value })} /></Field>
          <Field id="lg-unp" label="УНП"><input className="input mono" id="lg-unp" inputMode="numeric" maxLength={9} value={legal.unp} onChange={(e) => set("legal", { ...legal, unp: e.target.value.replace(/\D/g, "") })} /></Field>
          <Field id="lg-mail" label="Почта для обращений"><input className="input" id="lg-mail" type="email" value={legal.email} onChange={(e) => set("legal", { ...legal, email: e.target.value })} /></Field>
          <Field id="lg-addr" label="Юридический адрес" full><input className="input" id="lg-addr" value={legal.legalAddress} onChange={(e) => set("legal", { ...legal, legalAddress: e.target.value })} /></Field>
          <Field id="lg-days" label="Хранить данные клиентов, дней"><input className="input mono" id="lg-days" inputMode="numeric" value={legal.retentionDays} onChange={(e) => set("legal", { ...legal, retentionDays: Number(e.target.value.replace(/\D/g, "")) || 0 })} /></Field>
        </div>
      </section>
      {errs.length > 0 && <Notice kind="bad">{errs.map((x, i) => <div key={i}>{x}</div>)}</Notice>}
      <Result error={act.saveProfile.error} ok={act.saveProfile.isSuccess} okText="Сохранено. Сайт уже показывает новые данные." />
      <button className="btn primary block" disabled={act.saveProfile.isPending}>{act.saveProfile.isPending ? "Сохраняем…" : "Сохранить"}</button>
    </form>
  );
}

/* ------------------------------ услуги ------------------------------ */
function ServicesForm() {
  const { studio } = useStudioCtx();
  const act = useSettingsActions(studio.tenant.id, studio.tenant.slug);
  const [editing, setEditing] = useState<string | "new" | null>(null);
  return (
    <div className="stack">
      <p className="muted small">Изменение цены не меняет уже принятые записи: у них сохраняется цена на момент записи. Услуги не удаляются, а скрываются — на них ссылаются старые записи.</p>
      {studio.services.length === 0 && <Empty>Услуг пока нет.</Empty>}
      {studio.services.map((s) => editing === s.id ? <ServiceEdit key={s.id} s={s} onDone={() => setEditing(null)} act={act} sort={s.sort} /> : (
        <div key={s.id} className={`abk static${s.active ? "" : " dim"}`}>
          <span className="what">{s.name}{s.active ? "" : " · скрыта"}</span>
          <span className="when">{moneyBYN(s.price)} · {durationLabel(s.duration_min)}</span>
          <button className="btn small" onClick={() => setEditing(s.id)}>Изменить</button>
        </div>
      ))}
      {editing === "new" ? <ServiceEdit onDone={() => setEditing(null)} act={act} sort={studio.services.length} /> : <button className="btn" onClick={() => setEditing("new")}>Добавить услугу</button>}
    </div>
  );
}

function ServiceEdit({ s, onDone, act, sort }: { s?: { id: string; key: string; name: string; description: string; price: number; duration_min: number; active: boolean }; onDone: () => void; act: ReturnType<typeof useSettingsActions>; sort: number }) {
  const { studio } = useStudioCtx();
  const posts = studio.resources.filter((r) => r.active);
  const [chosen, setChosen] = useState<string[]>(() => (s ? studio.serviceResources.filter((x) => x.service_id === s.id).map((x) => x.resource_id) : []));
  const [f, setF] = useState({ name: s?.name ?? "", description: s?.description ?? "", price: String(s?.price ?? "").replace(".", ","), minutes: String(s?.duration_min ?? 60), active: s?.active ?? true });
  const [err, setErr] = useState("");
  const submit = (e: FormEvent) => {
    e.preventDefault();
    const price = Number(f.price.replace(",", ".").replace(/\s/g, ""));
    const dur = Number(f.minutes);
    if (f.name.trim().length < 2) return setErr("Название — хотя бы 2 символа");
    if (!(price >= 0) || Math.abs(price * 100 - Math.round(price * 100)) > 1e-6) return setErr("Цена: число, не больше двух знаков после запятой");
    if (!(dur >= 15 && dur <= 20160)) return setErr("Длительность от 15 минут до 14 суток (20160 мин)");
    setErr("");
    const posted = chosen.filter((id) => posts.some((p) => p.id === id));
    // все посты отмечены = «любой пост»: так новые посты тоже подхватят услугу
    act.saveService.mutate(
      { id: s?.id, name: f.name.trim(), description: f.description.trim(), price, duration_min: dur, active: f.active, sort, resourceIds: posted.length === posts.length ? [] : posted },
      { onSuccess: onDone, onError: (x) => setErr(humanError(x)) },
    );
  };
  return (
    <form className="panel stack" onSubmit={submit} noValidate>
      <div className="fields">
        <Field id="sv-n" label="Название" full><input className="input" id="sv-n" data-autofocus value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
        <Field id="sv-p" label="Цена, BYN"><input className="input mono" id="sv-p" inputMode="decimal" value={f.price} onChange={(e) => setF({ ...f, price: e.target.value })} /></Field>
        <Field id="sv-d" label="Длительность, мин" hint={Number(f.minutes) >= 15 ? durationLabel(Number(f.minutes)) : undefined}><input className="input mono" id="sv-d" inputMode="numeric" value={f.minutes} onChange={(e) => setF({ ...f, minutes: e.target.value.replace(/\D/g, "") })} /></Field>
        <Field id="sv-x" label="Что входит" full><input className="input" id="sv-x" value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} /></Field>
      </div>
      {posts.length > 1 && (
        <fieldset className="stack plain-fieldset">
          <legend className="muted small">На каких постах делаем (ничего не отмечено — на любом)</legend>
          {posts.map((p) => (
            <label key={p.id} className="check"><input type="checkbox" checked={chosen.includes(p.id)}
              onChange={(e) => setChosen(e.target.checked ? [...chosen, p.id] : chosen.filter((x) => x !== p.id))} /> {p.name}</label>
          ))}
        </fieldset>
      )}
      <label className="check"><input type="checkbox" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} /> Показывать на сайте</label>
      {err && <p className="err" role="alert">{err}</p>}
      <div className="row"><button className="btn primary" disabled={act.saveService.isPending}>Сохранить</button><button type="button" className="btn ghost" onClick={onDone}>Отмена</button></div>
    </form>
  );
}

/* ------------------------------ посты ------------------------------ */
function PostsForm() {
  const { studio } = useStudioCtx();
  const act = useSettingsActions(studio.tenant.id, studio.tenant.slug);
  const [name, setName] = useState("");
  const [names, setNames] = useState<Record<string, string>>({});
  return (
    <div className="stack">
      <p className="muted small">Пост (бокс, подъёмник) одновременно принимает одну машину. Выключенный пост не участвует в новой записи; старые записи на нём остаются.</p>
      {studio.resources.map((r) => (
        <div key={r.id} className="row">
          <input className="input" aria-label="Название поста" style={{ flex: 1 }} value={names[r.id] ?? r.name} onChange={(e) => setNames({ ...names, [r.id]: e.target.value })} />
          <button className="btn small" onClick={() => act.saveResource.mutate({ id: r.id, key: r.key, name: (names[r.id] ?? r.name).trim(), active: r.active, sort: r.sort })}>Сохранить</button>
          <button className="btn small ghost" onClick={() => act.saveResource.mutate({ id: r.id, key: r.key, name: r.name, active: !r.active, sort: r.sort })}>{r.active ? "Выключить" : "Включить"}</button>
        </div>
      ))}
      <div className="row">
        <input className="input" aria-label="Новый пост" placeholder="Пост 3" style={{ flex: 1 }} value={name} onChange={(e) => setName(e.target.value)} />
        <button className="btn" disabled={!name.trim()} onClick={() => act.saveResource.mutate({ key: `p${Date.now().toString(36)}`, name: name.trim(), active: true, sort: studio.resources.length }, { onSuccess: () => setName("") })}>Добавить пост</button>
      </div>
      <Result error={act.saveResource.error} ok={act.saveResource.isSuccess} okText="Посты сохранены" />
    </div>
  );
}

/* ------------------------------ график ------------------------------ */
const WD = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"];
function ScheduleForm() {
  const { studio } = useStudioCtx();
  const act = useSettingsActions(studio.tenant.id, studio.tenant.slug);
  const [rows, setRows] = useState(() => [1, 2, 3, 4, 5, 6, 0].map((wd) => {
    const h = studio.hours.find((x) => x.weekday === wd);
    return { weekday: wd, on: !!h, opens: h ? trimTime(h.opens) : "09:00", closes: h ? trimTime(h.closes) : "18:00" };
  }));
  const [ex, setEx] = useState({ day: "", closed: true, opens: "10:00", closes: "15:00", note: "" });
  const [err, setErr] = useState("");
  const today = todayIn(studio.tenant.timezone);
  const missing = upcomingHolidays(today, 365).filter((h) => !studio.exceptions.some((e) => e.day === h.date));

  const saveHours = () => {
    const bad = rows.find((r) => r.on && r.closes <= r.opens);
    if (bad) return setErr(`${WD[bad.weekday]}: закрытие должно быть позже открытия`);
    setErr("");
    act.saveHours.mutate(rows.filter((r) => r.on).map(({ weekday, opens, closes }) => ({ weekday, opens, closes })));
  };
  return (
    <div className="stack">
      <section className="panel stack"><h2>Часы приёма машин</h2>
        <p className="muted small">В эти часы клиент может привезти машину. Работы до 12 часов должны закончиться до закрытия; длинные работы идут через ночь.</p>
        {rows.map((r, i) => (
          <div key={r.weekday} className="hrow">
            <b>{WD[r.weekday]}</b>
            <input className="input mono" type="time" aria-label={`${WD[r.weekday]}: открытие`} disabled={!r.on} value={r.opens} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, opens: e.target.value } : x)))} />
            <input className="input mono" type="time" aria-label={`${WD[r.weekday]}: закрытие`} disabled={!r.on} value={r.closes} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, closes: e.target.value } : x)))} />
            <label className="check"><input type="checkbox" checked={r.on} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, on: e.target.checked } : x)))} /> рабочий</label>
          </div>
        ))}
        {err && <p className="err" role="alert">{err}</p>}
        <Result error={act.saveHours.error} ok={act.saveHours.isSuccess} okText="Часы сохранены" />
        <button className="btn primary" disabled={act.saveHours.isPending} onClick={saveHours}>Сохранить часы</button>
      </section>

      <section className="panel stack"><h2>Выходные и особые дни</h2>
        <div className="fields">
          <Field id="ex-d" label="Дата"><input className="input mono" type="date" id="ex-d" min={today} value={ex.day} onChange={(e) => setEx({ ...ex, day: e.target.value })} /></Field>
          <Field id="ex-n" label="Пометка"><input className="input" id="ex-n" maxLength={80} placeholder="Санитарный день" value={ex.note} onChange={(e) => setEx({ ...ex, note: e.target.value })} /></Field>
        </div>
        <label className="check"><input type="checkbox" checked={ex.closed} onChange={(e) => setEx({ ...ex, closed: e.target.checked })} /> Закрыто весь день</label>
        {!ex.closed && (
          <div className="fields">
            <Field id="ex-o" label="Открытие"><input className="input mono" type="time" id="ex-o" value={ex.opens} onChange={(e) => setEx({ ...ex, opens: e.target.value })} /></Field>
            <Field id="ex-c" label="Закрытие"><input className="input mono" type="time" id="ex-c" value={ex.closes} onChange={(e) => setEx({ ...ex, closes: e.target.value })} /></Field>
          </div>
        )}
        <div className="row">
          <button className="btn" disabled={!ex.day || act.saveException.isPending || (!ex.closed && ex.closes <= ex.opens)}
            onClick={() => act.saveException.mutate({ day: ex.day, closed: ex.closed, opens: ex.closed ? null : ex.opens, closes: ex.closed ? null : ex.closes, note: ex.note }, { onSuccess: () => setEx({ ...ex, day: "", note: "" }) })}>
            Сохранить день
          </button>
          <button className="btn ghost" disabled={!missing.length || act.saveException.isPending}
            onClick={async () => { for (const h of missing) await act.saveException.mutateAsync({ day: h.date, closed: true, opens: null, closes: null, note: h.name }); }}>
            {missing.length ? `Праздники РБ на год (${missing.length})` : "Праздники РБ уже добавлены"}
          </button>
        </div>
        <p className="muted small">Существующие записи на закрытый день не отменяются автоматически — перенесите их в разделе «Записи».</p>
        <Result error={act.saveException.error ?? act.removeException.error} ok={false} okText="" />
        {studio.exceptions.length === 0 ? <Empty>Особых дней нет.</Empty> : (
          <ul className="plain stack">
            {studio.exceptions.map((e) => (
              <li key={e.day} className="row between">
                <span>{dayLabel(e.day)} — {e.closed ? "выходной" : `${trimTime(e.opens!)}–${trimTime(e.closes!)}`}{e.note ? ` · ${e.note}` : ""}</span>
                <button className="btn small ghost" onClick={() => act.removeException.mutate(e.day)}>Убрать</button>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

/* ------------------------------ фото ------------------------------ */
function PhotosForm() {
  const { studio } = useStudioCtx();
  const act = useSettingsActions(studio.tenant.id, studio.tenant.slug);
  const p = studio.tenant.profile;
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");
  const [caps, setCaps] = useState<Record<string, string>>({});
  const [newCap, setNewCap] = useState("");

  const run = async (key: string, fn: () => Promise<void>, okText: string) => {
    setBusy(key); setErr(""); setOk("");
    try { await fn(); setOk(okText); } catch (e) { setErr(e instanceof Error && !("code" in e) ? e.message : humanError(e)); } finally { setBusy(null); }
  };
  const pick = async (e: ChangeEvent<HTMLInputElement>, max: number) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return null;
    if (!/^image\//.test(file.type)) throw new Error("Нужен файл изображения: JPG, PNG или WebP");
    return act.upload(await compressImage(file, max));
  };
  const replaceMedia = (k: "hero" | "logo") => (e: ChangeEvent<HTMLInputElement>) => run(k, async () => {
    const url = await pick(e, k === "logo" ? 512 : 2000);
    if (!url) return;
    const old = p.media?.[k];
    await act.saveProfile.mutateAsync({ ...p, media: { hero: p.media?.hero ?? "", logo: p.media?.logo ?? "", [k]: url } });
    if (old) await act.removeUpload(old);
  }, k === "hero" ? "Главное фото заменено" : "Логотип заменён. Иконка на телефоне обновится после переиздания оболочки.");

  return (
    <div className="stack">
      <section className="panel stack"><h2>Главное фото и логотип</h2>
        <div className="wedit"><img src={mediaUrl(p.media?.hero)} alt="Главное фото" />
          <div className="stack"><b>Главное фото</b><label className="btn small file-btn">{busy === "hero" ? "Загружаем…" : "Заменить фото"}<input type="file" accept="image/*" disabled={!!busy} onChange={replaceMedia("hero")} /></label></div></div>
        <div className="wedit"><img src={mediaUrl(p.media?.logo)} alt="Логотип" className="square" />
          <div className="stack"><b>Логотип</b><label className="btn small file-btn">{busy === "logo" ? "Загружаем…" : "Заменить логотип"}<input type="file" accept="image/*" disabled={!!busy} onChange={replaceMedia("logo")} /></label></div></div>
      </section>

      <section className="panel stack"><h2>Фотографии работ</h2>
        <p className="muted small">Замена фото или подписи меняет только эту карточку. Остальные работы остаются на месте.</p>
        {studio.works.length === 0 && <Empty>Работ пока нет — добавьте первую ниже.</Empty>}
        {studio.works.map((w) => (
          <div key={w.id} className="wedit">
            <img src={mediaUrl(w.photo_url)} alt={w.caption} />
            <div className="stack">
              <label className="btn small file-btn">{busy === w.id ? "Загружаем…" : "Заменить эту фотографию"}
                <input type="file" accept="image/*" disabled={!!busy} onChange={(e) => run(w.id, async () => {
                  const url = await pick(e, 1600);
                  if (!url) return;
                  await act.updateWork.mutateAsync({ id: w.id, photo_url: url });
                  await act.removeUpload(w.photo_url);
                }, "Фотография заменена")} /></label>
              <div className="row">
                <input className="input" aria-label="Подпись" maxLength={120} style={{ flex: 1, minWidth: 0 }} value={caps[w.id] ?? w.caption} onChange={(e) => setCaps({ ...caps, [w.id]: e.target.value })} />
                <button className="btn small" disabled={!!busy || !(caps[w.id] ?? w.caption).trim()} onClick={() => run(w.id, async () => { await act.updateWork.mutateAsync({ id: w.id, caption: (caps[w.id] ?? w.caption).trim() }); }, "Подпись сохранена")}>Сохранить подпись</button>
              </div>
              <button className="btn small ghost" disabled={!!busy} onClick={() => run(w.id, async () => { await act.removeWork.mutateAsync(w.id); await act.removeUpload(w.photo_url); }, "Карточка убрана")}>Убрать карточку</button>
            </div>
          </div>
        ))}
        <div className="wedit dashed">
          <div className="ph-new" aria-hidden="true">+</div>
          <div className="stack"><b>Новая карточка</b>
            <input className="input" aria-label="Подпись новой работы" placeholder="Подпись под фото" maxLength={120} value={newCap} onChange={(e) => setNewCap(e.target.value)} />
            <label className="btn small primary file-btn">{busy === "new" ? "Загружаем…" : "Выбрать фото и добавить"}
              <input type="file" accept="image/*" disabled={!!busy} onChange={(e) => run("new", async () => {
                const url = await pick(e, 1600);
                if (!url) return;
                await act.addWork.mutateAsync({ photo_url: url, caption: newCap.trim() || "Наша работа", sort: studio.works.length });
                setNewCap("");
              }, "Работа добавлена")} /></label>
          </div>
        </div>
      </section>
      {err && <Notice kind="bad">{err}</Notice>}
      {ok && <Notice kind="ok">{ok}</Notice>}
    </div>
  );
}

/* ------------------------------ запуск ------------------------------ */
function LaunchForm() {
  const { studio } = useStudioCtx();
  const act = useSettingsActions(studio.tenant.id, studio.tenant.slug);
  const p = studio.tenant.profile;
  const base = `/s/${studio.tenant.slug}/owner/settings`;
  const checks = [
    { ok: !!p.legal, text: "Данные оператора персональных данных (ИП или организация, УНП)", to: base },
    { ok: !/000-?00-?00/.test(p.phone), text: "Настоящий телефон студии", to: base },
    { ok: !/Укажите адрес/.test(p.address), text: "Адрес студии", to: base },
    { ok: studio.services.some((s) => s.active && !s.name.includes("(пример)")), text: "Свои услуги и цены", to: `${base}/services` },
    { ok: !(p.media?.hero ?? "").includes("/_default/"), text: "Своё главное фото (можно позже)", to: `${base}/photos`, optional: true },
  ];
  const ready = checks.every((c) => c.ok || c.optional);
  if (studio.tenant.mode === "live") return <Notice kind="ok">Студия работает: клиенты записываются, уведомления отправляются.</Notice>;
  return (
    <section className="panel stack"><h2>Запуск приёма записей</h2>
      <p className="muted small">Сейчас студия в режиме образца: записи помечаются как демо и уведомления не отправляются. После запуска демо-записи удалятся, а новые записи станут настоящими.</p>
      <ul className="plain stack">
        {checks.map((c) => (
          <li key={c.text} className="row between">
            <span>{c.ok ? "✓" : c.optional ? "○" : "✗"} {c.text}</span>
            {!c.ok && <NavLink className="link" to={c.to}>Заполнить</NavLink>}
          </li>
        ))}
      </ul>
      <Result error={act.goLive.error} ok={act.goLive.isSuccess} okText="Готово! Студия принимает настоящие записи." />
      <button className="btn primary block" disabled={!ready || act.goLive.isPending} onClick={() => act.goLive.mutate()}>
        {act.goLive.isPending ? "Запускаем…" : ready ? "Запустить приём записей" : "Сначала заполните пункты выше"}
      </button>
    </section>
  );
}

/* ------------------------------ аккаунт ------------------------------ */
function AccountForm() {
  return (
    <div className="stack">
      <EmailForm />
      <PasswordForm />
      <DangerZone />
    </div>
  );
}

/** Удаление студии или аккаунта самим владельцем — только с его текущим паролем. */
function DangerZone() {
  const { studio } = useStudioCtx();
  const [mode, setMode] = useState<null | "studio" | "account">(null);
  const [password, setPassword] = useState("");
  const [state, setState] = useState<{ busy: boolean; err: string; done: string }>({ busy: false, err: "", done: "" });
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!password) return setState({ busy: false, err: "Введите текущий пароль", done: "" });
    setState({ busy: true, err: "", done: "" });
    try {
      if (mode === "studio") {
        await deleteOwnStudio(studio.tenant.id, password);
        // кабинет удалённой студии больше не нужен: выходим и сбрасываем кэш (иначе видны старые данные)
        alert("Студия удалена вместе со всеми записями. Сейчас вы выйдете из кабинета.");
        await signOut(`/s/${studio.tenant.slug}/`); // откроется страница «Студия не найдена»
      } else {
        await deleteOwnAccount(password);
        alert("Аккаунт удалён. Сейчас вы выйдете из кабинета.");
        await signOut();
      }
    } catch (x) {
      setState({ busy: false, err: humanError(x), done: "" });
    }
  };
  if (state.done) return <Notice kind="ok">{state.done}</Notice>;
  return (
    <section className="panel stack danger-zone">
      <h2>Удаление</h2>
      {!mode && (
        <>
          <p className="muted small">Если нужно только временно закрыть онлайн-запись, напишите администратору сервиса — студию можно приостановить без удаления.</p>
          <div className="row">
            <button type="button" className="btn small ghost danger" onClick={() => setMode("studio")}>Удалить студию</button>
            <button type="button" className="btn small ghost danger" onClick={() => setMode("account")}>Удалить мой аккаунт</button>
          </div>
        </>
      )}
      {mode && (
        <form className="stack" onSubmit={submit} noValidate>
          <b>{mode === "studio" ? `Удалить «${studio.tenant.profile.name}» навсегда?` : "Удалить ваш аккаунт навсегда?"}</b>
          <p className="muted small">
            {mode === "studio"
              ? "Сайт студии перестанет открываться. Удалятся все записи клиентов, оплаты, статистика, услуги, график и фото. Вернуть нельзя."
              : "Войти с вашей почтой станет невозможно. Студия, записи и оплаты останутся — доступ к ним сможет выдать администратор сервиса."}
          </p>
          <Field id="dz-pw" label="Для подтверждения введите ваш пароль"><input className="input" id="dz-pw" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
          {state.err && <p className="err" role="alert">{state.err}</p>}
          <div className="row">
            <button className="btn small danger-solid" disabled={state.busy || !password}>{state.busy ? "Удаляем…" : mode === "studio" ? "Удалить студию" : "Удалить аккаунт"}</button>
            <button type="button" className="btn ghost small" onClick={() => { setMode(null); setPassword(""); setState({ busy: false, err: "", done: "" }); }}>Отмена</button>
          </div>
        </form>
      )}
    </section>
  );
}

function EmailForm() {
  const session = useSession();
  const current = session.data?.user.email ?? "";
  const [f, setF] = useState({ email: "", password: "" });
  const [state, setState] = useState<{ busy: boolean; err: string; ok: string }>({ busy: false, err: "", ok: "" });
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    const email = f.email.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return setState({ busy: false, err: "Проверьте новую почту", ok: "" });
    if (!f.password) return setState({ busy: false, err: "Введите текущий пароль — так мы убедимся, что это вы", ok: "" });
    setState({ busy: true, err: "", ok: "" });
    try {
      await changeOwnEmail(email, f.password);
      setF({ email: "", password: "" });
      setState({ busy: false, err: "", ok: `Готово. Теперь входите с почтой ${email.toLowerCase()} и прежним паролем.` });
    } catch (x) {
      setState({ busy: false, err: humanError(x), ok: "" });
    }
  };
  return (
    <form className="panel stack" onSubmit={submit} noValidate>
      <h2>Почта для входа</h2>
      <p className="muted small">Сейчас: <b>{current}</b>. Письмо-подтверждение не нужно: достаточно текущего пароля.</p>
      <div className="fields">
        <Field id="em-new" label="Новая почта"><input className="input" id="em-new" type="email" autoComplete="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
        <Field id="em-pw" label="Текущий пароль"><input className="input" id="em-pw" type="password" autoComplete="current-password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} /></Field>
      </div>
      {state.err && <p className="err" role="alert">{state.err}</p>}
      {state.ok && <Notice kind="ok">{state.ok}</Notice>}
      <button className="btn primary" disabled={state.busy || !f.email}>{state.busy ? "Сохраняем…" : "Сменить почту"}</button>
    </form>
  );
}

function PasswordForm() {
  const [pw, setPw] = useState({ a: "", b: "" });
  const [state, setState] = useState<{ busy: boolean; err: string; ok: boolean }>({ busy: false, err: "", ok: false });
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (pw.a.length < 8) return setState({ busy: false, err: "Пароль — не короче 8 символов", ok: false });
    if (pw.a !== pw.b) return setState({ busy: false, err: "Пароли не совпадают", ok: false });
    setState({ busy: true, err: "", ok: false });
    try {
      await changeOwnPassword(pw.a);
      setPw({ a: "", b: "" });
      setState({ busy: false, err: "", ok: true });
    } catch (x) {
      setState({ busy: false, err: humanError(x), ok: false });
    }
  };
  return (
    <form className="panel stack" onSubmit={submit} noValidate>
      <h2>Пароль</h2>
      <div className="fields">
        <Field id="pw-a" label="Новый пароль" hint="Не короче 8 символов"><input className="input" id="pw-a" type="password" autoComplete="new-password" value={pw.a} onChange={(e) => setPw({ ...pw, a: e.target.value })} /></Field>
        <Field id="pw-b" label="Повторите пароль"><input className="input" id="pw-b" type="password" autoComplete="new-password" value={pw.b} onChange={(e) => setPw({ ...pw, b: e.target.value })} /></Field>
      </div>
      {state.err && <p className="err" role="alert">{state.err}</p>}
      {state.ok && <Notice kind="ok">Пароль изменён. В следующий раз входите с новым паролем.</Notice>}
      <button className="btn primary" disabled={state.busy || !pw.a}>{state.busy ? "Сохраняем…" : "Сменить пароль"}</button>
    </form>
  );
}
