#!/usr/bin/env bash
# runpod-sniper.sh - Attempts to deploy a RunPod GPU pod until one is available.
#
# Usage:
#   ./runpod-sniper.sh <config_file>
#
# Also accepts CONFIG=<config_file> as an environment variable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

CONFIG_PATH="${1:-${CONFIG:-}}"
if [[ -z "$CONFIG_PATH" ]]; then
    usage
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "Error: config file not found: ${CONFIG_PATH}" >&2
    echo "Copy configs/example.conf to a new file, edit it, and pass its path as the first arg." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_PATH"

REQUIRED_KEYS=(RUNPOD_API_KEY GPU_TYPES GPU_COUNT CLOUD_TYPE IMAGE CONTAINER_DISK VOLUME_DISK POLL_INTERVAL TEMPLATE_ID VOLUME_ID POD_NAME NTFY_TOPIC MACOS_NOTIFY)
missing=()
for key in "${REQUIRED_KEYS[@]}"; do
    if ! declare -p "$key" &>/dev/null; then
        missing+=("$key")
    fi
done
if (( ${#missing[@]} > 0 )); then
    echo "Error: config \"${CONFIG_PATH}\" is missing required key(s): ${missing[*]}" >&2
    exit 1
fi

MIN_POLL_INTERVAL=10
if (( POLL_INTERVAL < MIN_POLL_INTERVAL )); then
    echo "Warning: POLL_INTERVAL=${POLL_INTERVAL} is below the minimum of ${MIN_POLL_INTERVAL}s; using ${MIN_POLL_INTERVAL}s." >&2
    POLL_INTERVAL=$MIN_POLL_INTERVAL
fi

if [[ -z "$RUNPOD_API_KEY" ]]; then
    if [[ -t 0 ]]; then
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
    fi
    if [[ -z "$RUNPOD_API_KEY" ]]; then
        if [[ -t 0 ]]; then
            echo "Error: no RUNPOD_API_KEY entered." >&2
        else
            echo "Error: RUNPOD_API_KEY is blank in config and no TTY available to prompt." >&2
        fi
        echo "Get a key at https://www.runpod.io/console/user/settings" >&2
        exit 1
    fi
fi

gen_pod_name() {
    if [[ -n "$POD_NAME" ]]; then
        printf '%s' "$POD_NAME"
    else
        printf 'launched-%s' "$(date '+%a-%b-%d--%I-%M-%p' | tr '[:upper:]' '[:lower:]')"
    fi
}

if [[ "$CLOUD_TYPE" == "ALL" ]]; then
    CLOUD_TYPES=("SECURE" "COMMUNITY")
else
    CLOUD_TYPES=("$CLOUD_TYPE")
fi

API="https://rest.runpod.io/v1/pods"

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

notify_success() {
    local gpu="$1" pod_id="$2"
    if [[ -n "$NTFY_TOPIC" ]]; then
        curl -s -d "RunPod ${gpu} grabbed! Pod: ${pod_id}" "https://ntfy.sh/$(url_encode "$NTFY_TOPIC")" >/dev/null || true
    fi
    if [[ "$MACOS_NOTIFY" == "true" ]]; then
        osascript -e "display notification \"RunPod ${gpu} grabbed!\" with title \"RunPod\"" || true
    fi
}

attempt=0
while true; do
    attempt=$((attempt + 1))

    for gpu in "${GPU_TYPES[@]}"; do
        for cloud in "${CLOUD_TYPES[@]}"; do
            echo "[$(date '+%H:%M:%S')] Attempt #${attempt} - trying ${gpu} (${cloud})..."

            fields=(
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
            # Join fields[] with ',' by setting IFS for the subshell's "${fields[*]}" expansion.
            body="{ $(IFS=,; echo "${fields[*]}") }"

            response=$(curl -sS -w "\n%{http_code}" \
                -X POST "$API" \
                -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
                -H "Content-Type: application/json" \
                -d "$body")

            http_code=$(echo "$response" | tail -1)
            resp_body=$(echo "$response" | sed '$d')

            if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
                pod_id=$(echo "$resp_body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
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

                exit 0
            else
                is_capacity=false
                if [[ "$http_code" == "400" ]] && echo "$resp_body" | grep -qi 'no longer any instances available'; then
                    is_capacity=true
                fi
                if [[ "$http_code" == "429" || "$http_code" == "000" || "$http_code" =~ ^5 ]]; then
                    is_capacity=true
                fi
                if [[ "$is_capacity" == "true" ]]; then
                    echo "  -> ${http_code}: $(echo "$resp_body" | head -c 200)"
                else
                    err_msg=$(echo "$resp_body" | awk '
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
                    ')
                    if [[ -z "$err_msg" ]]; then
                        if [[ -n "$resp_body" ]]; then
                            err_msg="$resp_body"
                        else
                            case "$http_code" in
                                400) err_msg="Bad Request" ;;
                                401) err_msg="Unauthorized (check RUNPOD_API_KEY)" ;;
                                403) err_msg="Forbidden" ;;
                                404) err_msg="Not Found" ;;
                                408) err_msg="Request Timeout" ;;
                                409) err_msg="Conflict" ;;
                                413) err_msg="Payload Too Large" ;;
                                422) err_msg="Unprocessable Entity" ;;
                                500) err_msg="Internal Server Error" ;;
                                502) err_msg="Bad Gateway" ;;
                                503) err_msg="Service Unavailable" ;;
                                504) err_msg="Gateway Timeout" ;;
                                000) err_msg="No response (network error)" ;;
                                *)   err_msg="(no response body)" ;;
                            esac
                        fi
                    fi
                    echo ""
                    echo "========================================="
                    echo " FATAL (HTTP ${http_code}): ${err_msg}"
                    echo "========================================="
                    exit 1
                fi
            fi
        done
    done

    echo "  Waiting ${POLL_INTERVAL}s before next attempt..."
    sleep "$POLL_INTERVAL"
done
