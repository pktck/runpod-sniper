#!/usr/bin/env bash
#
# runpod-sniper.sh - Deploy a RunPod GPU pod, retrying until one is available.
#
# Usage:
#   ./runpod-sniper.sh <config_file>
#
# Also accepts CONFIG=<config_file> as an environment variable.

set -euo pipefail

readonly API="https://rest.runpod.io/v1/pods"
readonly MIN_POLL_INTERVAL=10
readonly -a REQUIRED_KEYS=(
  RUNPOD_API_KEY GPU_TYPES GPU_COUNT CLOUD_TYPE IMAGE
  CONTAINER_DISK VOLUME_DISK POLL_INTERVAL TEMPLATE_ID
  VOLUME_ID POD_NAME NTFY_TOPIC MACOS_NOTIFY
)

# Prints usage to stderr and exits non-zero.
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <config_file>

Attempts to deploy a RunPod GPU using settings from the given config file,
until one is available.

Also accepts CONFIG=<config_file> as an environment variable.

Copy configs/example.conf to configs/<name>.conf, edit it, then:
    ./$(basename "$0") configs/<name>.conf
EOF
  exit 1
}

# Prints the pod name: POD_NAME if set, else a timestamp-suffixed default.
# Globals:
#   POD_NAME (read)
gen_pod_name() {
  if [[ -n "$POD_NAME" ]]; then
    printf '%s' "$POD_NAME"
  else
    local ts
    ts=$(date '+%a-%b-%d--%I-%M-%p' | tr '[:upper:]' '[:lower:]')
    printf 'launched-%s' "$ts"
  fi
}

# Escapes a string for embedding in a JSON value.
# Arguments:
#   $1 - string to escape
# Outputs:
#   Escaped string written to stdout.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Percent-encodes a string for use in a URL path segment.
url_encode() {
  local s="$1" out="" i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# Reads JSON on stdin and writes an indented version to stdout.
pretty_json() {
  awk '
  BEGIN { indent = 0; in_str = 0; esc = 0 }
  function pad(n,   s, i) { s=""; for (i=0; i<n; i++) s = s "  "; return s }
  {
    line = $0
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (in_str) {
        printf "%s", c
        if (esc) { esc = 0; continue }
        if (c == "\\") { esc = 1; continue }
        if (c == "\"") in_str = 0
        continue
      }
      if (c == "\"") { printf "%s", c; in_str = 1; continue }
      if (c == " " || c == "\t") continue
      if (c == "{" || c == "[") {
        indent++
        printf "%s\n%s", c, pad(indent)
      } else if (c == "}" || c == "]") {
        indent--
        printf "\n%s%s", pad(indent), c
      } else if (c == ",") {
        printf ",\n%s", pad(indent)
      } else if (c == ":") {
        printf ": "
      } else {
        printf "%s", c
      }
    }
  }
  END { printf "\n" }
  '
}

# Extracts the first JSON "message" field value from stdin and prints it.
extract_message() {
  awk '
  {
    s = $0
    n = index(s, "\"message\"")
    if (n == 0) next
    s = substr(s, n + length("\"message\""))
    sub(/^[[:space:]]*:[[:space:]]*"/, "", s)
    out = ""; esc = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (esc) { out = out c; esc = 0; continue }
      if (c == "\\") { esc = 1; continue }
      if (c == "\"") break
      out = out c
    }
    print out
    exit
  }
  '
}

# Sends ntfy and/or macOS notifications for a successful deployment.
# Globals:
#   NTFY_TOPIC (read)
#   MACOS_NOTIFY (read)
# Arguments:
#   $1 - GPU type
#   $2 - pod ID
notify_success() {
  local gpu="$1" pod_id="$2"
  if [[ -n "$NTFY_TOPIC" ]]; then
    curl -s \
      -d "RunPod ${gpu} grabbed! Pod: ${pod_id}" \
      "https://ntfy.sh/$(url_encode "$NTFY_TOPIC")" \
      >/dev/null || true
  fi
  if [[ "$MACOS_NOTIFY" == "true" ]]; then
    osascript -e \
      "display notification \"RunPod ${gpu} grabbed!\" with title \"RunPod\"" \
      || true
  fi
}

# Prompts on the TTY for RUNPOD_API_KEY, echoing asterisks.
# Globals:
#   RUNPOD_API_KEY (set)
prompt_api_key() {
  local char
  printf 'RUNPOD_API_KEY: '
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

# Sources the config file, validates required keys, clamps POLL_INTERVAL,
# and resolves RUNPOD_API_KEY via prompt if needed. Exits on failure.
# Globals:
#   REQUIRED_KEYS (read)
#   MIN_POLL_INTERVAL (read)
#   POLL_INTERVAL (may be overwritten)
#   RUNPOD_API_KEY (may be set)
# Arguments:
#   $1 - path to config file
load_config() {
  local config_path="$1"
  local -a missing=()
  local key

  if [[ ! -f "$config_path" ]]; then
    echo "Error: config file not found: ${config_path}" >&2
    echo "Copy configs/example.conf to a new file, edit it, and" >&2
    echo "pass its path as the first arg." >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$config_path"

  for key in "${REQUIRED_KEYS[@]}"; do
    if ! declare -p "$key" &>/dev/null; then
      missing+=("$key")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    printf 'Error: config "%s" is missing required key(s): %s\n' \
      "$config_path" "${missing[*]}" >&2
    exit 1
  fi

  if (( POLL_INTERVAL < MIN_POLL_INTERVAL )); then
    echo "Warning: POLL_INTERVAL=${POLL_INTERVAL} is below the minimum" \
         "of ${MIN_POLL_INTERVAL}s; using ${MIN_POLL_INTERVAL}s." >&2
    POLL_INTERVAL="$MIN_POLL_INTERVAL"
  fi

  if [[ -z "$RUNPOD_API_KEY" ]]; then
    if [[ -t 0 ]]; then
      prompt_api_key
    fi
    if [[ -z "$RUNPOD_API_KEY" ]]; then
      if [[ -t 0 ]]; then
        echo "Error: no RUNPOD_API_KEY entered." >&2
      else
        echo "Error: RUNPOD_API_KEY is blank in config," >&2
        echo "and no TTY available to prompt." >&2
      fi
      echo "Get a key at https://www.runpod.io/console/user/settings" >&2
      exit 1
    fi
  fi
}

# Builds the JSON pod-create request body for a given GPU + cloud pair.
# Globals:
#   IMAGE, GPU_COUNT, CONTAINER_DISK, TEMPLATE_ID, VOLUME_ID, VOLUME_DISK
# Arguments:
#   $1 - GPU type
#   $2 - cloud type
# Outputs:
#   JSON body written to stdout.
build_body() {
  local gpu="$1" cloud="$2"
  local -a fields=(
    "\"name\": \"$(json_escape "$(gen_pod_name)")\""
    "\"imageName\": \"$(json_escape "$IMAGE")\""
    "\"gpuTypeIds\": [\"$(json_escape "$gpu")\"]"
    "\"gpuCount\": ${GPU_COUNT}"
    "\"containerDiskInGb\": ${CONTAINER_DISK}"
    "\"cloudType\": \"$(json_escape "$cloud")\""
  )
  if [[ -n "$TEMPLATE_ID" ]]; then
    fields+=("\"templateId\": \"$(json_escape "$TEMPLATE_ID")\"")
  fi
  if [[ -n "$VOLUME_ID" ]]; then
    fields+=("\"networkVolumeId\": \"$(json_escape "$VOLUME_ID")\"")
  else
    fields+=("\"volumeInGb\": ${VOLUME_DISK}")
  fi
  # Join fields[] with ',' via IFS in the subshell expansion.
  printf '{ %s }' "$(IFS=,; echo "${fields[*]}")"
}

# Prints a human-readable message for a bare HTTP code.
http_code_message() {
  case "$1" in
    400) echo "Bad Request" ;;
    401) echo "Unauthorized (check RUNPOD_API_KEY)" ;;
    403) echo "Forbidden" ;;
    404) echo "Not Found" ;;
    408) echo "Request Timeout" ;;
    409) echo "Conflict" ;;
    413) echo "Payload Too Large" ;;
    422) echo "Unprocessable Entity" ;;
    500) echo "Internal Server Error" ;;
    502) echo "Bad Gateway" ;;
    503) echo "Service Unavailable" ;;
    504) echo "Gateway Timeout" ;;
    000) echo "No response (network error)" ;;
    *)   echo "(no response body)" ;;
  esac
}

# Returns 0 if the given HTTP code / response body is a retryable capacity
# or transient error; 1 otherwise.
is_capacity_error() {
  local http_code="$1" resp_body="$2"
  if [[ "$http_code" == "400" ]] \
     && echo "$resp_body" | grep -qi \
          'no longer any instances available'; then
    return 0
  fi
  if [[ "$http_code" == "429" || "$http_code" == "000" \
        || "$http_code" =~ ^5 ]]; then
    return 0
  fi
  return 1
}

# Prints a FATAL banner and exits non-zero.
# Arguments:
#   $1 - HTTP code
#   $2 - response body
fatal_error() {
  local http_code="$1" resp_body="$2" err_msg=""
  err_msg=$(echo "$resp_body" | extract_message)
  if [[ -z "$err_msg" ]]; then
    if [[ -n "$resp_body" ]]; then
      err_msg="$resp_body"
    else
      err_msg=$(http_code_message "$http_code")
    fi
  fi
  echo ""
  echo "========================================="
  echo " FATAL (HTTP ${http_code}): ${err_msg}"
  echo "========================================="
  exit 1
}

# Prints a SUCCESS banner with pod details and fires notifications.
# Arguments:
#   $1 - GPU type
#   $2 - cloud type
#   $3 - response body
report_success() {
  local gpu="$1" cloud="$2" resp_body="$3" pod_id
  pod_id=$(echo "$resp_body" \
    | grep -o '"id":"[^"]*"' \
    | head -1 \
    | cut -d'"' -f4)
  echo ""
  echo "========================================="
  echo " SUCCESS! Pod deployed."
  echo " GPU:    ${gpu}"
  echo " Cloud:  ${cloud}"
  echo " Pod ID: ${pod_id}"
  echo " Body:"
  echo "$resp_body" | pretty_json
  echo "========================================="
  notify_success "$gpu" "$pod_id"
}

# Makes one POST attempt. Exits 0 on success, 1 on fatal error; prints a
# one-line retry note and returns 0 for retryable capacity errors.
# Globals:
#   API, RUNPOD_API_KEY (read)
# Arguments:
#   $1 - GPU type
#   $2 - cloud type
#   $3 - attempt number
try_attempt() {
  local gpu="$1" cloud="$2" attempt="$3"
  local body response http_code resp_body
  printf '[%s] Attempt #%d - trying %s (%s)...\n' \
    "$(date '+%H:%M:%S')" "$attempt" "$gpu" "$cloud"
  body=$(build_body "$gpu" "$cloud")
  response=$(curl -sS -w "\n%{http_code}" \
    -X POST "$API" \
    -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body")
  http_code=$(echo "$response" | tail -1)
  resp_body=$(echo "$response" | sed '$d')
  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    report_success "$gpu" "$cloud" "$resp_body"
    exit 0
  fi
  if is_capacity_error "$http_code" "$resp_body"; then
    echo "  -> ${http_code}: $(echo "$resp_body" | head -c 200)"
    return 0
  fi
  fatal_error "$http_code" "$resp_body"
}

# Script entry point.
main() {
  local config_path="${1:-${CONFIG:-}}"
  if [[ -z "$config_path" ]]; then
    usage
  fi
  echo running with $config_path

  load_config "$config_path"

  local -a cloud_types=()
  if [[ "$CLOUD_TYPE" == "ALL" ]]; then
    cloud_types=("SECURE" "COMMUNITY")
  else
    cloud_types=("$CLOUD_TYPE")
  fi

  local attempt=0 gpu cloud
  while true; do
    attempt=$((attempt + 1))
    for gpu in "${GPU_TYPES[@]}"; do
      for cloud in "${cloud_types[@]}"; do
        try_attempt "$gpu" "$cloud" "$attempt"
      done
    done
    echo "  Waiting ${POLL_INTERVAL}s before next attempt..."
    sleep "$POLL_INTERVAL"
  done
}

main "$@"
