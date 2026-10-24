import type { Project, Task } from "./api";
import { dateKey } from "./calendar";

export interface TaskFilters {
  query: string;
  status: "all" | "open" | "completed";
  projectId: string;
  due: "all" | "overdue" | "today" | "upcoming" | "undated";
  sort: "due" | "title" | "priority";
}

export function isOverdue(task: Task, now = new Date()): boolean {
  if (task.completed || !task.due) return false;
  const today = dateKey(now);
  const clock = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
  return task.due < today || (task.due === today && !!task.dueTime && task.dueTime.slice(0, 5) < clock);
}

export function filterTasks(tasks: Task[], projects: Project[], filters: TaskFilters, now = new Date()): Task[] {
  const names = new Map(projects.map((project) => [project.id, project.name]));
  const query = filters.query.trim().toLocaleLowerCase();
  const today = dateKey(now);
  return tasks.filter((task) => {
    if (filters.status === "open" && task.completed) return false;
    if (filters.status === "completed" && !task.completed) return false;
    if (filters.projectId === "none" ? task.projectId !== null : filters.projectId && task.projectId !== filters.projectId) return false;
    if (query && ![task.title, task.notes, names.get(task.projectId ?? "")].join(" ").toLocaleLowerCase().includes(query)) return false;
    switch (filters.due) {
      case "overdue": return isOverdue(task, now);
      case "today": return task.due === today;
      case "upcoming": return !!task.due && task.due > today;
      case "undated": return !task.due;
      default: return true;
    }
  }).sort((a, b) => {
    if (filters.sort === "title") return a.title.localeCompare(b.title, "zh-CN");
    const completed = Number(a.completed) - Number(b.completed);
    if (completed) return completed;
    if (filters.sort === "priority") {
      const priority = (task: Task) => Number(task.important === true) * 2 + Number(task.urgent === true);
      const difference = priority(b) - priority(a);
      if (difference) return difference;
    }
    return `${a.due ?? "9999-99-99"}T${a.dueTime || "23:59:59"}`.localeCompare(`${b.due ?? "9999-99-99"}T${b.dueTime || "23:59:59"}`) || a.title.localeCompare(b.title, "zh-CN");
  });
}
