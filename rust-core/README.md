# fangcun-core

方寸 Rust 领域核心的第一阶段实现。当前承接服务端管理页使用的文档统计和持久化文档顶层结构校验；未知字段会被保留在网页端，不会因 Rust 核心升级而丢失。

```bash
cargo test --manifest-path rust-core/Cargo.toml
```

后续迁移顺序：同步冲突判定 → SQLite 数据访问 → 密码/会话相关核心 → HTTP API。网页界面暂时继续使用现有实现。
