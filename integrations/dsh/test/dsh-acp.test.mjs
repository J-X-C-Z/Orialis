import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { DshAcpClient } from "../dsh-acp.mjs";

test("actual ACP line parser ignores thought and raw tool data while retaining ordinary JSON content", async () => {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  const send = (frame) => child.stdout.write(JSON.stringify(frame) + "\n");
  child.stdin = { writable: true, write(raw) {
    const request = JSON.parse(raw);
    queueMicrotask(() => {
      if (request.method === "initialize") send({ id: request.id, result: {} });
      if (request.method === "session/new") send({ id: request.id, result: { sessionId: "s1" } });
      if (request.method === "session/prompt") {
        for (const update of [
          { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "HIDDEN" } },
          { sessionUpdate: "tool_call", toolCallId: "call", kind: "execute", status: "in_progress", rawInput: "SECRET", title: "SECRET" },
          { sessionUpdate: "tool_call_update", toolCallId: "call", status: "completed", content: [{ text: "SECRET" }] },
          { sessionUpdate: "agent_message_chunk", content: { type: "text", text: 'answer\n```orialis-ui\n{"broken":true}\n```' } },
        ]) send({ method: "session/update", params: { sessionId: "s1", update } });
        send({ id: request.id, result: { stopReason: "end_turn" } });
      }
    });
  } };
  const client = new DshAcpClient({ spawnProcess: () => child });
  const tools = [];
  const texts = [];
  client.on("toolStatus", (detail) => tools.push(detail));
  client.on("textChunk", ({ text }) => texts.push(text));
  await client.start();
  const session = await client.createSession(".");
  const result = await client.prompt(session, "untouched");
  assert.equal(result.text, 'answer\n```orialis-ui\n{"broken":true}\n```');
  assert.equal(tools.length, 2);
  assert.ok(!JSON.stringify(tools).includes("SECRET"));
  assert.ok(!result.text.includes("HIDDEN"));
  assert.equal(texts.join(""), result.text);
  client.reader.close();
  child.emit("exit", 0, null);
});

test("a timed-out ACP prompt sends the supported session/cancel notification", async () => {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  const sent = [];
  child.stdin = { writable: true, write(raw) {
    const frame = JSON.parse(raw);
    sent.push(frame);
    if (frame.method === "initialize") queueMicrotask(() => child.stdout.write(JSON.stringify({ id: frame.id, result: {} }) + "\n"));
  } };
  const client = new DshAcpClient({ spawnProcess: () => child, requestTimeoutMs: 5 });
  await client.start();
  await assert.rejects(client.prompt("s1", "unchanged"), /timed out/);
  assert.deepEqual(sent.at(-1), { jsonrpc: "2.0", method: "session/cancel", params: { sessionId: "s1" } });
  assert.equal(client.pending.size, 0);
  client.reader.close();
  child.emit("exit", 0, null);
});
