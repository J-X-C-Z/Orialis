import test from "node:test";
import assert from "node:assert/strict";

// A small DOM stand-in keeps these flow tests dependency-free. Browser layout is
// covered separately; scroll metrics here deliberately model a scrollable list.
class ElementStub extends EventTarget {
  inner = "";
  textContent = "";
  value = "";
  disabled = false;
  checked = false;
  isConnected = true;
  clientHeight = 300;
  dataset: Record<string, string> = {};
  nodes = new Map<string, ElementStub>();
  scrollHeight = 20;
  private top = 0;
  get innerHTML() { return this.inner; }
  set innerHTML(value: string) {
    this.inner = value;
    this.scrollHeight = Math.max(20, (value.match(/<article/g)?.length ?? 0) * 100);
  }
  get scrollTop() { return this.top; }
  set scrollTop(value: number) {
    this.top = Math.max(0, Math.min(value, this.scrollHeight - this.clientHeight));
  }
  querySelector(selector: string) { return this.nodes.get(selector) ?? null; }
  contains() { return this.isConnected; }
  closest() { return this; }
}

class DocumentStub extends EventTarget {
  hidden = false;
  body = new ElementStub();
  notice = new ElementStub();
  querySelector() { return this.notice; }
}

class ObserverStub {
  static observers = new Set<ObserverStub>();
  constructor(readonly callback: () => void) { ObserverStub.observers.add(this); }
  observe() {}
  disconnect() { ObserverStub.observers.delete(this); }
  static update() { for (const observer of this.observers) observer.callback(); }
}

Object.defineProperty(globalThis, "sessionStorage", {
  configurable: true,
  value: { getItem: () => null, setItem() {}, removeItem() {} },
});
const { renderChat } = await import("../src/chat");

const conversation = (id: string) => ({ id, title: id, isDefault: false, version: 1 });
const message = (id: string, conversationId = "A") => ({
  id, conversationId, role: "assistant", content: `message ${id}`,
  createdAt: "2026-10-23T10:00:00Z",
});
const response = (value: unknown, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { "Content-Type": "application/json" },
});
const page = (items: unknown[]) => response({ items, hasMore: false, nextCursor: null });
const deferred = <T,>() => {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
};
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

function fixture() {
  const document = new DocumentStub();
  Object.defineProperty(globalThis, "document", { configurable: true, value: document });
  Object.defineProperty(globalThis, "MutationObserver", { configurable: true, value: ObserverStub });
  const root = new ElementStub();
  for (const key of [".chat-layout", "[data-refresh]", "[data-conversations]", "[data-messages]", "[data-chat-title]", "[data-conversation-error]", "[data-message-error]", "[data-refresh-messages]", "[data-message-form]", "[data-new-conversation]", "[data-toggle-selection]", "[data-selection-actions]", "[data-select-all]", "[data-delete-selected]", "[data-cancel-selection]"])
    root.nodes.set(key, new ElementStub());
  Object.defineProperty(globalThis, "window", { configurable: true, value: { confirm: () => true } });
  const form = root.querySelector("[data-message-form]")!;
  for (const key of ['textarea[name="content"]', 'button[type="submit"]', '[role="alert"]'])
    form.nodes.set(key, new ElementStub());
  const textarea = form.querySelector('textarea[name="content"]')!;
  const choose = (id: string) => {
    const button = new ElementStub();
    button.dataset.conversation = id;
    const event = new Event("click");
    Object.defineProperty(event, "target", { value: button });
    root.querySelector("[data-conversations]")!.dispatchEvent(event);
  };
  const type = (content: string) => {
    textarea.value = content;
    textarea.dispatchEvent(new Event("input"));
  };
  const submit = () => form.dispatchEvent(new Event("submit", { cancelable: true }));
  const unmount = () => { root.isConnected = false; ObserverStub.update(); };
  return { document, root, form, textarea, choose, type, submit, unmount,
    messages: root.querySelector("[data-messages]")!,
    messageError: root.querySelector("[data-message-error]")!,
    formError: form.querySelector('[role="alert"]')!,
  };
}

test("polls every 5 seconds, preserves history scrolling, and recovers after network failure", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const ui = fixture();
  t.after(ui.unmount);
  let calls = 0;
  let offline = false;
  let items = Array.from({ length: 12 }, (_, index) => message(String(index)));
  t.mock.method(globalThis, "fetch", async (url: string) => {
    if (url.endsWith("/conversations")) return response([conversation("A")]);
    calls++;
    if (offline) throw new TypeError("offline");
    return page(items);
  });
  await renderChat(ui.root as unknown as HTMLElement);
  assert.equal(calls, 1);
  assert.equal(ui.messages.scrollTop, 900);
  ui.messages.scrollTop = 150;
  items = [...items, message("new")];
  t.mock.timers.tick(4999);
  assert.equal(calls, 1);
  t.mock.timers.tick(1);
  await settle();
  assert.equal(calls, 2);
  assert.match(ui.messages.innerHTML, /message new/);
  assert.equal(ui.messages.scrollTop, 150);
  offline = true;
  t.mock.timers.tick(5000);
  await settle();
  assert.match(ui.messageError.textContent, /无法连接服务/);
  assert.match(ui.messages.innerHTML, /message new/);
  offline = false;
  t.mock.timers.tick(5000);
  await settle();
  assert.equal(ui.messageError.textContent, "");
  ui.messages.scrollTop = ui.messages.scrollHeight;
  items = [...items, message("last")];
  t.mock.timers.tick(5000);
  await settle();
  assert.equal(ui.messages.scrollTop, 1100);
});

test("hidden pages pause polling; visibility resumes immediately; unmount removes polling and listeners", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const ui = fixture();
  let calls = 0;
  t.mock.method(globalThis, "fetch", async (url: string) => {
    if (url.endsWith("/conversations")) return response([conversation("A")]);
    calls++;
    return page([message(String(calls))]);
  });
  await renderChat(ui.root as unknown as HTMLElement);
  ui.document.hidden = true;
  ui.document.dispatchEvent(new Event("visibilitychange"));
  t.mock.timers.tick(15000);
  await settle();
  assert.equal(calls, 1);
  ui.document.hidden = false;
  ui.document.dispatchEvent(new Event("visibilitychange"));
  await settle();
  assert.equal(calls, 2);
  ui.unmount();
  ui.document.dispatchEvent(new Event("visibilitychange"));
  t.mock.timers.tick(15000);
  await settle();
  assert.equal(calls, 2);
  assert.equal(ObserverStub.observers.size, 0);
});

test("conversation changes isolate late reads and keep each conversation's draft", async (t) => {
  const ui = fixture();
  t.after(ui.unmount);
  const oldRead = deferred<Response>();
  let aReads = 0;
  t.mock.method(globalThis, "fetch", async (url: string) => {
    if (url.endsWith("/conversations")) return response([conversation("A"), conversation("B")]);
    if (url.includes("/A/")) return ++aReads === 1 ? page([message("A")]) : oldRead.promise;
    return page([message("B", "B")]);
  });
  await renderChat(ui.root as unknown as HTMLElement);
  ui.type("draft A");
  ui.root.querySelector("[data-refresh-messages]")!.dispatchEvent(new Event("click"));
  ui.choose("B");
  await settle();
  assert.equal(ui.textarea.value, "");
  ui.type("draft B");
  oldRead.resolve(page([message("stale A")]));
  await settle();
  assert.match(ui.messages.innerHTML, /message B/);
  assert.doesNotMatch(ui.messages.innerHTML, /stale A/);
  ui.choose("A");
  await settle();
  assert.equal(ui.textarea.value, "draft A");
  ui.choose("B");
  await settle();
  assert.equal(ui.textarea.value, "draft B");
});

test("send is locked per conversation and failed retries reuse their id without crossing drafts", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const ui = fixture();
  t.after(ui.unmount);
  const pending = deferred<Response>();
  const posts: { url: string; body: { id: string; content: string } }[] = [];
  t.mock.method(globalThis, "fetch", async (url: string, options?: RequestInit) => {
    if (options?.method === "POST") {
      posts.push({ url, body: JSON.parse(String(options.body)) });
      if (posts.length === 1) return pending.promise;
      return response(message("sent"));
    }
    if (url.endsWith("/conversations")) return response([conversation("A"), conversation("B")]);
    return page([]);
  });
  await renderChat(ui.root as unknown as HTMLElement);
  ui.type("hello A");
  ui.submit();
  ui.submit();
  assert.equal(posts.length, 1);
  ui.choose("B");
  ui.type("hello B");
  pending.reject(new TypeError("offline"));
  await settle();
  assert.equal(ui.textarea.value, "hello B");
  assert.equal(ui.formError.textContent, "");
  ui.choose("A");
  await settle();
  assert.equal(ui.textarea.value, "hello A");
  assert.match(ui.formError.textContent, /无法连接服务/);
  ui.submit();
  await settle();
  assert.equal(posts.length, 2);
  assert.deepEqual(posts[0], posts[1]);
  assert.match(posts[1].url, /\/A\/messages$/);
  assert.equal(ui.textarea.value, "");
  ui.choose("B");
  await settle();
  assert.equal(ui.textarea.value, "hello B");
  ui.submit();
  await settle();
  assert.match(posts[2].url, /\/B\/messages$/);
  assert.equal(posts[2].body.content, "hello B");
  assert.notEqual(posts[2].body.id, posts[0].body.id);
});

test("bulk delete confirms, protects the default conversation, and selects a surviving chat", async (t) => {
  const ui = fixture();
  t.after(ui.unmount);
  const items = [conversation("A"), conversation("B"), { ...conversation("main"), isDefault: true }];
  const deletes: { url: string; body: unknown }[] = [];
  t.mock.method(globalThis, "fetch", async (url: string, options?: RequestInit) => {
    if (options?.method === "DELETE") {
      deletes.push({ url, body: JSON.parse(String(options.body)) });
      return new Response(null, { status: 204 });
    }
    if (url.endsWith("/conversations")) return response(items);
    return page([]);
  });
  await renderChat(ui.root as unknown as HTMLElement);
  ui.root.querySelector("[data-toggle-selection]")!.dispatchEvent(new Event("click"));
  const checkbox = new ElementStub();
  checkbox.dataset.selectConversation = "A";
  checkbox.checked = true;
  const change = new Event("change");
  Object.defineProperty(change, "target", { value: checkbox });
  ui.root.querySelector("[data-conversations]")!.dispatchEvent(change);
  ui.root.querySelector("[data-delete-selected]")!.dispatchEvent(new Event("click"));
  await settle();
  assert.equal(deletes.length, 1);
  assert.match(deletes[0]!.url, /\/conversations\/A$/);
  assert.deepEqual(deletes[0]!.body, { baseVersion: 1 });
  assert.equal(ui.root.querySelector("[data-chat-title]")!.textContent, "B");
});

test("bulk delete retains failed sessions for retry after partial success", async (t) => {
  const ui = fixture();
  t.after(ui.unmount);
  const items = [conversation("A"), conversation("B")];
  t.mock.method(globalThis, "fetch", async (url: string, options?: RequestInit) => {
    if (options?.method === "DELETE")
      return url.endsWith("/B") ? response({ error: "conflict" }, 409) : new Response(null, { status: 204 });
    if (url.endsWith("/conversations")) return response(items);
    return page([]);
  });
  await renderChat(ui.root as unknown as HTMLElement);
  ui.root.querySelector("[data-toggle-selection]")!.dispatchEvent(new Event("click"));
  for (const id of ["A", "B"]) {
    const checkbox = new ElementStub();
    checkbox.dataset.selectConversation = id;
    checkbox.checked = true;
    const change = new Event("change");
    Object.defineProperty(change, "target", { value: checkbox });
    ui.root.querySelector("[data-conversations]")!.dispatchEvent(change);
  }
  ui.root.querySelector("[data-delete-selected]")!.dispatchEvent(new Event("click"));
  await settle();
  assert.match(ui.root.querySelector("[data-conversation-error]")!.textContent, /1 个已删除，1 个失败/);
  assert.equal(ui.root.querySelector("[data-delete-selected]")!.disabled, false);
});

test("a successful send keeps edits made while the request is pending", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const ui = fixture();
  t.after(ui.unmount);
  const pending = deferred<Response>();
  t.mock.method(globalThis, "fetch", async (url: string, options?: RequestInit) => {
    if (options?.method === "POST") return pending.promise;
    if (url.endsWith("/conversations")) return response([conversation("A")]);
    return page([]);
  });
  await renderChat(ui.root as unknown as HTMLElement);
  ui.type("first");
  ui.submit();
  ui.type("next draft");
  pending.resolve(response(message("sent")));
  await settle();
  assert.equal(ui.textarea.value, "next draft");
});

test("a confirmed send clears and unlocks the composer while message refresh is still pending", async (t) => {
  const ui = fixture();
  t.after(ui.unmount);
  const refresh = deferred<Response>();
  let messageReads = 0;
  t.mock.method(globalThis, "fetch", async (url: string, options?: RequestInit) => {
    if (options?.method === "POST") return response({ ...message("sent"), role: "user" });
    if (url.endsWith("/conversations")) return response([conversation("A")]);
    messageReads++;
    return messageReads === 1 ? page([]) : refresh.promise;
  });
  await renderChat(ui.root as unknown as HTMLElement);
  ui.type("hello");
  ui.submit();
  await settle();
  assert.equal(messageReads, 2);
  assert.equal(ui.textarea.value, "");
  assert.equal(ui.form.querySelector('button[type="submit"]')!.disabled, false);
  assert.equal(ui.form.querySelector('button[type="submit"]')!.textContent, "发送");
  refresh.resolve(page([message("sent")]));
});

test("waiting for an assistant reply polls every second without overlapping reads, then returns to five seconds", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const ui = fixture();
  t.after(ui.unmount);
  const pendingRead = deferred<Response>();
  let reads = 0;
  let readPending = false;
  let sentId = "";
  t.mock.method(globalThis, "fetch", async (url: string, options?: RequestInit) => {
    if (options?.method === "POST") {
      const body = JSON.parse(String(options.body));
      sentId = body.id;
      return response({ ...message(sentId), role: "user" });
    }
    if (url.endsWith("/conversations")) return response([conversation("A")]);
    reads++;
    if (readPending) return pendingRead.promise;
    return page(reads === 1 ? [] : [ { ...message(sentId), role: "user" } ]);
  });
  await renderChat(ui.root as unknown as HTMLElement);
  ui.type("hello");
  ui.submit();
  await settle();
  assert.equal(reads, 2);
  t.mock.timers.tick(999);
  await settle();
  assert.equal(reads, 2);
  t.mock.timers.tick(1);
  await settle();
  assert.equal(reads, 3);
  readPending = true;
  t.mock.timers.tick(1000);
  await settle();
  assert.equal(reads, 4);
  t.mock.timers.tick(2000);
  await settle();
  assert.equal(reads, 4);
  pendingRead.resolve(page([
    { ...message(sentId), role: "user" },
    { ...message("reply"), role: "assistant" },
  ]));
  await settle();
  readPending = false;
  t.mock.timers.tick(4999);
  await settle();
  assert.equal(reads, 4);
  t.mock.timers.tick(1);
  await settle();
  assert.equal(reads, 5);
});
