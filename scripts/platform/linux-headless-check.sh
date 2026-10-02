#!/usr/bin/env sh
set -eu

if [ "$(uname -s)" != Linux ]; then
  echo "SKIP: Linux/Docker acceptance requires a Linux runner; detected $(uname -s) $(uname -m)" >&2
  exit 2
fi
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker CLI is required" >&2; exit 2; }
printf 'HOST_OS=%s\nHOST_ARCH=%s\n' "$(uname -s)" "$(uname -m)"
docker version
docker compose -f compose.headless.yaml config
docker compose -f compose.headless.yaml build --no-cache
mkdir -p runtime-data
chmod 700 runtime-data
docker compose -f compose.headless.yaml up -d
trap 'docker compose -f compose.headless.yaml down' EXIT INT TERM
docker compose -f compose.headless.yaml ps
docker compose -f compose.headless.yaml logs --no-color --tail=100
docker compose -f compose.headless.yaml exec -T orialis-server sh -c 'id; test ! -w /etc; test -w /data; test -w /tmp'
curl --fail --silent --show-error http://127.0.0.1:18443/api/health
printf '\n'
docker compose -f compose.headless.yaml down
trap - EXIT INT TERM
