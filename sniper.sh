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
RUNPOD_API_KEY="${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"          # seconds between attempts
POD_NAME="${POD_NAME:-gr00t-dev}"
TEMPLATE_ID="${TEMPLATE_ID:-}"                # optional: your template ID
VOLUME_ID="${VOLUME_ID:-}"                    # optional: network volume ID
CONTAINER_DISK="${CONTAINER_DISK:-50}"        # GB
VOLUME_DISK="${VOLUME_DISK:-100}"             # GB (only if no network volume)
CLOUD_TYPE="${CLOUD_TYPE:-ALL}"               # ALL, COMMUNITY, SECURE
IMAGE="${IMAGE:-runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04}"

# GPU types to try, in priority order
GPU_TYPES=("NVIDIA L40S" "NVIDIA RTX 6000 Ada Generation")
# ─────────────────────────────────────────────────────────────────────────

API="https://rest.runpod.io/v1/pods"

attempt=0
while true; do
    attempt=$((attempt + 1))

    for gpu in "${GPU_TYPES[@]}"; do
        echo "[$(date '+%H:%M:%S')] Attempt #${attempt} — trying ${gpu}..."

        # Build the request body
        body=$(cat <<EOF
{
  "name": "${POD_NAME}",
  "imageName": "${IMAGE}",
  "gpuTypeId": "${gpu}",
  "gpuCount": 1,
  "containerDiskInGb": ${CONTAINER_DISK},
  "cloudType": "${CLOUD_TYPE}"
EOF
)
        # Add optional fields
        if [[ -n "$TEMPLATE_ID" ]]; then
            body=$(echo "$body" | sed '$ s/$/,/')
            body+=$'\n  "templateId": "'"${TEMPLATE_ID}"'"'
        fi
        if [[ -n "$VOLUME_ID" ]]; then
            body=$(echo "$body" | sed '$ s/$/,/')
            body+=$'\n  "networkVolumeId": "'"${VOLUME_ID}"'"'
        else
            body=$(echo "$body" | sed '$ s/$/,/')
            body+=$'\n  "volumeInGb": '"${VOLUME_DISK}"
        fi
        body+=$'\n}'

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
            echo " Pod ID: ${pod_id}"
            echo " Body:   ${resp_body}"
            echo "========================================="

            # Optional: send a notification (uncomment one)
            curl -s -d "RunPod ${gpu} grabbed! Pod: ${pod_id}" ntfy.sh/tellme-whatsup
            osascript -e "display notification \"${gpu} grabbed!\" with title \"RunPod\""

            exit 0
        else
            echo "  → ${http_code}: $(echo "$resp_body" | head -c 120)"
        fi
    done

    echo "  Waiting ${POLL_INTERVAL}s before next attempt..."
    sleep "$POLL_INTERVAL"
done
