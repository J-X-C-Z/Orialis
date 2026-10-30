import test from "node:test";
import assert from "node:assert/strict";

Object.defineProperty(globalThis, "sessionStorage", {
  configurable: true,
  value: { getItem: () => null, setItem() {}, removeItem() {} },
});
const { request, setToken } = await import("../src/api");

test("a response from a previous account cannot enter the new session", async () => {
  let resolve!: (response: Response) => void;
  Object.defineProperty(globalThis, "fetch", { configurable: true, value: () => new Promise<Response>((done) => { resolve = done; }) });
  setToken("account-a");
  const reading = request("/tasks");
  setToken("account-b");
  resolve(new Response(JSON.stringify({ private: "account-a" })));
  await assert.rejects(reading, /登录状态已变更/);
});

test("switching accounts while the response body is pending also discards it", async () => {
  let resolve!: (value: unknown) => void;
  Object.defineProperty(globalThis, "fetch", { configurable: true, value: async () => ({ ok: true, status: 200, json: () => new Promise((done) => { resolve = done; }) }) });
  setToken("account-a");
  const reading = request("/tasks");
  await Promise.resolve();
  setToken("");
  resolve({ private: "account-a" });
  await assert.rejects(reading, /登录状态已变更/);
});
