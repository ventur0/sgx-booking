import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "../../lib/supabase";
import { humanError } from "../../lib/errors";
import { Field, Notice } from "../../components/ui/States";

/**
 * Панель продавца: один Telegram-бот на весь сервис. Токен отправляется в базу и обратно не показывается.
 * Владельцы подключают свои чаты сами в кабинете (Настройки → Telegram).
 */
type TgAdmin = { configured: boolean; bot: string | null; siteUrl: string; lastOkAt: string | null; lastError: string | null; chats: number; studios: number; netReady: boolean };

export function TelegramSettings() {
  const qc = useQueryClient();
  const q = useQuery({
    queryKey: ["admin", "telegram"],
    refetchInterval: 30_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("admin_tg_get");
      if (error) throw error;
      return data as TgAdmin;
    },
  });
  const [f, setF] = useState({ token: "", bot: "", site: "" });
  const [ok, setOk] = useState("");
  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc("admin_tg_set", { p_token: f.token.trim() || null, p_bot: f.bot || q.data?.bot || "", p_site: f.site || q.data?.siteUrl || "" });
      if (error) throw error;
    },
    onSuccess: () => { setF({ token: "", bot: "", site: "" }); setOk("Сохранено. Владельцы могут подключать Telegram в кабинете: Настройки → Telegram."); void qc.invalidateQueries({ queryKey: ["admin", "telegram"] }); },
  });
  const submit = (e: FormEvent) => { e.preventDefault(); setOk(""); save.mutate(); };

  if (q.error) {
    const missing = /admin_tg_get|function|schema cache/i.test((q.error as { message?: string }).message ?? "");
    return (
      <section className="panel stack">
        <h2>Уведомления в Telegram</h2>
        <Notice kind="warn">{missing ? "В базе ещё не выполнен файл 16-telegram.sql (Supabase → SQL Editor → вставить → Run)." : humanError(q.error)}</Notice>
      </section>
    );
  }
  const d = q.data;
  return (
    <form className="panel stack" onSubmit={submit} noValidate>
      <h2>Уведомления в Telegram</h2>
      {d?.configured ? (
        <Notice kind={d.lastError ? "warn" : "ok"}>
          Бот @{d.bot} подключён. Чатов: {d.chats}, студий: {d.studios}.
          {d.lastOkAt ? ` Бот на связи (${new Date(d.lastOkAt).toLocaleTimeString("ru-RU")}).` : " Ждём первого ответа от Telegram (до минуты)."}
          {d.lastError ? ` Последняя ошибка: ${d.lastError}` : ""}
        </Notice>
      ) : (
        <ol className="muted small" style={{ margin: 0, paddingLeft: 18 }}>
          <li>В Telegram откройте @BotFather → /newbot, придумайте название и имя бота (на _bot).</li>
          <li>BotFather пришлёт токен — длинную строку вида 123456789:AA…</li>
          <li>Вставьте токен и имя бота ниже и нажмите «Сохранить».</li>
        </ol>
      )}
      {d && !d.netReady && <Notice kind="warn">В базе нет расширения pg_net: сообщения не будут отправляться. Supabase → Database → Extensions → pg_net → Enable.</Notice>}
      <div className="fields">
        <Field id="tg-token" label={d?.configured ? "Новый токен (если меняете бота)" : "Токен бота"} hint="Хранится только в базе, обратно не показывается">
          <input className="input mono" id="tg-token" type="password" autoComplete="off" value={f.token} onChange={(e) => setF({ ...f, token: e.target.value })} />
        </Field>
        <Field id="tg-bot" label="Имя бота" hint="например sgx_booking_bot">
          <input className="input mono" id="tg-bot" autoComplete="off" placeholder={d?.bot ?? ""} value={f.bot} onChange={(e) => setF({ ...f, bot: e.target.value })} />
        </Field>
        <Field id="tg-site" label="Адрес сайта для ссылок в сообщениях">
          <input className="input mono" id="tg-site" autoComplete="off" placeholder={d?.siteUrl ?? "https://sgx-booking-ten.vercel.app"} value={f.site} onChange={(e) => setF({ ...f, site: e.target.value })} />
        </Field>
      </div>
      {save.error && <p className="err" role="alert">{humanError(save.error)}</p>}
      {ok && <Notice kind="ok">{ok}</Notice>}
      <button className="btn primary block" disabled={save.isPending || (!d?.configured && (!f.token || !f.bot))}>{save.isPending ? "Сохраняем…" : "Сохранить"}</button>
    </form>
  );
}
