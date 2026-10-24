import "./style.css";
import {
  request,
  list,
  setToken,
  hasSession,
  type Schedule,
  type Task,
} from "./api";
import { escape as e, dialog, notify, errorText, submitting } from "./ui";
import {
  addDays,
  dateKey,
  weekDays,
  monthDays,
  toLocalInput,
  expandOccurrences,
  overlaps,
  occursOn,
} from "./calendar";
import { renderWorkspace } from "./workspace";

const app = document.querySelector<HTMLElement>("#app")!;
let schedules: Schedule[] = [];
let anchor = new Date();
let view: "week" | "month" | "agenda" = "week";
let page = "calendar";
let taskProjectId = "";
let query = "";
let renderVersion = 0;
const fmt = new Intl.DateTimeFormat("zh-CN", { month: "long", day: "numeric" });
const time = new Intl.DateTimeFormat("zh-CN", {
  hour: "2-digit",
  minute: "2-digit",
  hour12: false,
});
const weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
function eventTime(event: Schedule) {
  return event.allDay
    ? "全天"
    : time.format(new Date(event.startAt)) +
        " – " +
        time.format(new Date(event.endAt));
}
function auth() {
  app.innerHTML = `<main class="login"><section class="login-intro"><div class="brand-mark">O</div><h1>Orialis</h1><p class="lead">给每一天，留出从容。</p><p>在任务、项目与日程之间，找到自己的节奏。</p><div class="login-preview"><span>计划清晰，行动专注</span><i></i><i></i><i></i></div></section><form class="login-form"><h2>欢迎回来</h2><p class="muted">登录现有账号，继续你的安排。</p><label>用户名<input name="username" autocomplete="username" required minlength="3" maxlength="32"></label><label>密码<input name="password" type="password" autocomplete="current-password" required minlength="8" maxlength="128"></label><p role="alert" class="error"></p><button class="primary" type="submit">登录</button><button class="secondary" type="button" id="register">创建账号</button><p class="muted small">登录状态仅保存在当前浏览器会话中。</p></form></main>`;
  const form = app.querySelector<HTMLFormElement>("form")!;
  async function login(register = false) {
    if (!form.reportValidity()) return;
    await submitting(form, async () => {
      const values = Object.fromEntries(new FormData(form));
      const session = await request<{ accessToken: string }>(
        "/auth/" + (register ? "register" : "login"),
        "POST",
        values,
      );
      setToken(session.accessToken);
      await shell();
    });
  }
  form.onsubmit = (event) => {
    event.preventDefault();
    void login();
  };
  app.querySelector<HTMLButtonElement>("#register")!.onclick = () =>
    void login(true);
}
async function shell() {
  app.innerHTML = `<div class="app-shell"><aside class="sidebar"><a class="brand" href="#calendar"><span class="brand-mark">O</span>Orialis</a><p class="sidebar-caption">你的生活，有条不紊</p><nav aria-label="主导航">${[
    ["today", "◉", "今天"],
    ["calendar", "▦", "日程"],
    ["tasks", "✓", "任务"],
    ["projects", "▱", "项目"],
    ["chat", "◌", "聊天"],
  ]
    .map(
      ([id, icon, label]) =>
        `<button data-page="${id}"><span aria-hidden="true">${icon}</span>${label}</button>`,
    )
    .join(
      "",
    )}</nav><div class="sidebar-bottom"><div class="timezone">本地时区<br><strong>${e(Intl.DateTimeFormat().resolvedOptions().timeZone)}</strong></div><button id="logout">退出登录</button></div></aside><main class="main"><header class="topbar"><div><p class="eyebrow">让时间回到自己手里</p><h1 id="page-title">日程</h1></div><span class="today-label">${e(new Intl.DateTimeFormat("zh-CN", { month: "long", day: "numeric", weekday: "long" }).format(new Date()))}</span></header><section id="content" aria-live="polite"></section></main></div>`;
  app.querySelectorAll<HTMLButtonElement>("[data-page]").forEach(
    (button) =>
      (button.onclick = () => {
        page = button.dataset.page!;
        taskProjectId = "";
        query = "";
        void render();
      }),
  );
  app.querySelector<HTMLButtonElement>("#logout")!.onclick = async () => {
    try {
      await request("/auth/logout", "POST");
      setToken("");
      schedules = [];
      renderVersion++;
      auth();
      notify("已退出登录");
    } catch (error) {
      notify(errorText(error));
    }
  };
  await render();
}
async function render() {
  const version = ++renderVersion;
  const root = app.querySelector<HTMLElement>("#content");
  if (!root) return;
  app
    .querySelectorAll("[data-page]")
    .forEach((el) =>
      el.classList.toggle("active", (el as HTMLElement).dataset.page === page),
    );
  app.querySelector("#page-title")!.textContent = (
    {
      calendar: "日程",
      today: "今天",
      tasks: "任务",
      projects: "项目",
      chat: "聊天",
    } as Record<string, string>
  )[page];
  root.innerHTML = '<p class="empty">正在读取你的安排…</p>';
  try {
    if (page === "calendar" || page === "today") {
      const items = await list<Schedule>("/schedules");
      if (version !== renderVersion) return;
      schedules = items;
      if (page === "today") {
        await today(root);
        return;
      }
      calendar(root);
    } else {
      const isolated = document.createElement("div");
      root.replaceChildren(isolated);
      await renderWorkspace(isolated, page as "tasks" | "projects" | "chat", {
        projectId: taskProjectId,
        openProjectTasks: (projectId) => {
          taskProjectId = projectId;
          page = "tasks";
          void render();
        },
      });
    }
  } catch (error) {
    if (version !== renderVersion) return;
    root.innerHTML = `<div class="empty"><p role="alert">${e(errorText(error))}</p><button id="retry">重试</button><button id="relogin">重新登录</button></div>`;
    root.querySelector<HTMLButtonElement>("#retry")!.onclick = () =>
      void render();
    root.querySelector<HTMLButtonElement>("#relogin")!.onclick = () => {
      setToken("");
      auth();
    };
  }
}
async function today(root: HTMLElement) {
  const tasks = await list<Task>("/tasks");
  if (page !== "today") return;
  const events = schedules
    .filter((item) => occursOn(item, new Date()))
    .sort((a, b) => Date.parse(a.startAt) - Date.parse(b.startAt));
  const due = tasks.filter(
    (t) => !t.completed && t.due && t.due <= dateKey(new Date()),
  );
  root.innerHTML = `<div class="day-intro"><h2>把注意力留给当下。</h2><p class="muted">今天有 ${events.length} 项日程，${due.length} 项待处理任务。</p></div><div class="today-columns"><section><h2>今天的日程</h2>${events.map(card).join("") || '<p class="empty">今天还没有安排，留一些时间给自己。</p>'}</section><section><h2>需要关注</h2>${due.map((t) => `<div class="list-row"><div><strong>${e(t.title)}</strong><p class="muted">${e(t.due)} ${e(t.dueTime)}</p></div><button data-complete="${e(t.id)}">完成</button></div>`).join("") || '<p class="empty">没有到期任务。</p>'}</section></div>`;
  bindEvents(root);
  root.querySelectorAll<HTMLButtonElement>("[data-complete]").forEach(
    (button) =>
      (button.onclick = async () => {
        button.disabled = true;
        try {
          const task = tasks.find((t) => t.id === button.dataset.complete)!;
          await request("/tasks/" + encodeURIComponent(task.id), "PATCH", {
            completed: true,
            baseVersion: task.version,
          });
          await render();
        } catch (error) {
          button.disabled = false;
          notify(errorText(error));
        }
      }),
  );
}
function card(item: Schedule) {
  return `<button class="event-card ${item.important ? "important" : ""}" data-event="${e(item.id)}"><span class="event-time">${e(eventTime(item))}</span><strong>${e(item.title)}</strong>${item.location ? `<span class="event-location">${e(item.location)}</span>` : ""}${dateKey(new Date(item.startAt)) !== dateKey(new Date(Date.parse(item.endAt) - 1)) ? '<span class="small">跨天日程</span>' : ""}</button>`;
}
function bindEvents(root: HTMLElement) {
  root
    .querySelectorAll<HTMLButtonElement>("[data-event]")
    .forEach(
      (button) =>
        (button.onclick = () =>
          editor(schedules.find((s) => s.id === button.dataset.event)!)),
    );
}
function calendar(root: HTMLElement) {
  const days = view === "month" ? monthDays(anchor) : weekDays(anchor);
  const filtered = schedules.filter((s) =>
    (s.title + " " + (s.description || "") + " " + (s.location || ""))
      .toLowerCase()
      .includes(query.toLowerCase()),
  );
  const todayKey = dateKey(new Date());
  root.innerHTML = `<div class="calendar-toolbar"><div class="date-navigation"><h2>${anchor.getFullYear()} 年 ${anchor.getMonth() + 1} 月</h2><button class="icon" id="previous" aria-label="上一${view === "month" ? "月" : "周"}">‹</button><button class="icon" id="next" aria-label="下一${view === "month" ? "月" : "周"}">›</button><button id="today">今天</button></div><div class="toolbar-controls"><div class="segmented" aria-label="日历视图">${[
    ["week", "周"],
    ["month", "月"],
    ["agenda", "列表"],
  ]
    .map(
      ([v, title]) =>
        `<button data-view="${v}" aria-pressed="${view === v}">${title}</button>`,
    )
    .join(
      "",
    )}</div><button class="primary" id="create">＋ 新建日程</button></div></div><div class="calendar-subbar"><span class="muted">${fmt.format(days[0])} — ${fmt.format(days.at(-1)!)}</span><label class="search-label"><span>搜索日程</span><input id="search" type="search" placeholder="标题、地点或备注" value="${e(query)}"></label><button id="refresh">刷新</button></div>${
    view === "agenda"
      ? `<div class="agenda">${days
          .map(
            (day) =>
              `<section class="agenda-day"><h3>${fmt.format(day)} <span class="muted">${weekdays[day.getDay()]}</span></h3><div>${
                filtered
                  .filter((s) => occursOn(s, day))
                  .sort((a, b) => Date.parse(a.startAt) - Date.parse(b.startAt))
                  .map(card)
                  .join("") || '<p class="muted">暂无日程</p>'
              }</div></section>`,
          )
          .join("")}</div>`
      : `<div class="calendar-scroll"><div class="calendar-grid ${view}">${days
          .map(
            (day) =>
              `<section class="calendar-day ${dateKey(day) === todayKey ? "is-today" : ""} ${view === "month" && day.getMonth() !== anchor.getMonth() ? "outside" : ""}"><header><span>${weekdays[day.getDay()]}</span><button class="day-number" data-date="${dateKey(day)}" aria-label="在 ${dateKey(day)} 新建日程">${day.getDate()}</button></header><div class="day-events">${filtered
                .filter((s) => occursOn(s, day))
                .sort(
                  (a, b) =>
                    Number(b.allDay) - Number(a.allDay) ||
                    Date.parse(a.startAt) - Date.parse(b.startAt),
                )
                .map(card)
                .join(
                  "",
                )}</div><button class="add-in-day" data-date="${dateKey(day)}" aria-label="在 ${dateKey(day)} 添加日程">＋</button></section>`,
          )
          .join("")}</div></div>`
  }<footer class="calendar-footer"><span><i class="legend-dot"></i> 日常安排 <i class="legend-dot important"></i> 重要日程</span><span>重复安排会保存为独立日程，时间按本地时区显示。</span></footer>`;
  root.querySelector<HTMLButtonElement>("#create")!.onclick = () => editor();
  root.querySelector<HTMLButtonElement>("#today")!.onclick = () => {
    anchor = new Date();
    calendar(root);
  };
  root.querySelector<HTMLButtonElement>("#refresh")!.onclick = () =>
    void render();
  for (const [id, step] of [
    ["previous", -1],
    ["next", 1],
  ] as const)
    root.querySelector<HTMLButtonElement>("#" + id)!.onclick = () => {
      anchor =
        view === "month"
          ? new Date(anchor.getFullYear(), anchor.getMonth() + step, 1)
          : addDays(anchor, step * 7);
      calendar(root);
    };
  root.querySelectorAll<HTMLButtonElement>("[data-view]").forEach(
    (button) =>
      (button.onclick = () => {
        view = button.dataset.view as typeof view;
        calendar(root);
      }),
  );
  root
    .querySelectorAll<HTMLButtonElement>("[data-date]")
    .forEach(
      (button) =>
        (button.onclick = () => editor(undefined, button.dataset.date)),
    );
  root.querySelector<HTMLInputElement>("#search")!.oninput = (event) => {
    const input = event.target as HTMLInputElement;
    const caret = input.selectionStart;
    query = input.value;
    calendar(root);
    const next = root.querySelector<HTMLInputElement>("#search")!;
    next.focus();
    if (caret !== null) next.setSelectionRange(caret, caret);
  };
  bindEvents(root);
}
function editor(existing?: Schedule, day?: string, copy = false) {
  const editing = Boolean(existing && !copy);
  const start = existing
    ? toLocalInput(existing.startAt)
    : (day || dateKey(new Date())) + "T09:00";
  const end = existing
    ? toLocalInput(existing.endAt)
    : (day || dateKey(new Date())) + "T10:00";
  const modal = dialog(
    editing ? "编辑日程" : copy ? "复制日程" : "新建日程",
    `<form class="event-form"><div class="form-grid"><label class="wide">标题<input name="title" maxlength="500" required autofocus placeholder="给这段时间一个名字" value="${e(existing?.title ? (copy ? existing.title + "（副本）" : existing.title) : "")}"></label><label class="check"><input name="allDay" type="checkbox" ${existing?.allDay ? "checked" : ""}>全天</label><label class="check"><input name="important" type="checkbox" ${existing?.important ? "checked" : ""}>重要日程</label><label>开始<input name="start" type="datetime-local" required value="${start}"></label><label>结束<input name="end" type="datetime-local" required value="${end}"></label><p class="wide muted small" id="range-help">时间按 ${e(Intl.DateTimeFormat().resolvedOptions().timeZone)} 保存。支持跨天。</p><label>地点<input name="location" value="${e(existing?.location)}" placeholder="添加地点或会议链接"></label><label>提前提醒<select name="reminder"><option value="">不提醒</option>${[0, 5, 10, 15, 30, 60, 1440].map((n) => `<option value="${n}" ${existing?.reminderMinutes === n ? "selected" : ""}>${n === 0 ? "开始时" : n === 1440 ? "1 天前" : n + " 分钟前"}</option>`).join("")}${existing?.reminderMinutes != null && ![0, 5, 10, 15, 30, 60, 1440].includes(existing.reminderMinutes) ? `<option selected value="${existing.reminderMinutes}">${existing.reminderMinutes} 分钟前</option>` : ""}</select></label><label class="wide">备注<textarea name="description" rows="3" placeholder="准备事项、议程或其他补充">${e(existing?.description)}</textarea></label></div>${editing ? "" : `<fieldset class="repeat"><legend>重复安排</legend><div class="form-grid"><label>重复频率<select name="frequency"><option value="none">不重复</option><option value="daily">每天</option><option value="weekly">每周</option><option value="monthly">每月</option></select></label><label>间隔<input name="interval" type="number" min="1" max="100" value="1" required></label><div class="wide weekday-picker" aria-label="重复星期">${[1, 2, 3, 4, 5, 6, 0].map((n) => `<label><input name="weekdays" type="checkbox" value="${n}" ${n === new Date(start).getDay() ? "checked" : ""}><span>${weekdays[n].slice(1)}</span></label>`).join("")}</div><label>最多生成<input name="count" type="number" min="1" max="100" value="8" required></label><label>截止日期（可选）<input name="until" type="date"></label></div><p class="muted small">每次生成最多 100 条独立日程，保存后可分别修改。每月不存在的日期会跳过。</p></fieldset>`}<section class="preview-section"><h3>安排预览</h3><div id="preview"></div></section><p class="muted small">提醒设置会同步到现有客户端；此 Web 端暂不发送后台通知。</p><p role="alert" class="error"></p><div class="actions">${editing ? '<button type="button" id="delete-event" class="danger">删除日程</button><button type="button" id="duplicate-event">复制</button>' : ""}<button type="submit" class="primary">${editing ? "保存修改" : "保存日程"}</button></div></form>`,
  );
  const form = modal.querySelector<HTMLFormElement>("form")!;
  const startInput = form.elements.namedItem("start") as HTMLInputElement;
  const endInput = form.elements.namedItem("end") as HTMLInputElement;
  const allDay = form.elements.namedItem("allDay") as HTMLInputElement;
  let timedStart = start,
    timedEnd = end;
  function toggleAllDay(initial = false) {
    const currentStart = startInput.value,
      currentEnd = endInput.value;
    if (allDay.checked) {
      timedStart = currentStart;
      timedEnd = currentEnd;
      startInput.value = "";
      endInput.value = "";
      startInput.type = "date";
      endInput.type = "date";
      startInput.value = currentStart.slice(0, 10);
      endInput.value =
        existing?.allDay && initial
          ? dateKey(addDays(new Date(existing.endAt), -1))
          : currentEnd.slice(0, 10);
    } else {
      startInput.value = "";
      endInput.value = "";
      startInput.type = "datetime-local";
      endInput.type = "datetime-local";
      startInput.value = currentStart + "T" + (timedStart.slice(11) || "09:00");
      endInput.value = currentEnd + "T" + (timedEnd.slice(11) || "10:00");
      if (endInput.value <= startInput.value)
        endInput.value = toLocalInput(
          new Date(Date.parse(startInput.value) + 3600000).toISOString(),
        );
    }
    form.querySelector("#range-help")!.textContent = allDay.checked
      ? "结束日期包含在日程内，保存时使用次日零点作为结束。"
      : "时间按本地时区保存。支持跨天。";
  }
  if (allDay.checked) toggleAllDay(true);
  allDay.onchange = () => {
    toggleAllDay();
    preview();
  };
  function occurrences() {
    const data = new FormData(form);
    let s = startInput.value,
      t = endInput.value;
    if (allDay.checked) {
      s += "T00:00";
      t = dateKey(addDays(new Date(t + "T00:00"), 1)) + "T00:00";
    }
    return expandOccurrences(s, t, {
      frequency: (data.get("frequency") || "none") as
        "none" | "daily" | "weekly" | "monthly",
      interval: Number(data.get("interval") || 1),
      weekdays: data.getAll("weekdays").map(Number),
      until: String(data.get("until") || ""),
      count: Number(data.get("count") || 1),
    });
  }
  function preview() {
    try {
      const items = occurrences();
      const conflicts = items.flatMap((item) =>
        schedules
          .filter(
            (s) => (!editing || s.id !== existing?.id) && overlaps(item, s),
          )
          .map((s) => s.title),
      );
      const unique = [...new Set(conflicts)];
      const internal = items.some((item, index) =>
        items.slice(index + 1).some((other) => overlaps(item, other)),
      );
      form.querySelector("#preview")!.innerHTML =
        `<p>${items.length} 条日程${unique.length ? ` · <span class="conflict">与 ${unique.length} 项已有日程重叠</span>` : ""}</p>${internal ? '<p class="conflict">本批次的重复日程之间也有时间重叠，请核对跨天时长。</p>' : ""}${unique.length ? `<p class="conflict">${unique.map(e).join("、")}。你仍可以保存。</p>` : ""}<ol class="preview-list">${items
          .slice(0, 5)
          .map(
            (item) =>
              `<li>${e(fmt.format(new Date(item.startAt)))} ${allDay.checked ? "全天" : e(time.format(new Date(item.startAt)))} → ${e(fmt.format(new Date(allDay.checked ? Date.parse(item.endAt) - 1 : item.endAt)))} ${allDay.checked ? "" : e(time.format(new Date(item.endAt)))}</li>`,
          )
          .join(
            "",
          )}</ol>${items.length > 5 ? `<p class="muted small">另有 ${items.length - 5} 条</p>` : ""}`;
    } catch (error) {
      form.querySelector("#preview")!.textContent = errorText(error);
    }
  }
  form.addEventListener("input", preview);
  preview();
  let plan: Array<Record<string, unknown>> | null = null;
  let completed = 0;
  form.onsubmit = (event) => {
    event.preventDefault();
    void submitting(form, async () => {
      form.querySelector('[role="alert"]')!.textContent = "";
      if (!plan) {
        const data = new FormData(form);
        const title = String(data.get("title") || "").trim();
        if (!title) throw new Error("请输入日程标题。");
        const items = occurrences();
        if (!items.length)
          throw new Error("重复条件没有生成日程，请调整日期。");
        plan = items.map((item) => ({
          ...item,
          ...(editing ? {} : { id: crypto.randomUUID() }),
          title,
          description: String(data.get("description") || "") || null,
          location: String(data.get("location") || "") || null,
          allDay: allDay.checked,
          important: data.has("important"),
          reminderMinutes:
            data.get("reminder") === "" ? null : Number(data.get("reminder")),
        }));
      }
      try {
        if (editing && existing) {
          await request(
            "/schedules/" + encodeURIComponent(existing.id),
            "PATCH",
            { ...plan[0], baseVersion: existing.version },
          );
        } else {
          form
            .querySelectorAll<
              HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement
            >("input,select,textarea")
            .forEach((input) => (input.disabled = true));
          while (completed < plan.length) {
            const item = plan[completed];
            if (completed > 0 || form.dataset.retry) {
              const current = await list<Schedule>("/schedules");
              if (current.some((s) => s.id === item.id)) {
                completed++;
                continue;
              }
            }
            await request("/schedules", "POST", item);
            completed++;
          }
        }
        modal.close();
        notify(editing ? "日程已更新" : `已保存 ${completed} 条日程`);
        await render();
      } catch (error) {
        if (editing) {
          plan = null;
          throw error;
        }
        form.dataset.retry = "true";
        throw new Error(
          `已确认保存 ${completed}/${plan.length} 条。${errorText(error)} 点击保存可继续剩余日程；关闭编辑器会保留已保存的条目。`,
        );
      }
    });
  };
  modal
    .querySelector<HTMLButtonElement>("#delete-event")
    ?.addEventListener("click", async () => {
      if (!confirm("删除“" + existing!.title + "”？此操作会同步到其他设备。"))
        return;
      try {
        await request(
          "/schedules/" + encodeURIComponent(existing!.id),
          "DELETE",
        );
        modal.close();
        notify("日程已删除");
        await render();
      } catch (error) {
        form.querySelector('[role="alert"]')!.textContent = errorText(error);
      }
    });
  modal
    .querySelector<HTMLButtonElement>("#duplicate-event")
    ?.addEventListener("click", () => {
      modal.close();
      editor(existing, undefined, true);
    });
}
if (hasSession()) {
  request("/auth/session")
    .then(shell)
    .catch((error) => {
      if (
        "status" in Object(error) &&
        (error as { status: number }).status === 401
      )
        setToken("");
      auth();
      notify(errorText(error));
    });
} else auth();
