import { randomUUID } from "node:crypto";
import { RESPONSE_UI } from "./response-ui.mjs";

export const PROTOCOL_VERSION = 1;
export const MAX_REPLY_CHARS = 220_000;

const DEVICE_ID = /^[A-Za-z0-9]{2,24}_[A-Za-z0-9]{2,24}_[A-Za-z0-9]{2,24}$/;

export function isValidDeviceId(value) {
  return typeof value === "string" && value.length <= 80 && DEVICE_ID.test(value);
}

export function hello(deviceId, platform = "linux") {
  return {
    version: PROTOCOL_VERSION,
    type: "hello",
    device_id: deviceId,
    client: "orialis-dsh-bridge",
    plugin_version: "1.0.0",
    platform,
    capabilities: ["messages", "session.status", "response_ui.v1", "agent.start", "agent.delta", "agent.status", "agent.complete", "agent.error", "tool.started", "tool.completed", "tool.failed"],
    response_ui: RESPONSE_UI,
  };
}

export function ack(messageId) {
  return {
    version: PROTOCOL_VERSION,
    type: "message.ack",
    message_id: messageId,
    status: "received",
  };
}

export function pong() {
  return { version: PROTOCOL_VERSION, type: "pong" };
}

export function ping() {
  return { version: PROTOCOL_VERSION, type: "ping" };
}

export function reply(replyTo, conversationId, content) {
  return {
    version: PROTOCOL_VERSION,
    type: "message.reply",
    message_id: `dsh_${randomUUID()}`,
    reply_to: replyTo,
    conversation_id: conversationId,
    content: limitText(content || "(empty response)"),
  };
}

export function limitText(value) {
  const text = String(value);
  if (text.length <= MAX_REPLY_CHARS) return text;
  const suffix = "\n\n[truncated by Orialis DSH bridge]";
  return text.slice(0, MAX_REPLY_CHARS - suffix.length) + suffix;
}

export function parseFrame(raw) {
  let value;
  try {
    value = JSON.parse(raw.toString());
  } catch {
    throw new Error("frame is not valid JSON");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("frame must be a JSON object");
  }
  if (value.version !== PROTOCOL_VERSION || typeof value.type !== "string") {
    throw new Error("frame must carry version 1 and a string type");
  }
  if (value.type === "message.send") {
    for (const field of ["message_id", "conversation_id"]) {
      if (typeof value[field] !== "string" || !value[field].trim()) {
        throw new Error(`message.send is missing ${field}`);
      }
    }
    const attachments = Array.isArray(value.attachments) ? value.attachments : [];
    if ((typeof value.content !== "string" || !value.content.trim()) && attachments.length === 0) {
      throw new Error("message.send has neither text nor attachments");
    }
  }
  if (value.type === "session.info") {
    for (const field of ["request_id", "conversation_id", "session_id"]) {
      if (typeof value[field] !== "string" || !value[field].trim() || value[field].length > 160) {
        throw new Error(`session.info is missing or has invalid ${field}`);
      }
    }
  }
  return value;
}
