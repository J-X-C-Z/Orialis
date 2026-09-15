const crypto = require("node:crypto");
const { localEvents } = require("./outlook-sync");

const GOOGLE_API = "https://www.googleapis.com/calendar/v3";
const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";
const GOOGLE_USERINFO = "https://openidconnect.googleapis.com/v1/userinfo";
const SCOPES = "openid email profile https://www.googleapis.com/auth/calendar.app.created https://www.googleapis.com/auth/calendar.calendarlist.readonly";
const TIME_ZONE = "Asia/Shanghai";

function hash(value) {
  return crypto.createHash("sha256").update(typeof value === "string" ? value : JSON.stringify(value)).digest("hex");
}

function isoDate(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function dateFromIso(value) {
  const [year, month, day] = String(value || "").split("-").map(Number);
  return new Date(year, month - 1, day, 12);
}

function weekday(value) { return dateFromIso(value).getDay() || 7; }

function localEventHash(event) {
  return hash({ title: event.title, description: event.description, location: event.location, date: event.date, time: event.time, endDate: event.endDate, endTime: event.endTime, allDay: event.allDay, reminderMinutes: event.reminderMinutes });
}

function googleDateTime(date, time) { return `${date}T${time || "00:00"}:00+08:00`; }

function googlePayload(event) {
  const reminderMinutes = Number(event.reminderMinutes);
  return {
    summary: event.title,
    description: [event.description, "由方寸双向同步"].filter(Boolean).join("\n\n"),
    location: event.location || "",
    start: event.allDay ? { date: event.date } : { dateTime: googleDateTime(event.date, event.time), timeZone: TIME_ZONE },
    end: event.allDay
      ? { date: event.endDate || event.date }
      : { dateTime: googleDateTime(event.endDate || event.date, event.endTime || event.time), timeZone: TIME_ZONE },
    reminders: reminderMinutes >= 0
      ? { useDefault: false, overrides: [{ method: "popup", minutes: Math.max(0, reminderMinutes) }] }
      : { useDefault: false, overrides: [] },
    visibility: "private",
    transparency: "opaque",
    extendedProperties: { private: { fangcunManaged: "1", fangcunLocalKey: event.localKey } },
  };
}

function markerFromGoogleEvent(event) {
  return String(event?.extendedProperties?.private?.fangcunLocalKey || "");
}

function googleTemporal(value = {}) {
  if (value.date) return { date: String(value.date), time: "", allDay: true };
  const match = String(value.dateTime || "").match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/);
  return match ? { date: match[1], time: match[2], allDay: false } : { date: "", time: "", allDay: false };
}

function reminderFromGoogleEvent(event) {
  if (event.reminders?.useDefault) return 30;
  const popup = (event.reminders?.overrides || []).find((item) => item.method === "popup");
  return popup ? Number(popup.minutes || 0) : -1;
}

function googleToTask(event, id = `google-${crypto.randomUUID()}`) {
  const start = googleTemporal(event.start);
  const end = googleTemporal(event.end);
  return {
    id, title: String(event.summary || "Google 日程").replace(/^DDL\s*[·・-]\s*/, ""),
    notes: String(event.description || "").replace(/(?:\n\s*)?由方寸双向同步\s*$/u, "").trim(),
    location: event.location || "", due: "", dueTime: "", startDate: start.date,
    startTime: start.allDay ? "" : start.time, endDate: start.allDay ? "" : end.date,
    endTime: start.allDay ? "" : end.time, reminderMinutes: reminderFromGoogleEvent(event),
    estimateMinutes: 0, type: "event", repeat: "none", courseId: "", projectId: "",
    important: null, urgent: null, quadrant: null, today: start.date === isoDate(new Date()), completed: false,
    source: "google", createdAt: Date.parse(event.created) || Date.now(), updatedAt: Date.parse(event.updated) || Date.now(),
  };
}

class GoogleIntegration {
  constructor(database, env = process.env) {
    this.database = database;
    this.clientId = String(env.GOOGLE_CLIENT_ID || "").trim();
    this.clientSecret = String(env.GOOGLE_CLIENT_SECRET || "").trim();
    this.redirectUri = String(env.GOOGLE_REDIRECT_URI || "").trim();
    this.secret = String(env.FANGCUN_INTEGRATION_KEY || "");
    this.key = this.secret ? crypto.createHash("sha256").update(this.secret).digest() : null;
    this.configured = Boolean(this.clientId && this.clientSecret && this.redirectUri && this.key && this.secret.length >= 32);
    database.exec(`
      CREATE TABLE IF NOT EXISTS google_connections (
        user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        access_token TEXT, refresh_token TEXT, expires_at INTEGER,
        calendar_id TEXT, account_label TEXT,
        oauth_state_hash TEXT UNIQUE, oauth_state_expires INTEGER, oauth_source TEXT,
        sync_token TEXT, last_sync_at TEXT, last_error TEXT
      );
      CREATE TABLE IF NOT EXISTS google_event_links (
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        local_key TEXT NOT NULL, google_event_id TEXT NOT NULL,
        local_hash TEXT, remote_etag TEXT, last_synced_at TEXT NOT NULL,
        PRIMARY KEY(user_id, local_key), UNIQUE(user_id, google_event_id)
      );
    `);
    this.getConnection = database.prepare("SELECT * FROM google_connections WHERE user_id=?");
    this.getConnectionByState = database.prepare("SELECT * FROM google_connections WHERE oauth_state_hash=? AND oauth_state_expires>?");
    this.beginConnection = database.prepare("INSERT INTO google_connections (user_id, oauth_state_hash, oauth_state_expires, oauth_source) VALUES (?, ?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET oauth_state_hash=excluded.oauth_state_hash, oauth_state_expires=excluded.oauth_state_expires, oauth_source=excluded.oauth_source, last_error=NULL");
    this.finishConnection = database.prepare("UPDATE google_connections SET access_token=?, refresh_token=?, expires_at=?, calendar_id=?, account_label=?, oauth_state_hash=NULL, oauth_state_expires=NULL, sync_token=NULL, last_error=NULL WHERE user_id=?");
    this.updateTokens = database.prepare("UPDATE google_connections SET access_token=?, refresh_token=?, expires_at=? WHERE user_id=?");
    this.updateSync = database.prepare("UPDATE google_connections SET sync_token=?, last_sync_at=?, last_error=NULL WHERE user_id=?");
    this.clearSyncToken = database.prepare("UPDATE google_connections SET sync_token=NULL WHERE user_id=?");
    this.updateError = database.prepare("UPDATE google_connections SET last_error=? WHERE user_id=?");
    this.deleteConnection = database.prepare("DELETE FROM google_connections WHERE user_id=?");
    this.listConnected = database.prepare("SELECT user_id AS userId FROM google_connections WHERE refresh_token IS NOT NULL AND calendar_id IS NOT NULL");
    this.getLinks = database.prepare("SELECT * FROM google_event_links WHERE user_id=?");
    this.upsertLink = database.prepare("INSERT INTO google_event_links (user_id, local_key, google_event_id, local_hash, remote_etag, last_synced_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(user_id, local_key) DO UPDATE SET google_event_id=excluded.google_event_id, local_hash=excluded.local_hash, remote_etag=excluded.remote_etag, last_synced_at=excluded.last_synced_at");
    this.deleteLink = database.prepare("DELETE FROM google_event_links WHERE user_id=? AND local_key=?");
    this.deleteLinks = database.prepare("DELETE FROM google_event_links WHERE user_id=?");
  }

  encrypt(value) {
    if (!this.key || !value) return null;
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv("aes-256-gcm", this.key, iv);
    const ciphertext = Buffer.concat([cipher.update(String(value), "utf8"), cipher.final()]);
    return `${iv.toString("base64url")}.${cipher.getAuthTag().toString("base64url")}.${ciphertext.toString("base64url")}`;
  }

  decrypt(value) {
    if (!this.key || !value) return "";
    const [iv, tag, ciphertext] = String(value).split(".").map((part) => Buffer.from(part, "base64url"));
    const decipher = crypto.createDecipheriv("aes-256-gcm", this.key, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
  }

  status(userId) {
    const row = this.getConnection.get(userId);
    return {
      configured: this.configured, connected: Boolean(row?.refresh_token && row?.calendar_id),
      account: row?.account_label || "", calendarName: row?.calendar_id ? "方寸" : "",
      lastSyncAt: row?.last_sync_at || null, lastError: row?.last_error || null,
      intervalMinutes: 5, incremental: Boolean(row?.sync_token),
    };
  }

  begin(userId, source = "web") {
    if (!this.configured) throw Object.assign(new Error("服务端尚未配置 Google OAuth 应用"), { status: 503 });
    const state = crypto.randomBytes(32).toString("base64url");
    this.beginConnection.run(userId, hash(state), Date.now() + 10 * 60 * 1000, source === "android" ? "android" : "web");
    const params = new URLSearchParams({
      client_id: this.clientId, redirect_uri: this.redirectUri, response_type: "code", scope: SCOPES,
      access_type: "offline", include_granted_scopes: "true", prompt: "consent select_account", state,
    });
    return { authUrl: `https://accounts.google.com/o/oauth2/v2/auth?${params}` };
  }

  async callback(code, state) {
    if (!this.configured || !code || !state) throw Object.assign(new Error("Google 授权回调不完整"), { status: 400 });
    const connection = this.getConnectionByState.get(hash(state), Date.now());
    if (!connection) throw Object.assign(new Error("Google 授权已过期，请重新连接"), { status: 400 });
    const token = await this.tokenRequest({ client_id: this.clientId, client_secret: this.clientSecret, code, grant_type: "authorization_code", redirect_uri: this.redirectUri });
    const oldRefresh = this.decrypt(connection.refresh_token);
    if (!token.refresh_token && !oldRefresh) throw Object.assign(new Error("Google 未返回长期授权令牌，请撤销旧授权后重试"), { status: 502 });
    const temporary = {
      ...connection, access_token: this.encrypt(token.access_token), refresh_token: this.encrypt(token.refresh_token || oldRefresh),
      expires_at: Date.now() + Number(token.expires_in || 3600) * 1000,
    };
    const account = await this.request(temporary, "GET", GOOGLE_USERINFO);
    const calendarId = await this.ensureCalendar(temporary);
    this.finishConnection.run(temporary.access_token, temporary.refresh_token, temporary.expires_at, calendarId, account.email || account.name || "Google", connection.user_id);
    return { userId: connection.user_id, source: connection.oauth_source || "web" };
  }

  async tokenRequest(fields) {
    const response = await fetch(GOOGLE_TOKEN, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(fields) });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(body.error_description || body.error || "Google 授权失败"), { status: 502, remoteStatus: response.status });
    return body;
  }

  async accessToken(connection) {
    if (connection.expires_at > Date.now() + 60000 && connection.access_token) return this.decrypt(connection.access_token);
    const token = await this.tokenRequest({ client_id: this.clientId, client_secret: this.clientSecret, refresh_token: this.decrypt(connection.refresh_token), grant_type: "refresh_token" });
    connection.access_token = this.encrypt(token.access_token);
    connection.refresh_token = this.encrypt(token.refresh_token || this.decrypt(connection.refresh_token));
    connection.expires_at = Date.now() + Number(token.expires_in || 3600) * 1000;
    this.updateTokens.run(connection.access_token, connection.refresh_token, connection.expires_at, connection.user_id);
    return token.access_token;
  }

  async request(connection, method, pathname, body = null, options = {}) {
    const token = await this.accessToken(connection);
    const response = await fetch(pathname.startsWith("https://") ? pathname : `${GOOGLE_API}${pathname}`, {
      method, headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "Content-Type": "application/json" },
      body: body == null ? undefined : JSON.stringify(body),
    });
    if (response.status === 204 || (options.allow404 && response.status === 404)) return null;
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error(result.error?.message || `Google Calendar ${response.status}`), { status: 502, remoteStatus: response.status });
    return result;
  }

  async ensureCalendar(connection) {
    if (connection.calendar_id) return connection.calendar_id;
    let pageToken = "";
    do {
      const params = new URLSearchParams({ maxResults: "250" });
      if (pageToken) params.set("pageToken", pageToken);
      const page = await this.request(connection, "GET", `/users/me/calendarList?${params}`);
      const found = (page.items || []).find((calendar) => calendar.summary === "方寸");
      if (found) return found.id;
      pageToken = page.nextPageToken || "";
    } while (pageToken);
    const created = await this.request(connection, "POST", "/calendars", { summary: "方寸", description: "由方寸双向同步管理", timeZone: TIME_ZONE });
    return created.id;
  }

  async listRemoteChanges(connection) {
    const collect = async (syncToken = "") => {
      let pageToken = "";
      let nextSyncToken = "";
      const events = [];
      do {
        const params = new URLSearchParams({ singleEvents: "true", showDeleted: "true", maxResults: "2500", timeZone: TIME_ZONE });
        if (syncToken) params.set("syncToken", syncToken);
        if (pageToken) params.set("pageToken", pageToken);
        const page = await this.request(connection, "GET", `/calendars/${encodeURIComponent(connection.calendar_id)}/events?${params}`);
        events.push(...(page.items || []));
        pageToken = page.nextPageToken || "";
        nextSyncToken = page.nextSyncToken || nextSyncToken;
      } while (pageToken);
      return { events, nextSyncToken, full: !syncToken };
    };
    try { return await collect(connection.sync_token || ""); }
    catch (error) {
      if (error.remoteStatus !== 410 || !connection.sync_token) throw error;
      connection.sync_token = null;
      this.clearSyncToken.run(connection.user_id);
      return collect("");
    }
  }

  link(userId, localEvent, remote) {
    this.upsertLink.run(userId, localEvent.localKey, remote.id, localEventHash(localEvent), remote.etag || "", new Date().toISOString());
  }

  upsertCourseException(document, localKey, remote) {
    const match = localKey.match(/^course:([^:]+):(\d{4}-\d{2}-\d{2})$/);
    if (!match || !(document.courses || []).some((item) => item.id === match[1])) return false;
    const start = googleTemporal(remote.start);
    const end = googleTemporal(remote.end);
    let startSlot = (document.timeSlots || []).find((item) => item.startTime === start.time);
    let endSlot = (document.timeSlots || []).find((item) => item.endTime === end.time);
    if (!startSlot || !endSlot) {
      const number = Math.max(0, ...(document.timeSlots || []).map((item) => Number(item.number) || 0)) + 1;
      const slot = { number, startTime: start.time, endTime: end.time || start.time };
      document.timeSlots.push(slot);
      document.timeSlots.sort((a, b) => a.startTime.localeCompare(b.startTime));
      startSlot = slot; endSlot = slot;
    }
    document.courseExceptions = (document.courseExceptions || []).filter((item) => !(item.courseId === match[1] && item.date === match[2]));
    document.courseExceptions.push({ id: crypto.randomUUID(), courseId: match[1], date: match[2], targetDate: start.date, type: "reschedule", day: weekday(start.date), startSection: startSlot.number, endSection: endSlot.number, name: remote.summary || "课程", location: remote.location || "", source: "google", updatedAt: Date.now() });
    return true;
  }

  applyRemote(document, localKey, remote) {
    if (localKey.startsWith("task:")) {
      const id = localKey.slice(5);
      const index = (document.tasks || []).findIndex((item) => item.id === id);
      if (index < 0) return false;
      const existing = document.tasks[index];
      const next = googleToTask(remote, id);
      next.projectId = existing.projectId || ""; next.courseId = existing.courseId || "";
      next.important = existing.important; next.urgent = existing.urgent; next.quadrant = existing.quadrant;
      next.createdAt = existing.createdAt || next.createdAt;
      if (existing.due && !existing.startDate) {
        next.due = next.startDate; next.dueTime = next.startTime; next.startDate = ""; next.startTime = ""; next.endDate = ""; next.endTime = "";
      }
      document.tasks[index] = next;
      return true;
    }
    return this.upsertCourseException(document, localKey, remote);
  }

  applyRemoteDelete(document, localKey) {
    if (localKey.startsWith("task:")) {
      const before = (document.tasks || []).length;
      document.tasks = (document.tasks || []).filter((item) => item.id !== localKey.slice(5));
      return document.tasks.length !== before;
    }
    const match = localKey.match(/^course:([^:]+):(\d{4}-\d{2}-\d{2})$/);
    if (!match) return false;
    document.courseExceptions = (document.courseExceptions || []).filter((item) => !(item.courseId === match[1] && item.date === match[2]));
    document.courseExceptions.push({ id: crypto.randomUUID(), courseId: match[1], date: match[2], type: "cancel", source: "google", updatedAt: Date.now() });
    return true;
  }

  async sync(userId, sourceDocument) {
    if (!this.configured) throw Object.assign(new Error("服务端尚未配置 Google OAuth 应用"), { status: 503 });
    const connection = this.getConnection.get(userId);
    if (!connection?.refresh_token) throw Object.assign(new Error("请先连接 Google 日历"), { status: 409 });
    const document = JSON.parse(JSON.stringify(sourceDocument || {}));
    document.tasks ||= []; document.courses ||= []; document.courseExceptions ||= []; document.timeSlots ||= [];
    const batch = await this.listRemoteChanges(connection);
    const remoteById = new Map(batch.events.map((item) => [item.id, item]));
    const remoteByKey = new Map(batch.events.map((item) => [markerFromGoogleEvent(item), item]).filter(([key]) => key));
    const links = this.getLinks.all(userId);
    const linkByKey = new Map(links.map((item) => [item.local_key, item]));
    const linkById = new Map(links.map((item) => [item.google_event_id, item]));
    const stats = { pushed: 0, pulled: 0, deleted: 0, imported: 0, conflicts: 0 };
    let changed = false;

    for (const remote of batch.events) {
      const link = linkById.get(remote.id);
      const key = markerFromGoogleEvent(remote) || link?.local_key || "";
      if (remote.status === "cancelled") {
        if (key) {
          changed = this.applyRemoteDelete(document, key) || changed;
          this.deleteLink.run(userId, key); stats.pulled += 1; stats.deleted += 1;
        }
        continue;
      }
      if (key || link) continue;
      const task = googleToTask(remote);
      document.tasks.unshift(task);
      const local = localEvents(document).find((item) => item.localKey === `task:${task.id}`);
      const patched = await this.request(connection, "PATCH", `/calendars/${encodeURIComponent(connection.calendar_id)}/events/${encodeURIComponent(remote.id)}`, googlePayload(local));
      this.link(userId, local, patched);
      remoteByKey.set(local.localKey, patched);
      changed = true; stats.imported += 1;
    }

    let localMap = new Map(localEvents(document).map((item) => [item.localKey, item]));
    for (const [localKey, local] of localMap) {
      const link = linkByKey.get(localKey);
      const remote = (link && remoteById.get(link.google_event_id)) || remoteByKey.get(localKey);
      if (remote?.status === "cancelled") continue;
      if (batch.full && link && !remote) {
        changed = this.applyRemoteDelete(document, localKey) || changed;
        this.deleteLink.run(userId, localKey); stats.pulled += 1; stats.deleted += 1;
        continue;
      }
      if (!remote && !link) {
        const created = await this.request(connection, "POST", `/calendars/${encodeURIComponent(connection.calendar_id)}/events`, googlePayload(local));
        this.link(userId, local, created); stats.pushed += 1;
        continue;
      }
      if (!remote && link) {
        if (link.local_hash !== localEventHash(local)) {
          const patched = await this.request(connection, "PATCH", `/calendars/${encodeURIComponent(connection.calendar_id)}/events/${encodeURIComponent(link.google_event_id)}`, googlePayload(local));
          this.link(userId, local, patched); stats.pushed += 1;
        }
        continue;
      }
      const localChanged = Boolean(link && link.local_hash && link.local_hash !== localEventHash(local));
      const remoteChanged = Boolean(!link || (link.remote_etag && link.remote_etag !== (remote.etag || "")));
      if (localChanged && remoteChanged) stats.conflicts += 1;
      const remoteTime = Date.parse(remote.updated || 0) || 0;
      const localTime = Number(local.updatedAt || Date.parse(document.settings?.lastLocalChangeAt || 0) || 0);
      if (remoteChanged && (!localChanged || remoteTime >= localTime)) {
        changed = this.applyRemote(document, localKey, remote) || changed;
        const refreshed = localEvents(document).find((item) => item.localKey === localKey);
        if (refreshed) this.link(userId, refreshed, remote);
        stats.pulled += 1;
      } else if (localChanged) {
        const patched = await this.request(connection, "PATCH", `/calendars/${encodeURIComponent(connection.calendar_id)}/events/${encodeURIComponent(remote.id)}`, googlePayload(local));
        this.link(userId, local, patched); stats.pushed += 1;
      } else this.link(userId, local, remote);
    }

    localMap = new Map(localEvents(document).map((item) => [item.localKey, item]));
    for (const link of links) {
      if (localMap.has(link.local_key)) continue;
      const changedRemote = remoteById.get(link.google_event_id);
      if (changedRemote?.status !== "cancelled") {
        await this.request(connection, "DELETE", `/calendars/${encodeURIComponent(connection.calendar_id)}/events/${encodeURIComponent(link.google_event_id)}`, null, { allow404: true });
        stats.pushed += 1; stats.deleted += 1;
      }
      this.deleteLink.run(userId, link.local_key);
    }

    const syncedAt = new Date().toISOString();
    document.settings ||= {};
    document.settings.googleLastSyncAt = syncedAt;
    this.updateSync.run(batch.nextSyncToken || connection.sync_token || null, syncedAt, userId);
    return { document, changed: changed || stats.imported > 0 || stats.pulled > 0, stats, syncedAt, incremental: !batch.full };
  }

  disconnect(userId) {
    this.database.exec("BEGIN IMMEDIATE");
    try { this.deleteLinks.run(userId); this.deleteConnection.run(userId); this.database.exec("COMMIT"); }
    catch (error) { this.database.exec("ROLLBACK"); throw error; }
  }

  connectedUserIds() { return this.configured ? this.listConnected.all().map((item) => item.userId) : []; }
  recordError(userId, error) { this.updateError.run(String(error?.message || error).slice(0, 500), userId); }
}

module.exports = { GoogleIntegration, googlePayload, markerFromGoogleEvent, googleToTask, reminderFromGoogleEvent };
