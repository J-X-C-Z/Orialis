
const protocol = require('../common/protocol')
const store = require('./store')

let interconnect = null
let storage = null
try { interconnect = require('@system.interconnect') } catch (error) { console.warn('system.interconnect unavailable', error) }
try { storage = require('@system.storage') } catch (error) { console.warn('system.storage unavailable', error) }

function stringifyError(error) {
  return error && error.message ? error.message : String(error)
}

const transport = {
  data: {
    connectionStatus: '正在检查互联能力',
    detail: '',
    lastResult: '尚未发送 Ping',
    snapshotSummary: '尚无快照',
    storageSupported: true,
    conn: null,
    receiver: null,
    sequence: 0,
    pendingPings: null
  },
  onInit() {
    if (this.started) return
    this.started = true
    this.destroyed = false
    this.queue = []
    this.writing = false
    this.receiver = protocol.createReceiver(() => Date.now())
    this.pendingPings = Object.create(null)
    store.registerCacheInvalidation((guard) => this.invalidateCache(guard))
    this.loadSavedSnapshot()
    if (!interconnect || typeof interconnect.instance !== 'function') {
      this.connectionStatus = '不支持：system.interconnect 不可用'
      this.detail = '应用可继续启动；需在支持互联的 Vela 运行环境验证。'
      return
    }
    if (!storage || typeof storage.set !== 'function' || typeof storage.get !== 'function') {
      this.storageSupported = false
      this.connectionStatus = '不支持：system.storage 不可用'
      this.detail = '互联功能不可安全确认快照持久化；不会发送快照 ACK。'
    }
    try {
      this.conn = interconnect.instance()
      this.conn.onopen = (event) => { this.connectionStatus = event && event.isReconnected ? '已重连' : '连接已打开'; this.detail = ''; store.setPhoneState('online') }
      this.conn.onclose = (event) => { this.connectionStatus = '连接已断开'; this.detail = event && event.data ? String(event.data) : ''; store.setPhoneState('offline') }
      this.conn.onerror = (event) => { this.connectionStatus = '互联错误'; this.detail = event && event.data ? String(event.data) : ''; store.setPhoneState('offline') }
      this.conn.onmessage = (event) => this.receive(event && event.data)
      this.diagnose()
    } catch (error) {
      this.connectionStatus = '不支持：互联初始化失败'
      this.detail = stringifyError(error)
    }
  },
  diagnose() {
    if (!this.conn || typeof this.conn.diagnosis !== 'function') {
      this.connectionStatus = '不支持：diagnosis() 不可用'
      return
    }
    this.connectionStatus = '正在诊断连接'
    this.conn.diagnosis({
      timeout: 10000,
      success: (data) => {
        const status = data && data.status
        store.setPhoneState(status === 0 ? 'online' : 'offline')
        this.connectionStatus = status === 0 ? (this.storageSupported ? '已连接' : '已连接；快照存储不支持') : status === 204 ? '连接超时' : status === 1001 ? '手机端应用未安装' : '连接不可用 (' + status + ')'
        this.detail = status === 0 ? (this.storageSupported ? '可发送 W0 Ping。' : 'Ping 可用；快照不会确认持久化或发送 ACK。') : '检查手机应用安装、证书配对与 Mi Fitness 状态。'
      },
      fail: (data, code) => { this.connectionStatus = '连接诊断失败'; this.detail = 'code=' + code + ' ' + stringifyError(data) }
    })
  },
  ping() {
    if (!this.conn || typeof this.conn.send !== 'function') { this.lastResult = 'Ping 未发送：互联不可用'; return }
    this.sequence += 1
    const pingId = 'w0-' + Date.now() + '-' + this.sequence
    const frame = { ns: 'orialis.wear.v1', type: 'ping', payload: { pingId: pingId, sentAt: Date.now() } }
    if (protocol.serializedBytes(frame) > protocol.MAX_MESSAGE_BYTES) { this.lastResult = 'Ping 超出消息大小限制'; return }
    this.lastResult = '等待 Pong：' + pingId
    const timeout = setTimeout(() => {
      if (!this.pendingPings[pingId]) return
      delete this.pendingPings[pingId]
      this.lastResult = 'Pong 超时：' + pingId
    }, 10000)
    this.pendingPings[pingId] = timeout
    this.conn.send({
      data: frame,
      success: () => { console.info('W0 ping sent', pingId) },
      fail: (data, code) => {
        clearTimeout(this.pendingPings[pingId])
        delete this.pendingPings[pingId]
        this.lastResult = 'Ping 发送失败 (' + code + '): ' + stringifyError(data)
      }
    })
  },
  receive(raw) {
    let frame
    try { frame = protocol.decodeFrame(raw) } catch (error) { this.lastResult = '消息拒收：' + stringifyError(error); return }
    if (frame.type === 'ping') {
      const p = frame.payload
      if (!p || typeof p.pingId !== 'string' || !p.pingId || p.pingId.length > 96) { this.lastResult = 'Ping 拒收：标识无效'; return }
      if (!this.conn || typeof this.conn.send !== 'function') { this.lastResult = 'Pong 未发送：互联不可用'; return }
      this.conn.send({ data: { ns: 'orialis.wear.v1', type: 'pong', payload: { pingId: p.pingId } }, success: () => console.info('W0 pong sent', p.pingId), fail: (data, code) => { this.lastResult = 'Pong 发送失败 (' + code + ')：' + stringifyError(data) } })
      return
    }
    if (frame.type === 'pong' && frame.payload && typeof frame.payload.pingId === 'string') {
      const pending = this.pendingPings[frame.payload.pingId]
      if (!pending) { this.lastResult = '收到无匹配 Ping 的 Pong：' + frame.payload.pingId; return }
      clearTimeout(pending)
      delete this.pendingPings[frame.payload.pingId]
      this.lastResult = '收到 Pong：' + frame.payload.pingId
      return
    }
    if (frame.type !== 'snapshot.part') { this.lastResult = '未知消息类型：' + frame.type; return }
    if (!this.cacheReady) { this.lastResult = '快照拒收：缓存会话尚未就绪；未发送 ACK'; return }
    let complete
    try { complete = this.receiver.accept(frame) } catch (error) { this.lastResult = '快照拒收：' + stringifyError(error); return }
    if (!complete) { this.lastResult = '接收快照分片中：' + frame.payload.transferId; return }
    if (!storage || typeof storage.set !== 'function') { this.lastResult = '快照已校验但存储不可用；未发送 ACK'; return }
    try { store.assertSnapshot(complete.snapshot) } catch (error) { this.lastResult = '快照拒收：' + stringifyError(error); return }
    if (this.queue.length >= 4) { this.lastResult = '快照保存队列已满；未发送 ACK'; return }
    this.queue.push({ complete, generation: store.generation() })
    this.persistNext()
  },
  persistNext() {
    if (this.destroyed || this.writing || !this.queue.length) return
    const entry = this.queue.shift()
    if (entry.kind === 'clear') {
      this.writing = true
      if (!storage || typeof storage.set !== 'function' || typeof storage.delete !== 'function') { this.writing = false; entry.reject(new Error('storage unavailable')); this.persistNext(); return }
      const finish = () => { this.writing = false; this.persistNext() }
      storage.set({ key: 'orialis.wear.v1.cache.guard', value: JSON.stringify(entry.guard), success: () => {
        storage.delete({ key: 'orialis.wear.v1.snapshot', success: () => { if (!this.destroyed && entry.generation === store.generation()) this.cacheReady = true; entry.resolve(); finish() }, fail: () => { entry.reject(new Error('cache delete failed')); finish() } })
      }, fail: () => { entry.reject(new Error('cache guard persistence failed')); finish() } })
      return
    }
    const complete = entry.complete
    try {
      if (entry.generation !== store.generation()) throw new Error('session changed')
      store.assertSnapshot(complete.snapshot)
    } catch (error) { this.lastResult = '快照拒收：' + stringifyError(error); this.persistNext(); return }
    this.writing = true
    const value = JSON.stringify(complete.snapshot)
    const finish = () => { this.writing = false; this.persistNext() }
    storage.set({
      key: 'orialis.wear.v1.snapshot', value,
      success: () => {
        storage.get({
          key: 'orialis.wear.v1.snapshot',
          success: (stored) => {
            if (this.destroyed || entry.generation !== store.generation()) { finish(); return }
            if (stored !== value) { this.lastResult = '快照写入回读不匹配；未发送 ACK'; finish(); return }
            try { store.acceptSnapshot(complete.snapshot) } catch (error) { this.lastResult = '快照拒收：' + stringifyError(error); finish(); return }
            this.snapshotSummary = 'revision ' + complete.revision + ' · ' + (complete.snapshot.title || '手机快照')
            this.lastResult = '快照已持久化：' + complete.transferId + ' / revision ' + complete.revision
            this.sendAck(complete.transferId, complete.revision)
            finish()
          },
          fail: (data, code) => { this.lastResult = '快照写入后回读失败 (' + code + ')；未发送 ACK：' + stringifyError(data); finish() }
        })
      },
      fail: (data, code) => { this.lastResult = '快照持久化失败 (' + code + ')；未发送 ACK：' + stringifyError(data); finish() }
    })
  },
  sendAck(transferId, revision) {
    if (!this.conn || typeof this.conn.send !== 'function') { this.lastResult = '快照已保存；ACK 发送失败：互联不可用'; return }
    this.conn.send({
      data: { ns: 'orialis.wear.v1', type: 'snapshot.ack', payload: { transferId: transferId, revision: revision } },
      success: () => { console.info('W0 snapshot ack sent', transferId, revision) },
      fail: (data, code) => { this.lastResult = '快照已保存；ACK 发送失败 (' + code + ')：' + stringifyError(data) }
    })
  },
  invalidateCache(guard) {
    this.cacheReady = false
    this.queue = this.queue.filter((entry) => entry.kind === 'clear')
    return new Promise((resolve, reject) => { this.queue.push({ kind: 'clear', guard, generation: store.generation(), resolve, reject }); this.persistNext() })
  },
  loadSavedSnapshot() {
    this.cacheReady = false
    if (!storage || typeof storage.get !== 'function') return
    const generation = store.generation()
    const load = () => storage.get({
      key: 'orialis.wear.v1.snapshot',
      success: (value) => {
        if (this.destroyed || generation !== store.generation()) return
        const stored = typeof value === 'string' ? value : value && value.data
        if (!stored) return
        try {
          const saved = JSON.parse(stored)
          store.acceptSnapshot(saved, { restored: true })
          this.snapshotSummary = 'revision ' + saved.revision + ' · ' + (saved.title || '手机快照') + ' (已恢复)'
        } catch (error) { this.snapshotSummary = '缓存未恢复：' + stringifyError(error) }
      },
      fail: (data, code) => { this.detail = '读取快照失败 (' + code + '): ' + stringifyError(data) }
    })
    storage.get({ key: 'orialis.wear.v1.cache.guard', success: (value) => {
      if (this.destroyed || generation !== store.generation()) return
      if (value) {
        try { store.restoreScope(JSON.parse(value)) } catch (error) { this.detail = '缓存会话标记损坏；未恢复'; return }
      }
      this.cacheReady = true
      load()
    }, fail: (data, code) => { this.detail = '缓存会话读取失败 (' + code + ')；未恢复缓存' } })
  },
  onDestroy() {
    this.destroyed = true
    this.cacheReady = false
    this.started = false
    this.queue = []
    if (this.receiver && this.receiver.dispose) this.receiver.dispose()
    if (this.conn) { this.conn.onopen = null; this.conn.onclose = null; this.conn.onerror = null; this.conn.onmessage = null }
    if (!this.pendingPings) return
    Object.keys(this.pendingPings).forEach((pingId) => clearTimeout(this.pendingPings[pingId]))
    this.pendingPings = Object.create(null)
  }
}

Object.keys(transport.data).forEach((key) => {
  let value = transport.data[key]
  Object.defineProperty(transport, key, {
    get() { return value },
    set(next) { value = next; if (['connectionStatus', 'detail', 'lastResult', 'snapshotSummary'].indexOf(key) >= 0) { const patch = {}; patch[key] = next; store.setDiagnostic(patch) } }
  })
})
module.exports = transport
