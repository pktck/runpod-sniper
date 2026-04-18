#!/usr/bin/env bash
#
# Tests for runpod-sniper.sh.
#
# Usage:
#   ./tests/test-runpod-sniper.sh   # offline tests, then prompts for an API
#                                   # key to run the live create+delete
#                                   # round-trip (empty input skips live).

# Many test-local variables (out, rc, body_content, err, ...) are read
# only inside assert's `eval "$cond"`, which shellcheck can't trace.
# shellcheck disable=SC2034

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly SCRIPT="${ROOT_DIR}/runpod-sniper.sh"
readonly CONFIGS_DIR="${ROOT_DIR}/configs"
# Unique prefix so test configs never collide with real ones and match the
# gitignore pattern (configs/*.conf).
readonly TEST_PREFIX="test-$$-"
TMP_DIR=$(mktemp -d)
readonly TMP_DIR
readonly FAKE_BIN="${TMP_DIR}/bin"
readonly API_BASE="https://rest.runpod.io/v1"
readonly POD_ID_FILE="${TMP_DIR}/runpod_test_pod_id"

# Mutable globals used across tests and the assert helper.
pass=0
fail=0
offline_failed=0

# Live-test state, written by run_live_tests, read by live_cleanup trap.
created_pod_id=""

# Prints the full path of a test config by its short name.
config_path() {
  printf '%s/%s%s.conf' "$CONFIGS_DIR" "$TEST_PREFIX" "$1"
}

# Removes the temp dir and any test-prefixed config files.
# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup() {
  rm -rf "$TMP_DIR"
  rm -f "${CONFIGS_DIR}/${TEST_PREFIX}"*.conf
}

# Evaluates a condition and records pass/fail.
# Globals (written):
#   pass, fail
# Arguments:
#   $1 - message
#   $2 - condition expression (evaluated with `eval`)
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

# Writes a default test config named ${TEST_PREFIX}<name>.conf.
write_config() {
  local name="$1"
  cat > "$(config_path "$name")" <<EOF
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

# Edits a test config in place with sed args; cleans up the .bak file.
# Arguments:
#   $1 - config short name
#   $@ - sed script args
edit_config() {
  local name="$1"
  shift
  local path
  path=$(config_path "$name")
  sed -i.bak "$@" "$path"
  rm -f "${path}.bak"
}

# Writes a fake curl to $FAKE_BIN. It logs the request body to
# $CURL_BODY_LOG (if set) and prints $CURL_RESPONSE_BODY followed by
# $CURL_RESPONSE_CODE, matching the sniper's -w format.
install_fake_curl() {
  mkdir -p "$FAKE_BIN"
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

# Runs the sniper with a test config. Extra env vars must already be
# exported by the caller.
# Arguments:
#   $1 - config short name
#   $2 - stdin source (default /dev/null)
run_script() {
  local cfg="$1" stdin_src="${2:-/dev/null}"
  PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" "$(config_path "$cfg")" \
    < "$stdin_src"
}

# Runs the sniper in the background, waits, then kills it. Combined
# stdout+stderr is written to $TMP_DIR/out.
# Globals (written):
#   exited_before_kill
# Arguments:
#   $1 - config short name
#   $2 - seconds to wait before kill (default 2)
run_sniper_bg() {
  local cfg="$1" wait_secs="${2:-2}" pid
  PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" "$(config_path "$cfg")" \
    > "$TMP_DIR/out" 2>&1 < /dev/null &
  pid=$!
  sleep "$wait_secs"
  exited_before_kill=false
  if ! kill -0 "$pid" 2>/dev/null; then
    exited_before_kill=true
  fi
  pkill -P "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
}

# Cleanup trap for the live-test phase: deletes any pod we created, then
# runs the normal cleanup.
# Globals (read):
#   created_pod_id, API_BASE, AUTH, POD_ID_FILE
# shellcheck disable=SC2317,SC2329  # invoked via trap
live_cleanup() {
  if [[ -n "$created_pod_id" ]]; then
    echo "Cleanup: deleting pod ${created_pod_id}"
    curl -s -X DELETE "${API_BASE}/pods/${created_pod_id}" "${AUTH[@]}" \
      >/dev/null || true
  fi
  rm -f "$POD_ID_FILE"
  cleanup
}

# Prompts on the TTY for a RunPod API key (echoing asterisks).
# Globals (written):
#   RUNPOD_API_KEY
prompt_live_key() {
  local char
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
}

# Runs all offline (stub-curl) tests.
# Globals (read/written):
#   pass, fail, exited_before_kill
run_offline_tests() {
  install_fake_curl
  local out rc

  echo "Test 0: no args -> usage + non-zero exit"
  out="$(PATH="${FAKE_BIN}:${PATH}" env -u CONFIG "$SCRIPT" 2>&1 \
    < /dev/null)"; rc=$?
  assert "exits non-zero" "[[ $rc -ne 0 ]]"
  assert "stderr contains 'Usage:'" "[[ \"\$out\" == *'Usage:'* ]]"

  echo "Test 1: missing config file"
  out="$(PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" /nope/nonexistent-xyz.conf \
    2>&1 < /dev/null)"; rc=$?
  assert "exits non-zero" "[[ $rc -ne 0 ]]"
  assert "stderr mentions the bad path" \
    "[[ \"\$out\" == *'nonexistent-xyz.conf'* ]]"

  echo "Test 2: missing required key"
  write_config "missing-key"
  edit_config "missing-key" '/^GPU_COUNT=/d'
  out="$(run_script missing-key 2>&1)"; rc=$?
  assert "exits non-zero" "[[ $rc -ne 0 ]]"
  assert "stderr names GPU_COUNT" "[[ \"\$out\" == *GPU_COUNT* ]]"

  echo "Test 3: empty API key, non-TTY -> error"
  write_config "no-key"
  edit_config "no-key" 's/^RUNPOD_API_KEY=.*/RUNPOD_API_KEY=""/'
  out="$(run_script no-key 2>&1)"; rc=$?
  assert "exits non-zero" "[[ $rc -ne 0 ]]"
  assert "stderr mentions RUNPOD_API_KEY" \
    "[[ \"\$out\" == *RUNPOD_API_KEY* ]]"

  echo "Test 4: empty API key, TTY prompt"
  if command -v expect >/dev/null 2>&1; then
    local expect_script test_cfg
    expect_script="${TMP_DIR}/prompt.exp"
    test_cfg=$(config_path "no-key")
    cat > "$expect_script" <<EOF
set timeout 10
spawn env PATH=${FAKE_BIN}:\$env(PATH) ${SCRIPT} ${test_cfg}
expect "RUNPOD_API_KEY:"
send "typed-key\r"
expect {
"SUCCESS!" { exit 0 }
timeout    { exit 2 }
eof        { exit 3 }
}
EOF
    expect "$expect_script" >/dev/null 2>&1; rc=$?
    assert "interactive prompt accepts typed key and proceeds to SUCCESS" \
      "[[ $rc -eq 0 ]]"
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
  local body_content
  body_content="$(cat "$CURL_BODY_LOG")"
  assert "body contains GPU from config (NVIDIA TEST GPU)" \
    "[[ \"\$body_content\" == *'NVIDIA TEST GPU'* ]]"
  assert "body does NOT contain old hardcoded L40S" \
    "[[ \"\$body_content\" != *'L40S'* ]]"
  assert "body contains gpuCount from config" \
    "[[ \"\$body_content\" == *'\"gpuCount\": 1'* ]]"

  echo "Test 6b: json_escape handles quotes and backslashes in POD_NAME"
  write_config "escape"
  edit_config "escape" \
    's|^POD_NAME=.*|POD_NAME="has \\"quote\\" and \\\\ back"|'
  export CURL_RESPONSE_BODY='{"id":"pod-xyz"}'
  export CURL_RESPONSE_CODE=200
  export CURL_BODY_LOG="${TMP_DIR}/body_escape.json"
  out="$(run_script escape 2>&1)"; rc=$?
  local esc_body
  esc_body="$(cat "$CURL_BODY_LOG")"
  assert "happy exit on escaped POD_NAME" "[[ $rc -eq 0 ]]"
  assert "POD_NAME quotes are backslash-escaped in body" \
    "[[ \"\$esc_body\" == *'has \\\"quote\\\"'* ]]"
  assert "POD_NAME backslash is doubled in body" \
    "[[ \"\$esc_body\" == *'\\\\'* ]]"

  echo "Test 6c: body includes templateId and networkVolumeId when set"
  write_config "tpl"
  edit_config "tpl" \
    -e 's|^TEMPLATE_ID=.*|TEMPLATE_ID="my-tmpl"|' \
    -e 's|^VOLUME_ID=.*|VOLUME_ID="my-vol"|'
  export CURL_BODY_LOG="${TMP_DIR}/body_tpl.json"
  out="$(run_script tpl 2>&1)"; rc=$?
  local tpl_body
  tpl_body="$(cat "$CURL_BODY_LOG")"
  assert "body contains templateId" \
    "[[ \"\$tpl_body\" == *'\"templateId\": \"my-tmpl\"'* ]]"
  assert "body contains networkVolumeId" \
    "[[ \"\$tpl_body\" == *'\"networkVolumeId\": \"my-vol\"'* ]]"
  assert "body omits volumeInGb when VOLUME_ID is set" \
    "[[ \"\$tpl_body\" != *volumeInGb* ]]"

  echo "Test 6d: pretty_json indents nested JSON (via the real script)"
  write_config "pretty"
  local pretty_body='{"id":"pod-xyz","ports":[8888,22],'
  pretty_body+='"env":{"FOO":"bar","nested":{"x":1}}}'
  export CURL_RESPONSE_BODY="$pretty_body"
  export CURL_RESPONSE_CODE=200
  unset CURL_BODY_LOG
  local pretty_out
  pretty_out="$(run_script pretty 2>&1)"; rc=$?
  assert "happy exit on pretty-print test" "[[ $rc -eq 0 ]]"
  assert "pretty_json indents \"id\" two spaces" \
    "[[ \"\$pretty_out\" == *'  \"id\": \"pod-xyz\"'* ]]"
  assert "pretty_json expands nested object on its own lines" \
    "[[ \"\$pretty_out\" == *'    \"x\": 1'* ]]"
  assert "pretty_json expands array elements onto separate lines" \
    "[[ \"\$pretty_out\" == *'    8888,'* ]]"

  echo "Test 6e: POLL_INTERVAL below 10 triggers minimum-clamp warning"
  write_config "clamp-low"
  edit_config "clamp-low" 's/^POLL_INTERVAL=.*/POLL_INTERVAL=3/'
  export CURL_RESPONSE_BODY='{"id":"pod-xyz"}'
  export CURL_RESPONSE_CODE=200
  unset CURL_BODY_LOG
  local err
  err="$(PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" \
    "$(config_path "clamp-low")" 2>&1 >/dev/null < /dev/null)"; rc=$?
  assert "exits 0 (happy path still completes)" "[[ $rc -eq 0 ]]"
  assert "stderr contains clamp warning" \
    "[[ \"\$err\" == *'POLL_INTERVAL=3'*'minimum'* ]]"

  echo "Test 6f: POLL_INTERVAL >= 10 does NOT warn"
  write_config "clamp-ok"
  edit_config "clamp-ok" 's/^POLL_INTERVAL=.*/POLL_INTERVAL=30/'
  err="$(PATH="${FAKE_BIN}:${PATH}" "$SCRIPT" \
    "$(config_path "clamp-ok")" 2>&1 >/dev/null < /dev/null)"; rc=$?
  assert "exits 0" "[[ $rc -eq 0 ]]"
  assert "stderr does NOT mention minimum clamp" \
    "[[ \"\$err\" != *'minimum'* ]]"

  unset CURL_BODY_LOG

  echo "Test 7: capacity error (400 'no longer any instances') retries"
  write_config "capacity"
  edit_config "capacity" 's/^POLL_INTERVAL=.*/POLL_INTERVAL=1/'
  local cap_body='{"message":"There are no longer any instances available'
  cap_body+=' with the requested specifications."}'
  export CURL_RESPONSE_BODY="$cap_body"
  export CURL_RESPONSE_CODE=400
  unset CURL_BODY_LOG
  run_sniper_bg "capacity"
  out="$(cat "$TMP_DIR/out")"
  assert "script was still running at 2s (retry loop)" \
    "[[ \$exited_before_kill == false ]]"
  assert "did NOT fatal-exit (no 'FATAL' in output)" \
    "[[ \"\$out\" != *'FATAL'* ]]"
  assert "output shows the 400 was received" "[[ \"\$out\" == *'400'* ]]"

  echo "Test 8: non-capacity 400 (e.g. bad request) fails fast"
  write_config "badreq"
  export CURL_RESPONSE_BODY='{"message":"imageName is required"}'
  export CURL_RESPONSE_CODE=400
  out="$(run_script badreq 2>&1)"; rc=$?
  assert "exits non-zero" "[[ $rc -ne 0 ]]"
  assert "stdout contains FATAL" "[[ \"\$out\" == *'FATAL'* ]]"
  assert "stdout echoes the error body" \
    "[[ \"\$out\" == *'imageName is required'* ]]"

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
  edit_config "fivexx" 's/^POLL_INTERVAL=.*/POLL_INTERVAL=1/'
  export CURL_RESPONSE_BODY='{"message":"internal server error"}'
  export CURL_RESPONSE_CODE=500
  run_sniper_bg "fivexx"
  out="$(cat "$TMP_DIR/out")"
  assert "script was still running at 2s (5xx retry loop)" \
    "[[ \$exited_before_kill == false ]]"
  assert "did NOT fatal-exit on 500" "[[ \"\$out\" != *'FATAL'* ]]"

  unset CURL_RESPONSE_BODY CURL_RESPONSE_CODE

  echo "Test 11: gitignore rules"
  write_config "gitignore-check"
  local rel_cfg
  rel_cfg="configs/${TEST_PREFIX}gitignore-check.conf"
  git -C "$ROOT_DIR" check-ignore -q "$rel_cfg"; rc=$?
  assert "${rel_cfg} is ignored" "[[ $rc -eq 0 ]]"
  git -C "$ROOT_DIR" check-ignore -q "configs/example.conf"; rc=$?
  assert "configs/example.conf is NOT ignored" "[[ $rc -ne 0 ]]"

  echo
  echo "-----------------------------"
  echo " Offline: ${pass} passed, ${fail} failed"
  echo "-----------------------------"
}

# Runs the live create+delete round-trip against the real RunPod API.
# Expects RUNPOD_API_KEY set and configs/example.conf already sourced.
# Exits with an appropriate status.
# Globals (read/written):
#   RUNPOD_API_KEY, GPU_TYPES, IMAGE, GPU_COUNT, CONTAINER_DISK,
#   VOLUME_DISK, CLOUD_TYPE, created_pod_id, pass, fail, offline_failed
run_live_tests() {
  AUTH=(-H "Authorization: Bearer ${RUNPOD_API_KEY}")
  trap live_cleanup EXIT

  local code resp resp_body first_gpu body deleted_pod_id

  echo "Live test 8: GET /v1/pods auth smoke test"
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    "${API_BASE}/pods" "${AUTH[@]}")
  assert "GET /v1/pods returns 2xx" "[[ \$code =~ ^2 ]]"
  if [[ ! $code =~ ^2 ]]; then
    echo "Auth failed; aborting before create."
    exit 1
  fi

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
  resp=$(curl -s -w $'\n%{http_code}' -X POST "${API_BASE}/pods" \
    "${AUTH[@]}" -H 'Content-Type: application/json' -d "$body")
  code=$(echo "$resp" | tail -1)
  resp_body=$(echo "$resp" | sed '$d')
  if [[ ! $code =~ ^20 ]]; then
    echo "  [SKIP] (create failed: $code - no capacity for ${first_gpu})"
    echo "  response: $(echo "$resp_body" | head -c 200)"
    exit $(( offline_failed > 0 ? 1 : 0 ))
  fi
  created_pod_id=$(echo "$resp_body" \
    | grep -o '"id":"[^"]*"' \
    | head -1 \
    | cut -d'"' -f4)
  echo "$created_pod_id" > "$POD_ID_FILE"
  assert "POST returned non-empty pod id" "[[ -n \"\$created_pod_id\" ]]"

  code=$(curl -s -o /dev/null -w '%{http_code}' \
    "${API_BASE}/pods/${created_pod_id}" "${AUTH[@]}")
  assert "GET /v1/pods/{id} returns 200 after create" \
    "[[ \$code == 200 ]]"

  code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    "${API_BASE}/pods/${created_pod_id}" "${AUTH[@]}")
  assert "DELETE returns 2xx" "[[ \$code =~ ^2 ]]"
  deleted_pod_id="$created_pod_id"
  created_pod_id=""  # disarm cleanup

  # Brief delay then confirm it's gone.
  sleep 2
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    "${API_BASE}/pods/${deleted_pod_id}" "${AUTH[@]}")
  assert "GET /v1/pods/{id} returns 404 after delete" \
    "[[ \$code == 404 ]]"

  echo
  echo "-----------------------------"
  echo " Live: ${pass} passed, ${fail} failed"
  echo "-----------------------------"
  exit $(( (fail + offline_failed) > 0 ? 1 : 0 ))
}

# Entry point.
main() {
  trap cleanup EXIT

  run_offline_tests
  offline_failed=$fail

  # Live section: always prompt for an API key; empty input skips live.
  local live_config="${ROOT_DIR}/configs/example.conf"
  if [[ ! -f "$live_config" ]]; then
    echo "Error: $live_config not found" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$live_config"

  if [[ ! -t 0 ]]; then
    echo
    echo "Skipping live tests (no TTY for API key prompt)."
    exit $(( offline_failed > 0 ? 1 : 0 ))
  fi

  echo
  prompt_live_key

  if [[ -z "$RUNPOD_API_KEY" ]]; then
    echo "Skipped live tests."
    exit $(( offline_failed > 0 ? 1 : 0 ))
  fi

  # Reset counters so the live summary is standalone.
  pass=0
  fail=0

  run_live_tests
}

main "$@"
