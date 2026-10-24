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

function taskPage() {
  const h = harness()
  h.store.setPhoneState('online')
  h.store.acceptSnapshot({ transferId: 'actions', revision: 1, view: { dataState: 'live', organizer: {
    schemaVersion: 1, today: '2026-10-23', tasks: [
      { id: 'a', title: 'first', version: 3 }, { id: 'b', title: 'second', version: 4 }
    ]
  } } })
  h.page.openItem('tasks', 'a')
  return h
}

test('task action blocks repeated taps and stale data; response belongs to the opened detail', () => {
  const { page, store } = taskPage(); const calls = []
  page.wearTransport.completeTask = (task, completed, callback) => calls.push({ task, completed, callback })
  page.toggleTask(); page.toggleTask()
  assert.equal(calls.length, 1)
  assert.equal(calls[0].completed, true)
  assert.equal(page.taskMutationStatus, '正在同步…')
  page.openItem('tasks', 'b')
  calls[0].callback('completed')
  assert.equal(page.taskMutationStatus, '')
  store.setPhoneState('offline'); page.toggleTask()
  assert.equal(calls.length, 1)
  assert.match(page.taskMutationStatus, /连接手机/)
  page.onDestroy()
})

test('demo never sends task actions; destroyed detail ignores late phone replies', () => {
  const { page } = taskPage(); let callback
  page.wearTransport.completeTask = (_, __, cb) => { callback = cb }
  page.toggleTask(); page.onDestroy(); callback('completed')
  assert.equal(page.taskMutationStatus, '正在同步…')
  const demo = taskPage(); let calls = 0
  demo.page.wearTransport.completeTask = () => calls++
  demo.store.setDemo(true)
  demo.page.openItem('tasks', 'task-1')
  demo.page.organizer.detail.version = 1
  demo.page.toggleTask()
  assert.equal(calls, 0); assert.match(demo.page.taskMutationStatus, /演示/)
  demo.page.onDestroy()
})
