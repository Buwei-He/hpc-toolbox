#!/bin/bash
# Cosmos-Reason2 vLLM server — dedicated sbatch allocation (smart-auto mode).
# Submitted by bjob; expects DAAAM_AUTO_STATE_DIR set via --export.
# Runs for the full allocation (4 h) supervising vLLM health.

set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
# SLURM copies scripts to a temp dir, so BASH_SOURCE[0] won't point here.
# bjob passes the real path via --export=...,DAAAM_PROFILE_DIR=...
PROFILE_DIR="${DAAAM_PROFILE_DIR:?DAAAM_PROFILE_DIR must be set via --export}"

STATE_DIR="${DAAAM_AUTO_STATE_DIR:-$PROJECT/.cache/daaam-cosmos-auto/cosmos_${SLURM_JOB_ID:-manual}}"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

# Register state dir so 'bjob logs <jobid>' can find it
mkdir -p "$PROJECT/.bjob"
printf '%s\n' "$STATE_DIR" > "$PROJECT/.bjob/smart-auto-session.${SLURM_JOB_ID:-manual}"

cd "$PROJECT"
set +e +u; [[ -f ~/.bashrc ]] && source ~/.bashrc; set -euo pipefail

NODE="${SLURMD_NODENAME:-$(hostname -s)}"
printf '[%s] Cosmos server job %s starting on %s\n' "$(date -Is)" "${SLURM_JOB_ID:-manual}" "$NODE"
printf '  State: %s\n\n' "$STATE_DIR"

# Direct vLLM log into the shared state dir
export COSMOS_LOG="$LOG_DIR/cosmos-reason2-vllm.log"

# Start vLLM (source writes $PROJECT/.cosmos_url and sets COSMOS_VLLM_PID)
source "$PROFILE_DIR/../cosmos-reason2/setup.sh"

# Copy URL to state dir so DAAAM workers on other nodes can find it
if [[ -s "$PROJECT/.cosmos_url" ]]; then
    cp "$PROJECT/.cosmos_url" "$STATE_DIR/cosmos_url"
    printf '[%s] Cosmos URL: %s\n' "$(date -Is)" "$(cat "$STATE_DIR/cosmos_url")"
fi

# Supervisor — stay alive until the vLLM process exits or becomes unhealthy
printf '[%s] Cosmos supervisor running (health check every 15 s).\n' "$(date -Is)"
while true; do
    if [[ -n "${COSMOS_VLLM_PID:-}" ]] && ! kill -0 "$COSMOS_VLLM_PID" 2>/dev/null; then
        printf '[%s] ERROR: vLLM process %s exited. Check %s\n' \
            "$(date -Is)" "$COSMOS_VLLM_PID" "$COSMOS_LOG"
        exit 1
    fi
    if ! curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1; then
        printf '[%s] ERROR: Cosmos health check failed. Check %s\n' "$(date -Is)" "$COSMOS_LOG"
        exit 1
    fi
    sleep "${DAAAM_COSMOS_HEALTH_INTERVAL_SECONDS:-15}"
done
