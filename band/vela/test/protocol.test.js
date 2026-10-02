const test = require('node:test')
const assert = require('node:assert/strict')
const protocol = require('../src/common/protocol')

test('serialized UTF-8 budget counts Chinese and emoji bytes', () => {
  assert.equal(protocol.utf8Bytes('a中😀'), 8)
  assert.ok(protocol.serializedBytes({ text: '早安 😀' }) > Buffer.byteLength(JSON.stringify({ text: '早安 😀' }), 'utf8') - 1)
})

test('split, reorder and fully reassemble snapshot before ACK eligibility', () => {
  const snapshot = { transferId: 'transfer-1', revision: 7, title: '今日 🌤️', body: '项目进展 '.repeat(900) }
  const frames = protocol.splitSnapshot(snapshot, snapshot.transferId, snapshot.revision)
  assert.ok(frames.length > 1)
  const receiver = protocol.createReceiver(() => 100)
  let completed = null
  frames.slice().reverse().forEach((frame) => { completed = receiver.accept(frame) || completed })
  assert.deepEqual(completed, { transferId: 'transfer-1', revision: 7, snapshot })
})

test('rejects over-limit, corrupt and inconsistent input', () => {
  assert.throws(() => protocol.decodeFrame('x'.repeat(protocol.MAX_MESSAGE_BYTES + 1)), /byte limit/)
  assert.throws(() => protocol.splitSnapshot({ text: 'x'.repeat(protocol.MAX_TRANSFER_BYTES) }, 'too-large', 1), /byte limit/)
  const frames = protocol.splitSnapshot({ transferId: 't', revision: 1, title: 'ok' }, 't', 1)
  const bad = JSON.parse(JSON.stringify(frames[0]))
  bad.payload.checksum = '00000000'
  const receiver = protocol.createReceiver(() => 1)
  assert.throws(() => receiver.accept(bad), /checksum/)
})

test('expires incomplete transfer cache', () => {
  const frames = protocol.splitSnapshot({ transferId: 'ttl', revision: 3, text: 'x'.repeat(5000) }, 'ttl', 3)
  let now = 10
  const receiver = protocol.createReceiver(() => now)
  assert.equal(receiver.accept(frames[0]), null)
  now += protocol.TRANSFER_TTL_MS + 1
  if (frames.length > 1) assert.equal(receiver.accept(frames[1]), null)
})

test('caps concurrent incomplete transfer cache', () => {
  const receiver = protocol.createReceiver(() => 50)
  for (let i = 0; i < protocol.MAX_ACTIVE_TRANSFERS; i += 1) {
    const frames = protocol.splitSnapshot({ transferId: 'active-' + i, revision: i, body: 'x'.repeat(5000) }, 'active-' + i, i)
    assert.equal(receiver.accept(frames[0]), null)
  }
  const excess = protocol.splitSnapshot({ transferId: 'excess', revision: 99, body: 'x'.repeat(5000) }, 'excess', 99)
  assert.throws(() => receiver.accept(excess[0]), /too many active transfers/)
})
