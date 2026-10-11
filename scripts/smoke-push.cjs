// Проверка собранной функции /api/push без сети: модуль загружается, GET → 405, кривое тело → 400.
const { Readable } = require("node:stream");
const mod = require("../.vercel/output/functions/api/push.func/index.js");
const fn = mod.default || mod;
const call = (method, body) =>
  new Promise((resolve) => {
    const req = Readable.from(body ? [body] : []);
    req.method = method;
    req.setEncoding = () => req;
    const res = { statusCode: 0, headers: {}, setHeader(k, v) { this.headers[k] = v; }, end(b) { resolve({ status: this.statusCode, body: String(b) }); } };
    fn(req, res);
  });
(async () => {
  const a = await call("GET");
  const b = await call("POST", JSON.stringify({ job: "x", nonce: "y" }));
  const c = await call("POST", "не json");
  console.log("GET:", a.status, "| bad ids:", b.status, "| bad json:", c.status);
  if (typeof fn !== "function" || a.status !== 405 || b.status !== 400 || c.status !== 400) process.exit(1);
  console.log("✓ /api/push загружается и проверяет запросы");
})().catch((e) => { console.error(e); process.exit(1); });
