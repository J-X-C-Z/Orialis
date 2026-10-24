import { list, request, type Project, type ProjectSummary, type Task } from "./api";
import { dialog, errorText, escape, notify, submitting } from "./ui";
import { renderChat } from "./chat";
import { filterTasks, isOverdue, type TaskFilters } from "./task-view";

type Page = "tasks" | "projects" | "chat";
interface WorkspaceOptions {
  projectId?: string;
  openProjectTasks?: (projectId: string) => void;
}

const field = (
  label: string,
  name: string,
  value = "",
  type = "text",
  required = false,
) => `
  <label class="field">${escape(label)}
    <input name="${escape(name)}" type="${escape(type)}" value="${escape(value)}"${required ? " required" : ""}>
  </label>`;

const textarea = (label: string, name: string, value = "") => `
  <label class="field">${escape(label)}
    <textarea name="${escape(name)}" rows="3">${escape(value)}</textarea>
  </label>`;

const checked = (value: boolean) => (value ? " checked" : "");

function dateLabel(value: string | null, time?: string | null): string {
  if (!value) return "无截止日期";
  return `${value}${time ? ` ${time}` : ""}`;
}

function alertMarkup(): string {
  return '<p class="error" role="alert" aria-live="polite"></p>';
}

function showError(root: HTMLElement, error: unknown): void {
  let target = root.querySelector<HTMLElement>('[role="alert"]');
  if (!target) {
    target = document.createElement("p");
    target.className = "error";
    target.setAttribute("role", "alert");
    root.prepend(target);
  }
  target.textContent = errorText(error);
}

function formValue(form: HTMLFormElement, name: string): string {
  return String(new FormData(form).get(name) ?? "").trim();
}

function optional(value: string): string | null {
  return value || null;
}

async function openTaskEditor(
  root: HTMLElement,
  task: Task | null,
  projects: Project[],
  afterSave: () => Promise<void>,
  projectId = "",
): Promise<void> {
  const clientId = task ? undefined : crypto.randomUUID();
  const projectOptions = [
    '<option value="">未关联项目</option>',
    ...projects.map(
      (project) =>
        `<option value="${escape(project.id)}"${(task ? task.projectId : projectId) === project.id ? " selected" : ""}>${escape(project.name)}</option>`,
    ),
  ].join("");
  const content = `<form class="form-grid" data-task-form>
    ${alertMarkup()}
    ${field("任务名称", "title", task?.title ?? "", "text", true)}
    ${textarea("备注", "notes", task?.notes ?? "")}
    <label class="field">所属项目<select name="projectId">${projectOptions}</select></label>
    ${field("截止日期", "due", task?.due ?? "", "date")}
    ${field("截止时间", "dueTime", task?.dueTime ?? "", "time")}
    <label class="field">重要<select name="important">
      <option value=""${task?.important == null ? " selected" : ""}>未分类</option>
      <option value="true"${task?.important === true ? " selected" : ""}>是</option>
      <option value="false"${task?.important === false ? " selected" : ""}>否</option>
    </select></label>
    <label class="field">紧急<select name="urgent">
      <option value=""${task?.urgent == null ? " selected" : ""}>未分类</option>
      <option value="true"${task?.urgent === true ? " selected" : ""}>是</option>
      <option value="false"${task?.urgent === false ? " selected" : ""}>否</option>
    </select></label>
    <div class="actions wide"><button class="primary" type="submit">保存</button><button class="secondary" type="button" data-cancel>取消</button></div>
  </form>`;
  const modal = dialog(task ? "编辑任务" : "新建任务", content);
  modal
    .querySelector<HTMLButtonElement>("[data-cancel]")
    ?.addEventListener("click", () => modal.close());
  const form = modal.querySelector<HTMLFormElement>("[data-task-form]")!;
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void submitting(form, async () => {
      const title = formValue(form, "title");
      const due = formValue(form, "due");
      const dueTime = formValue(form, "dueTime");
      if (!title) throw new Error("请填写任务名称。");
      if (!due && dueTime)
        throw new Error("填写截止时间前，请先选择截止日期。");
      const body = {
        title,
        notes: optional(formValue(form, "notes")),
        projectId: optional(formValue(form, "projectId")),
        due: optional(due),
        dueTime: optional(dueTime),
        id: clientId,
        important:
          formValue(form, "important") === ""
            ? null
            : formValue(form, "important") === "true",
        urgent:
          formValue(form, "urgent") === ""
            ? null
            : formValue(form, "urgent") === "true",
        ...(task ? { baseVersion: task.version } : {}),
      };
      await request<Task>(
        task ? `/tasks/${encodeURIComponent(task.id)}` : "/tasks",
        task ? "PATCH" : "POST",
        body,
      );
      modal.close();
      await afterSave();
      notify(task ? "任务已更新。" : "任务已创建。");
    });
  });
}

async function openProjectEditor(
  root: HTMLElement,
  project: Project | null,
  options: WorkspaceOptions = {},
): Promise<void> {
  const clientId = project ? undefined : crypto.randomUUID();
  const content = `<form class="form-grid" data-project-form>
    ${alertMarkup()}
    ${field("项目名称", "name", project?.name ?? "", "text", true)}
    ${field("目标", "goal", project?.goal ?? "")}
    ${textarea("描述", "description", project?.description ?? "")}
    <label class="field">状态<select name="status">
      <option value="active"${project?.status === "active" || !project ? " selected" : ""}>进行中</option>
      <option value="completed"${project?.status === "completed" ? " selected" : ""}>已完成</option>
      <option value="archived"${project?.status === "archived" ? " selected" : ""}>已归档</option>
    </select></label>
    ${field("开始日期", "startDate", project?.startDate ?? "", "date")}
    ${field("截止日期", "due", project?.due ?? "", "date")}
    ${field("颜色标记", "color", project?.color ?? "")}
    <div class="actions wide"><button class="primary" type="submit">保存</button><button class="secondary" type="button" data-cancel>取消</button></div>
  </form>`;
  const modal = dialog(project ? "编辑项目" : "新建项目", content);
  modal
    .querySelector<HTMLButtonElement>("[data-cancel]")
    ?.addEventListener("click", () => modal.close());
  const form = modal.querySelector<HTMLFormElement>("[data-project-form]")!;
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void submitting(form, async () => {
      const name = formValue(form, "name");
      if (!name) throw new Error("请填写项目名称。");
      const body = {
        id: clientId,
        name,
        goal: optional(formValue(form, "goal")),
        description: optional(formValue(form, "description")),
        status: formValue(form, "status"),
        startDate: optional(formValue(form, "startDate")),
        due: optional(formValue(form, "due")),
        color: optional(formValue(form, "color")),
        ...(project ? { baseVersion: project.version } : {}),
      };
      await request<Project>(
        project ? `/projects/${encodeURIComponent(project.id)}` : "/projects",
        project ? "PATCH" : "POST",
        body,
      );
      modal.close();
      await renderProjects(root, options);
      notify(project ? "项目已更新。" : "项目已创建。");
    });
  });
}

function taskRows(tasks: Task[], projects: Project[]): string {
  if (!tasks.length) return '<p class="empty">没有符合条件的任务。</p>';
  const names = new Map(projects.map((project) => [project.id, project.name]));
  return `<div class="workspace-list">${tasks
    .map(
      (task) => `<article class="list-row" data-task="${escape(task.id)}">
    <label class="task-check"><input type="checkbox" data-complete="${escape(task.id)}"${checked(task.completed)} aria-label="${task.completed ? "标记未完成" : "标记完成"}：${escape(task.title)}"></label>
    <div class="task-main"><strong class="${task.completed ? "muted" : ""}">${escape(task.title)}</strong>
      <div class="muted">${escape(dateLabel(task.due, task.dueTime))}${task.projectId && names.has(task.projectId) ? ` · ${escape(names.get(task.projectId))}` : ""}</div>
      <div>${isOverdue(task) ? '<span class="pill overdue">已逾期</span>' : ""}${task.important ? '<span class="pill">重要</span>' : ""}${task.urgent ? '<span class="pill">紧急</span>' : ""}</div>
    </div>
    <div class="actions"><button class="secondary" type="button" data-edit-task="${escape(task.id)}">编辑</button><button class="secondary" type="button" data-delete-task="${escape(task.id)}">删除</button></div>
  </article>`,
    )
    .join("")}</div>`;
}

async function renderTasks(root: HTMLElement, projectId = ""): Promise<void> {
  root.innerHTML = `<div class="toolbar"><p class="muted">查看进度、截止日期和项目归属。</p><div class="actions"><button class="secondary" type="button" data-refresh>刷新</button><button class="primary" type="button" data-new-task disabled>新建任务</button></div></div>
    <div class="task-filters">
      <label class="field task-search">搜索任务<input type="search" data-query placeholder="标题、备注或项目名称"></label>
      <label class="field">完成状态<select data-filter="status"><option value="all">全部状态</option><option value="open">未完成</option><option value="completed">已完成</option></select></label>
      <label class="field">所属项目<select data-filter="projectId"><option value="">全部项目</option><option value="none">未关联项目</option></select></label>
      <label class="field">截止范围<select data-filter="due"><option value="all">全部日期</option><option value="overdue">已逾期</option><option value="today">今天到期</option><option value="upcoming">今天之后</option><option value="undated">无截止日期</option></select></label>
      <label class="field">排序<select data-filter="sort"><option value="due">截止日期优先</option><option value="priority">重要 / 紧急优先</option><option value="title">任务名称</option></select></label>
      <button type="button" class="secondary" data-reset>清除筛选</button>
    </div>${alertMarkup()}<p class="muted small" data-count role="status"></p><div data-content><p class="muted">正在加载任务…</p></div>`;
  const filters: TaskFilters = { query: "", status: "all", projectId, due: "all", sort: "due" };
  let tasks: Task[] = [];
  let projects: Project[] = [];
  const content = root.querySelector<HTMLElement>("[data-content]")!;
  const draw = () => {
    const visible = filterTasks(tasks, projects, filters);
    root.querySelector("[data-count]")!.textContent = `显示 ${visible.length} / ${tasks.length} 项任务 · 共 ${tasks.filter((task) => !task.completed).length} 项未完成`;
    content.innerHTML = taskRows(visible, projects);
    content.querySelectorAll<HTMLButtonElement>("[data-edit-task]").forEach((button) => button.addEventListener("click", () => {
      const task = visible.find((item) => item.id === button.dataset.editTask);
      if (task) void openTaskEditor(root, task, projects, reload).catch((error) => showError(root, error));
    }));
    content.querySelectorAll<HTMLInputElement>("[data-complete]").forEach((input) => input.addEventListener("change", () => {
      const task = visible.find((item) => item.id === input.dataset.complete);
      if (!task) return;
      input.disabled = true;
      void (async () => {
        try {
          await request<Task>(`/tasks/${encodeURIComponent(task.id)}`, "PATCH", { completed: input.checked, baseVersion: task.version });
          await reload();
        } catch (error) {
          input.checked = task.completed;
          showError(root, error);
        } finally { input.disabled = false; }
      })();
    }));
    content.querySelectorAll<HTMLButtonElement>("[data-delete-task]").forEach((button) => button.addEventListener("click", () => {
      const task = visible.find((item) => item.id === button.dataset.deleteTask);
      if (!task || !window.confirm(`确定删除任务“${task.title}”吗？`)) return;
      button.disabled = true;
      void (async () => {
        try {
          await request<void>(`/tasks/${encodeURIComponent(task.id)}`, "DELETE", { baseVersion: task.version });
          await reload();
          notify("任务已删除。");
        } catch (error) { showError(root, error); }
        finally { button.disabled = false; }
      })();
    }));
  };
  const reload = async () => {
    const refresh = root.querySelector<HTMLButtonElement>("[data-refresh]")!;
    refresh.disabled = true;
    root.querySelector('[role="alert"]')!.textContent = "";
    try {
      [tasks, projects] = await Promise.all([list<Task>("/tasks"), list<Project>("/projects")]);
      const select = root.querySelector<HTMLSelectElement>('[data-filter="projectId"]')!;
      select.innerHTML = '<option value="">全部项目</option><option value="none">未关联项目</option>' + projects.map((project) => `<option value="${escape(project.id)}">${escape(project.name)}</option>`).join("");
      if (filters.projectId && filters.projectId !== "none" && !projects.some((project) => project.id === filters.projectId)) filters.projectId = "";
      select.value = filters.projectId;
      root.querySelector<HTMLButtonElement>("[data-new-task]")!.disabled = false;
      draw();
    } catch (error) {
      if (!tasks.length) content.innerHTML = '<p class="empty">读取任务失败，请点击刷新重试。</p>';
      showError(root, error);
    } finally { refresh.disabled = false; }
  };
  root.querySelector<HTMLInputElement>("[data-query]")!.addEventListener("input", (event) => {
    filters.query = (event.target as HTMLInputElement).value;
    draw();
  });
  root.querySelectorAll<HTMLSelectElement>("[data-filter]").forEach((select) => select.addEventListener("change", () => {
    Object.assign(filters, { [select.dataset.filter!]: select.value });
    draw();
  }));
  root.querySelector("[data-reset]")!.addEventListener("click", () => {
    Object.assign(filters, { query: "", status: "all", projectId: "", due: "all", sort: "due" });
    root.querySelector<HTMLInputElement>("[data-query]")!.value = "";
    root.querySelectorAll<HTMLSelectElement>("[data-filter]").forEach((select) => { select.value = filters[select.dataset.filter as keyof TaskFilters]; });
    draw();
  });
  root.querySelector("[data-refresh]")!.addEventListener("click", () => void reload());
  root.querySelector("[data-new-task]")!.addEventListener("click", () => {
    void openTaskEditor(root, null, projects, reload, filters.projectId === "none" ? "" : filters.projectId).catch((error) => showError(root, error));
  });
  await reload();
}

async function renderProjects(root: HTMLElement, options: WorkspaceOptions = {}): Promise<void> {
  root.innerHTML = `<div class="toolbar"><div><p class="muted">把目标、截止日期和行动项放在一起。</p></div><div class="actions"><button class="secondary" type="button" data-refresh-projects>刷新</button><button class="primary" type="button" data-new-project>新建项目</button></div></div><div data-content><p class="muted">正在加载项目…</p></div>`;
  root
    .querySelector("[data-new-project]")!
    .addEventListener(
      "click",
      () =>
        void openProjectEditor(root, null, options).catch((error) =>
          showError(root, error),
        ),
    );
  root.querySelector("[data-refresh-projects]")!.addEventListener("click", () => void renderProjects(root, options));
  const content = root.querySelector<HTMLElement>("[data-content]")!;
  try {
    const projects = await list<Project>("/projects");
    if (!root.contains(content)) return;
    content.innerHTML = projects.length
      ? `<div class="project-grid">${projects
          .map(
            (
              project,
            ) => `<article class="project-card" data-project="${escape(project.id)}">
      <div class="toolbar"><div><h2>${escape(project.name)}</h2><span class="pill">${escape(({ active: "进行中", completed: "已完成", archived: "已归档" } as Record<string, string>)[project.status] ?? project.status)}</span></div><div class="actions"><button class="secondary" type="button" data-edit-project="${escape(project.id)}">编辑</button><button class="secondary" type="button" data-delete-project="${escape(project.id)}">删除</button></div></div>
      ${project.goal ? `<p>${escape(project.goal)}</p>` : ""}${project.description ? `<p class="muted">${escape(project.description)}</p>` : ""}
      <p class="muted">截止：${escape(project.due ?? "未设置")}</p>
      <div data-progress><p class="muted small">正在读取进度…</p></div>
      <button class="secondary" type="button" data-project-tasks="${escape(project.id)}">查看关联任务</button>
    </article>`,
          )
          .join("")}</div>`
      : '<p class="empty">还没有项目。</p>';
    root.querySelectorAll<HTMLButtonElement>("[data-project-tasks]").forEach((button) => button.addEventListener("click", () => {
      if (options.openProjectTasks) options.openProjectTasks(button.dataset.projectTasks!);
      else void renderTasks(root, button.dataset.projectTasks);
    }));
    const summaries = Promise.all(projects.map(async (project) => {
      const card = Array.from(content.querySelectorAll<HTMLElement>("[data-project]")).find((node) => node.dataset.project === project.id)!;
      const target = card.querySelector<HTMLElement>("[data-progress]")!;
      try {
        const summary = await request<ProjectSummary>(`/projects/${encodeURIComponent(project.id)}/summary`);
        target.innerHTML = `<div class="project-progress"><span>项目进度</span><strong>${Math.round(summary.progress)}%</strong></div><progress max="100" value="${summary.progress}" aria-label="${escape(project.name)}进度"></progress><p class="muted small">任务 ${summary.completedTasks} / ${summary.totalTasks} · 里程碑 ${summary.completedMilestones} / ${summary.totalMilestones}</p>${summary.nextAction ? `<p class="small">下一步：${escape(summary.nextAction.title)}</p>` : '<p class="muted small">暂无待办任务</p>'}`;
      } catch (error) { target.innerHTML = `<p class="error small" role="alert">进度读取失败：${escape(errorText(error))} 可点击刷新重试。</p>`; }
    }));
    root
      .querySelectorAll<HTMLButtonElement>("[data-edit-project]")
      .forEach((button) =>
        button.addEventListener("click", () => {
          const project = projects.find(
            (item) => item.id === button.dataset.editProject,
          );
          if (project)
            void openProjectEditor(root, project, options).catch((error) =>
              showError(root, error),
            );
        }),
      );
    root
      .querySelectorAll<HTMLButtonElement>("[data-delete-project]")
      .forEach((button) =>
        button.addEventListener("click", () => {
          const project = projects.find(
            (item) => item.id === button.dataset.deleteProject,
          );
          if (!project || !window.confirm(`确定删除项目“${project.name}”吗？`))
            return;
          void (async () => {
            try {
              await request<void>(
                `/projects/${encodeURIComponent(project.id)}`,
                "DELETE",
              );
              await renderProjects(root, options);
              notify("项目已删除。");
            } catch (error) {
              showError(root, error);
            }
          })();
        }),
      );
    await summaries;
  } catch (error) {
    if (root.contains(content)) showError(root, error);
  }
}

export async function renderWorkspace(
  root: HTMLElement,
  page: Page,
  options: WorkspaceOptions = {},
): Promise<void> {
  if (page === "tasks") return renderTasks(root, options.projectId);
  if (page === "projects") return renderProjects(root, options);
  return renderChat(root);
}
