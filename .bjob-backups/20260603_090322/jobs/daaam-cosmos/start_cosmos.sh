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
echo "Cosmos window is ready. Keep this window open while DAAAM is running."
exec bash -i
