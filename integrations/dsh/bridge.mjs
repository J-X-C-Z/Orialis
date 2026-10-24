#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { DshAcpClient } from "./dsh-acp.mjs";
import {
  ack,
  hello,
  isValidDeviceId,
  parseFrame,
  ping,
  pong,
  reply,
} from "./protocol.mjs";

const VERSION = "1.0.0";
const RECONNECT_MAX_MS = 30_000;

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function log(message, fields = {}) {
  const suffix = Object.entries(fields)
    .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
    .join(" ");
  console.log(`${new Date().toISOString()} ${message}${suffix ? ` ${suffix}` : ""}`);
}

export class OrialisDshBridge {
  constructor({ dsh } = {}) {
    this.serverUrl = requiredEnv("ORIALIS_SERVER_URL");
    this.deviceId = requiredEnv("ORIALIS_DEVICE_ID");
    this.deviceToken = requiredEnv("ORIALIS_DEVICE_TOKEN");
    this.dshCwd = process.env.DSH_CWD?.trim() || "/var/lib/orialis-dsh/workspace";
    this.requestTimeoutMs = Number(process.env.DSH_REQUEST_TIMEOUT_MS || 900_000);
    if (!isValidDeviceId(this.deviceId)) {
      throw new Error("ORIALIS_DEVICE_ID must use <USER>_<DEVICE>_<Agent>");
    }
    fs.mkdirSync(this.dshCwd, { recursive: true, mode: 0o700 });

    this.dsh = dsh || new DshAcpClient({
      command: process.env.DSH_COMMAND?.trim() || "dsh",
      profile: process.env.DSH_PROFILE?.trim() || "acp",
      cwd: this.dshCwd,
      requestTimeoutMs: this.requestTimeoutMs,
    });
    this.dsh.on("stderr", (text) => log("dsh_stderr", { text }));
    this.dsh.on("protocolError", (error) => log("dsh_protocol_error", { error }));
    this.dsh.on("permissionDenied", (detail) => log("dsh_permission_denied", detail));
    this.dsh.on("toolStatus", (detail) => this.handleToolStatus(detail));
    this.dsh.on("textChunk", ({ sessionId, text }) => {
      const conversation = [...this.sessionByConversation].find(([, id]) => id === sessionId)?.[0];
      const current = this.statusByConversation.get(conversation);
      if (current?.status === "running" && typeof text === "string" && text) {
        this.sendEvent("agent.delta", conversation, { run_id: current.runId, delta: text });
      }
    });
    this.dsh.on("exit", (detail) => {
      if (!this.stopping) {
        log("dsh_exited", detail);
        process.exit(1);
      }
    });

    this.ws = null;
    this.ready = false;
    this.stopping = false;
    this.reconnectDelay = 1000;
    this.heartbeat = null;
    this.seen = new Set();
    this.seenOrder = [];
    this.sessionByConversation = new Map();
    this.queueByConversation = new Map();
    this.statusByConversation = new Map();
    this.replyByMessage = new Map();
    this.replyWaiters = new Map();
    this.activeTools = new Map();
    this.sessionEpoch = `dsh-session-${randomUUID()}`;
    this.eventSequence = 0;
  }

  async start() {
    await this.dsh.start();
    await this.connect();
  }

  async stop() {
    this.stopping = true;
    clearInterval(this.heartbeat);
    this.heartbeat = null;
    if (this.ws) {
      this.ws.close(1000, "bridge stopping");
      this.ws = null;
    }
    for (const sessionId of this.sessionByConversation.values()) {
      await this.dsh.closeSession(sessionId).catch(() => {});
    }
    this.sessionByConversation.clear();
    await this.dsh.close();
  }

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.serverUrl, {
        headers: {
          Authorization: `Bearer ${this.deviceToken}`,
          "User-Agent": `Orialis-DSH/${VERSION}`,
        },
        handshakeTimeout: 15_000,
      });
      this.ws = ws;
      let settled = false;
      const handshakeTimer = setTimeout(() => {
        ws.terminate();
        if (!settled) {
          settled = true;
          reject(new Error("Orialis hello_ack timed out"));
        }
      }, 15_000);

      ws.on("open", () => {
        this.send(hello(this.deviceId, platformName()));
      });

      ws.on("message", (data) => {
        let frame;
        try {
          frame = parseFrame(data);
        } catch (error) {
          log("invalid_server_frame", { error: error.message });
          return;
        }
        if (frame.type === "hello_ack") {
          clearTimeout(handshakeTimer);
          this.ready = true;
          this.sessionEpoch = `dsh-session-${randomUUID()}`;
          this.eventSequence = 0;
          this.send({ version: 1, type: "capabilities.hello", capabilities: hello(this.deviceId).capabilities });
          for (const [conversation, current] of this.statusByConversation) {
            if (current.status === "running") this.sendEvent("agent.start", conversation, { run_id: current.runId });
            this.sendEvent("agent.status", conversation, { run_id: current.runId, status: current.status, message: current.message });
          }
          this.reconnectDelay = 1000;
          this.startHeartbeat();
          log("connected", { device_id: this.deviceId });
          if (!settled) {
            settled = true;
            resolve();
          }
          return;
        }
        this.handleFrame(frame);
      });

      ws.on("error", (error) => {
        log("websocket_error", { error: error.message });
        if (!settled) {
          settled = true;
          clearTimeout(handshakeTimer);
          reject(error);
        }
      });

      ws.on("close", (code, reason) => {
        clearTimeout(handshakeTimer);
        this.ready = false;
        clearInterval(this.heartbeat);
        this.heartbeat = null;
        log("disconnected", { code, reason: reason.toString() });
        if (!this.stopping) this.scheduleReconnect();
      });
    });
  }

  scheduleReconnect() {
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, RECONNECT_MAX_MS);
    setTimeout(async () => {
      if (this.stopping) return;
      try {
        await this.connect();
      } catch (error) {
        log("reconnect_failed", { error: error.message });
      }
    }, delay);
  }

  startHeartbeat() {
    clearInterval(this.heartbeat);
    this.heartbeat = setInterval(() => {
      if (this.ready) this.send(ping());
    }, 25_000);
  }

  send(frame) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(frame));
    }
  }

  handleFrame(frame) {
    if (frame.type === "ping") {
      this.send(pong());
      return;
    }
    if (["pong", "agent.ack", "capabilities.ack"].includes(frame.type)) return;
    if (frame.type === "session.info") {
      const current = this.statusByConversation.get(frame.conversation_id);
      this.send({ version: 1, type: "session.reply", request_id: frame.request_id,
        conversation_id: frame.conversation_id, session_id: frame.session_id,
        status: current?.status || "unknown", message: current?.message || "尚无本设备记录的处理状态" });
      return;
    }
    if (frame.type === "message.ack") {
      this.replyWaiters.get(frame.message_id)?.(frame.status === "received" || frame.status === "duplicate");
      return;
    }
    if (frame.type === "error") {
      if (frame.reply_to) this.replyWaiters.get(frame.reply_to)?.(false);
      log("server_error", {
        code: frame.code || "unknown",
        message: frame.message || "unknown error",
      });
      return;
    }
    if (frame.type === "message.send") {
      this.handleMessage(frame).catch((error) => {
        log("message_failed", {
          message_id: frame.message_id,
          error: error.message,
        });
        this.setStatus(frame.conversation_id, frame.message_id, "error", "处理失败，请稍后重试");
        if (!this.replyByMessage.has(frame.message_id)) {
          const response = reply(frame.message_id, frame.conversation_id, "DSH 暂时无法完成这条消息，请稍后重试。");
          this.replyByMessage.set(frame.message_id, response);
          this.send(response);
        }
      });
    }
  }

  handleMessage(frame) {
    if (this.seen.has(frame.message_id)) {
      this.send(ack(frame.message_id));
      const saved = this.replyByMessage.get(frame.message_id);
      if (saved) this.send(saved);
      return Promise.resolve();
    }
    this.remember(frame.message_id);
    this.send(ack(frame.message_id));
    const previous = this.queueByConversation.get(frame.conversation_id) || Promise.resolve();
    const next = previous
      .catch(() => {})
      .then(() => this.processMessage(frame));
    this.queueByConversation.set(frame.conversation_id, next);
    const cleanup = () => {
      if (this.queueByConversation.get(frame.conversation_id) === next) {
        this.queueByConversation.delete(frame.conversation_id);
      }
    };
    next.then(cleanup, cleanup);
    return next;
  }

  async processMessage(frame) {
    this.setStatus(frame.conversation_id, frame.message_id, "running", "正在处理请求");
    if (Array.isArray(frame.attachments) && frame.attachments.length > 0) {
      await this.sendReply(frame, "当前 DSH 桥接只支持文本消息，附件尚未接入。");
      this.setStatus(frame.conversation_id, frame.message_id, "error", "此设备尚不支持附件");
      return;
    }
    const text = String(frame.content || "").trim();
    if (!text) {
      await this.sendReply(frame, "消息内容为空。");
      this.setStatus(frame.conversation_id, frame.message_id, "error", "消息内容为空");
      return;
    }
    let sessionId = this.sessionByConversation.get(frame.conversation_id);
    if (!sessionId) {
      sessionId = await this.dsh.createSession(this.dshCwd);
      this.sessionByConversation.set(frame.conversation_id, sessionId);
    }
    let result;
    try {
      result = await this.dsh.prompt(sessionId, text);
    } catch (error) {
      this.sessionByConversation.delete(frame.conversation_id);
      await this.dsh.closeSession(sessionId).catch(() => {});
      throw error;
    }
    const cancelled = result.stopReason === "cancelled";
    const response = await this.sendReply(frame, result.text || (cancelled ? "本轮处理已取消。" : `DSH 未返回文本（${result.stopReason}）。`));
    const terminal = cancelled ? "cancelled" : result.text ? "completed" : "error";
    if (terminal !== "error") this.sendEvent("agent.complete", frame.conversation_id,
      { run_id: frame.message_id, content: response.content, message_id: response.message_id });
    this.setStatus(frame.conversation_id, frame.message_id, terminal,
      { cancelled: "本轮处理已取消", completed: "本轮处理已完成", error: "未收到有效回复" }[terminal]);
    log("reply_sent", {
      conversation_id: frame.conversation_id,
      reply_to: frame.message_id,
      stop_reason: result.stopReason,
    });
  }

  remember(messageId) {
    this.seen.add(messageId);
    this.seenOrder.push(messageId);
    if (this.seenOrder.length > 4096) {
      const oldest = this.seenOrder.shift();
      this.seen.delete(oldest);
      this.replyByMessage.delete(oldest);
    }
  }

  sendEvent(type, conversationId, fields) {
    if (!this.ready || this.ws?.readyState !== WebSocket.OPEN) return;
    this.send({ version: 1, type, event_id: `dsh-event-${randomUUID()}`, seq: ++this.eventSequence,
      session_id: this.sessionEpoch, conversation_id: conversationId, ...fields });
  }

  setStatus(conversationId, runId, status, message) {
    this.statusByConversation.delete(conversationId);
    this.statusByConversation.set(conversationId, { runId, status, message });
    if (this.statusByConversation.size > 4096) this.statusByConversation.delete(this.statusByConversation.keys().next().value);
    if (status === "running") {
      this.sendEvent("agent.start", conversationId, { run_id: runId });
    }
    this.sendEvent("agent.status", conversationId, { run_id: runId, status, message });
    if (status !== "running") {
      if (status === "error") this.sendEvent("agent.error", conversationId,
        { run_id: runId, code: "DSH_AGENT_FAILED", message });
      for (const [toolId, tool] of this.activeTools) {
        if (tool.conversationId !== conversationId) continue;
        this.sendEvent("tool.failed", conversationId, { run_id: runId, tool_call_id: toolId,
          code: "DSH_TOOL_RESULT_UNAVAILABLE", message: "本轮已结束，未收到该工具的完成状态" });
        this.activeTools.delete(toolId);
      }
    }
  }

  handleToolStatus({ sessionId, toolCallId, kind, status }) {
    const conversation = [...this.sessionByConversation].find(([, id]) => id === sessionId)?.[0];
    const current = this.statusByConversation.get(conversation);
    if (!current || current.status !== "running" || typeof toolCallId !== "string") return;
    const id = `${current.runId}:${toolCallId}`;
    const name = ["read", "edit", "delete", "move", "search", "execute", "fetch", "other", "switch_mode"].includes(kind) ? kind : "tool";
    const terminal = status === "completed" || status === "failed";
    if (terminal) {
      this.sendEvent(status === "failed" ? "tool.failed" : "tool.completed", conversation,
        { run_id: current.runId, tool_call_id: id, tool_name: name,
          ...(status === "failed" ? { code: "DSH_TOOL_FAILED", message: "工具执行失败" } : { output: "工具执行完成" }) });
      this.activeTools.delete(id);
    } else if (!this.activeTools.has(id)) {
      this.activeTools.set(id, { conversationId: conversation });
      this.sendEvent("tool.started", conversation, { run_id: current.runId, tool_call_id: id, tool_name: name });
    }
    current.message = this.activeTools.size && [...this.activeTools.values()].some((tool) => tool.conversationId === conversation)
      ? "正在执行工具" : "正在处理请求";
    this.sendEvent("agent.status", conversation, { run_id: current.runId, status: "running", message: current.message });
  }

  async sendReply(frame, content) {
    const response = this.replyByMessage.get(frame.message_id) || reply(frame.message_id, frame.conversation_id, content);
    this.replyByMessage.set(frame.message_id, response);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.replyWaiters.delete(response.message_id);
        reject(new Error("Orialis reply acknowledgement timed out"));
      }, 15_000);
      this.replyWaiters.set(response.message_id, (accepted) => {
        clearTimeout(timer);
        this.replyWaiters.delete(response.message_id);
        if (accepted) resolve();
        else reject(new Error("Orialis rejected assistant reply"));
      });
      this.send(response);
    });
    return response;
  }
}

function platformName() {
  if (os.platform() === "win32") return "windows";
  if (os.platform() === "darwin") return "macos";
  return "linux";
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
const bridge = new OrialisDshBridge();
let shutdownStarted = false;
async function shutdown(signal) {
  if (shutdownStarted) return;
  shutdownStarted = true;
  log("shutdown", { signal });
  await bridge.stop().catch((error) => log("shutdown_error", { error: error.message }));
  process.exit(0);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("uncaughtException", (error) => {
  log("uncaught_exception", { error: error.message });
  shutdown("uncaughtException");
});
process.on("unhandledRejection", (error) => {
  log("unhandled_rejection", { error: error instanceof Error ? error.message : String(error) });
  shutdown("unhandledRejection");
});

await bridge.start();
}
