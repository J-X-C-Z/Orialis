import test from "node:test";
import assert from "node:assert/strict";
import { AutoSync } from "../src/auto-sync";

const deferred = () => {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
};

test("automatic refresh preserves editing, coalesces reads, retries and stops", async () => {
  let editing = true;
  let count = 0;
  const pending = deferred();
  const sync = new AutoSync(async () => { count++; await pending.promise; }, () => !editing);
  await sync.refresh();
  assert.equal(count, 0);
  editing = false;
  const first = sync.refresh();
  await sync.refresh();
  assert.equal(count, 1);
  pending.resolve();
  await first;
  await sync.refresh();
  assert.equal(count, 2);
  sync.dispose();
  await sync.refresh();
  assert.equal(count, 2);
});

test("network failure allows a later refresh", async () => {
  let count = 0;
  const sync = new AutoSync(async () => { if (++count === 1) throw new Error("offline"); }, () => true);
  await sync.refresh();
  await sync.refresh();
  sync.dispose();
  assert.equal(count, 2);
});

test("foreground polling and online events stop when disposed", async (t) => {
  const document = new EventTarget();
  const window = new EventTarget();
  Object.defineProperty(globalThis, "document", { configurable: true, value: document });
  Object.defineProperty(globalThis, "window", { configurable: true, value: window });
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let count = 0;
  const sync = new AutoSync(async () => { count++; }, () => true);
  sync.start();
  t.mock.timers.tick(30_000);
  await Promise.resolve();
  assert.equal(count, 1);
  window.dispatchEvent(new Event("online"));
  await Promise.resolve();
  assert.equal(count, 2);
  document.dispatchEvent(new Event("visibilitychange"));
  await Promise.resolve();
  assert.equal(count, 3);
  sync.dispose();
  window.dispatchEvent(new Event("online"));
  t.mock.timers.tick(30_000);
  assert.equal(count, 3);
});
