import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import readline from "node:readline";

const PROTOCOL_VERSION = 1;

export class DshAcpClient extends EventEmitter {
  constructor({
    command = "dsh",
    profile = "acp",
    cwd = process.cwd(),
    env = process.env,
    requestTimeoutMs = 900_000,
    spawnProcess = spawn,
  } = {}) {
    super();
    this.command = command;
    this.profile = profile;
    this.cwd = cwd;
    this.env = env;
    this.requestTimeoutMs = requestTimeoutMs;
    this.spawnProcess = spawnProcess;
    this.nextId = 1;
    this.pending = new Map();
    this.textBySession = new Map();
    this.process = null;
    this.reader = null;
  }

  async start() {
    if (this.process) return;
    this.process = this.spawnProcess(this.command, ["--profile", this.profile], {
      cwd: this.cwd,
      env: this.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.process.once("exit", (code, signal) => {
      this.#failAll(new Error(`DSH ACP exited (${code ?? "null"}, ${signal ?? "no signal"})`));
      this.process = null;
      this.emit("exit", { code, signal });
    });
    this.reader = readline.createInterface({ input: this.process.stdout });
    this.reader.on("line", (line) => this.#handleLine(line));
    this.process.stderr.setEncoding("utf8");
    this.process.stderr.on("data", (chunk) => {
      const text = String(chunk).trim();
      if (text) this.emit("stderr", text.slice(-4000));
    });
    await this.request("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: {},
      clientInfo: { name: "orialis-dsh-bridge", version: "1.0.0" },
    }, 60_000);
  }

  async createSession(sessionCwd) {
    const result = await this.request("session/new", {
      cwd: sessionCwd,
      mcpServers: [],
    }, 120_000);
    if (!result?.sessionId) throw new Error("DSH ACP returned no sessionId");
    this.textBySession.set(result.sessionId, "");
    return result.sessionId;
  }

  async prompt(sessionId, text) {
    this.textBySession.set(sessionId, "");
    const result = await this.request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text }],
    }, this.requestTimeoutMs);
    const output = (this.textBySession.get(sessionId) || "").trim();
    return { text: output, stopReason: result?.stopReason ?? "end_turn" };
  }

  async closeSession(sessionId) {
    if (!sessionId) return;
    try {
      await this.request("session/close", { sessionId }, 60_000);
    } finally {
      this.textBySession.delete(sessionId);
    }
  }

  async close() {
    this.reader?.close();
    this.reader = null;
    if (!this.process) return;
    const process = this.process;
    process.stdin.end();
    await new Promise((resolve) => {
      const timer = setTimeout(() => {
        process.kill("SIGTERM");
        resolve();
      }, 5000);
      process.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
    this.process = null;
  }

  request(method, params, timeoutMs = 60_000) {
    if (!this.process?.stdin.writable) {
      return Promise.reject(new Error("DSH ACP is not running"));
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        if (method === "session/prompt" && this.process?.stdin.writable) {
          this.#send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId: params.sessionId } });
        }
        reject(new Error(`DSH ACP request timed out: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer, method });
      this.#send({ jsonrpc: "2.0", id, method, params });
    });
  }

  #send(message) {
    this.process.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #handleLine(line) {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.emit("protocolError", "DSH ACP wrote non-JSON output");
      return;
    }

    if (message.id !== undefined && ("result" in message || "error" in message)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(`${pending.method}: ${message.error.message || "ACP error"}`));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (message.id !== undefined && typeof message.method === "string") {
      this.#handleAgentRequest(message);
      return;
    }

    if (message.method === "session/update") {
      this.#handleSessionUpdate(message.params);
    }
  }

  #handleSessionUpdate(params) {
    const update = params?.update;
    if (!params?.sessionId || !update) return;
    // Thought chunks and raw tool inputs/outputs never cross the mobile boundary.
    if (["tool_call", "tool_call_update"].includes(update.sessionUpdate)) {
      this.emit("toolStatus", {
        sessionId: params.sessionId, toolCallId: update.toolCallId,
        kind: update.kind, status: update.status,
      });
      return;
    }
    if (update.sessionUpdate !== "agent_message_chunk") return;
    if (update.content?.type !== "text" || typeof update.content.text !== "string") return;
    const current = this.textBySession.get(params.sessionId) || "";
    this.textBySession.set(params.sessionId, current + update.content.text);
    this.emit("textChunk", { sessionId: params.sessionId, text: update.content.text });
  }

  #handleAgentRequest(message) {
    if (message.method !== "session/request_permission") {
      this.#send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: `unsupported client method: ${message.method}` },
      });
      return;
    }
    const options = Array.isArray(message.params?.options) ? message.params.options : [];
    const reject = options.find((item) => item.kind === "reject_always")
      || options.find((item) => item.kind === "reject_once");
    const outcome = reject
      ? { outcome: "selected", optionId: reject.optionId }
      : { outcome: "cancelled" };
    this.emit("permissionDenied", {
      title: message.params?.toolCall?.title || "tool request",
      kind: message.params?.toolCall?.kind || "unknown",
    });
    this.#send({
      jsonrpc: "2.0",
      id: message.id,
      result: { outcome },
    });
  }

  #failAll(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
