const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const protocol = require('../src/common/protocol')
function harness(options = {}) {
  delete require.cache[require.resolve('../src/services/store')]
  const store = require('../src/services/store')
  const disk = Object.assign(Object.create(null), options.disk); const sent = []; const writes = []; const reads = []
  const storage = {
    get(p) { if (options.delayReads || options.delayGuard && p.key === 'orialis.wear.v1.cache.guard') { reads.push(p); return }; p.success(disk[p.key] || '') },
    set(p) { writes.push(() => { disk[p.key] = p.value; p.success() }) },
    delete(p) { delete disk[p.key]; p.success() }
  }
  const conn = { diagnosis(p) { if (!options.offline) p.success({ status: 0 }) }, send(p) { sent.push(p.data); p.success() } }
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

test('task completion waits for a correlated phone result and reports its status', () => {
  const h = harness(); const results = []
  h.transport.completeTask({ id: 'task-1', version: 7 }, true, (status) => results.push(status))
  const request = h.sent[h.sent.length - 1]
  assert.equal(request.type, 'task.complete.request')
  assert.deepEqual(JSON.parse(JSON.stringify(request.payload)), { mutationId: request.payload.mutationId, taskId: 'task-1', completed: true, baseVersion: 7 })
  h.transport.receive(JSON.stringify({ ns: 'orialis.wear.v1', type: 'task.complete.result', payload: { mutationId: request.payload.mutationId, taskId: 'other-task', completed: true, status: 'completed' } }))
  assert.deepEqual(results, [])
  h.transport.receive(JSON.stringify({ ns: 'orialis.wear.v1', type: 'task.complete.result', payload: { mutationId: request.payload.mutationId, taskId: 'task-1', completed: true, status: 'conflict' } }))
  assert.deepEqual(results, ['conflict'])
  h.transport.onDestroy()
})


test('same task cannot send twice while a phone result is pending, even across pages', () => {
  const h = harness(); const results = []
  h.transport.completeTask({ id: 'a', version: 3 }, true, s => results.push(s))
  h.transport.completeTask({ id: 'a', version: 3 }, false, s => results.push(s))
  assert.equal(h.sent.length, 1); assert.deepEqual(results, ['busy'])
  h.transport.receive(JSON.stringify({ ns: 'orialis.wear.v1', type: 'task.complete.result', payload: {
    mutationId: h.sent[0].payload.mutationId, taskId: 'a', completed: true, status: 'completed'
  } }))
  h.transport.completeTask({ id: 'a', version: 4 }, false, s => results.push(s))
  assert.equal(h.sent.length, 2)
  h.transport.onDestroy()
})

function cachedSnapshot() {
  return { transferId: 'cached', revision: 3, title: '本地缓存', view: { dataState: 'live',
    organizer: { schemaVersion: 1, today: '2026-10-25', tasks: [{ id: 'cached-task', title: '已缓存任务', important: true, urgent: true }] } } }
}
const guardKey = 'orialis.wear.v1.cache.guard'
const snapshotKey = 'orialis.wear.v1.snapshot'
test('cache reads start together and display offline content without waiting for phone diagnosis', () => {
  const saved = cachedSnapshot()
  const h = harness({ delayReads: true, offline: true })
  assert.deepEqual(h.reads.map(p => p.key), [guardKey, snapshotKey])
  assert.equal(h.store.view().cacheLoading, true)
  h.reads.find(p => p.key === snapshotKey).success(JSON.stringify(saved))
  assert.equal(h.store.view().hasSnapshot, false)
  h.reads.find(p => p.key === guardKey).success('')
  assert.equal(h.store.view().cacheLoading, false)
  assert.equal(h.store.view().title, saved.title)
  assert.equal(h.store.organizerBuild('home').cards[0].preview, '已缓存任务')
  assert.equal(h.store.view().stale, true)
  assert.equal(h.store.view().operationsEnabled, false)
  assert.equal(h.sent.length, 0)
  h.transport.onDestroy()
})
test('phone snapshot arriving during cache restore is saved afterwards without a resend', () => {
  const h = harness({ delayReads: true })
  h.reads.find(p => p.key === guardKey).success('')
  sendSnapshot(h, 4)
  assert.equal(h.writes.length, 0)
  h.reads.find(p => p.key === snapshotKey).success(JSON.stringify(cachedSnapshot()))
  assert.equal(h.store.view().title, '本地缓存')
  assert.equal(h.writes.length, 1)
  h.writes.shift()()
  // Complete the durable readback (also delayed by this harness).
  h.reads[h.reads.length - 1].success(h.disk[snapshotKey])
  assert.equal(h.store.view().title, '中文 😀')
  assert.equal(h.sent[0].type, 'snapshot.ack')
  h.transport.onDestroy()
})
test('missing or corrupt cache finishes local loading without a phone connection', () => {
  for (const value of ['', '{broken']) {
    const h = harness({ disk: { [snapshotKey]: value }, offline: true })
    assert.equal(h.store.view().cacheLoading, false)
    assert.equal(h.store.view().hasSnapshot, false)
    assert.equal(h.transport.cacheReady, true)
    h.transport.onDestroy()
  }
})
test('pending startup callbacks cannot resurrect cache after reset or destruction', async () => {
  for (const action of ['reset', 'destroy']) {
    const h = harness({ delayReads: true })
    if (action === 'reset') { const cleared = h.store.resetCache(); h.writes.shift()(); await cleared }
    else h.transport.onDestroy()
    h.reads.find(p => p.key === guardKey).success('')
    h.reads.find(p => p.key === snapshotKey).success(JSON.stringify(cachedSnapshot()))
    assert.equal(h.store.view().hasSnapshot, false)
    if (action === 'reset') { assert.equal(h.store.view().cacheLoading, false); h.transport.onDestroy() }
  }
})
test('storage callback wrappers restore only cache matching the persisted session', () => {
  const scope = { accountId: 'a', sessionId: 's', targetId: 'mac' }
  for (const matching of [true, false]) {
    const h = harness({ delayReads: true })
    const saved = Object.assign(cachedSnapshot(), { scope: matching ? scope : { accountId: 'other', sessionId: 's' } })
    h.reads.find(p => p.key === snapshotKey).success({ data: JSON.stringify(saved) })
    h.reads.find(p => p.key === guardKey).success({ data: JSON.stringify({ expectedScope: h.store.scopeKey(scope), revoked: false }) })
    assert.equal(h.store.view().hasSnapshot, matching)
    assert.equal(h.store.view().cacheLoading, false)
    h.transport.onDestroy()
  }
})

test('phone snapshot queued during startup is rejected by a restored revocation guard', () => {
  const h = harness({ delayReads: true })
  sendSnapshot(h, 4)
  h.reads.find(p => p.key === snapshotKey).success(JSON.stringify(cachedSnapshot()))
  h.reads.find(p => p.key === guardKey).success(JSON.stringify({ expectedScope: '', revoked: true }))
  assert.equal(h.writes.length, 0)
  assert.equal(h.sent.length, 0)
  assert.equal(h.store.view().hasSnapshot, false)
  assert.equal(h.store.view().cacheLoading, false)
  h.transport.onDestroy()
})
