// Non-chat phone projection and memory-only preview. No RPC or replay queue.
const KINDS = ['tasks', 'schedules', 'projects', 'milestones']
const LABELS = { tasks: '任务', schedules: '日程', projects: '项目', milestones: '里程碑' }
let serial = 0
function str(v) { return typeof v === 'string' ? v.slice(0, 600) : '' }
function date(v) { return /^\d{4}-\d{2}-\d{2}$/.test(v || '') ? v : '' }
function tri(v) { return v === true ? true : v === false ? false : null }
function shift(d, n) { const x = new Date(d + 'T12:00:00Z'); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10) }
function dayOf(value, offset) {
  if (!value) return ''
  const epoch = Date.parse(value)
  return isFinite(epoch) && typeof offset === 'number' ? new Date(epoch + offset * 60000).toISOString().slice(0, 10) : value.slice(0, 10)
}
function timeOf(value, offset) {
  const epoch = Date.parse(value)
  return isFinite(epoch) && typeof offset === 'number' ? new Date(epoch + offset * 60000).toISOString().slice(11, 16) : (value || '').slice(11, 16)
}
function overlaps(s, d, offset) {
  // Phone Calendar uses [start,end), including multi-day/all-day intervals.
  const start = Date.parse(d + 'T00:00:00' + zone(offset)); const end = start + 86400000
  return Date.parse(s.startAt) < end && Date.parse(s.endAt) > start
}
function normalize(raw) {
  const source = raw && raw.schemaVersion === 1 ? raw : {}
  const o = { schemaVersion: 1, present: raw && raw.schemaVersion === 1, today: date(source.today), utcOffsetMinutes: typeof source.utcOffsetMinutes === 'number' ? source.utcOffsetMinutes : null, profile: source.profile || {}, sync: source.sync || {}, coverage: {}, truncated: !!(source.truncated || source.coverage && source.coverage.truncated) }
  KINDS.forEach((kind) => {
    o[kind] = (Array.isArray(source[kind]) ? source[kind] : []).slice(0, 80).filter((x) => x && typeof x.id === 'string' && typeof x[kind === 'projects' ? 'name' : 'title'] === 'string').map((x) => {
      const a = Object.assign({}, x)
      a.id = str(x.id); a.title = str(x.title); a.name = str(x.name); a.notes = str(x.notes); a.description = str(x.description); a.goal = str(x.goal); a.location = str(x.location)
      a.due = date(x.due) || null; a.important = tri(x.important); a.urgent = tri(x.urgent); if (kind === 'tasks' || kind === 'milestones') a.completed = x.completed === true; else delete a.completed
      ;['parentTaskId', 'scheduleId', 'projectId'].forEach((key) => { if (kind === 'tasks' || key === 'projectId' && kind === 'milestones') a[key] = typeof x[key] === 'string' && x[key] ? str(x[key]) : null })
      return a
    })
    const c = source.coverage && source.coverage[kind]
    o.coverage[kind] = { included: o[kind].length, total: c && Number.isInteger(c.total) ? Math.max(o[kind].length, c.total) : Array.isArray(source[kind]) ? source[kind].length : 0 }
    if (o.coverage[kind].total > o[kind].length) o.truncated = true
  })
  return o
}
function demo() {
  const now = new Date(); const offset = -now.getTimezoneOffset(); const today = new Date(now.getTime() + offset * 60000).toISOString().slice(0, 10)
  return normalize({ schemaVersion: 1, today, utcOffsetMinutes: offset, profile: { displayName: 'Orialis 演示用户', signedIn: false, serverLabel: '本地演示' }, sync: { status: '演示不参与同步', lastSyncAt: null },
    tasks: [
      { id: 'task-1', title: '完成手环界面设计', notes: '对齐手机非聊天功能。此处修改只在本地演示生效。', due: today, dueTime: '18:00', important: true, urgent: true, completed: false, projectId: 'project-1', manualPosition: 0 },
      { id: 'task-2', title: '检查日历交互', due: shift(today, 1), important: true, urgent: false, completed: false, projectId: 'project-1', manualPosition: 1 },
      { id: 'task-3', title: '整理下一周安排', important: null, urgent: null, completed: false, manualPosition: 2 },
      { id: 'task-4', title: '准备会议资料', important: false, urgent: true, completed: false, scheduleId: 'schedule-1' },
      { id: 'task-5', title: '确认颜色与字号', important: true, urgent: false, completed: true, parentTaskId: 'task-1', projectId: 'project-1' }
    ],
    schedules: [{ id: 'schedule-1', title: '产品设计讨论', description: '带上手环原型一起讨论', location: '会议室', startAt: today + 'T15:00:00' + zone(offset), endAt: today + 'T16:00:00' + zone(offset), allDay: false, important: true, reminderMinutes: 15 }],
    projects: [{ id: 'project-1', name: 'Orialis 手环', goal: '小屏也能轻松管理一天', status: 'active', nextActionTaskId: 'task-1', manualPosition: 0 }],
    milestones: [{ id: 'milestone-1', projectId: 'project-1', title: '完成界面原型', due: shift(today, 3), completed: false, position: 0 }] })
}
function zone(offset) { const n = typeof offset === 'number' ? offset : 0; return (n >= 0 ? '+' : '-') + ('0' + Math.floor(Math.abs(n) / 60)).slice(-2) + ':' + ('0' + Math.abs(n) % 60).slice(-2) }
function quadrant(t) { return t.important === null || t.urgent === null ? 4 : t.important ? t.urgent ? 0 : 1 : t.urgent ? 2 : 3 }
const QUADS = ['重要且紧急', '重要不紧急', '紧急不重要', '不重要不紧急', '未分类']
function ordered(items, position) { return items.slice().sort((a, b) => (typeof a[position] === 'number' ? a[position] : 999999) - (typeof b[position] === 'number' ? b[position] : 999999) || (a.due || '9999').localeCompare(b.due || '9999') || a.id.localeCompare(b.id)) }
function taskLabel(t) { return (t.completed ? '已完成' : QUADS[quadrant(t)]) + (t.due ? ' · ' + t.due + (t.dueTime ? ' ' + t.dueTime : '') : ' · 无截止') }
function rows(o, kind, items) { return items.map((x) => ({ id: x.id, kind, title: kind === 'projects' ? x.name : x.title, subtitle: kind === 'tasks' ? taskLabel(x) : kind === 'schedules' ? (x.allDay ? '全天' : timeOf(x.startAt, o.utcOffsetMinutes) + '–' + timeOf(x.endAt, o.utcOffsetMinutes)) + (x.location ? ' · ' + x.location : '') : kind === 'projects' ? x.goal || '暂无目标' : (x.completed ? '已完成' : '待完成') + (x.due ? ' · ' + x.due : ''), completed: !!x.completed, quadrant: kind === 'tasks' ? quadrant(x) : -1 })) }
function build(o, pageKind, selection, filter, calendarDate, calendarMode) {
  const d = date(calendarDate) || o.today; const rootTasks = o.tasks.filter((t) => !t.parentTaskId && !t.scheduleId)
  const model = { available: o.present, today: o.today, date: d, mode: calendarMode || '月', rows: [], scheduleRows: [], deadlines: [], later: [], groups: [], days: [], related: [], milestones: [], detail: null, coverage: KINDS.map((k) => LABELS[k] + ' ' + o.coverage[k].included + '/' + o.coverage[k].total).join(' · '), partial: o.truncated, profile: o.profile, sync: o.sync, nowSchedule: null }
  if (pageKind === 'home') {
    const focused = ordered(rootTasks.filter((t) => !t.completed && (t.important === true && t.urgent === true || t.due && t.due <= o.today)), 'manualPosition')
    model.rows = rows(o, 'tasks', focused)
    model.deadlines = rows(o, 'tasks', ordered(rootTasks.filter((t) => !t.completed && t.due && t.due > o.today), 'manualPosition').sort((a, b) => a.due.localeCompare(b.due)))
    const now = Date.now(); model.nowSchedule = rows(o, 'schedules', o.schedules.filter((s) => overlaps(s, o.today, o.utcOffsetMinutes) && Date.parse(s.endAt) > now).sort((a, b) => a.startAt.localeCompare(b.startAt)))[0] || null
    model.later = rows(o, 'schedules', o.schedules.filter((s) => dayOf(s.startAt, o.utcOffsetMinutes) === o.today && Date.parse(s.startAt) > now && (!model.nowSchedule || s.id !== model.nowSchedule.id)).sort((a, b) => a.startAt.localeCompare(b.startAt)))
    const next = model.nowSchedule ? [model.nowSchedule] : []
    model.cards = [
      { key: 'focus', label: '现在关注', tone: 'focusTone', items: model.rows },
      { key: 'next', label: '接下来', tone: 'nextTone', items: next },
      { key: 'due', label: '最近截止', tone: 'dueTone', items: model.deadlines },
      { key: 'later', label: '稍后日程', tone: 'laterTone', items: model.later }
    ].map((card) => Object.assign(card, { countLabel: o.present ? String(card.items.length) : '—', preview: card.items.length ? card.items[0].title : o.present ? '暂无安排' : '等待手机同步' }))
  } else if (pageKind === 'events') {
    const tasks = ordered(rootTasks.filter((t) => filter === '已完成' ? t.completed : !t.completed && (filter !== '无截止' || !t.due)), 'manualPosition')
    model.groups = QUADS.map((name, i) => ({ name, rows: rows(o, 'tasks', tasks.filter((t) => quadrant(t) === i)) }))
    model.rows = []; model.groups.forEach((g) => { model.rows = model.rows.concat(g.rows) })
  } else if (pageKind === 'projects') model.rows = rows(o, 'projects', ordered(o.projects, 'manualPosition'))
  else if (pageKind === 'calendar' && d) {
    const js = new Date(d + 'T12:00:00Z'); let first = d; let count = 1
    if (calendarMode === '周') { first = shift(d, -((js.getUTCDay() + 6) % 7)); count = 7 }
    if (calendarMode === '月') { first = d.slice(0, 8) + '01'; count = new Date(js.getUTCFullYear(), js.getUTCMonth() + 1, 0).getDate() }
    if (calendarMode === '月') { const padding = (new Date(first + 'T12:00:00Z').getUTCDay() + 6) % 7; for (let n = 0; n < padding; n++) model.days.push({ date: '', label: '', count: 0, selected: false }) }
    for (let i = 0; i < count; i++) { const value = shift(first, i); const schedules = o.schedules.filter((s) => overlaps(s, value, o.utcOffsetMinutes)); const tasks = o.tasks.filter((t) => !t.completed && t.due === value); model.days.push({ date: value, label: value.slice(8), count: schedules.length + tasks.length, selected: value === d }) }
    model.scheduleRows = rows(o, 'schedules', o.schedules.filter((s) => overlaps(s, d, o.utcOffsetMinutes)).sort((a, b) => a.startAt.localeCompare(b.startAt)))
    model.rows = rows(o, 'tasks', o.tasks.filter((t) => !t.completed && t.due === d))
  }
  if (selection) {
    const item = o[selection.kind].filter((x) => x.id === selection.id)[0]
    if (item) {
      const detail = Object.assign({}, item, { kind: selection.kind, displayTitle: selection.kind === 'projects' ? item.name : item.title, statusLabel: selection.kind === 'tasks' ? taskLabel(item) : selection.kind === 'projects' ? ({ active: '进行中', completed: '已完成', archived: '已归档' }[item.status] || item.status || '未知') : selection.kind === 'schedules' ? (item.allDay ? '全天日程' : '日程') : item.completed ? '已完成' : '待完成' })
      model.detail = detail
      if (selection.kind === 'tasks') { model.related = rows(o, 'tasks', o.tasks.filter((t) => t.parentTaskId === item.id)); detail.canAddChild = !item.parentTaskId && !item.scheduleId }
      if (selection.kind === 'schedules') { model.related = rows(o, 'tasks', o.tasks.filter((t) => t.scheduleId === item.id)); detail.when = dayOf(item.startAt, o.utcOffsetMinutes) + ' ' + timeOf(item.startAt, o.utcOffsetMinutes) + ' 至 ' + dayOf(item.endAt, o.utcOffsetMinutes) + ' ' + timeOf(item.endAt, o.utcOffsetMinutes) }
      if (selection.kind === 'projects') { model.related = rows(o, 'tasks', ordered(o.tasks.filter((t) => t.projectId === item.id && !t.parentTaskId), 'manualPosition')); model.milestones = rows(o, 'milestones', ordered(o.milestones.filter((m) => m.projectId === item.id), 'position')); detail.progress = model.milestones.filter((m) => m.completed).length + '/' + model.milestones.length; const next = o.tasks.filter((t) => t.id === item.nextActionTaskId && !t.completed)[0] || o.tasks.filter((t) => t.projectId === item.id && !t.completed).sort((a, b) => (a.due || '9999').localeCompare(b.due || '9999') || a.id.localeCompare(b.id))[0]; detail.next = next ? next.title : '暂无下一步任务' }
    }
  }
  return model
}
function toggle(o, kind, id) {
  const item = o[kind].filter((x) => x.id === id)[0]; if (!item || ['tasks', 'milestones'].indexOf(kind) < 0) return false
  item.completed = !item.completed
  if (kind === 'tasks') {
    if (item.completed) o.tasks.filter((t) => t.parentTaskId === id).forEach((t) => { t.completed = true })
    if (item.parentTaskId) { const p = o.tasks.filter((t) => t.id === item.parentTaskId)[0]; if (p) p.completed = o.tasks.filter((t) => t.parentTaskId === p.id).every((t) => t.completed) }
  }
  return true
}
function remove(o, kind, id) {
  const item = o[kind].filter((x) => x.id === id)[0]; if (!item) return false
  if (kind === 'tasks') o.tasks = o.tasks.filter((t) => t.id !== id && t.parentTaskId !== id)
  else if (kind === 'schedules') { o.schedules = o.schedules.filter((s) => s.id !== id); o.tasks = o.tasks.filter((t) => t.scheduleId !== id) }
  else if (kind === 'projects') o.projects = o.projects.filter((p) => p.id !== id)
  else o[kind] = o[kind].filter((x) => x.id !== id)
  return true
}
function reorder(o, kind, id, delta) {
  const field = kind === 'milestones' ? 'position' : 'manualPosition'; const item = o[kind].filter((x) => x.id === id)[0]; if (!item) return false
  const all = ordered(o[kind].filter((x) => kind === 'milestones' ? x.projectId === item.projectId : kind !== 'tasks' || x.parentTaskId === item.parentTaskId && x.scheduleId === item.scheduleId && quadrant(x) === quadrant(item) && x.completed === item.completed), field); const from = all.indexOf(item); const to = Math.max(0, Math.min(all.length - 1, from + delta)); all.splice(from, 1); all.splice(to, 0, item); all.forEach((x, i) => { x[field] = i }); return true
}
function fields(o, kind, item, context, d) {
  const value = item || {}; const list = []
  function add(key, label, choices, fallback) { const current = value[key] === undefined ? fallback : value[key]; if (choices.every((x) => x.value !== current)) choices.unshift({ label: str(current) || '未设置', value: current }); list.push({ key, label, choices, index: choices.map((x) => x.value).indexOf(current), value: current, shown: choices.filter((x) => x.value === current)[0].label }) }
  function options(values) { return values.map((v) => ({ label: v === null ? '未设置' : String(v), value: v })) }
  add(kind === 'projects' ? 'name' : 'title', kind === 'projects' ? '项目名称' : '标题', options(['完成手环界面设计', '检查日历交互', '整理下一周安排', '产品设计讨论', '新建' + LABELS[kind]]), '新建' + LABELS[kind])
  if (kind === 'projects') { add('goal', '项目目标', options([null, '小屏也能轻松管理一天', '完成本周工作', '保持专注与清晰']), null); return list }
  if (kind === 'tasks' || kind === 'schedules') add(kind === 'tasks' ? 'notes' : 'description', '备注', options([null, '在手机补充详细内容', '带上资料一起讨论', '本地演示内容']), null)
  if (kind !== 'schedules') add('due', '截止日期', options([null, d, shift(d, 1), shift(d, 7)]), d)
  if (kind === 'tasks') {
    add('dueTime', '截止时间', options([null, '09:00', '12:00', '15:00', '18:00', '21:00']), null)
    ;['important', 'urgent'].forEach((k) => add(k, k === 'important' ? '重要' : '紧急', [{ label: '未分类', value: null }, { label: '是', value: true }, { label: '否', value: false }], null))
    const projectChoices = [{ label: '无项目', value: null }].concat(o.projects.map((p) => ({ label: p.name, value: p.id }))); add('projectId', '所属项目', projectChoices, context && context.kind === 'projects' ? context.id : null)
  }
  if (kind === 'schedules') {
    add('_date', '日程日期', options([d, shift(d, 1), shift(d, 7)]), item ? dayOf(item.startAt, o.utcOffsetMinutes) : d)
    add('_endDate', '结束日期', options([d, shift(d, 1), shift(d, 7)]), item ? (item.allDay ? shift(dayOf(item.endAt, o.utcOffsetMinutes), -1) : dayOf(item.endAt, o.utcOffsetMinutes)) : d)
    add('_start', '开始时间', options(['08:00', '09:00', '10:00', '12:00', '15:00', '18:00', '21:00']), item ? timeOf(item.startAt, o.utcOffsetMinutes) : '09:00')
    add('_end', '结束时间', options(['09:00', '10:00', '11:00', '13:00', '16:00', '19:00', '22:00']), item ? timeOf(item.endAt, o.utcOffsetMinutes) : '10:00')
    add('allDay', '全天', [{ label: '否', value: false }, { label: '是', value: true }], false)
    add('important', '重要日程', [{ label: '否', value: false }, { label: '是', value: true }], false)
    add('location', '地点', options([null, '会议室', '家中', '线上', '办公室']), null)
  }
  if (kind === 'tasks' || kind === 'schedules') add('reminderMinutes', '提前提醒', [{ label: '不提醒', value: null }].concat([0, 5, 15, 30, 60].map((n) => ({ label: n + ' 分钟', value: n }))), null)
  return list
}
function save(o, kind, id, editorFields, context) {
  const existing = id ? o[kind].filter((x) => x.id === id)[0] : null; if (id && !existing) return '记录已失效'
  const item = existing ? Object.assign({}, existing) : { id: 'local-demo-' + (++serial), parentTaskId: null, scheduleId: null, projectId: null, manualPosition: o[kind].length, position: o[kind].length }
  editorFields.forEach((f) => { item[f.key] = f.value })
  if (kind === 'tasks' && item.completed === undefined || kind === 'milestones' && item.completed === undefined) item.completed = false
  if (!(kind === 'projects' ? item.name : item.title)) return '请选择标题'
  if (kind === 'schedules') { if (item._endDate < item._date) return '结束日期须不早于开始'; if (!item.allDay && item._endDate + 'T' + item._end <= item._date + 'T' + item._start) return '结束时间须晚于开始'; item.startAt = item._date + 'T' + (item.allDay ? '00:00' : item._start) + ':00' + zone(o.utcOffsetMinutes); item.endAt = (item.allDay ? shift(item._endDate, 1) : item._endDate) + 'T' + (item.allDay ? '00:00' : item._end) + ':00' + zone(o.utcOffsetMinutes); delete item._date; delete item._endDate; delete item._start; delete item._end }
  if (kind === 'tasks' && !existing && context) { if (context.kind === 'tasks') { const p = o.tasks.filter((t) => t.id === context.id)[0]; if (!p || p.parentTaskId || p.scheduleId) return '仅根任务可添加一级子项'; item.parentTaskId = p.id; item.scheduleId = null; item.projectId = p.projectId || null } if (context.kind === 'schedules') { if (!o.schedules.some((s) => s.id === context.id)) return '日程已失效'; item.scheduleId = context.id; item.parentTaskId = null } }
  if (kind === 'tasks' && !item.due && item.dueTime) return '截止时间需要截止日期'
  if (kind === 'tasks' && item.parentTaskId) { const parent = o.tasks.filter((t) => t.id === item.parentTaskId)[0]; if (!parent || parent.parentTaskId || parent.scheduleId || o.tasks.some((t) => t.parentTaskId === item.id)) return '子任务关系无效'; if (item.parentTaskId === item.id) return '任务不能关联自身' }
  if (kind === 'tasks' && item.scheduleId && (!o.schedules.some((s) => s.id === item.scheduleId) || o.tasks.some((t) => t.parentTaskId === item.id))) return '日程任务关系无效'
  if (kind === 'tasks' && item.parentTaskId && item.scheduleId) return '子任务与日程关系不能并存'
  if (kind === 'milestones') item.projectId = existing ? existing.projectId : context && context.kind === 'projects' ? context.id : null
  if (kind === 'milestones' && !item.projectId) return '需要所属项目'
  if (kind === 'projects' && !existing) item.status = 'active'
  if (existing) o[kind][o[kind].indexOf(existing)] = item; else o[kind].push(item)
  if (kind === 'tasks' && item.parentTaskId && !item.completed) { const p = o.tasks.filter((t) => t.id === item.parentTaskId)[0]; if (p) p.completed = false }
  return ''
}
module.exports = { normalize, demo, build, fields, save, toggle, remove, reorder, shift, quadrant, QUADS, KINDS }
