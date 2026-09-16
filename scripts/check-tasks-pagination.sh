#!/usr/bin/env bash

# Local API acceptance check for task cursor pagination.

set -u

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

[[ -n "${ORIS_BASE_URL:-}" ]] || fail 'ORIS_BASE_URL is required'
[[ -n "${ORIS_USERNAME:-}" ]] || fail 'ORIS_USERNAME is required'
[[ -n "${ORIS_PASSWORD:-}" ]] || fail 'ORIS_PASSWORD is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'

BASE_URL="${ORIS_BASE_URL%/}"
TOKEN=''
HTTP_STATUS=''
HTTP_BODY=''

request() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    local response
    if [[ -n "$data" ]]; then
        response="$(curl --silent --show-error --connect-timeout 3 --max-time 20 \
            --request "$method" --header 'Accept: application/json' \
            --header "Authorization: Session $TOKEN" \
            --header 'Content-Type: application/json' --data "$data" \
            --write-out $'\n%{http_code}' "$url")" \
            || fail "request failed: $method $url"
    else
        response="$(curl --silent --show-error --connect-timeout 3 --max-time 20 \
            --request "$method" --header 'Accept: application/json' \
            --header "Authorization: Session $TOKEN" \
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

assert_json() {
    local filter="$1"
    local description="$2"
    jq -e "$filter" <<<"$HTTP_BODY" >/dev/null 2>&1 \
        || fail "$description: $HTTP_BODY"
    pass "$description"
}

credentials="$(jq -cn --arg username "$ORIS_USERNAME" --arg password "$ORIS_PASSWORD" \
    '{username: $username, password: $password}')"
register_response="$(curl --silent --show-error --request POST \
    --header 'Content-Type: application/json' --data "$credentials" \
    "$BASE_URL/api/v1/auth/register")" \
    || fail 'could not register acceptance user'
TOKEN="$(jq -er '.accessToken' <<<"$register_response" 2>/dev/null)" \
    || fail "registration did not return a session: $register_response"
pass 'received session token'

create_task() {
    request POST "$BASE_URL/api/v1/tasks" "$1"
    expect_status 201 'created isolated task'
}

create_task '{"title":"pagination early","due":"2099-01-01"}'
create_task '{"title":"pagination timed","due":"2099-01-02","dueTime":"08:00"}'
create_task '{"title":"pagination undated"}'

request GET "$BASE_URL/api/v1/tasks?limit=2"
expect_status 200 'first task page returned'
assert_json '.items | type == "array" and length == 2' 'first page has two tasks'
assert_json '.hasMore == true and (.nextCursor | type == "string" and length > 0)' \
    'first page exposes continuation cursor'
assert_json '.items[0].title == "pagination early" and .items[1].title == "pagination timed"' \
    'task page preserves deadline ordering'
FIRST_ID="$(jq -er '.items[0].id' <<<"$HTTP_BODY")"
SECOND_ID="$(jq -er '.items[1].id' <<<"$HTTP_BODY")"
NEXT_CURSOR="$(jq -er '.nextCursor' <<<"$HTTP_BODY")"

request GET "$BASE_URL/api/v1/tasks?limit=2&after=$NEXT_CURSOR"
expect_status 200 'second task page returned'
assert_json '.items | type == "array" and length == 1' 'second page has remaining task'
assert_json '.items[0].title == "pagination undated" and .hasMore == false and .nextCursor == null' \
    'last page is terminal and uses null cursor'
jq -e --arg first "$FIRST_ID" --arg second "$SECOND_ID" \
    '[.items[].id] | all(. != $first and . != $second)' <<<"$HTTP_BODY" >/dev/null 2>&1 \
    || fail "pages do not repeat earlier tasks: $HTTP_BODY"
pass 'pages do not repeat earlier tasks'

request GET "$BASE_URL/api/v1/tasks?limit=0"
expect_status 400 'zero page size rejected'
request GET "$BASE_URL/api/v1/tasks?limit=101"
expect_status 400 'oversized page rejected'
request GET "$BASE_URL/api/v1/tasks?after=not-a-cursor"
expect_status 400 'invalid cursor rejected'

printf '\nTask pagination acceptance passed.\n'
