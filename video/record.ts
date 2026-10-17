/**
 * Видеоинструкции для покупателей: запись экрана телефона (Playwright) на локальной копии сайта
 * с демо-студией GRAPHITE и демо-владельцем из seed (только localhost). Подписи и «касания» рисуются поверх страницы.
 * Запуск: BASE_URL=http://localhost:4173 tsx video/record.ts → video/out/*.webm
 */
import { chromium, type Browser, type BrowserContext, type Locator, type Page } from "@playwright/test";
import { existsSync, mkdirSync, renameSync } from "node:fs";
import { join } from "node:path";

const BASE = process.env.BASE_URL ?? "http://localhost:4173";
const SLUG = "graphite";
const OWNER_EMAIL = `owner@${SLUG}.local`; // демо-владелец из supabase/seed.sql (только локально)
const OWNER_PASSWORD = "demo-owner-pass";
const OUT = join(process.cwd(), "video", "out");
mkdirSync(OUT, { recursive: true });

const VIEW = { width: 390, height: 844 };
const failures: string[] = [];

// ---------- подписи и касания поверх страницы ----------
// Скрипт страницы — строкой: tsx/esbuild добавляет в функции служебные вызовы (__name), которых нет в браузере.
const OVERLAY = String.raw`(() => {
  const css = "#vcap{position:fixed;left:10px;right:10px;top:10px;z-index:2147483647;pointer-events:none;" +
    "background:rgba(10,14,20,.92);color:#fff;border:1px solid rgba(70,144,255,.7);border-radius:16px;padding:12px 14px;" +
    "font:600 18px/1.3 -apple-system,Segoe UI,Roboto,sans-serif;box-shadow:0 10px 30px rgba(0,0,0,.5)}" +
    "#vcap small{display:block;font-weight:400;font-size:15px;color:#c9d6ea;margin-top:4px}#vcap:empty{display:none}" +
    ".vtap{position:fixed;z-index:2147483646;width:44px;height:44px;margin:-22px 0 0 -22px;border-radius:50%;pointer-events:none;" +
    "background:rgba(70,144,255,.35);border:3px solid #4690ff;animation:vtap .7s ease-out forwards}" +
    "@keyframes vtap{0%{transform:scale(.4);opacity:1}100%{transform:scale(1.5);opacity:0}}";
  function mount() {
    if (!document.body || document.getElementById("vcap")) return;
    var st = document.createElement("style"); st.textContent = css; document.head.appendChild(st);
    var d = document.createElement("div"); d.id = "vcap"; document.body.appendChild(d);
    try { var saved = sessionStorage.getItem("vcap"); if (saved) d.innerHTML = saved; } catch (e) {}
  }
  window.__cap = function (html) {
    mount(); try { sessionStorage.setItem("vcap", html); } catch (e) {}
    var el = document.getElementById("vcap"); if (el) el.innerHTML = html;
  };
  window.__tap = function (x, y) {
    if (!document.body) return;
    var t = document.createElement("div"); t.className = "vtap"; t.style.left = x + "px"; t.style.top = y + "px";
    document.body.appendChild(t); setTimeout(function () { t.remove(); }, 800);
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount); else mount();
})();`;

const wait = (p: Page, ms: number) => p.waitForTimeout(ms);
async function cap(p: Page, title: string, sub = "", hold = 1800) {
  await p.evaluate((h) => (window as unknown as { __cap: (s: string) => void }).__cap(h), sub ? `${title}<small>${sub}</small>` : title).catch(() => {});
  await wait(p, hold);
}
async function tap(p: Page, loc: Locator, after = 900) {
  await loc.scrollIntoViewIfNeeded({ timeout: 8000 });
  const box = await loc.boundingBox();
  if (box) await p.evaluate(([x, y]) => (window as unknown as { __tap?: (a: number, b: number) => void }).__tap?.(x, y), [box.x + box.width / 2, box.y + box.height / 2]).catch(() => {});
  await wait(p, 450);
  await loc.click({ timeout: 8000 });
  await wait(p, after);
}
async function type(p: Page, loc: Locator, text: string) {
  await tap(p, loc, 200);
  await loc.fill("");
  await loc.pressSequentially(text, { delay: 55 });
  await wait(p, 300);
}
async function scrollBy(p: Page, dy: number, ms = 900) {
  await p.evaluate((d) => window.scrollBy({ top: d, behavior: "smooth" }), dy);
  await wait(p, ms);
}
let current: Page | null = null;
async function step(name: string, fn: () => Promise<void>) {
  try { await fn(); } catch (e) {
    failures.push(`${name}: ${(e as Error).message.split("\n")[0]}`);
    console.warn("⚠", name, (e as Error).message.split("\n")[0]);
    if (current) {
      const f = name.replace(/[^a-zа-я0-9]+/gi, "-");
      await current.screenshot({ path: join(OUT, `fail-${f}.png`) }).catch(() => {});
      const txt = await current.evaluate(() => document.body.innerText.slice(0, 600)).catch(() => "");
      console.warn("   текст страницы:", txt.replace(/\s+/g, " "));
    }
  }
}
async function titleCard(p: Page, num: string, title: string, lines: string[]) {
  await p.evaluate(() => (window as unknown as { __cap: (s: string) => void }).__cap("")).catch(() => {});
  await p.setContent(`<html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;height:100vh;display:flex;flex-direction:column;justify-content:center;padding:32px;box-sizing:border-box;
    background:radial-gradient(120% 80% at 50% 0%,#12305f,#050607 70%);color:#fff;font-family:-apple-system,Segoe UI,Roboto,sans-serif">
    <div style="color:#4690ff;font:700 15px/1 sans-serif;letter-spacing:.12em;text-transform:uppercase">Видеоинструкция ${num}</div>
    <h1 style="font-size:34px;line-height:1.15;margin:14px 0 18px">${title}</h1>
    ${lines.map((l) => `<p style="font-size:18px;line-height:1.4;color:#c9d6ea;margin:6px 0">• ${l}</p>`).join("")}
    <p style="margin-top:36px;font-size:14px;color:#7f8ea3">Онлайн-запись для автосервисов и детейлинга</p></body></html>`);
  await wait(p, 3800);
}
async function endCard(p: Page, text: string) {
  await p.evaluate(() => (window as unknown as { __cap: (s: string) => void }).__cap("")).catch(() => {});
  await p.setContent(`<html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;text-align:center;padding:32px;box-sizing:border-box;
    background:#050607;color:#fff;font-family:-apple-system,Segoe UI,Roboto,sans-serif"><div><div style="font-size:54px">✓</div>
    <h2 style="font-size:26px;line-height:1.25">${text}</h2></div></body></html>`);
  await wait(p, 2500);
}

async function newRecorded(browser: Browser, name: string, storageStateIn?: string): Promise<{ ctx: BrowserContext; page: Page; save: () => Promise<void> }> {
  const ctx = await browser.newContext({
    viewport: VIEW, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: "ru-RU", timezoneId: "Europe/Minsk",
    userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36",
    colorScheme: "dark", storageState: storageStateIn && existsSync(storageStateIn) ? storageStateIn : undefined, recordVideo: { dir: OUT, size: { width: VIEW.width * 2, height: VIEW.height * 2 } },
  });
  await ctx.addInitScript({ content: OVERLAY });
  const page = await ctx.newPage();
  current = page;
  return {
    ctx, page,
    save: async () => {
      const v = page.video();
      await ctx.close();
      if (v) renameSync(await v.path(), join(OUT, `${name}.webm`));
    },
  };
}

async function ownerLogin(p: Page) {
  await p.goto(`${BASE}/s/${SLUG}/owner/`);
  if (await p.getByLabel("Почта").isVisible({ timeout: 6000 }).catch(() => false)) {
    await type(p, p.getByLabel("Почта"), OWNER_EMAIL);
    await type(p, p.getByLabel("Пароль"), OWNER_PASSWORD);
    await tap(p, p.getByRole("button", { name: "Войти" }), 2500);
    const err = await p.locator(".err").first().textContent({ timeout: 1000 }).catch(() => null);
    if (err) console.warn("   вход:", err);
  }
  await p.getByRole("button", { name: "Неделя" }).waitFor({ timeout: 15000 });
}

// быстрая запись «клиента» в отдельном окне без видео — чтобы показать, как она приходит владельцу
async function quickClientBooking(browser: Browser, who: { name: string; phone: string; car: string }, serviceIndex = 0, timeIndex = 1) {
  const ctx = await browser.newContext({ viewport: VIEW, locale: "ru-RU", timezoneId: "Europe/Minsk" });
  const p = await ctx.newPage();
  await p.goto(`${BASE}/s/${SLUG}/`);
  await p.getByRole("button", { name: "Записаться" }).first().click();
  const sheet = p.getByRole("dialog");
  await sheet.locator(".choice").nth(serviceIndex).click();
  await sheet.locator(".date:not([disabled])").nth(1).click();
  const times = sheet.locator(".time:not(.busy)");
  await times.first().waitFor({ timeout: 10000 });
  await (await times.count() > timeIndex ? times.nth(timeIndex) : times.first()).click();
  await sheet.locator("#bk-name").fill(who.name);
  await sheet.locator("#bk-phone").fill(who.phone);
  await sheet.locator("#bk-car").fill(who.car);
  await sheet.getByRole("checkbox").check();
  await p.getByRole("button", { name: "Подтвердить запись" }).click();
  await p.getByRole("heading", { name: "Вы записаны" }).waitFor({ timeout: 20000 });
  await ctx.close();
}

// =====================================================================
async function video1(browser: Browser) {
  const { page: p, save } = await newRecorded(browser, "01-kak-klient-zapisyvaetsya");
  await titleCard(p, "1", "Как клиент записывается", ["Без регистрации и установки", "Только свободное время", "Запись сразу у вас в кабинете"]);
  await p.goto(`${BASE}/s/${SLUG}/`);
  await wait(p, 1500);
  await cap(p, "Это сайт вашей студии", "Клиент открывает ссылку из Instagram, карт или мессенджера", 3000);
  await step("прокрутка главной", async () => {
    await scrollBy(p, 520); await cap(p, "Преимущества студии", "Три карточки — тексты меняете сами", 2200);
    await p.getByRole("heading", { name: "Услуги и цены" }).scrollIntoViewIfNeeded(); await wait(p, 600);
    await cap(p, "Услуги и цены", "Цены и длительность работ — из вашего кабинета", 2600);
    await p.getByRole("heading", { name: "Наши работы" }).scrollIntoViewIfNeeded(); await wait(p, 600);
    await cap(p, "Фото ваших работ", "", 2200);
    await p.getByRole("heading", { name: "Как нас найти" }).scrollIntoViewIfNeeded(); await wait(p, 600);
    await cap(p, "Адрес, телефон и часы работы", "Кнопки «Позвонить» и «Открыть на карте»", 2600);
    await p.evaluate(() => window.scrollTo({ top: 0, behavior: "smooth" })); await wait(p, 1200);
  });
  const sheet = p.getByRole("dialog");
  await step("запись", async () => {
    await cap(p, "Клиент нажимает «Записаться»", "", 900);
    await tap(p, p.getByRole("button", { name: "Записаться" }).first(), 1200);
    await cap(p, "1. Выбирает услугу", "Видны цена и время работы", 1500);
    await tap(p, sheet.locator(".choice").first(), 1200);
    await cap(p, "2. Выбирает дату", "Выходные и праздники РБ закрыты автоматически", 2000);
    await tap(p, sheet.locator(".date:not([disabled])").nth(1), 1200);
    await cap(p, "3. Выбирает свободное время", "Занятое время отмечено и недоступно — накладок не будет", 2600);
    await tap(p, sheet.locator(".time:not(.busy)").nth(2), 1200);
    await cap(p, "4. Оставляет имя, телефон и машину", "", 900);
    await type(p, sheet.locator("#bk-name"), "Андрей");
    await type(p, sheet.locator("#bk-phone"), "+375 29 555-12-34");
    await type(p, sheet.locator("#bk-car"), "VW Passat B8");
    await cap(p, "Согласие на обработку данных", "По Закону РБ № 99-З", 1200);
    await tap(p, sheet.getByRole("checkbox"), 700);
    await tap(p, p.getByRole("button", { name: "Подтвердить запись" }), 500);
    await p.getByRole("heading", { name: "Вы записаны" }).waitFor({ timeout: 20000 });
    await cap(p, "Готово — клиент записан", "Запись в ту же секунду появляется у вас в кабинете", 3200);
    await sheet.getByText("Сообщить о готовности").or(sheet.getByText("Добавить в календарь")).first().scrollIntoViewIfNeeded().catch(() => {});
    await cap(p, "Напоминание и уведомления", "Клиент может добавить запись в календарь и включить уведомление о готовности машины", 3200);
    await tap(p, p.getByRole("link", { name: "Открыть мою запись" }), 1800);
    await cap(p, "«Моя запись»", "Статус обновляется сам: «Машина принята» → «Готова, можно забирать»", 3500);
    await scrollBy(p, 400, 1200);
    await cap(p, "Отменить запись клиент может сам", "По вашим правилам — например, не позже чем за 4 часа", 3000);
  });
  await endCard(p, "Клиент записался сам — без звонка и переписки");
  await save();
}

async function video2(browser: Browser, statePath: string) {
  const { ctx, page: p, save } = await newRecorded(browser, "02-kabinet-zapisi-i-statusy");
  await titleCard(p, "2", "Кабинет: новые записи и статусы", ["Вход по почте и паролю", "Новая запись приходит сразу", "Принята → готова → оплачена"]);
  await step("вход", async () => {
    await p.goto(`${BASE}/s/${SLUG}/owner/`);
    await cap(p, "Кабинет владельца", "Адрес: ссылка студии + /owner. Входите по почте и паролю", 2600);
    await ownerLogin(p);
    await ctx.storageState({ path: statePath });
    await cap(p, "Записи на сегодня", "Переключатель «День / Неделя», стрелки — другие дни", 3000);
  });
  await step("новая запись приходит", async () => {
    await cap(p, "Клиент записывается на сайте…", "Смотрите, что происходит у вас", 1200);
    await quickClientBooking(browser, { name: "Ольга", phone: "+375 33 700-11-22", car: "Toyota RAV4" }, 0, 3);
    await p.locator(".alert-card").first().waitFor({ timeout: 40000 });
    await cap(p, "Новая запись — сразу со звуком", "Если кабинет свёрнут или закрыт — уведомление на телефон", 3200);
    await tap(p, p.locator(".alert-card").first().getByRole("button", { name: "Открыть" }), 1800);
  });
  const sheet = p.getByRole("dialog");
  await step("статусы", async () => {
    await sheet.waitFor({ timeout: 8000 });
    await cap(p, "Карточка записи", "Клиент, телефон (нажмите — позвонит), машина и цена", 3200);
    await cap(p, "Машина приехала", "Нажмите «Принять машину» — клиент видит это у себя", 1200);
    await tap(p, sheet.getByRole("button", { name: "Принять машину" }), 1500);
    await cap(p, "Работа закончена", "«Машина готова» — клиенту приходит «Готова, можно забирать»", 1500);
    await tap(p, sheet.getByRole("button", { name: "Машина готова" }), 1500);
    await cap(p, "Оплата", "Наличные, карта или ЕРИП. Можно частями и с возвратом", 1200);
    await tap(p, sheet.getByRole("button", { name: "Оплата / возврат" }), 1000);
    await tap(p, sheet.getByRole("button", { name: "Внести оплату" }), 1600);
    await cap(p, "Клиент забрал машину", "«Выдана, завершить» — запись выполнена", 1200);
    await tap(p, sheet.getByRole("button", { name: "Выдана, завершить" }), 1800);
    await cap(p, "Всё учтено", "Оплата и статус сохранены — они попадут в «Итоги»", 2600);
    await p.keyboard.press("Escape"); await wait(p, 900);
  });
  await step("неделя", async () => {
    await tap(p, p.getByRole("button", { name: "Неделя" }), 1200);
    await cap(p, "Вся неделя одним списком", "Видно, какие посты и дни уже заняты", 3200);
  });
  await endCard(p, "Все записи и деньги — в одном кабинете");
  await save();
}

async function video3(browser: Browser, statePath: string) {
  const { page: p, save } = await newRecorded(browser, "03-zapis-po-telefonu-perenos-blokirovka", statePath);
  await titleCard(p, "3", "Запись по телефону, перенос и блокировка", ["Клиент позвонил или приехал сам", "Перенос в два нажатия", "Закрыть пост на время"]);
  await ownerLogin(p);
  const sheet = p.getByRole("dialog");
  await step("ручная запись", async () => {
    await cap(p, "Клиент позвонил или приехал без записи", "Нажмите «+ Запись»", 1500);
    await tap(p, p.getByRole("button", { name: "Запись", exact: true }), 1400);
    await cap(p, "Услуга, дата и свободное время", "Как у клиента на сайте — накладку сделать нельзя", 1200);
    const day = new Date(Date.now() + 2 * 864e5);
    while (day.getUTCDay() === 0 || day.getUTCDay() === 6) day.setUTCDate(day.getUTCDate() + 1);
    await sheet.getByLabel("Дата").fill(day.toISOString().slice(0, 10));
    await wait(p, 1500);
    await tap(p, sheet.locator(".time:not(.busy)").nth(4), 900);
    await type(p, sheet.locator("#nb-name"), "Сергей");
    await type(p, sheet.locator("#nb-phone"), "+375 44 123-45-67");
    await type(p, sheet.locator("#nb-car"), "BMW X5");
    await tap(p, p.getByRole("button", { name: "Записать клиента" }), 2000);
    await cap(p, "Время занято", "Онлайн на это время уже никто не запишется", 3000);
  });
  await step("перенос", async () => {
    await tap(p, p.locator(".abk", { hasText: "Сергей" }).first(), 1400);
    await cap(p, "Перенести на другое время", "", 900);
    await tap(p, sheet.getByRole("button", { name: "Перенести" }), 1400);
    await tap(p, sheet.locator(".time:not(.busy)").first(), 900);
    await tap(p, sheet.getByRole("button", { name: "Перенести" }).last(), 1800);
    await cap(p, "Готово — запись перенесена", "Если клиент включил уведомления, он получит новое время", 2800);
    await p.keyboard.press("Escape"); await wait(p, 800);
  });
  await step("блокировка", async () => {
    await tap(p, p.getByRole("link", { name: "Блокировки" }), 1500);
    await cap(p, "Блокировки", "Пост на ремонте, обед или своя машина — закройте время, и онлайн его не займут", 3200);
    await p.getByLabel("С (время)").fill("13:00").catch(() => {});
    await p.getByLabel("По (время)").fill("14:00").catch(() => {});
    await type(p, p.getByLabel("Причина"), "Обед");
    await tap(p, p.getByRole("button", { name: "Заблокировать", exact: true }), 1800);
    await cap(p, "Пост заблокирован", "Снять блокировку — одной кнопкой", 2600);
  });
  await endCard(p, "Звонки, переносы и перерывы — без накладок");
  await save();
}

async function video4(browser: Browser, statePath: string) {
  const { page: p, save } = await newRecorded(browser, "04-ceny-uslugi-grafik-foto", statePath);
  await titleCard(p, "4", "Цены, услуги, график и фото", ["Всё меняете сами, без программиста", "Изменения сразу на сайте"]);
  await ownerLogin(p);
  await p.goto(`${BASE}/s/${SLUG}/owner/settings`);
  await wait(p, 1500);
  await step("студия", async () => {
    await cap(p, "Настройки → Студия", "Название, телефон, адрес, описание, цвет", 3000);
    await scrollBy(p, 700, 1200);
    await cap(p, "Три карточки на главной и правила записи", "Например: за сколько часов можно отменить", 3000);
    await p.evaluate(() => window.scrollTo({ top: 0, behavior: "smooth" })); await wait(p, 900);
  });
  await step("услуги", async () => {
    await tap(p, p.getByRole("link", { name: "Услуги" }), 1400);
    await cap(p, "Услуги и цены", "Нажмите «Изменить» у нужной услуги", 1800);
    await tap(p, p.getByRole("button", { name: "Изменить" }).first(), 1200);
    await type(p, p.getByLabel("Цена, BYN"), "49,90");
    await tap(p, p.getByRole("button", { name: "Сохранить" }).first(), 1800);
    await cap(p, "Новая цена уже на сайте", "Старые записи остаются по старой цене", 2800);
    await cap(p, "Новая услуга — «Добавить услугу»", "Название, цена, длительность и посты", 2400);
  });
  await step("график", async () => {
    await tap(p, p.getByRole("link", { name: "График" }), 1400);
    await cap(p, "Часы приёма машин", "Для каждого дня недели", 2800);
    await p.getByRole("heading", { name: "Выходные и особые дни" }).scrollIntoViewIfNeeded(); await wait(p, 700);
    await cap(p, "Выходные и особые дни", "Праздники РБ добавляются одной кнопкой", 2400);
    const d = new Date(Date.now() + 20 * 864e5).toISOString().slice(0, 10);
    await p.getByLabel("Дата").fill(d);
    await type(p, p.getByLabel("Пометка"), "Санитарный день");
    await tap(p, p.getByRole("button", { name: "Сохранить день" }), 1800);
    await cap(p, "День закрыт для записи", "", 2400);
  });
  await step("фото", async () => {
    await tap(p, p.getByRole("link", { name: "Фото" }), 1400);
    await cap(p, "Главное фото, логотип и фото работ", "Заменить, добавить карточку, поменять подпись", 3000);
    await scrollBy(p, 600, 1200);
    await cap(p, "Загружайте прямо с телефона", "Фото сжимаются автоматически", 2600);
  });
  await endCard(p, "Сайт всегда актуален — вы управляете им сами");
  await save();
}

async function video5(browser: Browser, statePath: string) {
  const { page: p, save } = await newRecorded(browser, "05-itogi-uvedomleniya-zapusk", statePath);
  await titleCard(p, "5", "Итоги, уведомления и запуск", ["Сколько машин и денег", "Уведомления на телефон", "Как запустить приём записей"]);
  await ownerLogin(p);
  await p.goto(`${BASE}/s/${SLUG}/owner/stats`);
  await wait(p, 1800);
  await step("итоги", async () => {
    await cap(p, "Итоги", "Заезды, выполненные заказы, отмены и реально полученные деньги", 3400);
    await scrollBy(p, 300, 1200);
    await cap(p, "День, неделя или свой период", "Полученные деньги считаются отдельно от ожидаемой стоимости", 3000);
  });
  await step("уведомления", async () => {
    await p.goto(`${BASE}/s/${SLUG}/owner/settings/notifications`); await wait(p, 1500);
    await cap(p, "Уведомления о новых записях", "Нажмите «Включить» — записи будут приходить на телефон, даже когда кабинет закрыт", 3800);
    await cap(p, "На iPhone", "Сначала «Поделиться» → «На экран „Домой“», затем включите здесь", 3200);
  });
  await step("запуск", async () => {
    await p.goto(`${BASE}/s/${SLUG}/owner/settings/launch`); await wait(p, 1500);
    await cap(p, "Запуск приёма записей", "Пока студия — образец, сверху плашка «Образец». Заполните данные и нажмите «Запуск»", 3800);
  });
  await step("аккаунт", async () => {
    await p.goto(`${BASE}/s/${SLUG}/owner/settings/account`); await wait(p, 1500);
    await cap(p, "Аккаунт", "Смените временный пароль на свой", 3000);
  });
  await endCard(p, "Готово! Студия принимает записи онлайн");
  await save();
}

// =====================================================================
const browser = await chromium.launch();
const statePath = join(OUT, "owner-state.json");
const only = process.argv[2];
const run = async (n: string, f: () => Promise<void>) => { if (!only || only === n) { console.log("▶ видео", n); await f(); } };
await run("1", () => video1(browser));
await run("2", () => video2(browser, statePath));
await run("3", () => video3(browser, statePath));
await run("4", () => video4(browser, statePath));
await run("5", () => video5(browser, statePath));
await browser.close();
console.log(failures.length ? `\nШаги с ошибками (${failures.length}):\n- ${failures.join("\n- ")}` : "\nВсе шаги записаны без ошибок");
