#!/usr/bin/env bash

# Local acceptance check for the mobile first-connection API.
# Start Oris with ORIS_DEV_DEVICE_AUTH=true before running this script.

set -u

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

[[ -n "${ORIS_BASE_URL:-}" ]] || fail 'ORIS_BASE_URL is required'
[[ -n "${ORIS_DEVICE_ID:-}" ]] || fail 'ORIS_DEVICE_ID is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'

BASE_URL="${ORIS_BASE_URL%/}"
DEVICE_ID="$ORIS_DEVICE_ID"
TASK_ID="mobile-task-$$"
MESSAGE_ID="mobile-message-$$"
CONVERSATION_ID="${ORIS_CONVERSATION_ID:-mobile-default}"

request() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    local response
    if [[ -n "$data" ]]; then
        response="$(curl --silent --show-error --connect-timeout 3 --max-time 20 \
            --request "$method" --header 'Accept: application/json' \
            --header "X-Oris-Device-Id: $DEVICE_ID" \
            --header 'Content-Type: application/json' --data "$data" \
            --write-out $'\n%{http_code}' "$url")" \
            || fail "request failed: $method $url"
    else
        response="$(curl --silent --show-error --connect-timeout 3 --max-time 20 \
            --request "$method" --header 'Accept: application/json' \
            --header "X-Oris-Device-Id: $DEVICE_ID" \
            --write-out $'\n%{http_code}' "$url")" \
            || fail "request failed: $method $url"
    fi
    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
}

expect_status() {
    local expected="$1"
    local description="$2"
    [[ "$HTTP_STATUS" == "$expected" ]] \
        || fail "$description: expected HTTP $expected, got $HTTP_STATUS: $HTTP_BODY"
    pass "$description"
}

request GET "$BASE_URL/api/v1/auth/session"
expect_status 200 'device authentication creates a stable user'
USER_ID="$(jq -er '.userId' <<<"$HTTP_BODY")" || fail 'session response has no userId'

request POST "$BASE_URL/api/v1/tasks" \
    "$(jq -cn --arg id "$TASK_ID" '{id: $id, title: "mobile connection task", due: "2099-12-31"}')"
expect_status 201 'created task with mobile local id'
asserted_id="$(jq -er '.id' <<<"$HTTP_BODY")" || fail 'task response has no id'
[[ "$asserted_id" == "$TASK_ID" ]] || fail "task id was not preserved: $asserted_id"
pass 'task local id was preserved'

request POST "$BASE_URL/api/v1/tasks" \
    "$(jq -cn --arg id "$TASK_ID" '{id: $id, title: "mobile connection task", due: "2099-12-31"}')"
expect_status 200 'replayed task create is idempotent'

request POST "$BASE_URL/api/v1/conversations/$CONVERSATION_ID/messages" \
    "$(jq -cn --arg id "$MESSAGE_ID" '{id: $id, content: "mobile connection message"}')"
expect_status 201 'created mobile chat message'
asserted_id="$(jq -er '.id' <<<"$HTTP_BODY")" || fail 'message response has no id'
[[ "$asserted_id" == "$MESSAGE_ID" ]] || fail "message id was not preserved: $asserted_id"
pass 'message local id was preserved'

request POST "$BASE_URL/api/v1/conversations/$CONVERSATION_ID/messages" \
    "$(jq -cn --arg id "$MESSAGE_ID" '{id: $id, content: "mobile connection message"}')"
expect_status 200 'replayed message create is idempotent'

request GET "$BASE_URL/api/v1/conversations/$CONVERSATION_ID/messages"
expect_status 200 'listed mobile chat messages'
jq -e --arg id "$MESSAGE_ID" 'any(.[]; .id == $id and .role == "user")' <<<"$HTTP_BODY" \
    >/dev/null 2>&1 || fail "message was not returned: $HTTP_BODY"
pass 'created message is readable by the same device'

request GET "$BASE_URL/api/v1/sync/events?after=0&limit=500"
expect_status 200 'read mobile sync events'
jq -e --arg id "$TASK_ID" 'any(.events[]; .entityType == "task" and .entityId == $id)' <<<"$HTTP_BODY" \
    >/dev/null 2>&1 || fail "task was not added to sync stream: $HTTP_BODY"
pass 'task appears in the sync stream'

printf '\nMobile connection acceptance passed for user %s.\n' "$USER_ID"
