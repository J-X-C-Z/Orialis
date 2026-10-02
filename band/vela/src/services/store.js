// Phone UI stays read-only; explicit demo mutations are memory-only, never RPC or queued.
const organizer = require('./organizer')
let demoOrganizer = null
let undoOrganizer = null
const STATUS = { online: '在线', offline: '离线', unknown: '未知' }
const TASK_STATUS = { running: '进行中', working: '进行中', pending: '待开始', waiting: '等待确认', done: '已完成', failed: '失败', cancelled: '已取消' }
const COMMAND_STATUS = { ready: '待接入', confirming: '待确认', waiting: '等待结果', done: '手机回报完成', failed: '失败', unavailable: '待接入' }
const listeners = []
let snapshot = null
let restored = false
let receivedAt = ''
let demo = false
let compact = false
let haptics = true
let reducedMotion = false
let previewTargetId = ''
let phoneState = 'unknown'
let expectedScope = ''
let scopeGeneration = 0
let revoked = false
let invalidateCache = null
let diagnostic = { connectionStatus: '尚未检查互联', detail: '', lastResult: '尚未发送 Ping', snapshotSummary: '尚无快照' }

function text(value, limit) {
  return typeof value === 'string' ? value.slice(0, limit || 300) : ''
}
function state(value) { return STATUS[value] ? value : 'unknown' }
function scopeKey(scope) {
  return scope && typeof scope.accountId === 'string' && typeof scope.sessionId === 'string'
    ? JSON.stringify([scope.accountId, scope.sessionId, text(scope.targetId)]) : ''
}
function list(value, kind) {
  if (!Array.isArray(value)) return []
  return value.slice(0, 20).filter((item) => item && typeof item.id === 'string' && typeof item.title === 'string').map((item) => ({
    id: text(item.id, 96), title: text(item.title), shortTitle: text(item.title, 24),
    status: text(item.status, 32), statusLabel: (kind === 'task' ? TASK_STATUS : COMMAND_STATUS)[item.status] || '未知',
    summary: text(item.summary, 600) || '暂无详情', shortSummary: text(item.summary, 38) || '暂无备注',
    tone: ['running', 'working'].indexOf(item.status) >= 0 ? 'running' : ['pending', 'waiting', 'confirming'].indexOf(item.status) >= 0 ? 'waiting' : item.status === 'failed' ? 'failed' : item.status === 'done' ? 'done' : '',
    progress: typeof item.progress === 'number' && isFinite(item.progress) ? Math.max(0, Math.min(100, Math.round(item.progress))) : -1
  }))
}
function devices(value) {
  if (!Array.isArray(value)) return []
  return value.slice(0, 20).filter((item) => item && typeof item.id === 'string' && typeof item.name === 'string').map((item) => ({
    id: text(item.id, 96), name: text(item.name, 80), platform: text(item.platform, 32) || '设备',
    status: state(item.status), statusLabel: STATUS[state(item.status)]
  }))
}
function demoSnapshot() {
  return { title: '演示工作区', view: { updatedAt: '2026-10-02T08:30:00+08:00', targetId: 'demo-mac',
    states: { phone: 'online', orialis: 'online', target: 'online' },
    tasks: [
      { id: 'demo-1', title: '检查 Orialis 手环与手机互联界面', status: 'running', progress: 72, summary: '演示任务。查看长标题、小屏详情和进度；这不是正在执行的真实任务。' },
      { id: 'demo-2', title: '构建结果需要查看', status: 'failed', summary: '演示失败：依赖未找到。请在手机查看完整日志。' },
      { id: 'demo-3', title: '确认下一步开发范围', status: 'waiting', summary: '演示等待确认。实际审批尚未接入，请在手机处理。' }
    ], commands: [
      { id: 'demo-c1', title: '查看当前任务', status: 'ready', summary: '手机下发的只读快捷指令列表将在此显示。演示仅可查看确认页面。' },
      { id: 'demo-c2', title: '刷新目标状态', status: 'waiting', summary: '演示等待结果。等待视图不会自动变成成功。' },
      { id: 'demo-c3', title: '重新查看构建结果', status: 'failed', summary: '演示失败：目标设备离线。请在手机恢复连接。' }
    ], devices: [
      { id: 'demo-mac', name: 'MacBook Air', platform: 'macOS', status: 'online' },
      { id: 'demo-pc', name: '工作电脑', platform: 'Windows', status: 'offline' },
      { id: 'demo-nas', name: '家中 NAS', platform: 'NAS', status: 'unknown' }
    ] } }
}
function view() {
  const current = demo ? demoSnapshot() : snapshot
  const data = current && current.view && typeof current.view === 'object' ? current.view : {}
  const dataState = demo ? 'mock' : text(data.dataState || (current && current.dataState), 16)
  const mock = dataState === 'mock'
  const rawStates = data.states || {}
  // Transport knows the phone only; never infer app or target connectivity from it.
  const currentPhone = demo ? state(rawStates.phone) : phoneState
  const stale = !!current && !demo && !mock && (restored || currentPhone !== 'online' || dataState !== 'live')
  const states = {
    phone: currentPhone,
    orialis: stale || mock && !demo ? 'unknown' : state(rawStates.orialis),
    target: stale || mock && !demo ? 'unknown' : state(rawStates.target)
  }
  const deviceList = devices(data.devices)
  const targetId = text(data.targetId, 96)
  const target = deviceList.filter((item) => item.id === targetId)[0]
  const previewId = previewTargetId || targetId
  const timestamp = text(data.updatedAt, 64) || receivedAt
  const empty = dataState === 'empty'
  const tasks = empty ? [] : list(data.tasks, 'task')
  const organizerData = demo ? demoOrganizer : organizer.normalize(empty ? null : data.organizer)
  return {
    demo, compact, haptics, reducedMotion, stale, mock, organizer: organizerData, hasSnapshot: !!current, tasks, commands: empty ? [] : list(data.commands, 'command'), devices: empty ? [] : deviceList,
    title: text(current && current.title, 80), targetId, previewTargetId: previewId,
    sourceShort: demo ? '演示数据' : mock ? '手机演示数据' : empty ? '无数据' : current ? (stale ? '缓存数据' : '手机同步') : '无数据',
    targetName: target ? target.name : targetId ? '目标资料待同步' : '尚未选择目标',
    phoneLabel: STATUS[states.phone], orialisLabel: STATUS[states.orialis], targetLabel: STATUS[states.target], states,
    provenance: demo ? '演示数据 · 只读预览' : mock ? '手机演示数据 · 只读' : empty ? '无数据 · 手机快照为空' : current ? (stale ? '缓存数据 · 只读' : '手机同步 · 只读') : '无数据 · 等待手机同步',
    syncLabel: timestamp ? '上次同步 ' + timestamp.replace('T', ' ').slice(0, 19) : '上次同步时间未知',
    scopeLabel: !demo && current && scopeKey(current.scope) ? '会话尚未通过真机验收' : '未验证会话 · 操作待接入',
    currentTask: tasks[0] || null,
    connectionStatus: diagnostic.connectionStatus, detail: diagnostic.detail,
    lastResult: diagnostic.lastResult, snapshotSummary: diagnostic.snapshotSummary,
    operationsEnabled: false
  }
}
function emit() { const data = view(); listeners.slice().forEach((listener) => listener(data)) }
function acceptSnapshot(value, options) {
  if (!value || typeof value !== 'object' || !Number.isInteger(value.revision) || value.revision < 0 || typeof value.transferId !== 'string') throw new Error('invalid UI snapshot identity')
  if (revoked) throw new Error('session revoked')
  const key = scopeKey(value.scope)
  if (expectedScope && key !== expectedScope) throw new Error('snapshot scope mismatch')
  if (snapshot && scopeKey(snapshot.scope) === key && value.revision < snapshot.revision) throw new Error('stale snapshot revision')
  if (snapshot && scopeKey(snapshot.scope) !== key) previewTargetId = ''
  snapshot = value
  restored = !!(options && options.restored)
  receivedAt = restored ? '' : new Date().toISOString()
  emit()
}
function clearSnapshot() { demo = false; demoOrganizer = null; undoOrganizer = null; snapshot = null; restored = false; receivedAt = ''; previewTargetId = ''; emit() }
module.exports = {
  view, acceptSnapshot, clearSnapshot, scopeKey,
  generation() { return scopeGeneration },
  assertSnapshot(value) {
    if (!value || typeof value !== 'object') throw new Error('invalid snapshot')
    if (revoked) throw new Error('session revoked')
    const key = scopeKey(value.scope)
    if (expectedScope && key !== expectedScope) throw new Error('snapshot scope mismatch')
    if (snapshot && scopeKey(snapshot.scope) === key && value.revision < snapshot.revision) throw new Error('stale snapshot revision')
  },
  // Future verified phone session adapter calls this on login/target/session changes.
  // This UI does not infer a trusted session from an arbitrary snapshot.
  setScope(scope) { expectedScope = scopeKey(scope); revoked = !expectedScope; scopeGeneration += 1; clearSnapshot(); return invalidateCache ? invalidateCache({ expectedScope, revoked }) : Promise.resolve() },
  resetCache() { scopeGeneration += 1; clearSnapshot(); return invalidateCache ? invalidateCache({ expectedScope, revoked }) : Promise.resolve() },
  restoreScope(guard) {
    if (!guard || typeof guard !== 'object' || typeof guard.expectedScope !== 'string' || typeof guard.revoked !== 'boolean') throw new Error('invalid cache guard')
    if (guard.expectedScope) {
      const identity = JSON.parse(guard.expectedScope)
      if (!Array.isArray(identity) || identity.length !== 3 || identity.some((part) => typeof part !== 'string')) throw new Error('invalid cache scope')
    }
    expectedScope = guard.expectedScope
    revoked = guard.revoked
  },
  registerCacheInvalidation(handler) { invalidateCache = handler },
  subscribe(listener) { listeners.push(listener); listener(view()); return () => { const index = listeners.indexOf(listener); if (index >= 0) listeners.splice(index, 1) } },
  setPhoneState(value) { phoneState = state(value); emit() },
  setDiagnostic(value) { diagnostic = Object.assign({}, diagnostic, value); emit() },
  setDemo(value) { demo = !!value; demoOrganizer = demo ? organizer.demo() : null; undoOrganizer = null; previewTargetId = ''; emit() },
  organizerBuild(kind, selection, filter, date, mode) { return organizer.build(view().organizer, kind, selection, filter, date, mode) },
  organizerFields(kind, item, context, date) { return organizer.fields(view().organizer, kind, item, context, date) },
  organizerShift: organizer.shift,
  organizerAction(action, kind, id, value, context) {
    if (!demo || !demoOrganizer) return '请在手机编辑；真实操作尚未接入'
    const before = JSON.parse(JSON.stringify(demoOrganizer)); let error = ''
    if (action === 'save') error = organizer.save(demoOrganizer, kind, id, value, context)
    else if (action === 'toggle') organizer.toggle(demoOrganizer, kind, id)
    else if (action === 'delete') organizer.remove(demoOrganizer, kind, id)
    else if (action === 'move') organizer.reorder(demoOrganizer, kind, id, value)
    else if (action === 'resetOrder') demoOrganizer[kind].forEach((x) => { x.manualPosition = null })
    else if (action === 'quadrant') { const t = demoOrganizer.tasks.filter((x) => x.id === id)[0]; if (t) { const q = (organizer.quadrant(t) + 1) % 5; t.important = q === 4 ? null : q < 2; t.urgent = q === 4 ? null : q === 0 || q === 2 } }
    else if (action === 'undo') { if (undoOrganizer) demoOrganizer = undoOrganizer; undoOrganizer = null; emit(); return '' }
    if (error) return error
    undoOrganizer = before
    organizer.KINDS.forEach((k) => { demoOrganizer.coverage[k] = { included: demoOrganizer[k].length, total: demoOrganizer[k].length } })
    emit(); return ''
  },
  setHaptics(value) { haptics = !!value; emit() },
  setReducedMotion(value) { reducedMotion = !!value; emit() },
  setCompact(value) { compact = !!value; emit() },
  selectPreviewTarget(id) { const found = view().devices.some((item) => item.id === id); if (found) { previewTargetId = id; emit() } return found }
}
