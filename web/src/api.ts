export interface Entity {
  id: string;
  version: number;
}
export interface Schedule extends Entity {
  title: string;
  description: string | null;
  location: string | null;
  startAt: string;
  endAt: string;
  allDay: boolean;
  important: boolean;
  reminderMinutes: number | null;
}
export interface Task extends Entity {
  title: string;
  notes: string | null;
  completed: boolean;
  due: string | null;
  dueTime: string | null;
  important: boolean | null;
  urgent: boolean | null;
  projectId: string | null;
}
export interface Project extends Entity {
  name: string;
  goal: string | null;
  description: string | null;
  status: string;
  due: string | null;
  color: string | null;
  startDate: string | null;
}
export interface ProjectSummary {
  totalTasks: number;
  completedTasks: number;
  totalMilestones: number;
  completedMilestones: number;
  progress: number;
  nextAction: Task | null;
}
export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}
let token = sessionStorage.getItem("orialis.session") || "";
export function setToken(value: string) {
  token = value;
  value
    ? sessionStorage.setItem("orialis.session", value)
    : sessionStorage.removeItem("orialis.session");
}
export function hasSession() {
  return Boolean(token);
}
export async function request<T>(
  path: string,
  method = "GET",
  body?: unknown,
): Promise<T> {
  let response: Response;
  try {
    response = await fetch("/api/v1" + path, {
      method,
      headers: {
        ...(token ? { Authorization: `Session ${token}` } : {}),
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new Error("无法连接服务，请检查网络后重试。");
  }
  if (!response.ok) {
    let detail = "";
    try {
      const value = await response.json();
      detail =
        typeof value.error === "string"
          ? value.error
          : value.error?.message || value.message || "";
    } catch {}
    throw new ApiError(
      response.status,
      response.status === 409
        ? "内容已在其他设备更新。请保留当前输入，关闭编辑器并刷新后重新编辑。"
        : response.status === 401
          ? "登录已失效或账号密码不正确，请重新登录。"
          : detail || `请求失败（${response.status}），请重试。`,
    );
  }
  return response.status === 204 ? (undefined as T) : response.json();
}
export async function list<T>(path: string): Promise<T[]> {
  const items: T[] = [];
  let cursor: string | null = null;
  do {
    const page: { items: T[]; nextCursor: string | null; hasMore: boolean } =
      await request(
        `${path}${path.includes("?") ? "&" : "?"}limit=100${cursor ? "&after=" + encodeURIComponent(cursor) : ""}`,
      );
    items.push(...page.items);
    if (page.hasMore && !page.nextCursor)
      throw new Error("服务端分页响应不完整，请重试。");
    cursor = page.hasMore ? page.nextCursor : null;
  } while (cursor);
  return items;
}
