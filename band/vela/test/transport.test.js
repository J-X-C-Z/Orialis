const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const protocol = require('../src/common/protocol')
function harness(options = {}) {
  delete require.cache[require.resolve('../src/services/store')]
  const store = require('../src/services/store')
  const disk = Object.create(null); const sent = []; const writes = []; const reads = []
  const storage = {
    get(p) { if (options.delayGuard && p.key === 'orialis.wear.v1.cache.guard') { reads.push(p); return }; p.success(disk[p.key] || '') },
    set(p) { writes.push(() => { disk[p.key] = p.value; p.success() }) },
    delete(p) { delete disk[p.key]; p.success() }
  }
  const conn = { diagnosis(p) { p.success({ status: 0 }) }, send(p) { sent.push(p.data); p.success() } }
  const ctx = { module: { exports: {} }, console: { info() {}, warn() {} }, setTimeout, clearTimeout, require(id) { if (id === './store') return store; if (id === '../common/protocol') return protocol; if (id === '@system.interconnect') return { instance() { return conn } }; if (id === '@system.storage') return storage; throw new Error(id) } }
  vm.runInNewContext(fs.readFileSync(require.resolve('../src/services/transport'), 'utf8'), ctx)
  const transport = ctx.module.exports; transport.onInit()
  return { store, transport, disk, sent, writes, reads }
}
function sendSnapshot(h, revision, scope) { const snap = { transferId: 't-' + revision, revision, title: '中文 😀', scope }; protocol.splitSnapshot(snap, snap.transferId, revision).forEach((frame) => h.transport.receive(JSON.stringify(frame))) }
test('ACK only follows exact durable readback and late revision cannot replace cache', () => {
  const h = harness(); sendSnapshot(h, 8); assert.equal(h.sent.length, 0); h.writes.shift()()
  assert.equal(h.sent[0].type, 'snapshot.ack'); assert.equal(h.store.view().title, '中文 😀')
  sendSnapshot(h, 7); assert.equal(h.writes.length, 0); assert.equal(JSON.parse(h.disk['orialis.wear.v1.snapshot']).revision, 8); h.transport.onDestroy()
})
test('scope change during async write removes old cache after write finishes and persists guard', async () => {
  const h = harness(); sendSnapshot(h, 1)
  const scope = { accountId: 'new', sessionId: 'session', targetId: 'mac' }
  const cleared = h.store.setScope(scope); h.writes.shift()(); h.writes.shift()(); await cleared
  assert.equal(h.disk['orialis.wear.v1.snapshot'], undefined); assert.equal(h.sent.length, 0)
  assert.equal(JSON.parse(h.disk['orialis.wear.v1.cache.guard']).expectedScope, h.store.scopeKey(scope)); h.transport.onDestroy()
})
test('restored revocation guard prevents old scoped cache from entering UI', async () => {
  const h = harness(); const scope = { accountId: 'a', sessionId: 's' }; const cleared = h.store.setScope(null); h.writes.shift()(); await cleared
  h.disk['orialis.wear.v1.snapshot'] = JSON.stringify({ transferId: 'old', revision: 1, scope, title: 'old account' })
  h.transport.loadSavedSnapshot(); assert.equal(h.store.view().hasSnapshot, false); h.transport.onDestroy()
})
test('bidirectional ping has correlated Pong and invalid IDs never produce a reply', () => {
  const h = harness(); h.transport.receive(JSON.stringify({ ns: 'orialis.wear.v1', type: 'ping', payload: { pingId: 'phone-1' } }))
  assert.equal(h.sent[0].type, 'pong'); assert.equal(h.sent[0].payload.pingId, 'phone-1')
  h.transport.receive(JSON.stringify({ ns: 'orialis.wear.v1', type: 'ping', payload: { pingId: '' } })); assert.equal(h.sent.length, 1)
  h.transport.ping(); const pingId = h.sent[1].payload.pingId
  h.transport.receive(JSON.stringify({ ns: 'orialis.wear.v1', type: 'pong', payload: { pingId } })); assert.match(h.transport.lastResult, /收到 Pong/)
  h.transport.receive(JSON.stringify({ ns: 'orialis.wear.v1', type: 'pong', payload: { pingId: 'unmatched' } })); assert.match(h.transport.lastResult, /无匹配/); h.transport.onDestroy()
})
test('malformed durable session guard fails closed before loading a previous account cache', () => {
  const h = harness()
  h.disk['orialis.wear.v1.cache.guard'] = 'null'
  h.disk['orialis.wear.v1.snapshot'] = JSON.stringify({ transferId: 'old', revision: 1, title: 'previous account' })
  h.transport.loadSavedSnapshot()
  assert.equal(h.store.view().hasSnapshot, false)
  assert.match(h.transport.detail, /标记损坏/)
  h.transport.onDestroy()
})

test('startup rejects snapshots until durable revocation guard is restored', () => {
  const h = harness({ delayGuard: true })
  sendSnapshot(h, 1)
  assert.equal(h.writes.length, 0)
  assert.equal(h.sent.length, 0)
  h.reads.shift().success(JSON.stringify({ expectedScope: '', revoked: true }))
  sendSnapshot(h, 2)
  assert.equal(h.writes.length, 0)
  assert.equal(h.store.view().hasSnapshot, false)
  h.transport.onDestroy()
})
test('guard read failure blocks snapshots while missing guard preserves legacy W0', () => {
  const h = harness({ delayGuard: true })
  h.reads.shift().fail('disk error', 1)
  sendSnapshot(h, 1)
  assert.equal(h.writes.length, 0)
  h.transport.loadSavedSnapshot()
  h.reads.shift().success('')
  sendSnapshot(h, 2); assert.equal(h.writes.length, 1)
  h.writes.shift()(); assert.equal(h.sent[0].type, 'snapshot.ack')
  h.transport.onDestroy()
})
