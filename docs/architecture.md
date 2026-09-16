# Orialis V1 架构

Orialis V1 是 Flutter 手机端、Rust 服务端和两端之间的 local-first 同步系统。

```text
Flutter UI → Riverpod / ViewModel → EventRepository → Drift / SQLite
                                      ↕
                                  SyncEngine ↔ HTTP
                                      ↕
                              Rust Axum → SQLx → SQLite
```

手机可以在没有服务器时启动、读取和修改本地数据。服务端是跨设备的权威状态，WebSocket 只负责 heartbeat 和变化提示，不作为唯一数据源。

`Task` 表示有截止日期的行动事项，`CalendarEvent` 表示具有明确起止时间的日程。Today 是二者的聚合读取视图，不拥有独立数据库。
