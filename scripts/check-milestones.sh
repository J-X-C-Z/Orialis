#!/usr/bin/env bash

# Local API acceptance check for project milestones.
# Required runtime tools: curl, jq.
# The script never starts Oris and leaves its test project for inspection.

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
    local idempotency_key="${4:-}"
    local response
    local body_length
    local -a curl_args

    curl_args=(
        --silent
        --show-error
        --connect-timeout 3
        --max-time 20
        --request "$method"
        --header 'Accept: application/json'
        --write-out $'\n%{http_code}'
        "$url"
    )

    if [[ -n "$TOKEN" ]]; then
        curl_args+=(--header "Authorization: Session $TOKEN")
    fi
    if [[ -n "$data" ]]; then
        curl_args+=(--header 'Content-Type: application/json' --data "$data")
    fi
    if [[ -n "$idempotency_key" ]]; then
        curl_args+=(--header "Idempotency-Key: $idempotency_key")
    fi

    response="$(curl "${curl_args[@]}")" || fail "request failed (service may not be running): $method $url"
    [[ "${response: -4:1}" == $'\n' ]] || fail "curl did not return an HTTP status: $method $url"
    HTTP_STATUS="${response: -3}"
    body_length=$((${#response} - 4))
    HTTP_BODY="${response:0:body_length}"
}

expect_status() {
    local expected="$1"
    local description="$2"
    [[ "$HTTP_STATUS" == "$expected" ]] || fail "$description: expected HTTP $expected, got $HTTP_STATUS: $HTTP_BODY"
    pass "$description"
}

json_value() {
    local filter="$1"
    jq -er "$filter" <<<"$HTTP_BODY" 2>/dev/null || fail "invalid response for '$filter': $HTTP_BODY"
}

json_body() {
    jq -cn "$@" || fail 'could not build JSON request body'
}

assert_json() {
    local filter="$1"
    local description="$2"
    jq -e "$filter" <<<"$HTTP_BODY" >/dev/null 2>&1 || fail "$description: $HTTP_BODY"
    pass "$description"
}

assert_json_arg() {
    local name="$1"
    local value="$2"
    local filter="$3"
    local description="$4"
    jq -e --arg "$name" "$value" "$filter" <<<"$HTTP_BODY" >/dev/null 2>&1 \
        || fail "$description: $HTTP_BODY"
    pass "$description"
}

request GET "$BASE_URL/api/v1/health"
expect_status 200 'service is running'
assert_json '.ok == true' 'health response is ok'

CREDENTIALS="$(json_body --arg username "$ORIS_USERNAME" --arg password "$ORIS_PASSWORD" \
    '{username: $username, password: $password}')"

request POST "$BASE_URL/api/v1/auth/register" "$CREDENTIALS"
case "$HTTP_STATUS" in
    201)
        pass 'registered acceptance user'
        ;;
    409)
        pass 'acceptance user already exists; logging in'
        request POST "$BASE_URL/api/v1/auth/login" "$CREDENTIALS"
        expect_status 200 'logged in acceptance user'
        ;;
    *)
        fail "register acceptance user: expected HTTP 201 or 409, got $HTTP_STATUS: $HTTP_BODY"
        ;;
esac

TOKEN="$(json_value '.accessToken')"
[[ -n "$TOKEN" ]] || fail 'authentication response did not contain accessToken'
pass 'received session token'

PROJECT_NAME="milestone-acceptance-$$-${RANDOM}"
PROJECT_BODY="$(json_body --arg name "$PROJECT_NAME" '{name: $name}')"
request POST "$BASE_URL/api/v1/projects" "$PROJECT_BODY" "project-$$-${RANDOM}"
expect_status 201 'created isolated acceptance project'
PROJECT_ID="$(json_value '.id')"
[[ -n "$PROJECT_ID" ]] || fail 'project response did not contain id'

request GET "$BASE_URL/api/v1/sync/snapshot"
expect_status 200 'read sync snapshot before milestone changes'
BASE_CURSOR="$(json_value '.cursor')"
assert_json '.milestones | type == "array"' 'snapshot exposes milestones collection'

MILESTONE_TITLE="Complete milestone acceptance $$-${RANDOM}"
MILESTONE_BODY="$(json_body \
    --arg title "$MILESTONE_TITLE" \
    '{title: $title, due: "2099-12-31", completed: false, position: 0}')"
request POST "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones" "$MILESTONE_BODY" \
    "milestone-create-$$-${RANDOM}"
expect_status 201 'created milestone'
MILESTONE_ID="$(json_value '.id')"
[[ -n "$MILESTONE_ID" ]] || fail 'milestone response did not contain id'
assert_json_arg id "$PROJECT_ID" '.projectId == $id' 'milestone belongs to acceptance project'
assert_json '.completed == false and .due == "2099-12-31" and .version == 1' \
    'milestone has deadline-only initial state'

request GET "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones"
expect_status 200 'listed project milestones'
assert_json_arg id "$MILESTONE_ID" 'any(.[]; .id == $id)' 'created milestone appears in project list'

request GET "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones/$MILESTONE_ID"
expect_status 200 'read created milestone'
assert_json_arg id "$MILESTONE_ID" '.id == $id' 'read milestone has expected id'

UPDATED_TITLE="${MILESTONE_TITLE} updated"
UPDATE_BODY="$(json_body --arg title "$UPDATED_TITLE" \
    '{title: $title, completed: true, position: 1, baseVersion: 1}')"
request PATCH "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones/$MILESTONE_ID" "$UPDATE_BODY" \
    "milestone-update-$$-${RANDOM}"
expect_status 200 'updated milestone'
assert_json_arg title "$UPDATED_TITLE" \
    '.title == $title and .completed == true and .completedAt != null and .version == 2' \
    'milestone update applied and completion timestamp generated'

CLEAR_DUE_BODY='{"due":null,"baseVersion":2}'
request PATCH "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones/$MILESTONE_ID" "$CLEAR_DUE_BODY" \
    "milestone-clear-due-$$-${RANDOM}"
expect_status 200 'cleared milestone deadline explicitly'
assert_json '.due == null and .version == 3' 'explicit null clears milestone deadline'

INVALID_DUE_BODY='{"due":"2099-02-30","baseVersion":3}'
request PATCH "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones/$MILESTONE_ID" "$INVALID_DUE_BODY"
expect_status 400 'invalid milestone deadline rejected'

STALE_BODY="$(json_body --arg title "$MILESTONE_TITLE stale" \
    '{title: $title, baseVersion: 1}')"
request PATCH "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones/$MILESTONE_ID" "$STALE_BODY"
expect_status 409 'stale milestone update rejected with version conflict'

request GET "$BASE_URL/api/v1/calendar-events"
expect_status 200 'listed calendar events'
assert_json_arg id "$MILESTONE_ID" \
    'all(.[]; .id != $id)' \
    'milestone does not enter calendar events'

request DELETE "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones/$MILESTONE_ID" \
    '' "milestone-delete-$$-${RANDOM}"
expect_status 204 'soft-deleted milestone'

request GET "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones"
expect_status 200 'listed milestones after deletion'
assert_json_arg id "$MILESTONE_ID" 'all(.[]; .id != $id)' \
    'soft-deleted milestone is absent from normal list'

request GET "$BASE_URL/api/v1/projects/$PROJECT_ID/milestones/$MILESTONE_ID"
expect_status 404 'deleted milestone is not readable as active resource'

request GET "$BASE_URL/api/v1/sync/events?after=$BASE_CURSOR&limit=500"
expect_status 200 'read milestone sync events'
assert_json_arg id "$MILESTONE_ID" \
    'any(.events[]; .entityType == "project_milestone" and .entityId == $id and .operation == "upsert")' \
    'milestone upsert appears in sync stream'
assert_json_arg id "$MILESTONE_ID" \
    'any(.events[]; .entityType == "project_milestone" and .entityId == $id and .operation == "delete" and .tombstone == true)' \
    'milestone deletion appears as a tombstone'

printf '\nMilestone API acceptance passed.\nProject fixture: %s\nMilestone fixture: %s\n' "$PROJECT_ID" "$MILESTONE_ID"
