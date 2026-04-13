# runpod-sniper

A bash script that repeatedly attempts to deploy a RunPod GPU pod until one is available. It cycles through a prioritized list of GPU types (and cloud tiers) on each attempt, waiting between rounds, and exits as soon as a pod is successfully created.

## Setup

Export your RunPod API key before running:

```bash
export RUNPOD_API_KEY="rpa_..."
```

Get a key at https://www.runpod.io/console/user/settings.

## Usage

```bash
./sniper.sh
```

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `RUNPOD_API_KEY` | *(required)* | Your RunPod API key. |
| `POLL_INTERVAL` | `60` | Seconds to wait between retry rounds. |
| `POD_NAME` | `launched-<timestamp>` | Name for the created pod. |
| `TEMPLATE_ID` | *(unset)* | Optional RunPod template ID to use. |
| `VOLUME_ID` | *(unset)* | Optional network volume ID to attach. |
| `CONTAINER_DISK` | `50` | Container disk size in GB. |
| `VOLUME_DISK` | `256` | Volume disk size in GB (ignored if `VOLUME_ID` is set). |
| `CLOUD_TYPE` | `SECURE` | `SECURE`, `COMMUNITY`, or `ALL` (tries both). |
| `IMAGE` | `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404` | Container image to run. |

GPU priority order is defined in the `GPU_TYPES` array at the top of the script — edit it to change which GPUs are attempted.
