function payloadOf(snapshot) { return snapshot && snapshot.payload ? snapshot.payload : {} }

function priorityOf(task) {
  if (task.important && task.urgent) return "red"
  if (task.urgent) return "yellow"
  if (task.important) return "blue"
  return "green"
}

function snapshotTasks(snapshot, limit) {
  const list = payloadOf(snapshot).tasks && payloadOf(snapshot).tasks.items
  return (Array.isArray(list) ? list : []).slice(0, limit || 20).map(item => ({
    id: item.id || "task-" + Math.random().toString(36).slice(2),
<<<<<<< HEAD
    projectId: item.projectId || "",
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
    title: item.title || "未命名任务",
    note: item.dueTime ? `${item.due || ""} ${item.dueTime}`.trim() : (item.due || ""),
    priority: priorityOf(item),
    completed: !!item.completed
  }))
}

function snapshotSchedule(snapshot) {
  const list = payloadOf(snapshot).schedule && payloadOf(snapshot).schedule.items
  return (Array.isArray(list) ? list : []).slice(0, 12).map(item => ({
    id: item.id || "schedule-" + Math.random().toString(36).slice(2),
    time: item.startTime || item.time || (item.startSection ? `第${item.startSection}节` : ""),
    title: item.title || item.name || "未命名安排",
    location: item.location || "地点待定",
    duration: item.duration || "",
    active: !!item.active
  }))
}

<<<<<<< HEAD
function projectItems(snapshot) {
  const payload = payloadOf(snapshot)
  if (Array.isArray(payload.projects)) return payload.projects
  if (payload.projects && Array.isArray(payload.projects.items)) return payload.projects.items
  if (snapshot && Array.isArray(snapshot.projects)) return snapshot.projects
  if (snapshot && snapshot.data && Array.isArray(snapshot.data.projects)) return snapshot.data.projects
  return null
}

function projectProgress(project, tasks, milestones) {
  const explicit = Number(project.progress && typeof project.progress === "object" ? project.progress.percent : project.progress)
  if (Number.isFinite(explicit)) return Math.max(0, Math.min(100, Math.round(explicit > 1 ? explicit : explicit * 100)))
  const total = tasks.length + milestones.length
  if (!total) return 0
  const completed = tasks.filter(item => item.completed).length + milestones.filter(item => item.completed).length
  return Math.round(completed * 100 / total)
}

function snapshotProjects(snapshot, limit) {
  const source = projectItems(snapshot)
  if (!source) return null
  const allTasks = snapshotTasks(snapshot, 1000)
  return source.slice(0, limit || 20).map((project, index) => {
    const tasks = allTasks.filter(task => task.projectId === project.id)
    const milestones = Array.isArray(project.milestones)
      ? project.milestones
      : (project.milestones && Array.isArray(project.milestones.items) ? project.milestones.items : [])
    const completed = tasks.filter(task => task.completed).concat(milestones.filter(item => item.completed))
    const projectedPending = Array.isArray(project.pendingActions) ? project.pendingActions : []
    const pending = (projectedPending.length ? projectedPending : tasks.filter(task => !task.completed))
      .concat(milestones.filter(item => !item.completed).map(item => ({ title: item.title || "未命名里程碑", due: item.due || "" })))
    const explicitNext = project.nextAction && typeof project.nextAction === "object" ? project.nextAction.title : (project.nextAction || project.nextActionTitle)
    const nextTask = project.nextActionTaskId && tasks.find(task => task.id === project.nextActionTaskId)
    return {
      id: project.id || `project-${index}`,
      name: project.name || "未命名项目",
      progress: projectProgress(project, tasks, milestones),
      progressWidth: Math.round(projectProgress(project, tasks, milestones) * 2.66),
      recent: project.recentCompleted || (completed.length ? (completed[completed.length - 1].title || "已完成一项") : "暂无完成记录"),
      next: explicitNext || (nextTask && nextTask.title) || (pending[0] && pending[0].title) || "暂无下一步行动",
      color: project.color === "teal" || project.color === "sage" ? "teal" : "blue"
    }
  })
}

export { payloadOf, snapshotTasks, snapshotSchedule, snapshotProjects }
=======
export { payloadOf, snapshotTasks, snapshotSchedule }
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89
