const assert = require("node:assert/strict");
const { DatabaseSync } = require("node:sqlite");
const { GoogleIntegration, googlePayload, markerFromGoogleEvent, googleToTask, reminderFromGoogleEvent } = require("./google-sync");

const local = {
  localKey: "task:ddl-google", title: "DDL · 提交报告", description: "检查引用", location: "线上",
  date: "2026-09-18", time: "20:00", endDate: "2026-09-18", endTime: "20:15",
  allDay: false, reminderMinutes: 1440, updatedAt: Date.now(),
};
const payload = googlePayload(local);
assert.equal(payload.start.timeZone, "Asia/Shanghai");
assert.equal(payload.start.dateTime, "2026-09-18T20:00:00+08:00");
assert.equal(payload.reminders.overrides[0].minutes, 1440);
assert.equal(payload.extendedProperties.private.fangcunLocalKey, "task:ddl-google");
assert.equal(markerFromGoogleEvent(payload), "task:ddl-google");

const imported = googleToTask({
  id: "remote-1", summary: "Google 会议", description: "讨论进度", location: "会议室",
  start: { dateTime: "2026-09-02T14:00:00+08:00" }, end: { dateTime: "2026-09-02T15:30:00+08:00" },
  reminders: { useDefault: false, overrides: [{ method: "popup", minutes: 30 }] },
  created: "2026-08-31T09:00:00Z", updated: "2026-08-31T10:00:00Z",
}, "imported-google");
assert.equal(imported.startDate, "2026-09-02");
assert.equal(imported.endTime, "15:30");
assert.equal(imported.reminderMinutes, 30);
assert.equal(reminderFromGoogleEvent({ reminders: { useDefault: false, overrides: [] } }), -1);

const database = new DatabaseSync(":memory:");
database.exec("CREATE TABLE users (id INTEGER PRIMARY KEY)");
database.prepare("INSERT INTO users (id) VALUES (?)").run(1);
const integration = new GoogleIntegration(database, {
  GOOGLE_CLIENT_ID: "google-client-id", GOOGLE_CLIENT_SECRET: "google-client-secret",
  GOOGLE_REDIRECT_URI: "https://schedule.example/api/integrations/google/callback",
  FANGCUN_INTEGRATION_KEY: "test-integration-key-not-for-production",
});
const authorization = integration.begin(1, "android");
assert.match(authorization.authUrl, /^https:\/\/accounts\.google\.com\/o\/oauth2\/v2\/auth\?/);
assert.match(authorization.authUrl, /access_type=offline/);
assert.match(authorization.authUrl, /calendar/);
assert.equal(integration.status(1).configured, true);
const encrypted = integration.encrypt("refresh-token");
assert.notEqual(encrypted, "refresh-token");
assert.equal(integration.decrypt(encrypted), "refresh-token");

database.prepare("UPDATE google_connections SET access_token=?, refresh_token=?, expires_at=?, calendar_id=?, account_label=? WHERE user_id=?")
  .run(integration.encrypt("access"), integration.encrypt("refresh"), Date.now() + 3600000, "fangcun-calendar", "student@example.com", 1);
const sourceDocument = {
  tasks: [{ id: "sync-task", title: "提交报告", due: "2026-09-18", dueTime: "20:00", notes: "初稿", location: "线上", reminderMinutes: 60, completed: false, updatedAt: 10 }],
  projects: [], courses: [], timeSlots: [], courseExceptions: [], calendarRules: [], semester: {}, settings: {},
};
let remoteEvent;
let mode = "initial";
integration.request = async (_connection, method, pathname, body) => {
  if (method === "GET" && pathname.includes("/events?")) {
    if (mode === "initial") return { items: [], nextSyncToken: "sync-1" };
    if (mode === "changed") return { items: [{ ...remoteEvent, summary: "DDL · 修改后的报告", etag: "etag-2", updated: "2099-09-01T00:00:00Z" }], nextSyncToken: "sync-2" };
    return { items: [{ id: remoteEvent.id, status: "cancelled", etag: "etag-3", updated: "2099-09-02T00:00:00Z" }], nextSyncToken: "sync-3" };
  }
  if (method === "POST" && pathname.includes("/events")) {
    remoteEvent = { ...body, id: "google-event-1", status: "confirmed", etag: "etag-1", created: "2026-09-01T00:00:00Z", updated: "2026-09-01T00:00:00Z" };
    return remoteEvent;
  }
  throw new Error(`Unexpected mock request: ${method} ${pathname}`);
};

(async () => {
  const pushed = await integration.sync(1, sourceDocument);
  assert.equal(pushed.stats.pushed, 1);
  assert.equal(integration.getConnection.get(1).sync_token, "sync-1");
  mode = "changed";
  const pulled = await integration.sync(1, pushed.document);
  assert.equal(pulled.document.tasks[0].title, "修改后的报告");
  assert.equal(pulled.stats.pulled, 1);
  mode = "deleted";
  const deleted = await integration.sync(1, pulled.document);
  assert.equal(deleted.document.tasks.length, 0);
  assert.equal(deleted.stats.deleted, 1);
  database.close();
  console.log("Google 双向同步检查通过：事件映射、提醒、稳定标记、增量增改删、OAuth 状态和令牌加密均正常。");
})().catch((error) => {
  database.close();
  console.error(error);
  process.exit(1);
});
