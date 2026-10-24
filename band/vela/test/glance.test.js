const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const organizer = require('../src/services/organizer')
const pages = require('../src/services/page')
function harness(kind) {
  delete require.cache[require.resolve('../src/services/store')]
  const store = require('../src/services/store')
  const page = pages.createPage(kind)
  Object.assign(page, JSON.parse(JSON.stringify(page.data)), { $app: { $def: { wearStore: store, wearTransport: {}, wearNavigation: ['home', 'menu', kind] } } })
  page.onInit()
  return { page, store }
}
test('four glance slots stay stable when empty; next schedule is not repeated in later', () => {
  assert.deepEqual(organizer.build(organizer.normalize(null), 'home').cards.map(c => c.key), ['focus', 'next', 'due', 'later'])
  const o = organizer.demo()
  const now = new Date(); o.today = now.toISOString().slice(0, 10); o.utcOffsetMinutes = 0
  o.schedules = [1, 2].map((id) => ({ id: String(id), title: 'schedule ' + id, startAt: new Date(now.getTime() + id * 60000).toISOString(), endAt: new Date(now.getTime() + (id + 1) * 60000).toISOString() }))
  const model = organizer.build(o, 'home')
  assert.equal(model.nowSchedule.id, '1')
  assert.equal(model.later.some(s => s.id === '1'), false)
})
test('quadrants open separately, paginate, and back closes detail before the quadrant', () => {
  const { page, store } = harness('events')
  const data = organizer.demo(); data.tasks = Array.from({length: 25}, (_, i) => ({ id: 't' + i, title: '任务' + i, important: true, urgent: true }))
  store.acceptSnapshot({transferId:'g', revision:1, view:{dataState:'live', organizer:data}})
  assert.equal(page.quadrants.length, 4)
  page.selectQuadrant(0); assert.equal(page.visibleRows.length, 10); assert.equal(page.hasMore, true)
  page.showMore(); assert.equal(page.visibleRows.length, 20)
  page.openItem('tasks', 't0'); page.goBack(); assert.equal(page.selection, null); assert.equal(page.quadrantFilter, 0)
  page.goBack(); assert.equal(page.quadrantFilter, -1)
  page.onDestroy()
})
test('home card detail returns to its category, and revocation removes all displayed records', async () => {
  const { page, store } = harness('home'); store.setDemo(true)
  page.openSection('focus'); page.openItem('tasks', 'task-1')
  page.handleSwipe({direction:'right'}); assert.equal(page.selection, null); assert.equal(page.homeSection, 'focus')
  await store.setScope(null); assert.equal(page.visibleRows.length, 0); assert.equal(page.organizer.cards.every(c => c.items.length === 0), true)
  page.goBack(); assert.equal(page.homeSection, '')
  page.onDestroy()
})
test('watch task completion uses the phone result; other business edits remain phone-only', () => {
  for (const kind of ['home','events','projects','calendar']) {
    const source = fs.readFileSync('src/pages/' + kind + '/' + kind + '.ux','utf8')
    assert.doesNotMatch(source, /onclick="(?:addTask|addSchedule|addProject|addMilestone|editItem|deleteItem|toggleDetail|saveEditor|moveUp|moveDown|cycleQuadrant|undoChange)/)
  }
  assert.match(fs.readFileSync('src/pages/events/events.ux','utf8'), /onclick="toggleTask"/)
  assert.match(fs.readFileSync('src/pages/calendar/calendar.ux','utf8'), /onclick="toggleTask"/)
  assert.equal(pages.createPage('home').startEditor, undefined)
})
test('vibration is short, throttled, optional and fails without blocking navigation', () => {
  let now = 1000; let calls = []
  const sandbox = {module:{exports:{}}, require:() => ({vibrate:o => {calls.push(o)}}), Date:{now:() => now}}
  vm.runInNewContext(fs.readFileSync('src/services/feedback.js','utf8'),sandbox)
  const pulse = sandbox.module.exports.pulse
  assert.equal(pulse(false),false); assert.equal(pulse(true),true); assert.equal(calls[0].mode,'short')
  assert.equal(pulse(true),false); now += 260; assert.equal(pulse(true),true)
  calls[1].fail(); now += 260; assert.equal(pulse(true),false)
})
test('reduced motion and haptics settings update live without touching organizer data', () => {
  const {page, store} = harness('settings'); store.setDemo(true)
  const before = JSON.stringify(store.view().organizer)
  page.entryMotion = 'enter'; page.toggleReducedMotion(); assert.equal(page.motionClass,'')
  page.toggleHaptics(); assert.equal(store.view().haptics,false)
  assert.equal(JSON.stringify(store.view().organizer), before); page.onDestroy()
})

test('returning to quadrants resets counts to pending, and snapshot deletion clears the detail trail', () => {
  const {page, store} = harness('events'); store.setDemo(true)
  page.selectQuadrant(1); page.cycleFilter(); page.cycleFilter(); page.goBack()
  assert.equal(page.filter, '待完成'); assert.equal(page.quadrants[1].count,1)
  const data = organizer.demo(); store.setDemo(false)
  store.acceptSnapshot({transferId:'a', revision:1, view:{dataState:'live',organizer:data}})
  page.openItem('projects','project-1'); page.openItem('tasks','task-1')
  data.tasks = data.tasks.filter(t => t.id !== 'task-1')
  store.acceptSnapshot({transferId:'b',revision:2,view:{dataState:'live',organizer:data}})
  assert.equal(page.selection,null); assert.deepEqual(page.detailTrail,[])
  page.onDestroy()
})
test('horizontal touch bubbles from cards, rejects vertical scroll and prevents accidental opening', () => {
  const {page} = harness('home'); let menus = 0; page.menu = () => { menus++ }
  const point = (x,y) => ({identifier:0, clientX:x, clientY:y})
  page.touchStart({touches:[point(280,100)]}); page.touchMove({touches:[point(100,105)]}); page.touchEnd({changedTouches:[point(80,105)]})
  assert.equal(menus,1); page.openSection('focus'); assert.equal(page.homeSection,'')
  page.touchStart({touches:[point(200,100)]}); page.touchMove({touches:[point(195,240)]}); page.touchEnd({changedTouches:[point(190,280)]})
  assert.equal(menus,1)
  page.onDestroy()
})
test('repeated settings/profile visits collapse cycles and retain the home root', () => {
  const {page} = harness('settings')
  page.navigation = ['home','menu','settings']
  for(let i=0;i<12;i++) { page.routeAt=0; page.visit('profile'); page.pageKind='profile'; page.routeAt=0; page.visit('settings'); page.pageKind='settings' }
  assert.deepEqual(page.navigation,['home','menu','settings'])
  page.onDestroy()
})

test('scroll suppresses setting, cache and transport clicks until the guard expires', async () => {
  const {page, store} = harness('settings'); store.setDemo(true)
  const snapshot = { transferId:'scroll', revision:1, view:{dataState:'live', organizer:organizer.demo()} }
  store.acceptSnapshot(snapshot)
  let diagnoses = 0; let pings = 0
  page.wearTransport = { diagnose() { diagnoses++ }, ping() { pings++ } }
  const before = store.view()
  const point = (x,y) => ({identifier:0, clientX:x, clientY:y})
  page.touchStart({touches:[point(180,90)]})
  page.touchMove({touches:[point(178,230)]})
  page.touchEnd({changedTouches:[point(178,230)]})
  const actions = ['toggleDemo', 'toggleHaptics', 'toggleReducedMotion', 'toggleCompact', 'clearCache', 'diagnose', 'ping']
  actions.forEach(action => page[action]())
  await Promise.resolve()
  const guarded = store.view()
  for (const key of ['demo','haptics','reducedMotion','compact','hasSnapshot']) assert.equal(guarded[key], before[key], key)
  assert.equal(diagnoses, 0); assert.equal(pings, 0)
  page.ignoreTapUntil = Date.now() - 1
  actions.forEach(action => page[action]())
  await Promise.resolve()
  const after = store.view()
  for (const key of ['demo','haptics','reducedMotion','compact']) assert.equal(after[key], !before[key], key)
  assert.equal(after.hasSnapshot, false)
  assert.equal(after.snapshotSummary, '缓存已清除')
  assert.equal(diagnoses, 1); assert.equal(pings, 1)
  page.onDestroy()
})

test('scroll suppresses list controls while horizontal swipe can still close details', () => {
  const {page, store} = harness('events'); store.setDemo(true)
  page.selectQuadrant(0); page.openItem('tasks','task-1')
  page.ignoreTapUntil = Date.now() + 1000
  page.showMore(); page.cycleFilter(); page.cycleGroup(); page.closeDetail()
  assert.equal(page.visibleLimit, 10); assert.equal(page.filter, '待完成'); assert.equal(page.quadrantFilter, 0)
  assert.equal(page.selection.id, 'task-1')
  page.handleSwipe({direction:'right'})
  assert.equal(page.selection, null); assert.equal(page.quadrantFilter, 0)
  page.ignoreTapUntil = Date.now() - 1
  page.showMore(); assert.equal(page.visibleLimit, 20)
  page.cycleFilter(); assert.equal(page.filter, '无截止')
  page.cycleGroup(); assert.equal(page.quadrantFilter, 1)
  page.onDestroy()
})


test('home distinguishes a running schedule and exposes local start time without losing title', () => {
  const now = Date.now(); const offset = 480
  const today = new Date(now + offset * 60000).toISOString().slice(0, 10)
  const o = organizer.normalize({ schemaVersion: 1, today, utcOffsetMinutes: offset, schedules: [{
    id: 'current', title: '正在讨论', startAt: new Date(now - 60000).toISOString(), endAt: new Date(now + 60000).toISOString()
  }] })
  const card = organizer.build(o, 'home').cards[1]
  assert.equal(card.label, '正在进行'); assert.equal(card.preview, '正在讨论')
  assert.equal(card.timeLabel, new Date(now - 60000 + offset * 60000).toISOString().slice(11, 16))
})
