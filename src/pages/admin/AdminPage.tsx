import { useEffect, useState, type FormEvent } from "react";
import { SignOut } from "@phosphor-icons/react";
import { signOut, useSession } from "../../data/owner";
import { existingAccount, makePassword, slugify, useAdminActions, useIsPlatformAdmin, useStudios, type StudioRow } from "../../data/admin";
import { humanError } from "../../lib/errors";
import { Empty, ErrorState, Field, Loading, Notice } from "../../components/ui/States";
import { Login } from "../owner/OwnerPage";

/**
 * /admin — панель продавца сервиса. Здесь создаются студии и выдаётся доступ владельцам;
 * всё остальное (услуги, цены, график, фото, пароль, запуск) владелец делает сам в своём кабинете.
 */
export function AdminPage() {
  const session = useSession();
  const admin = useIsPlatformAdmin(session.data?.user.id);
  const studios = useStudios(admin.data === true);
  const [notice, setNotice] = useState("");

  useEffect(() => {
    document.title = "Панель продавца";
  }, []);

  const head = (
    <header className="owner-head">
      <span />
      <div><span className="eyebrow">Сервис онлайн-записи</span><h1>Панель продавца</h1></div>
      {session.data && <button className="icon-btn" aria-label="Выйти" onClick={() => void signOut()}><SignOut /></button>}
    </header>
  );

  if (session.isLoading) return <main className="wrap pad-top">{head}<Loading /></main>;
  if (!session.data) return <main className="wrap pad-top">{head}<Login title="Вход для продавца" /></main>;
  if (admin.isLoading) return <main className="wrap pad-top">{head}<Loading label="Проверяем доступ" /></main>;
  if (admin.error) return <main className="wrap pad-top">{head}<ErrorState error={admin.error} onRetry={() => admin.refetch()} /></main>;
  if (!admin.data)
    return (
      <main className="wrap pad-top">{head}
        <Notice kind="warn">Аккаунт {session.data.user.email} не является продавцом сервиса. Владельцы студий входят по ссылке своей студии: /s/адрес/owner.</Notice>
        <button className="btn" onClick={() => void signOut()}>Выйти</button>
      </main>
    );

  return (
    <main className="wrap pad-top stack admin">
      {head}
      <NewStudio />
      <section className="stack">
        <h2>Студии{studios.data ? ` · ${studios.data.length}` : ""}</h2>
        {notice && <Notice kind="ok">{notice}</Notice>}
        {studios.isLoading && <Loading rows={3} />}
        {studios.error && <ErrorState error={studios.error} onRetry={() => studios.refetch()} />}
        {studios.data?.length === 0 && <Empty>Студий пока нет.</Empty>}
        {studios.data?.map((s) => <StudioCard key={s.id} s={s} onNotice={setNotice} />)}
      </section>
    </main>
  );
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Выдать доступ: новый аккаунт создаётся с временным паролем. Если аккаунт с этой почтой уже есть,
 * продавец явно подтверждает привязку (пароль у такого аккаунта прежний — его знает только владелец).
 */
async function giveAccess(act: ReturnType<typeof useAdminActions>, a: { tenantId: string; email: string; password: string }) {
  try {
    return await act.createOwner.mutateAsync(a);
  } catch (e) {
    const studios = existingAccount(e);
    if (!studios) throw e;
    const list = studios.length ? `\nУ него уже есть студии: ${studios.join(", ")}.` : "";
    if (!confirm(`Аккаунт ${a.email} уже существует.${list}\n\nПривязать его к этой студии? Пароль у аккаунта останется прежним — убедитесь, что почта принадлежит вашему покупателю.`))
      throw new Error("cancelled");
    return await act.createOwner.mutateAsync({ ...a, linkExisting: true });
  }
}

const origin = () => location.origin;
const siteUrl = (slug: string) => `${origin()}/s/${slug}/`;
const ownerUrl = (slug: string) => `${origin()}/s/${slug}/owner`;

/** Текст для покупателя: ссылки, логин и временный пароль — одной кнопкой «Скопировать». */
function Handoff({ slug, name, email, password, onClose }: { slug: string; name: string; email: string; password: string | null; onClose: () => void }) {
  const text = [
    `Ваша онлайн-запись «${name}» готова.`,
    ``,
    `Сайт для клиентов: ${siteUrl(slug)}`,
    `Кабинет владельца: ${ownerUrl(slug)}`,
    `Почта для входа: ${email}`,
    password ? `Временный пароль: ${password}` : `Пароль: прежний, от вашего аккаунта`,
    ``,
    `В кабинете → Настройки заполните услуги, цены, график, фото и данные ИП, затем «Запуск».`,
    password ? `Пароль смените в Настройки → Аккаунт.` : ``,
  ].filter((x, i, a) => x !== "" || a[i - 1] !== "").join("\n");
  const [copied, setCopied] = useState(false);
  return (
    <div className="panel stack handoff">
      <b>Отправьте покупателю</b>
      <pre className="handoff-text">{text}</pre>
      <div className="row">
        <button type="button" className="btn primary" onClick={() => void navigator.clipboard.writeText(text).then(() => setCopied(true))}>{copied ? "Скопировано ✓" : "Скопировать"}</button>
        <button type="button" className="btn ghost" onClick={onClose}>Готово</button>
      </div>
    </div>
  );
}

function NewStudio() {
  const act = useAdminActions();
  const [f, setF] = useState({ name: "", slug: "", slugTouched: false, email: "", password: makePassword() });
  const [err, setErr] = useState("");
  const [done, setDone] = useState<{ slug: string; name: string; email: string; password: string | null } | null>(null);
  const [created, setCreated] = useState("");
  const busy = act.createStudio.isPending || act.createOwner.isPending;
  const slug = f.slugTouched ? f.slug : slugify(f.name);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setErr("");
    setCreated("");
    if (!f.name.trim()) return setErr("Укажите название студии");
    if (!/^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$/.test(slug)) return setErr(humanError({ message: "bad_slug" }));
    const email = f.email.trim();
    if (email && !EMAIL_RE.test(email)) return setErr("Проверьте почту владельца");
    let tenantId: string;
    try {
      tenantId = await act.createStudio.mutateAsync({ slug, name: f.name.trim() });
    } catch (x) {
      return setErr(humanError(x));
    }
    if (!email) {
      setDone(null);
      setF({ name: "", slug: "", slugTouched: false, email: "", password: makePassword() });
      return setCreated(`Студия создана: ${siteUrl(slug)}. Доступ владельцу выдайте в её карточке ниже.`);
    }
    try {
      const r = await giveAccess(act, { tenantId, email, password: f.password });
      setDone({ slug, name: f.name.trim(), email, password: r.created ? f.password : null });
      setF({ name: "", slug: "", slugTouched: false, email: "", password: makePassword() });
    } catch (x) {
      setErr(`Студия создана, но аккаунт владельца — нет: ${humanError(x)} Выдайте доступ в карточке студии ниже.`);
    }
  };

  return (
    <section className="stack">
      {done && <Handoff {...done} onClose={() => setDone(null)} />}
      <form className="panel stack" onSubmit={submit} noValidate>
        <h2>Новая студия</h2>
        <p className="muted small">Создаётся заготовка: один пост, услуга-пример и график пн–сб. Остальное владелец заполнит сам в своём кабинете.</p>
        <div className="fields">
          <Field id="ns-name" label="Название студии"><input className="input" id="ns-name" maxLength={60} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
          <Field id="ns-slug" label="Адрес на сайте" hint={slug ? `${origin()}/s/${slug}/` : "латиница, цифры, дефис"}>
            <input className="input mono" id="ns-slug" maxLength={40} value={slug} onChange={(e) => setF({ ...f, slug: e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""), slugTouched: true })} />
          </Field>
          <Field id="ns-email" label="Почта владельца (логин)" hint="Можно оставить пустым и выдать доступ позже">
            <input className="input" id="ns-email" type="email" autoComplete="off" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} />
          </Field>
          <Field id="ns-pass" label="Временный пароль" hint="Владелец сменит его в кабинете">
            <div className="row"><input className="input mono" id="ns-pass" autoComplete="off" style={{ flex: 1, minWidth: 0 }} value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} />
              <button type="button" className="btn small ghost" onClick={() => setF({ ...f, password: makePassword() })}>Новый</button></div>
          </Field>
        </div>
        {err && <p className="err" role="alert">{err}</p>}
        {created && <Notice kind="ok">{created}</Notice>}
        <button className="btn primary block" disabled={busy}>{busy ? "Создаём…" : "Создать студию"}</button>
      </form>
    </section>
  );
}

function StudioCard({ s, onNotice }: { s: StudioRow; onNotice: (text: string) => void }) {
  const act = useAdminActions();
  const me = useSession().data?.user.id;
  const [panel, setPanel] = useState<null | { kind: "add" | "delete" } | { kind: "password" | "email" | "deleteUser"; userId: string; email: string }>(null);
  const [confirmText, setConfirmText] = useState("");
  const myEmail = useSession().data?.user.email ?? "";
  // подтверждение удаления студии: почта любого её владельца; если владельцев нет — ваша почта продавца
  const studioConfirmOk = s.owners.length
    ? s.owners.some((o) => o.email.toLowerCase() === confirmText.trim().toLowerCase())
    : !!myEmail && confirmText.trim().toLowerCase() === myEmail.toLowerCase();
  const [val, setVal] = useState({ email: "", password: makePassword() });
  const [msg, setMsg] = useState<{ kind: "ok" | "bad"; text: string } | null>(null);
  const [handoff, setHandoff] = useState<{ email: string; password: string | null } | null>(null);

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setMsg(null);
    try {
      await fn();
      setMsg({ kind: "ok", text: ok });
      setPanel(null);
    } catch (x) {
      setMsg({ kind: "bad", text: humanError(x) });
    }
  };
  const open = (p: NonNullable<typeof panel>) => {
    setPanel(p);
    setMsg(null);
    setVal({ email: p.kind === "email" ? p.email : "", password: makePassword() });
  };

  return (
    <article className="panel stack">
      <div className="row between">
        <div>
          <b>{s.name}</b>
          <div className="muted small mono">/s/{s.slug}/</div>
        </div>
        <div className="row">
          <span className={`pill ${s.mode === "live" ? "ok" : ""}`}>{s.mode === "live" ? "Работает" : "Образец"}</span>
          {s.suspended && <span className="pill bad">Приостановлена</span>}
        </div>
      </div>
      <DomainRow s={s} />
      <p className="muted small">Записей за 30 дней: {s.bookings30}{s.lastBookingAt ? ` · последняя ${new Date(s.lastBookingAt).toLocaleDateString("ru-BY")}` : ""}</p>
      <div className="row">
        <a className="btn small ghost" href={siteUrl(s.slug)} target="_blank" rel="noreferrer">Сайт</a>
        <a className="btn small ghost" href={ownerUrl(s.slug)} target="_blank" rel="noreferrer">Кабинет</a>
        <button className="btn small ghost" onClick={() => void run(() => act.setSuspended.mutateAsync({ tenantId: s.id, suspended: !s.suspended }), s.suspended ? "Запись возобновлена" : "Онлайн-запись приостановлена")}>
          {s.suspended ? "Возобновить" : "Приостановить"}
        </button>
        <button className="btn small ghost danger" onClick={() => { open({ kind: "delete" }); setConfirmText(""); }}>Удалить</button>
      </div>

      <div className="stack">
        <span className="eyebrow">Владельцы</span>
        {s.owners.length === 0 && <p className="muted small">Доступа ещё ни у кого нет.</p>}
        {s.owners.map((o) => (
          <div key={o.userId} className="row between">
            <span>{o.email}</span>
            <div className="row">
              <button className="btn small ghost" onClick={() => open({ kind: "password", userId: o.userId, email: o.email })}>Новый пароль</button>
              <button className="btn small ghost" onClick={() => open({ kind: "email", userId: o.userId, email: o.email })}>Сменить почту</button>
              <button className="btn small ghost" onClick={() => {
                if (confirm(`Убрать доступ ${o.email} к «${s.name}»? Записи студии останутся.`))
                  void run(() => act.removeOwner.mutateAsync({ tenantId: s.id, userId: o.userId }), "Доступ убран");
              }}>Убрать</button>
              {o.userId !== me && (
                <button className="btn small ghost danger" onClick={() => { open({ kind: "deleteUser", userId: o.userId, email: o.email }); setConfirmText(""); }}>Удалить аккаунт</button>
              )}
            </div>
          </div>
        ))}
        {!panel && <button className="btn small" onClick={() => open({ kind: "add" })}>Выдать доступ владельцу</button>}
      </div>

      {panel?.kind === "add" && (
        <form className="stack" noValidate onSubmit={(e) => {
          e.preventDefault();
          const email = val.email.trim();
          void run(async () => {
            if (!EMAIL_RE.test(email)) throw new Error("bad_email");
            const r = await giveAccess(act, { tenantId: s.id, email, password: val.password });
            setHandoff({ email, password: r.created ? val.password : null });
          }, "Доступ выдан");
        }}>
          <div className="fields">
            <Field id={`ao-e-${s.id}`} label="Почта владельца"><input className="input" id={`ao-e-${s.id}`} type="email" data-autofocus value={val.email} onChange={(e) => setVal({ ...val, email: e.target.value })} /></Field>
            <Field id={`ao-p-${s.id}`} label="Временный пароль" hint="Если аккаунт с этой почтой уже есть, пароль не меняется"><input className="input mono" id={`ao-p-${s.id}`} value={val.password} onChange={(e) => setVal({ ...val, password: e.target.value })} /></Field>
          </div>
          <div className="row"><button className="btn primary small" disabled={act.createOwner.isPending}>Выдать доступ</button><button type="button" className="btn ghost small" onClick={() => setPanel(null)}>Отмена</button></div>
        </form>
      )}
      {panel?.kind === "password" && (
        <form className="stack" noValidate onSubmit={(e) => {
          e.preventDefault();
          void run(async () => {
            await act.setPassword.mutateAsync({ userId: panel.userId, password: val.password });
            setHandoff({ email: panel.email, password: val.password });
          }, "Пароль изменён");
        }}>
          <Field id={`sp-${s.id}`} label={`Новый пароль для ${panel.email}`}><input className="input mono" id={`sp-${s.id}`} value={val.password} onChange={(e) => setVal({ ...val, password: e.target.value })} /></Field>
          <div className="row"><button className="btn primary small" disabled={act.setPassword.isPending}>Сохранить пароль</button><button type="button" className="btn ghost small" onClick={() => setPanel(null)}>Отмена</button></div>
        </form>
      )}
      {panel?.kind === "email" && (
        <form className="stack" noValidate onSubmit={(e) => {
          e.preventDefault();
          void run(() => act.changeEmail.mutateAsync({ userId: panel.userId, email: val.email.trim() }), "Почта изменена. Пароль остался прежним.");
        }}>
          <Field id={`ce-${s.id}`} label={`Новая почта вместо ${panel.email}`}><input className="input" id={`ce-${s.id}`} type="email" value={val.email} onChange={(e) => setVal({ ...val, email: e.target.value })} /></Field>
          <div className="row"><button className="btn primary small" disabled={act.changeEmail.isPending}>Сменить почту</button><button type="button" className="btn ghost small" onClick={() => setPanel(null)}>Отмена</button></div>
        </form>
      )}
      {panel?.kind === "delete" && (
        <form className="stack panel danger-zone" noValidate onSubmit={(e) => {
          e.preventDefault();
          void run(async () => {
            await act.deleteStudio.mutateAsync({ tenantId: s.id, confirmEmail: confirmText.trim() });
            onNotice(`Студия «${s.name}» удалена`); // карточка исчезнет из списка — сообщение показываем над ним
          }, "Студия удалена");
        }}>
          <b>Удалить «{s.name}» навсегда?</b>
          <p className="muted small">Сайт перестанет открываться. Удалятся все записи клиентов, оплаты, статистика, услуги, график и фото. Вернуть нельзя. Если нужно только временно закрыть запись — нажмите «Приостановить».</p>
          <Field id={`del-${s.id}`} label={s.owners.length ? "Для подтверждения введите почту владельца студии" : "Владельцев нет — для подтверждения введите вашу почту (почту продавца)"}>
            <input className="input" id={`del-${s.id}`} type="email" autoComplete="off" value={confirmText} onChange={(e) => setConfirmText(e.target.value)} />
          </Field>
          <div className="row">
            <button className="btn small danger-solid" disabled={!studioConfirmOk || act.deleteStudio.isPending}>{act.deleteStudio.isPending ? "Удаляем…" : "Удалить навсегда"}</button>
            <button type="button" className="btn ghost small" onClick={() => setPanel(null)}>Отмена</button>
          </div>
        </form>
      )}
      {panel?.kind === "deleteUser" && (
        <form className="stack panel danger-zone" noValidate onSubmit={(e) => {
          e.preventDefault();
          void run(() => act.deleteUser.mutateAsync({ userId: panel.userId, confirmEmail: confirmText.trim() }), `Аккаунт ${panel.email} удалён`);
        }}>
          <b>Удалить аккаунт владельца навсегда?</b>
          <p className="muted small">Войти с этой почтой станет невозможно, доступ пропадёт ко всем его студиям. Сами студии, записи и оплаты останутся — доступ можно выдать другому человеку.</p>
          <Field id={`du-${s.id}`} label="Для подтверждения введите почту этого аккаунта">
            <input className="input" id={`du-${s.id}`} type="email" autoComplete="off" value={confirmText} onChange={(e) => setConfirmText(e.target.value)} />
          </Field>
          <div className="row">
            <button className="btn small danger-solid" disabled={confirmText.trim().toLowerCase() !== panel.email.toLowerCase() || act.deleteUser.isPending}>{act.deleteUser.isPending ? "Удаляем…" : "Удалить аккаунт"}</button>
            <button type="button" className="btn ghost small" onClick={() => setPanel(null)}>Отмена</button>
          </div>
        </form>
      )}
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {handoff && <Handoff slug={s.slug} name={s.name} email={handoff.email} password={handoff.password} onClose={() => setHandoff(null)} />}
    </article>
  );
}

/** Собственный домен студии: продавец вписывает домен, покупатель (или вы) подключает его в Cloudflare. */
function DomainRow({ s }: { s: StudioRow }) {
  const act = useAdminActions();
  const [edit, setEdit] = useState(false);
  const [val, setVal] = useState(s.customDomain ?? "");
  const [err, setErr] = useState("");
  const save = (e: FormEvent) => {
    e.preventDefault();
    setErr("");
    act.setDomain.mutate({ tenantId: s.id, domain: val }, { onSuccess: () => setEdit(false), onError: (x) => setErr(humanError(x)) });
  };
  return (
    <div className="stack">
      <div className="row between">
        <span className="muted small">
          Домен: {s.customDomain ? <a className="link mono" href={`https://${s.customDomain}/`} target="_blank" rel="noreferrer">{s.customDomain}</a> : "не подключён"}
        </span>
        <button className="btn small ghost" onClick={() => { setEdit(!edit); setVal(s.customDomain ?? ""); }}>{s.customDomain ? "Изменить домен" : "Свой домен…"}</button>
      </div>
      {edit && (
        <form className="stack" onSubmit={save} noValidate>
          <Field id={`dm-${s.id}`} label="Домен студии" hint="Например zapis.studio.by. Пусто — отключить">
            <input className="input mono" id={`dm-${s.id}`} autoComplete="off" value={val} onChange={(e) => setVal(e.target.value)} />
          </Field>
          <p className="muted small">После сохранения добавьте этот домен в Cloudflare: Workers & Pages → sgx-booking → Custom domains → Set up a custom domain. Cloudflare покажет запись DNS (CNAME), которую нужно добавить у регистратора домена. Через 5–30 минут сайт студии откроется по этому адресу.</p>
          <div className="row"><button className="btn primary small" disabled={act.setDomain.isPending}>Сохранить</button><button type="button" className="btn ghost small" onClick={() => setEdit(false)}>Отмена</button></div>
        </form>
      )}
      {err && <p className="err" role="alert">{err}</p>}
    </div>
  );
}
