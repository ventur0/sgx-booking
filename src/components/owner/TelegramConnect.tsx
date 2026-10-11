import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { TelegramLogo, Trash } from "@phosphor-icons/react";
import { supabase } from "../../lib/supabase";
import { humanError } from "../../lib/errors";

/**
 * Уведомления владельцу в Telegram. Кнопка «Подключить» получает с сервера одноразовую ссылку на бота
 * (t.me/<бот>?start=<код>); владелец нажимает «Start» — чат привязывается к студии (это делает сервер,
 * опрашивая бота раз в 10 секунд). Здесь же список подключённых чатов и отключение.
 * compact — короткая строка-приглашение над записями, пока ни одного чата нет.
 */
type TgState = { configured: boolean; chats: { id: string; title: string; createdAt: string }[] };

export function useTelegram(tenantId: string) {
  return useQuery({
    queryKey: ["owner", tenantId, "telegram"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("owner_tg_list", { p_tenant: tenantId });
      if (error) throw error;
      return data as TgState;
    },
  });
}

export function TelegramConnect({ tenantId, compact = false }: { tenantId: string; compact?: boolean }) {
  const qc = useQueryClient();
  const q = useTelegram(tenantId);
  const [waiting, setWaiting] = useState(false);
  const [err, setErr] = useState("");
  const refresh = () => qc.invalidateQueries({ queryKey: ["owner", tenantId, "telegram"] });

  // после нажатия «Подключить» ждём, пока сервер увидит «Start» в боте (до 3 минут)
  useQuery({
    queryKey: ["owner", tenantId, "telegram-wait"],
    enabled: waiting,
    refetchInterval: 4000,
    queryFn: async () => {
      const before = q.data?.chats.length ?? 0;
      const { data } = await supabase.rpc("owner_tg_list", { p_tenant: tenantId });
      const now = (data as TgState | null)?.chats.length ?? 0;
      if (now > before) { setWaiting(false); link.reset(); void refresh(); }
      return now;
    },
  });

  const link = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc("owner_tg_link", { p_tenant: tenantId });
      if (error) throw error;
      return data as { bot: string; url: string };
    },
  });
  const remove = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc("owner_tg_remove", { p_tenant: tenantId, p_id: id });
      if (error) throw error;
    },
    onSuccess: refresh,
  });

  // ссылку получаем по первому нажатию, а открываем вторым — настоящей ссылкой (так её не блокирует ни один браузер)
  const getLink = () => { setErr(""); link.mutate(undefined, { onError: (e) => setErr(humanError(e)) }); };
  const opened = () => { setWaiting(true); setTimeout(() => setWaiting(false), 180_000); };

  if (!q.data?.configured) return null;
  const chats = q.data.chats;
  if (compact && chats.length) return null;

  const button = link.data ? (
    <a className="btn small primary" href={link.data.url} target="_blank" rel="noopener" onClick={opened}>Открыть бота в Telegram</a>
  ) : (
    <button className="btn small primary" disabled={link.isPending} onClick={getLink}>
      {link.isPending ? "Готовим ссылку…" : chats.length ? "Подключить ещё чат" : "Подключить"}
    </button>
  );
  const hint = waiting && <p className="muted small">В Telegram нажмите «Запустить» (Start) — через несколько секунд здесь появится подтверждение.</p>;

  if (compact)
    return (
      <div className="notify-ask">
        <TelegramLogo weight="fill" aria-hidden="true" />
        <span>Получайте новые записи и отмены сообщением в Telegram</span>
        {button}
        {hint}
        {err && <p className="err" role="alert">{err}</p>}
      </div>
    );

  return (
    <section className="panel stack">
      <h2>Уведомления в Telegram</h2>
      <p className="muted small">Каждая новая запись клиента и каждая отмена приходят сообщением: имя, телефон, услуга, время, машина и ссылка на запись в кабинете. Можно подключить несколько чатов, например свой и администратора.</p>
      {chats.length === 0 && <p>Пока не подключено.</p>}
      {chats.map((c) => (
        <div className="row-between" key={c.id}>
          <span><TelegramLogo weight="fill" aria-hidden="true" /> {c.title || "Чат Telegram"}</span>
          <button className="icon-btn" aria-label={`Отключить ${c.title || "чат"}`} disabled={remove.isPending} onClick={() => remove.mutate(c.id)}><Trash /></button>
        </div>
      ))}
      <div>{button}</div>
      {hint}
      {(err || remove.error) && <p className="err" role="alert">{err || humanError(remove.error)}</p>}
    </section>
  );
}
