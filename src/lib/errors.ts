/** Коды ошибок серверных функций → понятный текст для человека. */
const MESSAGES: Record<string, string> = {
  slot_taken: "Это время только что заняли. Выберите другое — ваши данные сохранились.",
  too_soon: "На это время уже нельзя записаться онлайн. Выберите время позже.",
  too_far: "Так далеко вперёд запись пока закрыта.",
  closed: "В этот день студия не работает.",
  outside_hours: "Это время вне графика приёма.",
  service_not_found: "Эта услуга сейчас недоступна.",
  tenant_not_found: "Студия не найдена. Проверьте ссылку.",
  rate_limited: "Слишком много запросов подряд. Подождите немного или позвоните в студию.",
  consent_required: "Отметьте согласие на обработку персональных данных.",
  bad_phone: "Проверьте номер: например +375 29 123-45-67.",
  bad_client_data: "Проверьте имя и автомобиль.",
  bad_token: "Ссылка на запись повреждена.",
  idempotency_conflict: "Запрос уже был отправлен с другого устройства. Обновите страницу.",
  not_found: "Запись не найдена или данные по ней удалены.",
  cannot_cancel_late: "Отменить онлайн уже нельзя: до начала слишком мало времени. Позвоните в студию.",
  cannot_cancel_status: "Эту запись уже нельзя отменить онлайн.",
  cannot_move_status: "Завершённую или отменённую запись перенести нельзя.",
  bad_transition: "Такой переход статуса невозможен.",
  refund_exceeds_paid: "Возврат не может быть больше оплаченной суммы.",
  bad_amount: "Введите сумму больше нуля, не больше двух знаков после запятой.",
  block_conflict: "На это время уже есть запись или блокировка.",
  bad_range: "Проверьте начало и конец периода.",
  cannot_anonymize_active: "Удалить данные можно только у завершённой или отменённой записи.",
  forbidden: "Нет прав на это действие.",
  in_past: "Нельзя записать на прошедшую дату.",
  config_invalid: "Настройки не сохранены: проверьте поля.",
  studio_suspended: "Онлайн-запись в этой студии временно недоступна. Позвоните в студию.",
  not_ready_legal: "Сначала заполните данные оператора персональных данных в настройках студии.",
  not_ready_phone: "Сначала укажите настоящий телефон студии.",
  bad_slug: "Адрес студии: латинские буквы, цифры и дефис, от 2 до 40 символов.",
  bad_name: "Укажите название студии.",
  slug_taken: "Такой адрес уже занят. Придумайте другой.",
  weak_password: "Пароль — не короче 8 символов.",
  wrong_password: "Текущий пароль указан неверно.",
  email_taken: "Эта почта уже занята другим аккаунтом.",
  functions_missing: "Функция admin-users не установлена в Supabase. См. инструкцию «Панель продавца».",
  "should be different from the old password": "Новый пароль совпадает со старым.",
  "Password should be at least": "Пароль слишком короткий.",
  "Invalid login credentials": "Неверная почта или пароль.",
};

export function errorCode(e: unknown): string | null {
  const msg = (e as { message?: string })?.message ?? String(e ?? "");
  return Object.keys(MESSAGES).find((k) => msg.includes(k)) ?? null;
}

export function humanError(e: unknown): string {
  const code = errorCode(e);
  if (code) return MESSAGES[code];
  const msg = (e as { message?: string })?.message ?? "";
  if (/Failed to fetch|NetworkError|network|Load failed/i.test(msg)) return "Нет связи с сервером. Проверьте интернет и попробуйте ещё раз.";
  return "Что-то пошло не так. Попробуйте ещё раз.";
}

/** Сетевая ошибка, после которой стоит повторить тот же запрос с тем же ключом. */
export const isRetryable = (e: unknown) => errorCode(e) === null && /fetch|network|Load failed|timeout/i.test((e as { message?: string })?.message ?? "");
