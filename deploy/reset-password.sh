#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请使用 sudo bash /opt/fangcun/deploy/reset-password.sh 用户名 运行。" >&2
  exit 1
fi

USERNAME=${1:-}
if [[ -z "$USERNAME" ]]; then
  echo "用法：sudo bash /opt/fangcun/deploy/reset-password.sh <用户名>" >&2
  exit 2
fi

read -r -s -p "为 ${USERNAME} 输入新密码（至少 8 位）：" NEW_PASSWORD
printf '\n'
read -r -s -p "再次输入新密码：" CONFIRM_PASSWORD
printf '\n'

if [[ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]]; then
  echo "两次输入的密码不一致。" >&2
  exit 2
fi
if (( ${#NEW_PASSWORD} < 8 || ${#NEW_PASSWORD} > 128 )); then
  echo "新密码长度需要在 8 到 128 个字符之间。" >&2
  exit 2
fi

printf '%s\n' "$NEW_PASSWORD" | runuser -u fangcun -- env DATA_DIR=/var/lib/fangcun node /opt/fangcun/reset-password.js "$USERNAME" --activate
unset NEW_PASSWORD CONFIRM_PASSWORD
echo "现在可以用新密码登录；其他设备上的旧会话已失效。"
