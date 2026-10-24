import test from "node:test";
import assert from "node:assert/strict";
import { filterTasks, isOverdue, type TaskFilters } from "../src/task-view";
import type { Project, Task } from "../src/api";

const now = new Date(2026, 9, 23, 12, 30);
const task = (id: string, values: Partial<Task> = {}): Task => ({ id, title: id, version: 1, notes: null, completed: false, due: null, dueTime: null, important: null, urgent: null, projectId: null, ...values });
const projects: Project[] = [{ id: "p1", name: "考试复习", version: 1, goal: null, description: null, status: "active", due: null, color: null, startDate: null }];
const defaults: TaskFilters = { query: "", status: "all", projectId: "", due: "all", sort: "due" };
const tasks = [task("yesterday", { due: "2026-10-22", projectId: "p1", notes: "Math" }), task("morning", { due: "2026-10-23", dueTime: "09:00:00", important: true }), task("today", { due: "2026-10-23" }), task("tomorrow", { due: "2026-10-24", urgent: true }), task("done", { due: "2026-10-20", completed: true, projectId: "p1" }), task("undated")];
const ids = (changes: Partial<TaskFilters>) => filterTasks(tasks, projects, { ...defaults, ...changes }, now).map((item) => item.id);

test("combined search, status and project filters include notes and project name", () => {
  assert.deepEqual(ids({ query: " MATH ", status: "open", projectId: "p1" }), ["yesterday"]);
  assert.deepEqual(ids({ query: "考试复习", status: "completed" }), ["done"]);
  assert.deepEqual(ids({ projectId: "none", due: "today" }), ["morning", "today"]);
  assert.deepEqual(ids({ query: "missing" }), []);
});
test("overdue uses local calendar and optional clock without treating undated or completed tasks as overdue", () => {
  assert.deepEqual(ids({ due: "overdue" }), ["yesterday", "morning"]);
  assert.equal(isOverdue(task("equal", { due: "2026-10-23", dueTime: "12:30:00" }), now), false);
  assert.equal(isOverdue(task("late", { due: "2026-10-23", dueTime: "12:29:00" }), now), true);
  assert.equal(isOverdue(tasks[2], now), false);
  assert.equal(isOverdue(tasks[4], now), false);
});
test("due filters distinguish today, future and no date", () => {
  assert.deepEqual(ids({ due: "today" }), ["morning", "today"]);
  assert.deepEqual(ids({ due: "upcoming" }), ["tomorrow"]);
  assert.deepEqual(ids({ due: "undated" }), ["undated"]);
});
test("due sorting puts open dated tasks first and leaves input order untouched", () => {
  const before = tasks.map((item) => item.id);
  assert.deepEqual(ids({}), ["yesterday", "morning", "today", "tomorrow", "undated", "done"]);
  assert.deepEqual(tasks.map((item) => item.id), before);
});
test("priority sorting preserves tri-state values and title sorting is explicit", () => {
  assert.deepEqual(ids({ sort: "priority" }).slice(0, 2), ["morning", "tomorrow"]);
  assert.deepEqual(ids({ sort: "title" }), [...tasks].sort((a, b) => a.title.localeCompare(b.title, "zh-CN")).map((item) => item.id));
});