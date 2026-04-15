#!/usr/bin/env bash
# runpod_sniper.sh — Keep trying to deploy a pod until a GPU is available.
#
# Usage:
#   export RUNPOD_API_KEY="rpa_..."
#   bash runpod_sniper.sh
#
# Optional: set POLL_INTERVAL (seconds, default 60), TEMPLATE_ID, VOLUME_ID

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────
if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
    echo "Error: RUNPOD_API_KEY is not set." >&2
    echo "Export your RunPod API key before running, e.g.:" >&2
    echo "    export RUNPOD_API_KEY=\"rpa_...\"" >&2
    echo "Get a key at https://www.runpod.io/console/user/settings" >&2
    exit 1
fi
POLL_INTERVAL="${POLL_INTERVAL:-60}"          # seconds between attempts
POD_NAME="${POD_NAME:-launched-$(date '+%a-%b-%d--%I-%M-%p' | tr '[:upper:]' '[:lower:]')}"
TEMPLATE_ID="${TEMPLATE_ID:-}"                # runpod-torch-v240 — grab ID from console
VOLUME_ID="${VOLUME_ID:-}"                    # optional: network volume ID
CONTAINER_DISK="${CONTAINER_DISK:-50}"        # GB
VOLUME_DISK="${VOLUME_DISK:-256}"             # GB (only if no network volume)
CLOUD_TYPE="${CLOUD_TYPE:-SECURE}"            # ALL, COMMUNITY, SECURE
IMAGE="${IMAGE:-runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404}"

# GPU types to try, in priority order
GPU_TYPES=("NVIDIA L40S" "NVIDIA RTX 6000 Ada Generation")

# The API only accepts SECURE or COMMUNITY; expand ALL into both.
if [[ "$CLOUD_TYPE" == "ALL" ]]; then
    CLOUD_TYPES=("SECURE" "COMMUNITY")
else
    CLOUD_TYPES=("$CLOUD_TYPE")
fi
# ─────────────────────────────────────────────────────────────────────────

API="https://rest.runpod.io/v1/pods"

attempt=0
while true; do
    attempt=$((attempt + 1))

    for gpu in "${GPU_TYPES[@]}"; do
        for cloud in "${CLOUD_TYPES[@]}"; do
            echo "[$(date '+%H:%M:%S')] Attempt #${attempt} — trying ${gpu} (${cloud})..."

            # Build the request body
            if [[ -n "$TEMPLATE_ID" && -n "$VOLUME_ID" ]]; then
                body=$(cat <<EOF
{
  "name": "${POD_NAME}",
  "imageName": "${IMAGE}",
  "gpuTypeIds": ["${gpu}"],
  "gpuCount": 1,
  "containerDiskInGb": ${CONTAINER_DISK},
  "cloudType": "${cloud}",
  "templateId": "${TEMPLATE_ID}",
  "networkVolumeId": "${VOLUME_ID}"
}
EOF
)
            elif [[ -n "$TEMPLATE_ID" ]]; then
                body=$(cat <<EOF
{
  "name": "${POD_NAME}",
  "imageName": "${IMAGE}",
  "gpuTypeIds": ["${gpu}"],
  "gpuCount": 1,
  "containerDiskInGb": ${CONTAINER_DISK},
  "volumeInGb": ${VOLUME_DISK},
  "cloudType": "${cloud}",
  "templateId": "${TEMPLATE_ID}"
}
EOF
)
            elif [[ -n "$VOLUME_ID" ]]; then
                body=$(cat <<EOF
{
  "name": "${POD_NAME}",
  "imageName": "${IMAGE}",
  "gpuTypeIds": ["${gpu}"],
  "gpuCount": 1,
  "containerDiskInGb": ${CONTAINER_DISK},
  "cloudType": "${cloud}",
  "networkVolumeId": "${VOLUME_ID}"
}
EOF
)
            else
                body=$(cat <<EOF
{
  "name": "${POD_NAME}",
  "imageName": "${IMAGE}",
  "gpuTypeIds": ["${gpu}"],
  "gpuCount": 1,
  "containerDiskInGb": ${CONTAINER_DISK},
  "volumeInGb": ${VOLUME_DISK},
  "cloudType": "${cloud}"
}
EOF
)
            fi

            response=$(curl -s -w "\n%{http_code}" \
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
                echo " Body:   ${resp_body}"
                echo "========================================="

                # Optional: send a notification (uncomment as needed)
                # curl -s -d "RunPod ${gpu} grabbed! Pod: ${pod_id}" ntfy.sh/YOUR_TOPIC
                # osascript -e 'display notification "'"RunPod ${gpu} grabbed!"'" with title "RunPod"'

                exit 0
            else
                echo "  → ${http_code}: $(echo "$resp_body" | head -c 120)"
            fi
        done
    done

    echo "  Waiting ${POLL_INTERVAL}s before next attempt..."
    sleep "$POLL_INTERVAL"
done