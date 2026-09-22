#!/bin/bash
set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
ENV_FILE="$PROJECT/.bjob/daaam-cosmos-${SLURM_JOB_ID:-manual}.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

set +e +u
[[ -f ~/.bashrc ]] && source ~/.bashrc
set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${SLURMD_NODENAME:-$(hostname -s)}"
STATE_DIR="${DAAAM_AUTO_STATE_DIR:-$PROJECT/.cache/daaam-cosmos-auto/${SLURM_JOB_ID:-manual}}"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

rm -f "$STATE_DIR/auto.stop" "$STATE_DIR/auto.done"
printf '%s\n' "auto-all" > "$STATE_DIR/mode"

cosmos_pid=""
bag_pid=""
launch_status=0
bag_status=0

kill_tree() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0
    kill "-$pid" 2>/dev/null || true
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
}

cleanup() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        touch "$STATE_DIR/auto.stop" 2>/dev/null || true
    fi
    kill_tree "$bag_pid"
    kill_tree "$cosmos_pid"
}
trap cleanup EXIT INT TERM

printf '\nDAAAM + Cosmos full automation on %s\n' "$NODE"
printf '  batches: batch_%s..batch_%s\n' "${DAAAM_AUTO_BATCH_START:-1}" "${DAAAM_AUTO_BATCH_END:-7}"
printf '  bag delay: %s seconds\n' "${DAAAM_AUTO_BAG_DELAY_SECONDS:-480}"
printf '  state: %s\n' "$STATE_DIR"
printf '  logs:  %s\n\n' "$LOG_DIR"

printf '[%s] Starting Cosmos worker\n' "$(date -Is)" | tee -a "$LOG_DIR/auto_all.log"
setsid bash "$PROFILE_DIR/start_cosmos.sh" > >(tee -a "$LOG_DIR/cosmos_terminal.log") 2>&1 &
cosmos_pid=$!
printf '%s\n' "$cosmos_pid" > "$STATE_DIR/cosmos.pid"

printf '[%s] Starting delayed bag worker\n' "$(date -Is)" | tee -a "$LOG_DIR/auto_all.log"
setsid bash "$PROFILE_DIR/auto_bag_play.sh" > >(tee -a "$LOG_DIR/auto_bag_terminal.log") 2>&1 &
bag_pid=$!
printf '%s\n' "$bag_pid" > "$STATE_DIR/auto_bag.pid"

printf '[%s] Starting launch worker\n' "$(date -Is)" | tee -a "$LOG_DIR/auto_all.log"
set +e
bash "$PROFILE_DIR/auto_ros_launch.sh" > >(tee -a "$LOG_DIR/auto_launch_terminal.log") 2>&1
launch_status=$?
set -e

if [[ "$launch_status" -ne 0 ]]; then
    printf '[%s] Launch worker failed with %s\n' "$(date -Is)" "$launch_status" | tee -a "$LOG_DIR/auto_all.log"
    touch "$STATE_DIR/auto.stop"
fi

set +e
wait "$bag_pid"
bag_status=$?
set -e

printf '[%s] Bag worker exited with %s\n' "$(date -Is)" "$bag_status" | tee -a "$LOG_DIR/auto_all.log"
printf '[%s] Full automation finished: launch=%s bag=%s\n' "$(date -Is)" "$launch_status" "$bag_status" | tee -a "$LOG_DIR/auto_all.log"

if [[ "$launch_status" -ne 0 ]]; then
    exit "$launch_status"
fi
exit "$bag_status"
