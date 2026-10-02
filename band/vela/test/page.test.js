const test = require('node:test')
const assert = require('node:assert/strict')
const pages = require('../src/services/page')
function harness() {
  delete require.cache[require.resolve('../src/services/store')]
  const store = require('../src/services/store')
  const page = pages.createPage('tasks')
  Object.assign(page, page.data, { $app: { $def: { wearStore: store, wearTransport: {} } } })
  page.onInit()
  return { page, store }
}
function snapshot(revision, title) {
  return { transferId: 'p-' + revision, revision, view: { dataState: 'live', tasks: [{ id: 't', title }], commands: [{ id: 'c', title }] } }
}
test('visible details and confirmation are cleared immediately on session revocation', async () => {
  const { page, store } = harness()
  store.acceptSnapshot(snapshot(1, 'private detail'))
  page.openTask('t'); page.openCommand('c'); page.previewConfirmation()
  await store.setScope(null)
  assert.equal(page.selectedTask, null)
  assert.equal(page.selectedCommand, null)
  assert.equal(page.confirmCommand, false)
  page.onDestroy()
})
test('open details refresh from new snapshots and disappear when removed or demo ends', () => {
  const { page, store } = harness()
  store.acceptSnapshot(snapshot(1, 'old')); page.openTask('t'); page.openCommand('c')
  store.acceptSnapshot(snapshot(2, 'new'))
  assert.equal(page.selectedTask.title, 'new'); assert.equal(page.selectedCommand.title, 'new')
  store.clearSnapshot(); assert.equal(page.selectedTask, null); assert.equal(page.selectedCommand, null)
  store.setDemo(true); page.openTask('demo-1'); store.setDemo(false)
  assert.equal(page.selectedTask, null)
  page.onDestroy()
})
