#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 sudo bash deploy/backup.sh 运行。" >&2
  exit 1
fi

BACKUP_DIR=/var/backups/fangcun
STAMP=$(date +%Y%m%d-%H%M%S)
install -d -m 0700 "$BACKUP_DIR"
systemctl stop fangcun.service
trap 'systemctl start fangcun.service' EXIT
cp --preserve=mode,timestamps /var/lib/fangcun/fangcun.sqlite "$BACKUP_DIR/fangcun-$STAMP.sqlite"
find "$BACKUP_DIR" -type f -name 'fangcun-*.sqlite' -mtime +30 -delete
echo "备份已保存：$BACKUP_DIR/fangcun-$STAMP.sqlite"

