import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { OrialisDshBridge } from "../bridge.mjs";

function setup(t) {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "orialis-dsh-test-"));
  Object.assign(process.env, { ORIALIS_SERVER_URL: "ws://127.0.0.1:1", ORIALIS_DEVICE_ID: "JXCZ_HAKARI_DSH", ORIALIS_DEVICE_TOKEN: "fixture-only", DSH_CWD: cwd });
  const dsh = new EventEmitter();
  dsh.createSession = async () => "real-acp-session";
  dsh.closeSession = async () => {};
  const bridge = new OrialisDshBridge({ dsh });
  const frames = [];
  bridge.ready = true;
  let acknowledge = true;
  bridge.ws = { readyState: 1, send(raw) {
    const frame = JSON.parse(raw);
    frames.push(frame);
    if (frame.type === "message.reply" && acknowledge) bridge.handleFrame({ type: "message.ack", message_id: frame.message_id, status: "received" });
  } };
  t.after(() => fs.rmSync(cwd, { recursive: true, force: true }));
  return { bridge, dsh, frames, setAck(value) { acknowledge = value; } };
}

const message = (id = "user-1") => ({ version: 1, type: "message.send", message_id: id, conversation_id: "chat", content: "unchanged user prompt" });

test("status refresh before first token is running, does not enqueue or modify prompt", async (t) => {
  const { bridge, dsh, frames } = setup(t);
  let finish;
  dsh.prompt = async (sessionId, text) => {
    assert.equal(text, "unchanged user prompt");
    return await new Promise((resolve) => { finish = resolve; });
  };
  const pending = bridge.handleMessage(message());
  while (!finish) await new Promise(setImmediate);
  bridge.handleFrame({ type: "session.info", request_id: "refresh-1", conversation_id: "chat", session_id: "chat" });
  assert.equal(frames.at(-1).type, "session.reply");
  assert.equal(frames.at(-1).status, "running");
  assert.equal(frames.at(-1).request_id, "refresh-1");
  const text = 'intro\n```orialis-ui\n{"version":1,"fallback":"Math 60","blocks":[{"type":"chart","items":[{"label":"Math","value":60}]}]}\n```';
  dsh.emit("textChunk", { sessionId: "real-acp-session", text });
  assert.equal(frames.at(-1).type, "agent.delta");
  assert.equal(frames.at(-1).delta, text);
  finish({ text, stopReason: "end_turn" });
  await pending;
  const reply = frames.find((frame) => frame.type === "message.reply");
  assert.equal(reply.content, text);
  assert.equal(bridge.statusByConversation.get("chat").status, "completed");
  assert.equal(frames.find((frame) => frame.type === "agent.complete").message_id, reply.message_id);
  assert.equal(frames.find((frame) => frame.type === "agent.complete").content, text);
  await bridge.handleMessage(message());
  assert.equal(frames.at(-1).message_id, reply.message_id);
  assert.equal(frames.filter((frame) => frame.type === "agent.start").length, 1);
});

test("completion waits for persistence ACK; cancelled and malformed UI remain intact", async (t) => {
  const { bridge, dsh, frames, setAck } = setup(t);
  const text = '保留文字\n```orialis-ui\n{broken JSON}\n```';
  dsh.prompt = async () => ({ text, stopReason: "cancelled" });
  setAck(false);
  const pending = bridge.handleMessage(message());
  while (!frames.some((frame) => frame.type === "message.reply")) await new Promise(setImmediate);
  assert.equal(bridge.statusByConversation.get("chat").status, "running");
  const reply = frames.find((frame) => frame.type === "message.reply");
  assert.equal(reply.content, text);
  bridge.handleFrame({ type: "message.ack", message_id: reply.message_id, status: "received" });
  await pending;
  assert.equal(bridge.statusByConversation.get("chat").status, "cancelled");
  assert.equal(frames.at(-1).type, "agent.status");
  assert.equal(frames.at(-1).status, "cancelled");
  assert.ok(frames.findIndex((frame) => frame.type === "agent.complete") < frames.length - 1);
});

test("public tool events never include ACP title, raw arguments or thought content", async (t) => {
  const { bridge, dsh, frames } = setup(t);
  let finish;
  dsh.prompt = async () => await new Promise((resolve) => { finish = resolve; });
  const pending = bridge.handleMessage(message());
  while (!finish) await new Promise(setImmediate);
  dsh.emit("toolStatus", { sessionId: "real-acp-session", toolCallId: "call-1", kind: "execute", status: "in_progress", title: "SECRET", rawInput: "SECRET" });
  assert.equal(bridge.statusByConversation.get("chat").message, "正在执行工具");
  dsh.emit("toolStatus", { sessionId: "real-acp-session", toolCallId: "call-1", status: "failed" });
  assert.equal(bridge.activeTools.size, 0);
  assert.equal(bridge.statusByConversation.get("chat").message, "正在处理请求");
  assert.ok(frames.some((frame) => frame.type === "tool.failed"));
  assert.ok(!JSON.stringify(frames).includes("SECRET"));
  finish({ text: "answer", stopReason: "end_turn" });
  await pending;
});

test("provider failures report error; read-only unknown query never prompts", async (t) => {
  const { bridge, dsh, frames } = setup(t);
  let calls = 0;
  dsh.prompt = async () => { calls += 1; throw new Error("provider failure"); };
  bridge.handleFrame(message());
  while (!frames.some((frame) => frame.type === "agent.error")) await new Promise(setImmediate);
  assert.equal(bridge.statusByConversation.get("chat").status, "error");
  bridge.handleFrame({ type: "session.info", request_id: "other", conversation_id: "unknown-chat", session_id: "unknown-chat" });
  assert.equal(frames.at(-1).status, "unknown");
  assert.equal(calls, 1);
  bridge.ws.readyState = 3;
  const seq = bridge.eventSequence;
  bridge.sendEvent("agent.status", "chat", { status: "running" });
  assert.equal(bridge.eventSequence, seq);
});
