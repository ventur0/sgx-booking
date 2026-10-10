import { useState, type FormEvent } from "react";
import { Link, NavLink, Route, Routes } from "react-router-dom";
import { CalendarDots, ChartBar, Gear, Prohibit, SignOut } from "@phosphor-icons/react";
import { useStudioCtx } from "../client/StudioLayout";
import { signOut, useMembership, useSession } from "../../data/owner";
import { supabase } from "../../lib/supabase";
import { humanError } from "../../lib/errors";
import { ErrorState, Field, Loading, Notice } from "../../components/ui/States";
import { AgendaPage } from "./AgendaPage";
import { BlocksPage } from "./BlocksPage";
import { StatsPage } from "./StatsPage";
import { SettingsPage } from "./SettingsPage";
import { NewBookingAlerts } from "../../components/owner/NewBookingAlerts";

/**
 * Кабинет /s/<slug>/owner/. Вход только по почте и паролю (Supabase Auth), регистрации нет:
 * аккаунт владельцу создаёт конвейер. Студия подтверждается сервером через is_member().
 */
export function OwnerPage() {
  const { studio } = useStudioCtx();
  const { tenant } = studio;
  const session = useSession();
  const member = useMembership(tenant.id, session.data?.user.id);
  const base = `/s/${tenant.slug}/owner`;

  const head = (
    <header className="owner-head">
      <Link className="link" to={`/s/${tenant.slug}/`}>← На сайт</Link>
      <div><span className="eyebrow">Кабинет</span><h1>{tenant.profile.name}</h1></div>
      {session.data && <button className="icon-btn" aria-label="Выйти" onClick={() => void signOut()}><SignOut /></button>}
    </header>
  );

  if (session.isLoading) return <main className="wrap pad-top">{head}<Loading /></main>;
  if (!session.data) return <main className="wrap pad-top">{head}<Login /></main>;
  if (member.isLoading) return <main className="wrap pad-top">{head}<Loading label="Проверяем доступ" /></main>;
  if (member.error) return <main className="wrap pad-top">{head}<ErrorState error={member.error} onRetry={() => member.refetch()} /></main>;
  if (!member.data)
    return (
      <main className="wrap pad-top">{head}
        <Notice kind="warn">Аккаунт {session.data.user.email} не владеет этой студией. Войдите под почтой владельца.</Notice>
        <button className="btn" onClick={() => void signOut()}>Выйти</button>
      </main>
    );

  return (
    <div className="owner">
      <main className="wrap pad-top owner-main">
        {head}
        <NewBookingAlerts tenantId={tenant.id} tz={tenant.timezone} base={base} studioName={tenant.profile.name} />
        {tenant.mode === "preview" && <Notice kind="info">Студия в режиме образца: записи помечены как демо, уведомления клиентам не отправляются. <Link className="link" to={`${base}/settings/launch`}>Как запустить →</Link></Notice>}
        {tenant.suspended && <Notice kind="warn">Онлайн-запись приостановлена администратором сервиса. Сайт открывается, но новые записи не принимаются.</Notice>}
        <Routes>
          <Route index element={<AgendaPage />} />
          <Route path="blocks" element={<BlocksPage />} />
          <Route path="stats" element={<StatsPage />} />
          <Route path="settings/*" element={<SettingsPage />} />
        </Routes>
      </main>
      <nav className="tabbar glass" aria-label="Разделы кабинета">
        <NavLink end to={`${base}/`} className="tab"><CalendarDots weight="fill" /><span>Записи</span></NavLink>
        <NavLink to={`${base}/blocks`} className="tab"><Prohibit weight="bold" /><span>Блокировки</span></NavLink>
        <NavLink to={`${base}/stats`} className="tab"><ChartBar weight="fill" /><span>Итоги</span></NavLink>
        <NavLink to={`${base}/settings`} className="tab"><Gear weight="fill" /><span>Настройки</span></NavLink>
      </nav>
    </div>
  );
}

export function Login({ title = "Вход для владельца" }: { title?: string }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setErr("");
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (error) setErr(humanError(error));
  };
  return (
    <form className="panel login" onSubmit={submit} noValidate>
      <h2>{title}</h2>
      <Field id="l-email" label="Почта"><input className="input" id="l-email" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
      <Field id="l-pass" label="Пароль"><input className="input" id="l-pass" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
      {err && <p className="err" role="alert">{err}</p>}
      <button className="btn primary block" disabled={busy || !email || !password}>{busy ? "Входим…" : "Войти"}</button>
      <p className="muted small">Регистрации нет: доступ выдаёт администратор при публикации студии.</p>
    </form>
  );
}
