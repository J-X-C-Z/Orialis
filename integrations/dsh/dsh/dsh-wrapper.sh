#!/bin/sh
for env_file in /etc/dsh/deepseek.env /etc/dsh/westlake.env; do
  if [ -r "$env_file" ]; then
    set -a
    . "$env_file"
    set +a
  fi
done
if [ -z "${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${http_proxy:-}${https_proxy:-}${all_proxy:-}" ]; then
  export HTTP_PROXY="http://127.0.0.1:7890"
  export HTTPS_PROXY="http://127.0.0.1:7890"
  export ALL_PROXY="http://127.0.0.1:7890"
  export http_proxy="$HTTP_PROXY"
  export https_proxy="$HTTPS_PROXY"
  export all_proxy="$ALL_PROXY"
fi
if [ -z "${NO_PROXY:-}${no_proxy:-}" ]; then
  export NO_PROXY="localhost,127.0.0.1,::1"
  export no_proxy="$NO_PROXY"
fi
exec /usr/local/bin/dsh-bin "$@"
