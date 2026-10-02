const test = require('node:test')
const assert = require('node:assert/strict')
function fresh() { delete require.cache[require.resolve('../src/services/store')]; return require('../src/services/store') }
function sample(revision, dataState) { return { transferId: 'test-' + revision, revision, title: '中文 😀', view: { dataState, updatedAt: '2026-10-02T08:30:00+08:00', targetId: 'mac', states: { phone: 'online', orialis: 'online', target: 'online' }, devices: [{ id: 'mac', name: 'Mac', status: 'online' }, { id: 'pc', name: 'PC', status: 'offline' }], tasks: [{ id: 't', title: '检查设备界面', status: 'working', progress: 72 }], commands: [{ id: 'c', title: '查看状态', status: 'waiting' }] } } }
test('starts empty, local mock never impersonates real operations', () => {
  const store = fresh(); assert.equal(store.view().tasks.length, 0); assert.equal(store.view().phoneLabel, '未知')
  store.setDemo(true); assert.match(store.view().provenance, /演示数据/); assert.equal(store.view().mock, true); assert.equal(store.view().operationsEnabled, false)
  store.setDemo(false); assert.equal(store.view().tasks.length, 0)
})
test('mock, explicit stale, absent provenance and empty are conservatively represented', () => {
  const store = fresh(); store.setPhoneState('online')
  store.acceptSnapshot(sample(1, 'mock')); assert.match(store.view().provenance, /手机演示数据/); assert.equal(store.view().mock, true); assert.equal(store.view().orialisLabel, '未知')
  store.acceptSnapshot(sample(2, 'stale')); assert.equal(store.view().stale, true)
  store.acceptSnapshot(sample(3)); assert.equal(store.view().stale, true)
  store.acceptSnapshot(sample(4, 'empty')); assert.equal(store.view().tasks.length, 0); assert.match(store.view().provenance, /手机快照为空/)
})
test('restored live snapshots remain stale and transport never infers target status', () => {
  const store = fresh(); store.setPhoneState('online'); store.acceptSnapshot(sample(3, 'live'), { restored: true })
  assert.equal(store.view().stale, true); assert.equal(store.view().targetLabel, '未知')
  store.acceptSnapshot(sample(4, 'live')); assert.equal(store.view().targetLabel, '在线')
  store.setPhoneState('offline'); assert.equal(store.view().targetLabel, '未知')
})
test('late revisions are rejected and local target previews do not change phone target', () => {
  const store = fresh(); store.acceptSnapshot(sample(8, 'live')); assert.throws(() => store.acceptSnapshot(sample(7, 'live')), /stale/)
  store.selectPreviewTarget('pc'); assert.equal(store.view().previewTargetId, 'pc'); assert.equal(store.view().targetId, 'mac'); assert.equal(store.view().targetName, 'Mac')
})
test('scope transition requests durable invalidation, rejects wrong session and revocation', async () => {
  const store = fresh(); const guards = []; store.registerCacheInvalidation((guard) => { guards.push(guard); return Promise.resolve() })
  const scope = { accountId: 'a', sessionId: 's', targetId: 'mac' }; await store.setScope(scope)
  assert.equal(guards.length, 1); assert.throws(() => store.acceptSnapshot(sample(1, 'live')), /scope mismatch/)
  const next = sample(2, 'live'); next.scope = scope; store.acceptSnapshot(next)
  await store.setScope(null); assert.equal(store.view().hasSnapshot, false); assert.equal(guards[1].revoked, true); assert.throws(() => store.acceptSnapshot(next), /revoked/)
})
