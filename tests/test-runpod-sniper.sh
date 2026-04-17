#!/usr/bin/env bash
# Tests for runpod-sniper.sh
# Usage:
#   ./tests/test-runpod-sniper.sh          # offline tests, then prompts for an
#                                          # API key to run the live
#                                          # create+delete round-trip (empty
#                                          # input skips the live portion).

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/runpod-sniper.sh"
CONFIGS_DIR="${ROOT_DIR}/configs"

# Unique prefix so tests never collide with real user configs; matches gitignore (configs/*.conf).
TEST_PREFIX="test-$$-"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="${TMP_DIR}/bin"
mkdir -p "$FAKE_BIN"

cleanup() {
    rm -rf "$TMP_DIR"
    rm -f "${CONFIGS_DIR}/${TEST_PREFIX}"*.conf
}
trap cleanup EXIT

pass=0
fail=0
assert() {
    local msg="$1" cond="$2"
    if eval "$cond"; then
        echo "  [PASS] $msg"
        pass=$((pass + 1))
    else
        echo "  [FAIL] $msg"
        fail=$((fail + 1))
    fi
}

write_config() {
    local name="$1"
    cat > "${CONFIGS_DIR}/${TEST_PREFIX}${name}.conf" <<EOF
RUNPOD_API_KEY="dummy"
GPU_TYPES=("NVIDIA TEST GPU")
GPU_COUNT=1
CLOUD_TYPE="SECURE"
IMAGE="test/image:latest"
CONTAINER_DISK=50
VOLUME_DISK=256
POLL_INTERVAL=60
TEMPLATE_ID=""
VOLUME_ID=""
POD_NAME="test-pod"
NTFY_TOPIC=""
MACOS_NOTIFY=false
EOF
}

install_fake_curl() {
    # Canned fake: echoes request body to $CURL_BODY_LOG, prints $CURL_RESPONSE_BODY,
    # then prints status code on its own line (matches the script's -w format).
    cat > "${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
body=""
while (( $# )); do
    case "$1" in
        -d) body="$2"; shift 2 ;;
        -d*) body="${1#-d}"; shift ;;
        *) shift ;;
    esac
done
[[ -n "${CURL_BODY_LOG:-}" ]] && printf '%s' "$body" > "$CURL_BODY_LOG"
printf '%s\n' "${CURL_RESPONSE_BODY-{\"id\":\"pod-xyz\"\}}"
printf '%s\n' "${CURL_RESPONSE_CODE-200}"
EOF
    chmod +x "${FAKE_BIN}/curl"
}

run_script() {
    # Args: config_name, stdin_source (default /dev/null), extra env vars are already exported.
    local cfg="$1" stdin_src="${2:-/dev/null}"
    PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" "${CONFIGS_DIR}/${TEST_PREFIX}${cfg}.conf" < "$stdin_src"
}

# --- Offline tests ----------------------------------------------------------
install_fake_curl

echo "Test 0: no args -> usage + non-zero exit"
out="$(PATH="${FAKE_BIN}:${PATH}" env -u CONFIG "$SCRIPT" 2>&1 < /dev/null)"; rc=$?
assert "exits non-zero" "[[ $rc -ne 0 ]]"
assert "stderr contains 'Usage:'" "[[ \"\$out\" == *'Usage:'* ]]"

echo "Test 1: missing config file"
out="$(PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" /nope/nonexistent-xyz.conf 2>&1 < /dev/null)"; rc=$?
assert "exits non-zero" "[[ $rc -ne 0 ]]"
assert "stderr mentions the bad path" "[[ \"\$out\" == *'nonexistent-xyz.conf'* ]]"

echo "Test 2: missing required key"
write_config "missing-key"
# Remove GPU_COUNT line
sed -i.bak '/^GPU_COUNT=/d' "${CONFIGS_DIR}/${TEST_PREFIX}missing-key.conf" && rm -f "${CONFIGS_DIR}/${TEST_PREFIX}missing-key.conf.bak"
out="$(run_script missing-key 2>&1)"; rc=$?
assert "exits non-zero" "[[ $rc -ne 0 ]]"
assert "stderr names GPU_COUNT" "[[ \"\$out\" == *GPU_COUNT* ]]"

echo "Test 3: empty API key, non-TTY -> error"
write_config "no-key"
sed -i.bak 's/^RUNPOD_API_KEY=.*/RUNPOD_API_KEY=""/' "${CONFIGS_DIR}/${TEST_PREFIX}no-key.conf" && rm -f "${CONFIGS_DIR}/${TEST_PREFIX}no-key.conf.bak"
out="$(run_script no-key 2>&1)"; rc=$?
assert "exits non-zero" "[[ $rc -ne 0 ]]"
assert "stderr mentions RUNPOD_API_KEY" "[[ \"\$out\" == *RUNPOD_API_KEY* ]]"

echo "Test 4: empty API key, TTY prompt"
if command -v expect >/dev/null 2>&1; then
    expect_script="${TMP_DIR}/prompt.exp"
    cat > "$expect_script" <<EOF
set timeout 10
spawn env PATH=${FAKE_BIN}:\$env(PATH) ${SCRIPT} ${CONFIGS_DIR}/${TEST_PREFIX}no-key.conf
expect "RUNPOD_API_KEY:"
send "typed-key\r"
expect {
"SUCCESS!" { exit 0 }
timeout    { exit 2 }
eof        { exit 3 }
}
EOF
    expect "$expect_script" >/dev/null 2>&1; rc=$?
    assert "interactive prompt accepts typed key and proceeds to SUCCESS" "[[ $rc -eq 0 ]]"
else
    echo "  [SKIP] (expect not installed)"
fi

echo "Test 5: happy path (stubbed curl -> 200)"
write_config "happy"
export CURL_RESPONSE_BODY='{"id":"pod-xyz","status":"ok"}'
export CURL_RESPONSE_CODE=200
export CURL_BODY_LOG="${TMP_DIR}/body.json"
out="$(run_script happy 2>&1)"; rc=$?
assert "exits 0" "[[ $rc -eq 0 ]]"
assert "stdout contains SUCCESS!" "[[ \"\$out\" == *'SUCCESS!'* ]]"
assert "stdout contains pod-xyz" "[[ \"\$out\" == *'pod-xyz'* ]]"

echo "Test 6: request body reflects config GPU_TYPES"
assert "body file exists" "[[ -f \"\$CURL_BODY_LOG\" ]]"
body_content="$(cat "$CURL_BODY_LOG")"
assert "body contains GPU from config (NVIDIA TEST GPU)" "[[ \"\$body_content\" == *'NVIDIA TEST GPU'* ]]"
assert "body does NOT contain old hardcoded L40S" "[[ \"\$body_content\" != *'L40S'* ]]"
assert "body contains gpuCount from config" "[[ \"\$body_content\" == *'\"gpuCount\": 1'* ]]"

echo "Test 6b: json_escape handles quotes and backslashes in POD_NAME"
write_config "escape"
sed -i.bak 's|^POD_NAME=.*|POD_NAME="has \\"quote\\" and \\\\ back"|' "${CONFIGS_DIR}/${TEST_PREFIX}escape.conf" && rm -f "${CONFIGS_DIR}/${TEST_PREFIX}escape.conf.bak"
export CURL_RESPONSE_BODY='{"id":"pod-xyz"}'
export CURL_RESPONSE_CODE=200
export CURL_BODY_LOG="${TMP_DIR}/body_escape.json"
out="$(run_script escape 2>&1)"; rc=$?
esc_body="$(cat "$CURL_BODY_LOG")"
assert "happy exit on escaped POD_NAME" "[[ $rc -eq 0 ]]"
assert "POD_NAME quotes are backslash-escaped in body" "[[ \"\$esc_body\" == *'has \\\"quote\\\"'* ]]"
assert "POD_NAME backslash is doubled in body" "[[ \"\$esc_body\" == *'\\\\'* ]]"

echo "Test 6c: body includes templateId when TEMPLATE_ID set, networkVolumeId when VOLUME_ID set"
write_config "tpl"
sed -i.bak -e 's|^TEMPLATE_ID=.*|TEMPLATE_ID="my-tmpl"|' -e 's|^VOLUME_ID=.*|VOLUME_ID="my-vol"|' "${CONFIGS_DIR}/${TEST_PREFIX}tpl.conf" && rm -f "${CONFIGS_DIR}/${TEST_PREFIX}tpl.conf.bak"
export CURL_BODY_LOG="${TMP_DIR}/body_tpl.json"
out="$(run_script tpl 2>&1)"; rc=$?
tpl_body="$(cat "$CURL_BODY_LOG")"
assert "body contains templateId" "[[ \"\$tpl_body\" == *'\"templateId\": \"my-tmpl\"'* ]]"
assert "body contains networkVolumeId" "[[ \"\$tpl_body\" == *'\"networkVolumeId\": \"my-vol\"'* ]]"
assert "body omits volumeInGb when VOLUME_ID is set" "[[ \"\$tpl_body\" != *volumeInGb* ]]"

echo "Test 6d: pretty_json indents nested JSON (via the real script)"
write_config "pretty"
export CURL_RESPONSE_BODY='{"id":"pod-xyz","ports":[8888,22],"env":{"FOO":"bar","nested":{"x":1}}}'
export CURL_RESPONSE_CODE=200
unset CURL_BODY_LOG
pretty_out="$(run_script pretty 2>&1)"; rc=$?
assert "happy exit on pretty-print test" "[[ $rc -eq 0 ]]"
assert "pretty_json indents \"id\" two spaces" "[[ \"\$pretty_out\" == *'  \"id\": \"pod-xyz\"'* ]]"
assert "pretty_json expands nested object on its own lines" "[[ \"\$pretty_out\" == *'    \"x\": 1'* ]]"
assert "pretty_json expands array elements onto separate lines" "[[ \"\$pretty_out\" == *'    8888,'* ]]"

echo "Test 6e: POLL_INTERVAL below 10 triggers minimum-clamp warning"
write_config "clamp-low"
sed -i.bak 's/^POLL_INTERVAL=.*/POLL_INTERVAL=3/' "${CONFIGS_DIR}/${TEST_PREFIX}clamp-low.conf" && rm -f "${CONFIGS_DIR}/${TEST_PREFIX}clamp-low.conf.bak"
export CURL_RESPONSE_BODY='{"id":"pod-xyz"}'
export CURL_RESPONSE_CODE=200
unset CURL_BODY_LOG
err="$(PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" "${CONFIGS_DIR}/${TEST_PREFIX}clamp-low.conf" 2>&1 >/dev/null < /dev/null)"; rc=$?
assert "exits 0 (happy path still completes)" "[[ $rc -eq 0 ]]"
assert "stderr contains clamp warning" "[[ \"\$err\" == *'POLL_INTERVAL=3'*'minimum'* ]]"

echo "Test 6f: POLL_INTERVAL >= 10 does NOT warn"
write_config "clamp-ok"
sed -i.bak 's/^POLL_INTERVAL=.*/POLL_INTERVAL=30/' "${CONFIGS_DIR}/${TEST_PREFIX}clamp-ok.conf" && rm -f "${CONFIGS_DIR}/${TEST_PREFIX}clamp-ok.conf.bak"
err="$(PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" "${CONFIGS_DIR}/${TEST_PREFIX}clamp-ok.conf" 2>&1 >/dev/null < /dev/null)"; rc=$?
assert "exits 0" "[[ $rc -eq 0 ]]"
assert "stderr does NOT mention minimum clamp" "[[ \"\$err\" != *'minimum'* ]]"

unset CURL_BODY_LOG

echo "Test 7: capacity error (400 'no longer any instances') loops to retry"
write_config "capacity"
sed -i.bak 's/^POLL_INTERVAL=.*/POLL_INTERVAL=1/' "${CONFIGS_DIR}/${TEST_PREFIX}capacity.conf" && rm -f "${CONFIGS_DIR}/${TEST_PREFIX}capacity.conf.bak"
export CURL_RESPONSE_BODY='{"message":"There are no longer any instances available with the requested specifications."}'
export CURL_RESPONSE_CODE=400
unset CURL_BODY_LOG
# Run sniper in background; kill it and children after 2s. If it was retrying (not fatal), it stayed alive until killed.
PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" "${CONFIGS_DIR}/${TEST_PREFIX}capacity.conf" > "$TMP_DIR/out" 2>&1 < /dev/null &
pid=$!
sleep 2
exited_before_kill=false
if ! kill -0 "$pid" 2>/dev/null; then exited_before_kill=true; fi
pkill -P "$pid" 2>/dev/null || true
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null
out="$(cat "$TMP_DIR/out")"
assert "script was still running at 2s (retry loop)" "[[ \$exited_before_kill == false ]]"
assert "did NOT fatal-exit (no 'FATAL' in output)" "[[ \"\$out\" != *'FATAL'* ]]"
assert "output shows the 400 was received" "[[ \"\$out\" == *'400'* ]]"

echo "Test 8: non-capacity 400 (e.g. bad request) fails fast"
write_config "badreq"
export CURL_RESPONSE_BODY='{"message":"imageName is required"}'
export CURL_RESPONSE_CODE=400
out="$(run_script badreq 2>&1)"; rc=$?
assert "exits non-zero" "[[ $rc -ne 0 ]]"
assert "stdout contains FATAL" "[[ \"\$out\" == *'FATAL'* ]]"
assert "stdout echoes the error body" "[[ \"\$out\" == *'imageName is required'* ]]"

echo "Test 9: 401 unauthorized fails fast"
write_config "unauth"
export CURL_RESPONSE_BODY='{"message":"unauthorized"}'
export CURL_RESPONSE_CODE=401
out="$(run_script unauth 2>&1)"; rc=$?
assert "exits non-zero" "[[ $rc -ne 0 ]]"
assert "stdout contains FATAL" "[[ \"\$out\" == *'FATAL'* ]]"

echo "Test 9b: empty body falls back to HTTP code meaning"
write_config "emptybody"
export CURL_RESPONSE_BODY=''
export CURL_RESPONSE_CODE=403
out="$(run_script emptybody 2>&1)"; rc=$?
assert "exits non-zero" "[[ $rc -ne 0 ]]"
assert "stdout contains 'Forbidden'" "[[ \"\$out\" == *'Forbidden'* ]]"
assert "stdout contains HTTP 403" "[[ \"\$out\" == *'HTTP 403'* ]]"

echo "Test 10: 5xx retries (transient)"
write_config "fivexx"
sed -i.bak 's/^POLL_INTERVAL=.*/POLL_INTERVAL=1/' "${CONFIGS_DIR}/${TEST_PREFIX}fivexx.conf" && rm -f "${CONFIGS_DIR}/${TEST_PREFIX}fivexx.conf.bak"
export CURL_RESPONSE_BODY='{"message":"internal server error"}'
export CURL_RESPONSE_CODE=500
PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" "${CONFIGS_DIR}/${TEST_PREFIX}fivexx.conf" > "$TMP_DIR/out" 2>&1 < /dev/null &
pid=$!
sleep 2
exited_before_kill=false
if ! kill -0 "$pid" 2>/dev/null; then exited_before_kill=true; fi
pkill -P "$pid" 2>/dev/null || true
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null
out="$(cat "$TMP_DIR/out")"
assert "script was still running at 2s (5xx retry loop)" "[[ \$exited_before_kill == false ]]"
assert "did NOT fatal-exit on 500" "[[ \"\$out\" != *'FATAL'* ]]"

# Reset response state for subsequent tests
unset CURL_RESPONSE_BODY CURL_RESPONSE_CODE

echo "Test 11: gitignore rules"
write_config "gitignore-check"
git -C "$ROOT_DIR" check-ignore -q "configs/${TEST_PREFIX}gitignore-check.conf"; rc=$?
assert "configs/${TEST_PREFIX}gitignore-check.conf is ignored" "[[ $rc -eq 0 ]]"
git -C "$ROOT_DIR" check-ignore -q "configs/example.conf"; rc=$?
assert "configs/example.conf is NOT ignored" "[[ $rc -ne 0 ]]"

echo
echo "-----------------------------"
echo " Offline: ${pass} passed, ${fail} failed"
echo "-----------------------------"
offline_failed=$fail

# --- Live tests -------------------------------------------------------------
# Always prompt for an API key; empty input skips live.
LIVE_CONFIG="${ROOT_DIR}/configs/example.conf"
if [[ ! -f "$LIVE_CONFIG" ]]; then
    echo "Error: $LIVE_CONFIG not found" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$LIVE_CONFIG"

if [[ ! -t 0 ]]; then
    echo
    echo "Skipping live tests (no TTY for API key prompt)."
    exit $(( offline_failed > 0 ? 1 : 0 ))
fi

echo
printf 'Enter RUNPOD_API_KEY to run live tests (leave empty to skip): '
RUNPOD_API_KEY=""
while IFS= read -r -s -n1 char; do
    if [[ -z "$char" ]]; then
        break
    elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
        if [[ -n "$RUNPOD_API_KEY" ]]; then
            RUNPOD_API_KEY="${RUNPOD_API_KEY%?}"
            printf '\b \b'
        fi
    else
        RUNPOD_API_KEY+="$char"
        printf '*'
    fi
done
printf '\n'

if [[ -z "$RUNPOD_API_KEY" ]]; then
    echo "Skipped live tests."
    exit $(( offline_failed > 0 ? 1 : 0 ))
fi

# Reset pass/fail counters for the live section so its summary is standalone.
pass=0
fail=0

API_BASE="https://rest.runpod.io/v1"
AUTH=(-H "Authorization: Bearer ${RUNPOD_API_KEY}")
POD_ID_FILE="${TMP_DIR}/runpod_test_pod_id"
created_pod_id=""
live_cleanup() {
    if [[ -n "$created_pod_id" ]]; then
        echo "Cleanup: deleting pod ${created_pod_id}"
        curl -s -X DELETE "${API_BASE}/pods/${created_pod_id}" "${AUTH[@]}" >/dev/null || true
    fi
    rm -f "$POD_ID_FILE"
    cleanup
}
trap live_cleanup EXIT

echo "Live test 8: GET /v1/pods auth smoke test"
code=$(curl -s -o /dev/null -w '%{http_code}' "${API_BASE}/pods" "${AUTH[@]}")
assert "GET /v1/pods returns 2xx" "[[ \$code =~ ^2 ]]"
[[ ! $code =~ ^2 ]] && { echo "Auth failed; aborting before create."; exit 1; }

echo "Live test 9: create + delete round-trip"
# Build a body from the live config, first GPU only, to keep cost minimal.
first_gpu="${GPU_TYPES[0]}"
body=$(cat <<EOF
{
  "name": "sniper-test-$$",
  "imageName": "${IMAGE}",
  "gpuTypeIds": ["${first_gpu}"],
  "gpuCount": ${GPU_COUNT},
  "containerDiskInGb": ${CONTAINER_DISK},
  "volumeInGb": ${VOLUME_DISK},
  "cloudType": "${CLOUD_TYPE}"
}
EOF
)
resp=$(curl -s -w $'\n%{http_code}' -X POST "${API_BASE}/pods" "${AUTH[@]}" -H 'Content-Type: application/json' -d "$body")
code=$(echo "$resp" | tail -1)
resp_body=$(echo "$resp" | sed '$d')
if [[ ! $code =~ ^20 ]]; then
    echo "  [SKIP] (create failed: $code - likely no capacity for ${first_gpu})"
    echo "  response: $(echo "$resp_body" | head -c 200)"
    exit $(( offline_failed > 0 ? 1 : 0 ))
fi
created_pod_id=$(echo "$resp_body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "$created_pod_id" > "$POD_ID_FILE"
assert "POST returned non-empty pod id" "[[ -n \"\$created_pod_id\" ]]"

code=$(curl -s -o /dev/null -w '%{http_code}' "${API_BASE}/pods/${created_pod_id}" "${AUTH[@]}")
assert "GET /v1/pods/{id} returns 200 after create" "[[ \$code == 200 ]]"

code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "${API_BASE}/pods/${created_pod_id}" "${AUTH[@]}")
assert "DELETE returns 2xx" "[[ \$code =~ ^2 ]]"
deleted_pod_id="$created_pod_id"
created_pod_id=""  # disarm cleanup

# Brief delay then confirm gone
sleep 2
code=$(curl -s -o /dev/null -w '%{http_code}' "${API_BASE}/pods/${deleted_pod_id}" "${AUTH[@]}")
assert "GET /v1/pods/{id} returns 404 after delete" "[[ \$code == 404 ]]"

echo
echo "-----------------------------"
echo " Live: ${pass} passed, ${fail} failed"
echo "-----------------------------"
exit $(( (fail + offline_failed) > 0 ? 1 : 0 ))
