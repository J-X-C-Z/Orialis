let router = null
let storage = null
const feedback = require('./feedback')
try { router = require('@system.router') } catch (error) { console.warn('router unavailable') }
try { storage = require('@system.storage') } catch (error) { console.warn('storage unavailable') }
function navigate(uri) { if (router && typeof router.replace === 'function') router.replace({ uri }) }
function savePreferences(activeStore) {
  if (!storage || typeof storage.set !== 'function') return
  const value = JSON.stringify({ compact: activeStore.view().compact, haptics: activeStore.view().haptics, reducedMotion: activeStore.view().reducedMotion })
  storage.set({ key: 'orialis.wear.ui.preferences', value, fail: () => activeStore.setDiagnostic({ detail: '本地偏好保存失败；当前设置在重启后可能恢复默认。' }) })
}
function createPage(kind) {
  return Object.assign({
    data: { pageKind: kind || 'home', motionClass: '', vm: { tasks: [], commands: [], devices: [], provenance: '无数据 · 等待手机同步' }, selectedTask: null, selectedCommand: null, confirmCommand: false, organizer: { rows: [], groups: [], days: [], related: [], milestones: [], deadlines: [], later: [], profile: {}, sync: {} }, selection: null, detailTrail: [], editor: null, fields: [], filter: '待完成', quadrantFilter: -1, quadrantLabel: '全部象限', calendarDate: '', calendarMode: '日', calendarDateLabel: '', calendarWeekday: '', calendarIsToday: false, calendarTotal: 0, visibleScheduleRows: [], notice: '', confirmDelete: false, homeSection: '', sectionTitle: '', visibleRows: [], visibleLimit: 10, hasMore: false, quadrants: [], unclassifiedCount: 0, pageTitle: { home: '今日', events: '四象限', calendar: '日历', projects: '项目', profile: '我的' }[kind] || 'Orialis' },
    onInit() {
      this.wearStore = this.$app.$def.wearStore
      this.wearTransport = this.$app.$def.wearTransport
      this.navigation = this.$app.$def.wearNavigation || [this.pageKind]
      this.entryMotion = this.$app.$def.wearMotion || ''
      this.$app.$def.wearMotion = ''
      this.unsubscribe = this.wearStore.subscribe((vm) => this.applyView(vm))
    },
    applyView(vm) {
      // Details must follow the current projection, including revocation/clear.
      this.selectedTask = this.selectedTask ? vm.tasks.filter((task) => task.id === this.selectedTask.id)[0] || null : null
      this.selectedCommand = this.selectedCommand ? vm.commands.filter((command) => command.id === this.selectedCommand.id)[0] || null : null
      if (!this.selectedCommand) this.confirmCommand = false
      if (this.pageKind === 'calendar' && (!this.calendarDate || this.calendarDate === (this.vm.organizer && this.vm.organizer.today))) this.calendarDate = vm.organizer.today
      this.vm = vm
      this.motionClass = vm.reducedMotion ? '' : this.entryMotion || ''
      if (!vm.demo) { this.editor = null; this.fields = [] }
      if (!vm.organizer.present) { this.selection = null; this.detailTrail = []; this.confirmDelete = false; this.calendarDate = ''; this.visibleLimit = 10 }
      this.refreshOrganizer()
    },
    onShow() { if (this.wearStore) this.applyView(this.wearStore.view()) },
    onDestroy() { if (this.unsubscribe) this.unsubscribe() },
    tapFeedback() { feedback.pulse(this.vm.haptics) },
    ignoreTap() { return !this.swiping && Date.now() < (this.ignoreTapUntil || 0) },
    beginRoute(back) {
      if (this.ignoreTap()) return false
      const now = Date.now()
      if (this.routeAt && now - this.routeAt < 280) return false
      this.routeAt = now
      this.$app.$def.wearMotion = this.vm.reducedMotion ? '' : back ? 'enterBack' : 'enter'
      this.tapFeedback()
      return true
    },
    visit(kind) {
      if (!this.beginRoute(false)) return
      if (this.navigation[this.navigation.length - 1] !== this.pageKind) { this.navigation.length = 0; this.navigation.push(this.pageKind) }
      const existing = this.navigation.indexOf(kind)
      if (existing >= 0) this.navigation.splice(existing + 1)
      else this.navigation.push(kind)
      if (this.navigation.length > 8) this.navigation.splice(1, 1)
      navigate('/pages/' + (kind === 'diagnostics' ? 'index' : kind))
    },
    home() { if (!this.beginRoute(true)) return; this.navigation.length = 0; this.navigation.push('home'); navigate('/pages/home') },
    menu() { this.visit('menu') }, tasks() { this.visit('tasks') },
    events() { this.visit('events') }, calendar() { this.visit('calendar') }, projects() { this.visit('projects') }, profile() { this.visit('profile') },
    commands() { this.visit('commands') }, devices() { this.visit('devices') }, settings() { this.visit('settings') }, diagnostics() { this.visit('diagnostics') },
    goBack() {
      if (this.ignoreTap()) return
      if (this.selection) { this.closeDetail(); return }
      if (this.selectedTask) { this.closeTask(); return }
      if (this.selectedCommand) { this.closeCommand(); return }
      if (this.homeSection) { this.homeSection = ''; this.visibleLimit = 10; this.tapFeedback(); this.refreshOrganizer(); return }
      if (this.pageKind === 'events' && this.quadrantFilter >= 0) { this.quadrantFilter = -1; this.filter = '待完成'; this.visibleLimit = 10; this.tapFeedback(); this.refreshOrganizer(); return }
      if (!this.beginRoute(true)) return
      if (this.navigation.length > 1 && this.navigation[this.navigation.length - 1] === this.pageKind) this.navigation.pop()
      const previous = this.navigation[this.navigation.length - 1] !== this.pageKind && this.navigation[this.navigation.length - 1] || (this.pageKind === 'diagnostics' ? 'settings' : 'home')
      navigate('/pages/' + (previous === 'diagnostics' ? 'index' : previous))
    },
    touchStart(event) {
      const t = event.touches && event.touches[0]
      this.touchOrigin = t ? { x: t.clientX, y: t.clientY, id: t.identifier } : null
      this.touchAxis = ''; this.lastTouch = t || null
    },
    touchMove(event) {
      const t = event.touches && event.touches[0]; const start = this.touchOrigin
      if (!t || !start || t.identifier !== start.id) return
      this.lastTouch = t
      const dx = t.clientX - start.x; const dy = t.clientY - start.y
      if (!this.touchAxis && Math.max(Math.abs(dx), Math.abs(dy)) > 12) this.touchAxis = Math.abs(dx) > Math.abs(dy) * 1.5 ? 'horizontal' : 'vertical'
      if (this.touchAxis) this.ignoreTapUntil = Date.now() + 350
    },
    touchEnd(event) {
      const t = event.changedTouches && event.changedTouches[0] || this.lastTouch; const start = this.touchOrigin
      this.touchOrigin = null
      if (!t || !start || t.identifier !== start.id || this.touchAxis === 'vertical') return
      const dx = t.clientX - start.x; const dy = t.clientY - start.y
      if (Math.abs(dx) >= 44 && Math.abs(dx) > Math.abs(dy) * 1.5) {
        this.ignoreTapUntil = Date.now() + 350
        this.handleSwipe({ direction: dx < 0 ? 'left' : 'right' })
      }
    },
    handleSwipe(event) {
      if (!event || ['left', 'right'].indexOf(event.direction) < 0) return
      const now = Date.now()
      if (now - (this.lastSwipeAt || 0) < 350) return
      this.lastSwipeAt = now
      this.swiping = true
      // Vela swipe recognizer supplies cardinal directions: vertical scroll never routes.
      if (event.direction === 'right' && (this.pageKind !== 'home' || this.selection || this.homeSection)) this.goBack()
      else if (event.direction === 'left' && this.pageKind === 'home' && !this.selection && !this.homeSection) this.menu()
      this.swiping = false
    },
    openTask(id) { this.selectedTask = this.vm.tasks.filter((task) => task.id === id)[0] || null },
    closeTask() { this.selectedTask = null },
    openCommand(id) { this.selectedCommand = this.vm.commands.filter((command) => command.id === id)[0] || null; this.confirmCommand = false },
    previewConfirmation() { this.confirmCommand = true },
    closeCommand() { this.selectedCommand = null; this.confirmCommand = false },
    refreshOrganizer() {
      if (!this.wearStore || !this.vm.organizer) return
      if (!this.calendarDate) this.calendarDate = this.vm.organizer.today
      if (this.pageKind === 'calendar') this.calendarMode = '日'
      this.organizer = this.wearStore.organizerBuild(this.pageKind, this.selection, this.filter, this.calendarDate, this.calendarMode)
      if (this.pageKind === 'events') {
        const tones = ['focusTone', 'nextTone', 'dueTone', 'laterTone']
        this.quadrants = this.organizer.groups.slice(0, 4).map((g, index) => ({ index, name: g.name, count: g.rows.length, tone: tones[index] }))
        this.unclassifiedCount = this.organizer.groups[4].rows.length
        if (this.quadrantFilter >= 0) this.organizer.rows = this.organizer.groups[this.quadrantFilter].rows
      }
      let all = this.organizer.rows
      if (this.pageKind === 'home') {
        const section = (this.organizer.cards || []).filter((c) => c.key === this.homeSection)[0]
        all = section ? section.items : []
        this.sectionTitle = section ? section.label : ''
      }
      if (this.pageKind === 'calendar') {
        const day = this.organizer.date
        const weekday = day ? new Date(day + 'T12:00:00Z').getUTCDay() : NaN
        this.calendarDateLabel = day ? Number(day.slice(5, 7)) + '月' + Number(day.slice(8)) + '日' : '等待手机同步'
        this.calendarWeekday = isFinite(weekday) ? day.slice(0, 4) + '年 · 周' + '日一二三四五六'.charAt(weekday) : ''
        this.calendarIsToday = !!day && day === this.vm.organizer.today
        this.calendarTotal = this.organizer.scheduleRows.length + all.length
        // One shared budget: schedules and deadlines together start at ten rows.
        this.visibleScheduleRows = this.organizer.scheduleRows.slice(0, this.visibleLimit)
        this.visibleRows = all.slice(0, Math.max(0, this.visibleLimit - this.visibleScheduleRows.length))
        this.hasMore = this.calendarTotal > this.visibleScheduleRows.length + this.visibleRows.length
      } else {
        this.visibleRows = all.slice(0, this.visibleLimit)
        this.hasMore = all.length > this.visibleRows.length
      }
      if (this.selection && !this.organizer.detail) { this.selection = null; this.detailTrail = []; this.confirmDelete = false }
    },
    openSection(key) { if (this.ignoreTap()) return; this.homeSection = key; this.visibleLimit = 10; this.tapFeedback(); this.refreshOrganizer() },
    selectQuadrant(index) { if (this.ignoreTap()) return; this.quadrantFilter = index; this.quadrantLabel = ['重要且紧急', '重要不紧急', '紧急不重要', '不重要不紧急', '未分类'][index]; this.filter = '待完成'; this.visibleLimit = 10; this.tapFeedback(); this.refreshOrganizer() },
    showMore() { this.visibleLimit += 10; this.refreshOrganizer() },
    openItem(kind, id) { if (this.ignoreTap()) return; this.tapFeedback(); if (this.selection) { this.detailTrail = this.detailTrail.concat([this.selection]).slice(-4) } this.selection = { kind, id }; this.confirmDelete = false; this.notice = ''; this.refreshOrganizer() },
    closeDetail() { this.tapFeedback(); this.selection = this.detailTrail.length ? this.detailTrail[this.detailTrail.length - 1] : null; this.detailTrail = this.detailTrail.slice(0, -1); this.confirmDelete = false; this.notice = ''; this.refreshOrganizer() },
    cycleFilter() { this.visibleLimit = 10; this.tapFeedback(); const choices = ['待完成', '无截止', '已完成']; this.filter = choices[(choices.indexOf(this.filter) + 1) % 3]; this.refreshOrganizer() },
    cycleGroup() { this.quadrantFilter = (this.quadrantFilter + 2) % 6 - 1; this.quadrantLabel = ['全部象限', '重要且紧急', '重要不紧急', '紧急不重要', '不重要不紧急', '未分类'][this.quadrantFilter + 1]; this.refreshOrganizer() },
    dateStep(delta) {
      if (this.ignoreTap()) return
      if (!this.calendarDate) { this.notice = '等待手机本地日期同步'; return }
      this.selectDate(this.wearStore.organizerShift(this.calendarDate, delta))
    },
    prevDate() { this.dateStep(-1) }, nextDate() { this.dateStep(1) },
    selectDate(value) {
      if (this.ignoreTap() || !value) return
      this.calendarDate = value; this.visibleLimit = 10; this.notice = ''; this.tapFeedback(); this.refreshOrganizer()
    },
    todayDate() { this.selectDate(this.vm.organizer.today) },
    phoneAccount() { this.notice = '登录、注册、退出及账户凭据请在手机「我的」完成' },
    phoneSync() { this.notice = '服务器、手动同步与冲突处理请在手机「我的」完成' },
    phoneAppearance() { this.notice = '亮色、暗色、跟随系统与高性能模式请在手机设置；手环采用黑底' },
    phoneSecurity() { this.notice = '配对确认、拒绝、撤销凭据及切换当前设备请在手机「设备中心」完成' },
    selectDevice(id) { this.wearStore.selectPreviewTarget(id) },
    toggleDemo() { this.wearStore.setDemo(!this.vm.demo) },
    toggleHaptics() { this.wearStore.setHaptics(!this.vm.haptics); this.tapFeedback(); savePreferences(this.wearStore) },
    toggleReducedMotion() { this.wearStore.setReducedMotion(!this.vm.reducedMotion); this.tapFeedback(); savePreferences(this.wearStore) },
    toggleCompact() { this.wearStore.setCompact(!this.vm.compact); savePreferences(this.wearStore) },
    diagnose() { this.wearTransport.diagnose() }, ping() { this.wearTransport.ping() },
    clearCache() { this.wearStore.resetCache().then(() => this.wearStore.setDiagnostic({ snapshotSummary: '缓存已清除' })).catch(() => this.wearStore.setDiagnostic({ detail: '缓存清除失败，请重试。' })) }
  })
}
function loadPreferences(activeStore) {
  if (!storage || typeof storage.get !== 'function') return
  storage.get({ key: 'orialis.wear.ui.preferences', success: (value) => { try { const data = JSON.parse(value); activeStore.setCompact(data.compact === true); activeStore.setHaptics(data.haptics !== false); activeStore.setReducedMotion(data.reducedMotion === true) } catch (error) {} } })
}
module.exports = { createPage, loadPreferences }
