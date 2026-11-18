#!/bin/bash
set -o pipefail

curl_exe='C:\Windows\System32\curl.exe'
failed=0
for platform in wechat qq wecom email; do
  if status=$(printf '{"platform":"%s"}' "$platform" | timeout 90 ssh -T windows-mcp \
    "$curl_exe --noproxy * -s -m 60 -o NUL -w %{http_code} -X POST http://127.0.0.1:8765/api/sync -H Content-Type:application/json -d @-") && [[ $status =~ ^[1-5][0-9]{2}$ ]]; then
    printf '%s HTTP %s\n' "$platform" "$status"
    [[ $status == 200 ]] || failed=1
  else
    printf '%s transport failed\n' "$platform" >&2
    failed=1
  fi
done
exit "$failed"
