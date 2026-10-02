// Orialis-owned W0 envelope. These are local safety limits, not Xiaomi frame limits.
const MAX_MESSAGE_BYTES = 16384
const MAX_PARTS = 32
const MAX_TRANSFER_BYTES = 16384
const TRANSFER_TTL_MS = 60000
const MAX_CHUNK_BYTES = 4096
const MAX_ACTIVE_TRANSFERS = 4

function utf8Bytes(value) {
  let size = 0
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i)
    if (code <= 0x7f) size += 1
    else if (code <= 0x7ff) size += 2
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length && value.charCodeAt(i + 1) >= 0xdc00 && value.charCodeAt(i + 1) <= 0xdfff) {
      size += 4
      i += 1
    } else size += 3
  }
  return size
}

function serializedBytes(value) {
  return utf8Bytes(JSON.stringify(value))
}

function checksum(text) {
  // Adler-32 detects transfer corruption; it is not a cryptographic authenticator.
  let a = 1
  let b = 0
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i)
    let point = code
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const low = text.charCodeAt(i + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        point = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
        i += 1
      } else point = 0xfffd
    } else if (code >= 0xdc00 && code <= 0xdfff) point = 0xfffd
    const bytes = point <= 0x7f ? [point] : point <= 0x7ff ? [0xc0 | (point >> 6), 0x80 | (point & 0x3f)] : point <= 0xffff ? [0xe0 | (point >> 12), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f)] : [0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f)]
    for (let j = 0; j < bytes.length; j += 1) {
      a = (a + bytes[j]) % 65521
      b = (b + a) % 65521
    }
  }
  return ('00000000' + (((b << 16) | a) >>> 0).toString(16)).slice(-8)
}

function splitSnapshot(snapshot, transferId, revision) {
  if (typeof transferId !== 'string' || !transferId || transferId.length > 96 || !Number.isInteger(revision) || revision < 0) throw new Error('invalid transfer identity')
  const text = JSON.stringify(snapshot)
  if (utf8Bytes(text) > MAX_TRANSFER_BYTES) throw new Error('snapshot exceeds byte limit')
  const chunks = []
  let chunk = ''
  let chunkSize = 0
  for (let i = 0; i < text.length; i += 1) {
    let scalar = text[i]
    const first = text.charCodeAt(i)
    if (first >= 0xd800 && first <= 0xdbff && i + 1 < text.length && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
      scalar += text[i + 1]
      i += 1
    }
    const scalarSize = utf8Bytes(scalar)
    if (chunk && chunkSize + scalarSize > MAX_CHUNK_BYTES) {
      chunks.push(chunk)
      chunk = ''
      chunkSize = 0
    }
    chunk += scalar
    chunkSize += scalarSize
  }
  if (chunk || chunks.length === 0) chunks.push(chunk)
  if (chunks.length > MAX_PARTS) throw new Error('snapshot requires too many parts')
  const digest = checksum(text)
  return chunks.map((value, index) => {
    const frame = { ns: 'orialis.wear.v1', type: 'snapshot.part', payload: { transferId, revision, index, count: chunks.length, checksum: digest, chunk: value } }
    if (serializedBytes(frame) > MAX_MESSAGE_BYTES) throw new Error('encoded part exceeds byte limit')
    return frame
  })
}

function decodeFrame(raw) {
  if (typeof raw !== 'string' || utf8Bytes(raw) > MAX_MESSAGE_BYTES) throw new Error('frame exceeds byte limit')
  const frame = JSON.parse(raw)
  if (!frame || typeof frame !== 'object' || frame.ns !== 'orialis.wear.v1' || typeof frame.type !== 'string') throw new Error('invalid envelope')
  return frame
}

function createReceiver(now) {
  const transfers = Object.create(null)
  return {
    dispose() { Object.keys(transfers).forEach((id) => { clearTimeout(transfers[id].expiry); delete transfers[id] }) },
    accept(frame) {
      if (frame.type !== 'snapshot.part') throw new Error('unexpected frame type')
      const p = frame.payload
      if (!p || typeof p.transferId !== 'string' || !p.transferId || p.transferId.length > 96 || !Number.isInteger(p.revision) || p.revision < 0 || !Number.isInteger(p.index) || !Number.isInteger(p.count) || p.count < 1 || p.count > MAX_PARTS || p.index < 0 || p.index >= p.count || typeof p.chunk !== 'string' || typeof p.checksum !== 'string' || !/^[0-9a-f]{8}$/.test(p.checksum)) throw new Error('invalid snapshot part')
      const timestamp = now()
      Object.keys(transfers).forEach((id) => { if (timestamp - transfers[id].createdAt > TRANSFER_TTL_MS) delete transfers[id] })
      let transfer = transfers[p.transferId]
      if (!transfer) {
        if (Object.keys(transfers).length >= MAX_ACTIVE_TRANSFERS) throw new Error('too many active transfers')
        transfer = transfers[p.transferId] = { createdAt: timestamp, revision: p.revision, count: p.count, checksum: p.checksum, chunks: Object.create(null), bytes: 0, received: 0 }
        transfer.expiry = setTimeout(() => {
          if (transfers[p.transferId] === transfer) delete transfers[p.transferId]
        }, TRANSFER_TTL_MS)
        if (transfer.expiry && typeof transfer.expiry.unref === 'function') transfer.expiry.unref()
      }
      if (transfer.revision !== p.revision || transfer.count !== p.count || transfer.checksum !== p.checksum) {
        clearTimeout(transfer.expiry)
        delete transfers[p.transferId]
        throw new Error('conflicting snapshot metadata')
      }
      if (transfer.chunks[p.index] === undefined) {
        transfer.bytes += utf8Bytes(p.chunk)
        if (transfer.bytes > MAX_TRANSFER_BYTES) { clearTimeout(transfer.expiry); delete transfers[p.transferId]; throw new Error('snapshot exceeds byte limit') }
        transfer.chunks[p.index] = p.chunk
        transfer.received += 1
      } else if (transfer.chunks[p.index] !== p.chunk) {
        clearTimeout(transfer.expiry)
        delete transfers[p.transferId]
        throw new Error('conflicting duplicate part')
      }
      if (transfer.received !== transfer.count) return null
      let text = ''
      for (let i = 0; i < transfer.count; i += 1) {
        if (transfer.chunks[i] === undefined) return null
        text += transfer.chunks[i]
      }
      clearTimeout(transfer.expiry)
      delete transfers[p.transferId]
      if (utf8Bytes(text) > MAX_TRANSFER_BYTES || checksum(text) !== transfer.checksum) throw new Error('snapshot checksum mismatch')
      const snapshot = JSON.parse(text)
      if (!snapshot || typeof snapshot !== 'object' || snapshot.transferId !== p.transferId || snapshot.revision !== p.revision) throw new Error('snapshot identity mismatch')
      return { transferId: p.transferId, revision: p.revision, snapshot }
    }
  }
}

module.exports = { MAX_MESSAGE_BYTES, MAX_PARTS, MAX_TRANSFER_BYTES, TRANSFER_TTL_MS, MAX_ACTIVE_TRANSFERS, checksum, createReceiver, decodeFrame, serializedBytes, splitSnapshot, utf8Bytes }
