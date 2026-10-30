const test = require('node:test')
const assert = require('node:assert/strict')
const organizer = require('../src/services/organizer')
function fixture(extra) {
  return organizer.normalize(Object.assign({schemaVersion: 1, today: '2026-10-28', utcOffsetMinutes: 480}, extra))
}
test('newly confirmed agenda events use chronological order across timezone representations', () => {
  const o = fixture({schedules: [
    {id: 'later', title: '稍后', startAt: '2026-10-28T08:00:00Z', endAt: '2026-10-28T09:00:00Z'},
    {id: 'earlier', title: '已确认日程', startAt: '2026-10-28T10:00:00+08:00', endAt: '2026-10-28T11:00:00+08:00'}
  ]})
  const model = organizer.build(o, 'calendar', null, null, o.today, '日')
  assert.deepEqual(model.scheduleRows.map(x => x.id), ['earlier', 'later'])
  assert.equal(model.scheduleRows[0].subtitle, '10:00–11:00')
})
test('all-day proposal detail displays the inclusive final date, retaining exclusive calendar boundaries', () => {
  const o = fixture({schedules: [{id: 'all', title: '全天安排', allDay: true, startAt: '2026-10-28T00:00:00+08:00', endAt: '2026-10-30T00:00:00+08:00'}]})
  const model = organizer.build(o, 'calendar', {kind: 'schedules', id: 'all'}, null, o.today, '日')
  assert.equal(model.detail.when, '2026-10-28 至 2026-10-29 · 全天')
  assert.equal(organizer.build(o, 'calendar', null, null, '2026-10-30', '日').scheduleRows.length, 0)
})
test('invalid schedule intervals are omitted and remain visible in coverage', () => {
  const o = fixture({schedules: [{id:'bad', title:'不完整', allDay:true, startAt:'invalid', endAt:'invalid'}]})
  assert.equal(o.schedules.length, 0)
  assert.equal(o.coverage.schedules.total, 1)
  assert.equal(o.truncated, true)
})
test('recent deadlines retain the phone manual order', () => {
  const o = fixture({tasks: [
    {id:'soon', title:'明天', due:'2026-10-29', manualPosition:2},
    {id:'first', title:'用户置顶', due:'2026-11-01', manualPosition:0}
  ]})
  assert.deepEqual(organizer.build(o, 'home').deadlines.map(x => x.id), ['first','soon'])
})
test('snapshot timestamps display in phone timezone and unknown cloud sync is not translated to success', () => {
  delete require.cache[require.resolve('../src/services/store')]
  const store = require('../src/services/store')
  store.acceptSnapshot({transferId:'zone', revision:1, view:{dataState:'live', updatedAt:'2026-10-28T01:30:00Z', organizer:fixture({sync:{status:'unknown'}})}})
  assert.equal(store.view().syncLabel, '上次同步 2026-10-28 09:30:00')
  assert.equal(store.view().organizer.sync.status, '同步状态未知')
  store.acceptSnapshot({transferId:'utc', revision:2, view:{updatedAt:'2026-10-28T01:30:00Z'}})
  assert.equal(store.view().syncLabel, '上次同步 2026-10-28 01:30:00 UTC')
})
