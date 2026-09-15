"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { DatabaseSync } = require("node:sqlite");

const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "fangcun-password-reset-"));
const databasePath = path.join(temporaryDirectory, "fangcun.sqlite");

try {
  const database = new DatabaseSync(databasePath);
  database.exec(`
    CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE, password_record TEXT NOT NULL, status TEXT NOT NULL);
    CREATE TABLE user_sessions (token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
    INSERT INTO users (username, password_record, status) VALUES ('member', '{}', 'disabled');
    INSERT INTO user_sessions (token_hash, user_id, created_at, expires_at) VALUES ('old-session', 1, 1, 2);
  `);
  database.close();

  const result = spawnSync(process.execPath, [path.join(__dirname, "reset-password.js"), "member", "--activate"], {
    input: "newpass8\n",
    encoding: "utf8",
    env: { ...process.env, FANGCUN_DB_PATH: databasePath },
  });
  assert.equal(result.status, 0, result.stderr);

  const verified = new DatabaseSync(databasePath);
  const user = verified.prepare("SELECT password_record, status FROM users WHERE username = 'member'").get();
  const sessions = verified.prepare("SELECT COUNT(*) AS count FROM user_sessions WHERE user_id = 1").get();
  const record = JSON.parse(user.password_record);
  const actual = crypto.scryptSync("newpass8", Buffer.from(record.salt, "hex"), Buffer.from(record.hash, "hex").length, { N: record.N, r: record.r, p: record.p, maxmem: 64 * 1024 * 1024 });
  assert.equal(crypto.timingSafeEqual(actual, Buffer.from(record.hash, "hex")), true);
  assert.equal(user.status, "active");
  assert.equal(sessions.count, 0);
  verified.close();
  console.log("密码重置检查通过：离线重置、账号启用、scrypt 哈希与旧会话清理均正常。");
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}
