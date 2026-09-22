#!/bin/bash
set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
ENV_FILE="$PROJECT/.bjob/daaam-cosmos-${SLURM_JOB_ID:-manual}.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSMOS_URL_FILE="${COSMOS_URL_FILE:-$PROJECT/.cosmos_url.${SLURM_JOB_ID:-manual}}"

set +e +u
[[ -f ~/.bashrc ]] && source ~/.bashrc
set -euo pipefail
source "$PROFILE_DIR/../cosmos-reason2/setup.sh"

if [[ -s "$PROJECT/.cosmos_url" ]]; then
    cp "$PROJECT/.cosmos_url" "$COSMOS_URL_FILE"
    echo "Cosmos URL copied to $COSMOS_URL_FILE"
fi

echo ""
if [[ "${DAAAM_COSMOS_SUPERVISE:-0}" == "1" || ! -t 0 ]]; then
    echo "Cosmos supervisor is active. This process will stay alive while vLLM is healthy."
    echo "Health: http://127.0.0.1:8000/health"
    while true; do
        if [[ -n "${COSMOS_VLLM_PID:-}" ]] && ! kill -0 "$COSMOS_VLLM_PID" 2>/dev/null; then
            echo "ERROR: vLLM process $COSMOS_VLLM_PID exited. Check ${COSMOS_LOG:-$PROJECT/.cache/cosmos-reason2-vllm.log}"
            exit 1
        fi
        if ! curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1; then
            echo "ERROR: Cosmos health check failed. Check ${COSMOS_LOG:-$PROJECT/.cache/cosmos-reason2-vllm.log}"
            exit 1
        fi
        sleep "${DAAAM_COSMOS_HEALTH_INTERVAL_SECONDS:-15}"
    done
fi

echo "Cosmos window is ready. Keep this window open while DAAAM is running."
exec bash -i
