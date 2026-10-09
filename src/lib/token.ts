/**
 * Доступ клиента к записи без регистрации.
 * Токен (32 случайных байта) создаётся в браузере ДО отправки и хранится вместе с ключом идемпотентности.
 * Если ответ потерялся (сеть, перезагрузка), повтор уходит с тем же ключом и токеном — сервер
 * вернёт ту же запись, и доступ к ней сохранится. В базе лежит только sha256 токена.
 */
export type MyRef = { id: string; token: string; createdAt: string };
export type PendingAttempt = { key: string; token: string; payload: string };

const listKey = (slug: string) => `sgx:${slug}:bookings`;
const pendingKey = (slug: string) => `sgx:${slug}:pending`;

export function newToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function read<T>(k: string, d: T): T {
  try {
    const v = localStorage.getItem(k);
    return v ? (JSON.parse(v) as T) : d;
  } catch {
    return d;
  }
}
function write(k: string, v: unknown) {
  try {
    localStorage.setItem(k, JSON.stringify(v));
  } catch {
    /* приватный режим: запись создана, но не запомнится на этом устройстве */
  }
}

export const myBookings = (slug: string) => read<MyRef[]>(listKey(slug), []);
export function rememberBooking(slug: string, ref: MyRef) {
  const all = myBookings(slug).filter((r) => r.id !== ref.id);
  write(listKey(slug), [ref, ...all].slice(0, 30));
}
export function forgetBooking(slug: string, id: string) {
  write(listKey(slug), myBookings(slug).filter((r) => r.id !== id));
}

/** Попытка записи переживает перезагрузку: тот же payload → те же ключ и токен. */
export function attemptFor(slug: string, payload: string): PendingAttempt {
  const p = read<PendingAttempt | null>(pendingKey(slug), null);
  if (p && p.payload === payload) return p;
  const fresh = { key: crypto.randomUUID(), token: newToken(), payload };
  write(pendingKey(slug), fresh);
  return fresh;
}
export function clearAttempt(slug: string) {
  try {
    localStorage.removeItem(pendingKey(slug));
  } catch {
    /* ignore */
  }
}
