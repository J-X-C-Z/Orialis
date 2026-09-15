# Flutter—方寸服务器连接协议

Flutter 客户端使用 `/api/v1` HTTPS REST API，不直接访问数据库，也不依赖网页 Cookie。旧版 `/api` 路径仍保留给现有网页客户端。

## 登录

请求：

```http
POST /api/v1/auth/login
Content-Type: application/json

{"username":"用户名","password":"密码","client":"flutter"}
```

响应中的 `accessToken` 是 30 天会话令牌。后续请求统一携带：

```http
Authorization: Session <accessToken>
```

令牌应只保存在 Flutter 的安全存储中。退出登录调用 `POST /api/auth/logout`，并删除本地令牌。密码修改、账号停用或账号删除会使旧会话失效。

## 启动同步

1. `GET /api/v1/health` 检查服务可达性。
2. `GET /api/v1/auth/session` 检查令牌是否仍有效。
3. `GET /api/v1/data` 读取当前数据；响应包含 `data`、`revision`、`updatedAt`。
4. 本地变更时使用 `PUT /api/v1/data`，提交完整文档和读取到的 `revision`。
<<<<<<< HEAD
5. 需要同步到手环时使用 `GET /api/v1/link/snapshot`，Flutter 将完整信封交给原生 `syncWristband` MethodChannel；这个步骤不经过 WebView，也不让手环访问服务器。

Flutter 的最小调用链是 `FangcunServerClient.getLinkSnapshot()` → `WristbandClient.sync(snapshot.raw)`。
服务端只负责鉴权和生成标准化快照，具体手环 SDK 由 Android 原生 adapter 负责；没有 adapter 时必须返回 `state: unsupported`，不能把服务器拉取成功误报为手环同步成功。
=======
>>>>>>> c64843a8c7ef9e0eac318215525082a9111c2b89

## 同步约定

```json
{
  "baseRevision": 12,
  "data": { "schemaVersion": 3, "tasks": [], "projects": [], "courses": [], "timeSlots": [], "courseExceptions": [], "semester": {}, "settings": {} }
}
```

服务端以版本号检测并发修改。返回 `409` 时，客户端必须重新拉取远程数据，再根据本地未同步变更合并后重试；禁止直接覆盖远程版本。网络离线时，Flutter 可以继续编辑本地副本，联网后按此流程同步。

## Agent 与 Flutter 的边界

Flutter 使用 `Session` 令牌；编码代理使用 `Bearer` Agent 令牌。两者不能互换。Agent API 适合自动化，Flutter API 适合用户登录后的完整应用同步。外部 Google、Outlook 授权仍通过服务器返回的授权 URL 完成，不在客户端保存第三方密钥。

## 错误处理

- `401`：清除本地令牌，回到登录页。
- `409`：执行版本合并流程。
- `413`：缩小同步文档或拆分操作。
- `429`：按响应中的等待时间延迟重试。
- `5xx`：保留本地变更，采用指数退避，不重复提交未知结果的写入。
