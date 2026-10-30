const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')

function harness() {
  const diagnoses = []
  const states = []
  const conn = { diagnosis(options) { diagnoses.push(options) } }
  const store = {
    registerCacheInvalidation() {}, setCacheLoading() {}, generation() { return 0 },
    setPhoneState(state) { states.push(state) }, setDiagnostic() {}
  }
  const context = {
    module: { exports: {} }, console: { warn() {} },
    require(id) {
      if (id === './store') return store
      if (id === '../common/protocol') return { createReceiver() { return {} } }
      if (id === '@system.interconnect') return { instance() { return conn } }
      if (id === '@system.storage') return { get(options) { options.success('') }, set() {} }
      throw new Error(id)
    }
  }
  vm.runInNewContext(fs.readFileSync(require.resolve('../src/services/transport'), 'utf8'), context)
  const transport = context.module.exports
  transport.onInit()
  return { transport, conn, diagnoses, states }
}

test('reconnection wins over an earlier timeout or failed diagnosis', () => {
  for (const result of ['timeout', 'failure']) {
    const h = harness()
    h.conn.onopen({ isReconnected: true })
    if (result === 'timeout') h.diagnoses[0].success({ status: 204 })
    else h.diagnoses[0].fail('closed', 1006)
    assert.equal(h.transport.connectionStatus, '已重连')
    assert.deepEqual(h.states, ['online'])
    h.transport.onDestroy()
  }
})

test('close and error events cannot be overwritten by a stale successful diagnosis', () => {
  for (const event of ['onclose', 'onerror']) {
    const h = harness()
    h.conn[event]({ data: 'disconnected' })
    const status = h.transport.connectionStatus
    h.diagnoses[0].success({ status: 0 })
    assert.equal(h.transport.connectionStatus, status)
    assert.deepEqual(h.states, ['offline'])
    h.transport.onDestroy()
  }
})

test('only the latest diagnosis can update state, and none can update after destruction', () => {
  const h = harness()
  h.transport.diagnose()
  h.diagnoses[1].success({ status: 0 })
  h.diagnoses[0].success({ status: 204 })
  assert.equal(h.transport.connectionStatus, '已连接')
  h.transport.diagnose()
  h.diagnoses[2].fail('closed', 1006)
  assert.equal(h.states.at(-1), 'offline')
  h.transport.diagnose()
  h.transport.onDestroy()
  const status = h.transport.connectionStatus
  h.diagnoses[3].success({ status: 0 })
  h.transport.diagnose()
  assert.equal(h.transport.connectionStatus, status)
  assert.equal(h.states.at(-1), 'offline')
  assert.equal(h.diagnoses.length, 4)
})
