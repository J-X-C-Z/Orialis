import interconnect from "@system.interconnect"
import storage from "./snapshotStorage.js"

const DATA_TAG = "fangcun.link.v1"
const ACK_TAG = "fangcun.link.ack"
const MAX_CHUNK_SIZE = 1200
const MAX_CHUNKS = 256

<<<<<<< HEAD
// The Vela simulator does not expose every device service. Keep the module
// import-safe so a missing interconnect service cannot blank the whole app.
function unavailableConnection() {
  return {
    send({ fail }) { if (fail) fail({ code: "UNSUPPORTED", message: "system.interconnect unavailable" }) },
    getReadyState({ fail }) { if (fail) fail({ code: "UNSUPPORTED" }) },
    diagnosis({ fail }) { if (fail) fail({ code: "UNSUPPORTED" }) }
  }
}

=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
function safeParse(value) {
  try { return typeof value === "string" ? JSON.parse(value) : value } catch (e) { return null }
}

<<<<<<< HEAD
function callbackInfo(data, code) {
  const info = data && typeof data === "object" ? Object.assign({}, data) : { data }
  if (code != null && info.code == null) info.code = code
  if (info.data != null && typeof info.data !== "string") info.data = String(info.data)
  return info
}

function logInfo(prefix, value) {
  try { console.log("fangcun interconnect " + prefix, JSON.stringify(value)) }
  catch (e) { console.log("fangcun interconnect " + prefix, value) }
}

class FangcunInterconnect {
  constructor() {
    try {
      const candidate = interconnect && typeof interconnect.instance === "function"
        ? interconnect.instance()
        : null
      this.conn = candidate || unavailableConnection()
    } catch (e) {
      console.warn("fangcun interconnect unavailable", e)
      this.conn = unavailableConnection()
    }
    this.parts = Object.create(null)
    this.snapshot = null
    this.pendingActions = []
    this.flushingActions = false
    this.listeners = []
    this.state = "unknown"
    this.conn.onmessage = data => this.receive(data && !data.tag && data.data != null ? data.data : data)
    this.conn.onopen = data => {
      const info = callbackInfo(data)
      logInfo("onopen", info)
      this.emit("open", info)
      this.setState("connected")
      this.flushPendingActions()
    }
    this.conn.onclose = data => {
      const info = callbackInfo(data)
      logInfo("onclose", info)
      this.emit("close", info)
      this.setState("disconnected")
    }
    this.conn.onerror = data => {
      const info = callbackInfo(data)
      logInfo("onerror", info)
      this.emit("error", info)
      this.setState("error")
    }
    this.refreshState()
    this.loadSnapshot()
    this.loadPendingActions()
  }

  setState(state) {
    if (this.state === state) return
    this.state = state
    this.emit("state", state)
  }

  refreshState() {
    return this.getReadyState().catch(() => null)
  }

  getReadyState() {
    return new Promise((resolve, reject) => {
      this.conn.getReadyState({
        success: data => {
          const info = callbackInfo(data)
          logInfo("getReadyState success", info)
          this.emit("readyState", info)
          if (info.status === 1) this.setState("connected")
          else if (info.status === 2) this.setState("disconnected")
          else this.setState("unknown")
          resolve(info)
          if (info.status === 1) this.flushPendingActions()
        },
        fail: (data, code) => {
          const info = callbackInfo(data, code)
          logInfo("getReadyState fail", info)
          this.emit("readyStateError", info)
          this.setState("unknown")
          reject(info)
        }
      })
    })
  }

  diagnose() {
    return new Promise((resolve, reject) => {
      this.conn.diagnosis({
        timeout: 5000,
        success: data => {
          const info = callbackInfo(data)
          logInfo("diagnosis success", info)
          this.emit("diagnosis", info)
          resolve(info)
        },
        fail: (data, code) => {
          const info = callbackInfo(data, code)
          logInfo("diagnosis fail", info)
          this.emit("diagnosisError", info)
          reject(info)
        }
      })
    })
=======
class FangcunInterconnect {
  constructor() {
    this.conn = interconnect.instance()
    this.parts = Object.create(null)
    this.snapshot = null
    this.listeners = []
    this.conn.onmessage = ({ data }) => this.receive(data)
    this.conn.onopen = () => this.emit("open")
    this.conn.onclose = () => this.emit("close")
    this.conn.onerror = () => this.emit("error")
    this.loadSnapshot()
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
  }

  emit(event, value) {
    this.listeners.forEach(listener => {
      try { listener(event, value) } catch (e) { console.error("fangcun link listener", e) }
    })
  }

<<<<<<< HEAD
  on(listener) {
    this.listeners.push(listener)
    return () => { this.listeners = this.listeners.filter(item => item !== listener) }
  }

  send(payload) {
    return new Promise((resolve, reject) => {
      this.conn.send({
        data: payload,
        success: data => {
          logInfo("send success", { tag: payload && payload.tag, transferId: payload && payload.transferId, data })
          this.emit("send", { payload, data })
          resolve(data)
        },
        fail: (data, code) => {
          const info = callbackInfo(data, code)
          logInfo("send fail", info)
          this.emit("sendError", { payload, error: info })
          reject(info)
        }
      })
=======
  on(listener) { this.listeners.push(listener); return this.listeners.length - 1 }

  send(payload) {
    return new Promise((resolve, reject) => {
      this.conn.send({ data: payload, success: resolve, fail: reject })
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    })
  }

  async sendAck(transferId, ok, error, revision) {
    const message = { tag: ACK_TAG, transferId, ok: !!ok }
    if (error) message.error = error
    if (revision != null) message.revision = String(revision)
    try { await this.send(message) } catch (e) { console.error("fangcun link ack", e) }
  }

<<<<<<< HEAD
  async sendAction(action) {
    const transferId = "action-" + Date.now() + "-" + Math.random().toString(36).slice(2)
    const payload = Object.assign({ schema: DATA_TAG, type: "action" }, action || {})
    this.pendingActions.push({ transferId, payload })
    await this.savePendingActions()
    this.flushPendingActions()
    return transferId
  }

  async flushPendingActions() {
    if (this.flushingActions || !this.pendingActions.length || this.state !== "connected") return
    this.flushingActions = true
    try {
      for (const item of this.pendingActions) {
        await this.send({ tag: DATA_TAG, kind: "action", transferId: item.transferId, data: JSON.stringify(item.payload), index: 0, total: 1 })
      }
    } catch (e) {
      logInfo("action send deferred", e)
    } finally {
      this.flushingActions = false
    }
  }

  async acknowledgeAction(transferId) {
    const next = this.pendingActions.filter(item => item.transferId !== transferId)
    if (next.length === this.pendingActions.length) return
    this.pendingActions = next
    await this.savePendingActions()
    this.emit("actionAck", { transferId })
  }

  async loadPendingActions() {
    try {
      const values = safeParse(await storage.getActions())
      this.pendingActions = Array.isArray(values) ? values.filter(item => item && item.transferId && item.payload) : []
      this.flushPendingActions()
    } catch (e) { console.error("fangcun link action storage", e) }
  }

  async savePendingActions() {
    try { await storage.setActions(JSON.stringify(this.pendingActions)) }
    catch (e) { console.error("fangcun link action storage", e) }
  }

  async receive(raw) {
    const message = safeParse(raw)
    if (!message || !message.tag) {
      logInfo("message invalid", { raw })
      this.emit("messageError", { raw })
      return
    }
    logInfo("message", { tag: message.tag, kind: message.kind, transferId: message.transferId, index: message.index, total: message.total })
    this.emit("message", message)
    if (message.tag !== DATA_TAG) {
      if (message.tag === ACK_TAG) {
        logInfo("ack", message)
        if (message.kind === "action" && message.ok && message.transferId) await this.acknowledgeAction(message.transferId)
        this.emit("ack", message)
      }
=======
  async receive(raw) {
    const message = safeParse(raw)
    if (!message || !message.tag) return
    if (message.tag !== DATA_TAG) {
      if (message.tag === ACK_TAG) this.emit("ack", message)
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
      return
    }
    if (message.kind === "snapshot") {
      await this.commitSnapshot(message.payload || message.data, message.transferId || message.messageId)
<<<<<<< HEAD
      this.flushPendingActions()
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
      return
    }
    if (message.kind !== "chunk" || typeof message.data !== "string") return
    const transferId = String(message.transferId || "")
    const index = Number(message.index)
    const total = Number(message.total)
    if (!transferId || !Number.isInteger(index) || !Number.isInteger(total) || total < 1 || total > MAX_CHUNKS || index < 0 || index >= total) {
      await this.sendAck(transferId, false, "invalid_chunk")
      return
    }
    let transfer = this.parts[transferId]
    if (!transfer || transfer.total !== total) transfer = this.parts[transferId] = { total, chunks: [], received: 0 }
    if (transfer.chunks[index] == null) { transfer.chunks[index] = message.data; transfer.received++ }
    if (transfer.received !== total) return
    delete this.parts[transferId]
    const payload = safeParse(transfer.chunks.join(""))
    if (!payload) { await this.sendAck(transferId, false, "invalid_json"); return }
    await this.commitSnapshot(payload, transferId)
  }

  async commitSnapshot(payload, transferId) {
    const snapshot = safeParse(payload)
    if (snapshot && (snapshot.type === "handshake" || snapshot.type === "heartbeat")) {
      await this.sendAck(transferId, true)
      return
    }
    if (!snapshot || snapshot.schema !== "fangcun.link.v1" || snapshot.type !== "snapshot") {
      await this.sendAck(transferId, false, "invalid_snapshot")
      return
    }
<<<<<<< HEAD
    const incomingValue = snapshot.sync && snapshot.sync.revision
    const currentValue = this.snapshot && this.snapshot.sync && this.snapshot.sync.revision
    const incomingRevision = Number(incomingValue)
    const currentRevision = Number(currentValue)
    if (incomingValue != null && currentValue != null && Number.isFinite(incomingRevision) && Number.isFinite(currentRevision) && incomingRevision < currentRevision) {
      await this.sendAck(transferId || snapshot.messageId, true, null, currentRevision)
      return
    }
    try { await storage.set(JSON.stringify(snapshot)) }
    catch (e) {
      console.error("fangcun link storage", e)
      await this.sendAck(transferId || snapshot.messageId, false, "storage_failed")
      return
    }
    this.snapshot = snapshot
=======
    const incomingRevision = Number(snapshot.sync && snapshot.sync.revision)
    const currentRevision = Number(this.snapshot && this.snapshot.sync && this.snapshot.sync.revision)
    if (Number.isFinite(incomingRevision) && Number.isFinite(currentRevision) && incomingRevision < currentRevision) {
      await this.sendAck(transferId || snapshot.messageId, true, null, currentRevision)
      return
    }
    this.snapshot = snapshot
    try { await storage.set(JSON.stringify(snapshot)) } catch (e) { console.error("fangcun link storage", e) }
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    this.emit("snapshot", snapshot)
    await this.sendAck(transferId || snapshot.messageId, true, null, snapshot.sync && snapshot.sync.revision)
  }

  async loadSnapshot() {
    try {
      const value = safeParse(await storage.get())
<<<<<<< HEAD
      if (!this.snapshot && value && value.schema === DATA_TAG && value.type === "snapshot") {
        this.snapshot = value
        this.emit("snapshot", value)
      }
=======
      if (value) { this.snapshot = value; this.emit("snapshot", value) }
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    } catch (e) { console.error("fangcun link load", e) }
  }

  getSnapshot() { return this.snapshot }
<<<<<<< HEAD
  getState() { return this.state }
=======
  getState() { try { return this.conn.getApkStatus() } catch (e) { return "unknown" } }
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
}

export { DATA_TAG, ACK_TAG, MAX_CHUNK_SIZE }
export default new FangcunInterconnect()
