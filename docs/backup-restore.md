# A02.7 最小备份/恢复方案

`scripts/backup-restore.sh` 提供一个保守的本地/运维辅助脚本，覆盖当前 Orialis 的 SQLite 数据库和上传文件。

## 备份

```sh
scripts/backup-restore.sh backup \
  /var/lib/orialis/orialis.db \
  /var/lib/orialis/uploads \
  /var/backups/orialis/2026-09-17T120000
```

备份目录必须是不存在的路径。脚本使用 SQLite 的 `.backup` 命令生成一致性数据库副本，然后复制 `uploads` 下的全部内容。完成前会执行 SQLite `PRAGMA integrity_check`，并逐项比较上传目录；任何校验失败都会退出且不会发布临时目录。

备份目录包含：

```text
database.sqlite3
uploads/
backup.info
```

## 恢复

```sh
scripts/backup-restore.sh restore \
  /var/backups/orialis/2026-09-17T120000 \
  /var/lib/orialis-restored
```

恢复只接受显式的备份目录和目标目录。目标目录必须不存在；脚本没有默认覆盖行为，也没有隐式的生产路径或环境变量回退。脚本先将数据库和上传文件复制到同级临时目录，执行 SQLite 完整性检查和上传文件比较，验证通过后才原子地将临时目录移动为目标目录。

该脚本不会停止服务、修改生产目录、删除旧数据或执行服务切换。实际恢复前应先停止使用目标目录的服务，并由操作者明确选择新的目标路径；本任务仅实现和验证脚本，不执行恢复。

## 验证

脚本运行时会输出 `Verified:` 行以及最终的 `Backup created:` 或 `Restore prepared:` 结果。静态验证至少包括：

```sh
bash -n scripts/backup-restore.sh
shellcheck scripts/backup-restore.sh
```

如果环境未安装 ShellCheck，使用 `bash -n` 加临时 SQLite/上传目录的备份演练和恢复目标校验作为等价检查；演练只使用临时目录，不连接或写入 production。
