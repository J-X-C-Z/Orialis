import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { SourceTextModule, SyntheticModule, createContext } from "node:vm"

const sent = []
let stored = ""
let storedActions = "[]"
let failWrite = false
const connection = {
  send({ data, success }) { sent.push(data); success() },
  getReadyState({ success }) { success({ status: 1 }) },
  diagnosis({ success }) { success({ status: 0 }) }
}
const interconnect = { instance: () => connection }
const storage = {
  get: async () => stored,
  set: async value => {
    if (failWrite) throw new Error("disk full")
    stored = value
  },
  getActions: async () => storedActions,
  setActions: async value => { storedActions = value }
}
const context = createContext({ console, Promise, Number, JSON, String, Object })
const source = readFileSync(new URL("../src/utils/interconnect.js", import.meta.url), "utf8")
const module = new SourceTextModule(source, { context })
await module.link(async specifier => {
  const value = specifier === "@system.interconnect" ? interconnect : storage
  return new SyntheticModule(["default"], function () { this.setExport("default", value) }, { context })
})
await module.evaluate()
const link = module.namespace.default

function frame(kind, transferId, data, index = 0, total = 1) {
  return { tag: "fangcun.link.v1", kind, transferId, data, index, total }
}
function snapshot(revision) {
  return { schema: "fangcun.link.v1", type: "snapshot", sync: { revision }, tasks: [] }
}
async function deliver(message) {
  await connection.onmessage(message)
}

assert.equal(link.getState(), "connected")
assert.equal((await link.diagnose()).status, 0)
let updates = 0
const stop = link.on(event => { if (event === "snapshot") updates++ })

await deliver(frame("snapshot", "handshake", JSON.stringify({ type: "handshake", protocol: "fangcun.link.v1" })))
assert.equal(sent.at(-1).ok, true)
assert.equal(sent.at(-1).transferId, "handshake")
await deliver(frame("snapshot", "heartbeat", JSON.stringify({ type: "heartbeat" })))
assert.equal(sent.at(-1).ok, true)
assert.equal(sent.at(-1).transferId, "heartbeat")

const actionTransferId = await link.sendAction({ action: "confirm", taskId: "task-1" })
assert.equal(sent.at(-1).kind, "action")
assert.equal(sent.at(-1).transferId, actionTransferId)
assert.deepEqual(JSON.parse(sent.at(-1).data).taskId, "task-1")
await deliver({ tag: "fangcun.link.ack", kind: "action", transferId: actionTransferId, ok: true })
assert.equal(JSON.parse(storedActions).length, 0)

await deliver({ data: JSON.stringify(frame("snapshot", "direct", JSON.stringify(snapshot(1)))) })
assert.equal(link.getSnapshot().sync.revision, 1)
assert.equal(JSON.parse(stored).sync.revision, 1)
assert.deepEqual({ ok: sent.at(-1).ok, transferId: sent.at(-1).transferId }, { ok: true, transferId: "direct" })

const payload = JSON.stringify(snapshot(2))
await deliver(frame("chunk", "chunked", payload.slice(10), 1, 2))
assert.equal(link.getSnapshot().sync.revision, 1)
await deliver(frame("chunk", "chunked", payload.slice(0, 10), 0, 2))
assert.equal(link.getSnapshot().sync.revision, 2)
assert.equal(sent.at(-1).transferId, "chunked")

await deliver(frame("snapshot", "stale", JSON.stringify(snapshot(1))))
assert.equal(link.getSnapshot().sync.revision, 2)
assert.equal(sent.at(-1).revision, "2")

failWrite = true
await deliver(frame("snapshot", "failed", JSON.stringify(snapshot(3))))
assert.equal(link.getSnapshot().sync.revision, 2)
assert.equal(sent.at(-1).ok, false)
assert.equal(sent.at(-1).error, "storage_failed")
assert.equal(updates, 2)
stop()
failWrite = false
await deliver(frame("snapshot", "after-unsubscribe", JSON.stringify(snapshot(4))))
assert.equal(updates, 2)

connection.onclose()
assert.equal(link.getState(), "disconnected")
connection.onopen()
assert.equal(link.getState(), "connected")
console.log("interconnect protocol simulation passed")
