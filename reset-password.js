"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");

const username = String(process.argv[2] || "").trim();
const activate = process.argv.includes("--activate");
const password = fs.readFileSync(0, "utf8").replace(/\r?\n$/, "");

if (!/^[\p{L}\p{N}_-]{3,32}$/u.test(username)) {
  console.error("用户名格式无效。用法：printf '新密码\\n' | node reset-password.js <用户名> [--activate]");
  process.exit(2);
}
if (password.length < 8 || password.length > 128) {
  console.error("新密码长度需要在 8 到 128 个字符之间。");
  process.exit(2);
}

const databasePath = process.env.FANGCUN_DB_PATH
  ? path.resolve(process.env.FANGCUN_DB_PATH)
  : path.join(path.resolve(process.env.DATA_DIR || path.join(__dirname, "data")), "fangcun.sqlite");

if (!fs.existsSync(databasePath)) {
  console.error(`找不到数据库：${databasePath}`);
  process.exit(1);
}

const salt = crypto.randomBytes(16);
const params = { N: 2 ** 14, r: 8, p: 5, maxmem: 64 * 1024 * 1024 };
const hash = crypto.scryptSync(password, salt, 64, params);
const record = JSON.stringify({ algorithm: "scrypt", N: params.N, r: params.r, p: params.p, salt: salt.toString("hex"), hash: hash.toString("hex") });
const database = new DatabaseSync(databasePath);
database.exec("PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;");

try {
  const user = database.prepare("SELECT id, username, status FROM users WHERE username = ? COLLATE NOCASE").get(username);
  if (!user) {
    console.error(`账号不存在：${username}`);
    process.exitCode = 1;
  } else {
    database.exec("BEGIN IMMEDIATE");
    try {
      database.prepare(`UPDATE users SET password_record = ?${activate ? ", status = 'active'" : ""} WHERE id = ?`).run(record, user.id);
      database.prepare("DELETE FROM user_sessions WHERE user_id = ?").run(user.id);
      database.exec("COMMIT");
      console.log(`已重置账号 ${user.username} 的密码并注销所有旧会话${activate ? "，账号已启用" : ""}。`);
    } catch (error) {
      database.exec("ROLLBACK");
      throw error;
    }
  }
} finally {
  database.close();
}
