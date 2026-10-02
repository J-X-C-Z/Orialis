const test = require('node:test')
const assert = require('node:assert/strict')
const pages = require('../src/services/page')

function harness(today = '2028-02-28') {
  delete require.cache[require.resolve('../src/services/store')]
  const store = require('../src/services/store')
  const page = pages.createPage('calendar')
  Object.assign(page, JSON.parse(JSON.stringify(page.data)), { $app: { $def: { wearStore: store, wearTransport: {}, wearNavigation: ['home', 'menu', 'calendar'] } } })
  page.onInit()
  const data = { schemaVersion: 1, today, utcOffsetMinutes: 480, tasks: [], schedules: [], projects: [], milestones: [] }
  let revision = 0
  function publish() { store.acceptSnapshot({ transferId: 'calendar-' + (++revision), revision, view: { dataState: 'live', organizer: data } }) }
  publish()
  return { page, store, data, publish }
}

test('calendar stays in day view and advances one local date across leap days and years', () => {
  const { page } = harness()
  assert.equal(page.calendarMode, '日')
  assert.equal(page.organizer.days.length, 1)
  assert.equal(page.calendarDateLabel, '2月28日')
  assert.equal(page.calendarWeekday, '2028年 · 周一')
  page.nextDate(); assert.equal(page.calendarDate, '2028-02-29')
  page.nextDate(); assert.equal(page.calendarDate, '2028-03-01')
  page.prevDate(); assert.equal(page.calendarDate, '2028-02-29')
  page.selectDate('2028-12-31'); page.nextDate(); assert.equal(page.calendarDate, '2029-01-01')
  page.todayDate(); assert.equal(page.calendarDate, '2028-02-28'); assert.equal(page.calendarIsToday, true)
  page.onDestroy()
})

test('schedules and deadlines share one ten-row budget and changing day resets it', () => {
  const { page, store, data, publish } = harness()
  data.schedules = Array.from({ length: 12 }, (_, i) => ({ id: 's' + i, title: '日程' + i, startAt: data.today + 'T09:00:00+08:00', endAt: data.today + 'T10:00:00+08:00' }))
  data.tasks = Array.from({ length: 11 }, (_, i) => ({ id: 't' + i, title: '任务' + i, due: data.today, completed: false }))
  publish()
  const before = JSON.stringify(store.view().organizer)
  assert.equal(page.calendarTotal, 23)
  assert.equal(page.visibleScheduleRows.length, 10)
  assert.equal(page.visibleRows.length, 0)
  assert.equal(page.hasMore, true)
  page.showMore(); assert.equal(page.visibleScheduleRows.length, 12); assert.equal(page.visibleRows.length, 8)
  page.showMore(); assert.equal(page.visibleRows.length, 11); assert.equal(page.hasMore, false)
  page.openItem('tasks', 't10'); page.goBack(); assert.equal(page.selection, null); assert.equal(page.visibleRows.length, 11)
  page.nextDate(); assert.equal(page.calendarTotal, 0); assert.equal(page.hasMore, false)
  page.todayDate(); assert.equal(page.visibleLimit, 10); assert.equal(page.visibleScheduleRows.length + page.visibleRows.length, 10)
  assert.equal(JSON.stringify(store.view().organizer), before)
  page.onDestroy()
})

test('phone day refresh follows Today but preserves a deliberately selected other date', () => {
  const { page, data, publish } = harness()
  data.today = '2028-02-29'; publish()
  assert.equal(page.calendarDate, '2028-02-29'); assert.equal(page.calendarIsToday, true)
  page.prevDate(); data.today = '2028-03-01'; publish()
  assert.equal(page.calendarDate, '2028-02-28'); assert.equal(page.calendarIsToday, false)
  page.todayDate(); assert.equal(page.calendarDate, '2028-03-01')
  page.onDestroy()
})

test('calendar revocation clears both row groups and date; a new session uses its phone date', async () => {
  const { page, store, data, publish } = harness()
  data.schedules = [{ id: 's', title: '私密日程', startAt: data.today + 'T09:00:00+08:00', endAt: data.today + 'T10:00:00+08:00' }]
  data.tasks = [{ id: 't', title: '私密任务', due: data.today }]
  publish(); page.openItem('schedules', 's')
  await store.setScope(null)
  assert.equal(page.selection, null); assert.deepEqual(page.detailTrail, [])
  assert.equal(page.calendarDate, ''); assert.equal(page.calendarWeekday, '')
  assert.equal(page.visibleScheduleRows.length, 0); assert.equal(page.visibleRows.length, 0); assert.equal(page.calendarTotal, 0)
  await store.setScope({ accountId: 'other', sessionId: 'new', targetId: 'band' })
  store.acceptSnapshot({ transferId: 'new', revision: 1, scope: { accountId: 'other', sessionId: 'new', targetId: 'band' }, view: { dataState: 'live', organizer: { schemaVersion: 1, today: '2029-01-01', utcOffsetMinutes: 0 } } })
  assert.equal(page.calendarDate, '2029-01-01'); assert.equal(page.calendarDateLabel, '1月1日')
  page.onDestroy()
})

test('scroll gestures do not trigger date buttons and valid changes give touch feedback', () => {
  const { page } = harness(); let pulses = 0; page.tapFeedback = () => { pulses++ }
  page.ignoreTapUntil = Date.now() + 1000
  page.nextDate(); page.todayDate(); assert.equal(page.calendarDate, '2028-02-28'); assert.equal(pulses, 0)
  page.ignoreTapUntil = 0
  page.nextDate(); assert.equal(page.calendarDate, '2028-02-29'); assert.equal(pulses, 1)
  page.onDestroy()
})
