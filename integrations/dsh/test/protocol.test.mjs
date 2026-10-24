import test from "node:test";
import assert from "node:assert/strict";
import {
  ack,
  hello,
  isValidDeviceId,
  limitText,
  parseFrame,
  reply,
} from "../protocol.mjs";

test("validates Orialis device IDs", () => {
  assert.equal(isValidDeviceId("JXCZ_HAKARI_DSH"), true);
  assert.equal(isValidDeviceId("bad-id"), false);
  assert.equal(isValidDeviceId("TOO_MANY_PARTS_DSH"), false);
});

test("builds baseline hello, ack, and reply frames", () => {
  assert.deepEqual(hello("JXCZ_HAKARI_DSH"), {
    version: 1,
    type: "hello",
    device_id: "JXCZ_HAKARI_DSH",
    client: "orialis-dsh-bridge",
    plugin_version: "1.0.0",
    platform: "linux",
    capabilities: ["messages", "session.status", "response_ui.v1", "agent.start", "agent.delta", "agent.status", "agent.complete", "agent.error", "tool.started", "tool.completed", "tool.failed"],
    response_ui: { format: "orialis-ui", version: 1, transport: "content_fence",
      block_types: ["metrics", "chart", "tabs", "checklist", "choices"],
      limits: { json_bytes: 32768, blocks: 12, items: 12, title: 80, fallback: 4000,
        label: 120, value: 120, detail: 240, content: 4000, prompt: 1000, unit: 32 } },
  });
  assert.equal(ack("message-1").status, "received");
  const frame = reply("message-1", "conversation-1", "hello");
  assert.equal(frame.reply_to, "message-1");
  assert.equal(frame.conversation_id, "conversation-1");
  assert.equal(frame.content, "hello");
});

test("rejects malformed message.send frames", () => {
  assert.throws(() => parseFrame(JSON.stringify({
    version: 1,
    type: "message.send",
    message_id: "message-1",
  })), /conversation_id/);
});

test("bounds oversized replies", () => {
  const value = limitText("x".repeat(300_000));
  assert.ok(value.length <= 220_000);
  assert.match(value, /truncated by Orialis DSH bridge/);
});
