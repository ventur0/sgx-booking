import { expect, test } from "@playwright/test";

/**
 * Сквозной сценарий: клиент выбирает услугу → дату → время → вводит данные → подтверждает,
 * затем владелец входит в кабинет и видит эту запись. В конце запись отменяется.
 * Нужны: TENANT (по умолчанию graphite), OWNER_EMAIL, OWNER_PASSWORD (локально — демо-владелец из seed).
 */
const TENANT = process.env.TENANT ?? "graphite";
const OWNER_EMAIL = process.env.OWNER_EMAIL ?? `owner@${TENANT}.local`;
const OWNER_PASSWORD = process.env.OWNER_PASSWORD ?? "demo-owner-pass";

test("запись от выбора услуги до появления у владельца", async ({ page, browser }, info) => {
  const stamp = `${info.project.name}-${Date.now().toString(36)}`;
  const name = `E2E ${stamp}`;

  await page.goto(`/s/${TENANT}/`);
  await expect(page.getByRole("navigation", { name: "Навигация" })).toBeVisible();
  await page.getByRole("button", { name: "Записаться" }).first().click();

  const sheet = page.getByRole("dialog");
  await expect(sheet).toBeVisible();
  await sheet.locator(".choice").first().click();
  await sheet.locator(".date:not([disabled])").first().click();
  await expect(sheet.locator(".times")).toBeVisible();
  // занятые слоты недоступны для выбора
  for (const busy of await sheet.locator(".time.busy").all()) await expect(busy).toBeDisabled();
  await sheet.locator(".time:not(.busy)").first().click();

  await sheet.getByLabel("Имя").fill(name);
  await sheet.getByLabel("Телефон").fill(`+375 29 ${String(Date.now()).slice(-7)}`);
  await sheet.getByLabel("Автомобиль").fill("Тестовая машина");
  await page.getByRole("button", { name: "Подтвердить запись" }).click();
  await expect(sheet.getByText("Нужно согласие на обработку персональных данных")).toBeVisible();
  await sheet.getByRole("checkbox").check();
  // двойное нажатие не создаёт копию: ключ идемпотентности один
  const confirm = page.getByRole("button", { name: "Подтвердить запись" });
  await Promise.all([confirm.click(), confirm.click({ force: true }).catch(() => {})]);
  await expect(page.getByRole("heading", { name: "Вы записаны" })).toBeVisible({ timeout: 20_000 });
  await page.getByRole("link", { name: "Открыть мою запись" }).click();
  await expect(page.getByText("Ждём вас")).toBeVisible();

  // владелец в отдельном контексте браузера
  const owner = await browser.newPage();
  await owner.goto(`/s/${TENANT}/owner/`);
  await owner.getByLabel("Почта").fill(OWNER_EMAIL);
  await owner.getByLabel("Пароль").fill(OWNER_PASSWORD);
  await owner.getByRole("button", { name: "Войти" }).click();
  await owner.getByRole("button", { name: "Неделя" }).click();
  // запись может быть на следующей неделе — листаем до 5 недель
  for (let i = 0; i < 5 && !(await owner.getByText(name).first().isVisible().catch(() => false)); i++) {
    await owner.getByRole("button", { name: "Вперёд" }).click();
    await owner.waitForTimeout(600);
  }
  await expect(owner.getByText(name)).toHaveCount(1);
  await owner.getByText(name).click();
  await owner.getByRole("button", { name: "Отменить" }).click();
  await owner.getByRole("button", { name: "Да, отменить" }).click();
  await expect(owner.getByRole("dialog").getByText("Отменена")).toBeVisible();
  await owner.close();
});
