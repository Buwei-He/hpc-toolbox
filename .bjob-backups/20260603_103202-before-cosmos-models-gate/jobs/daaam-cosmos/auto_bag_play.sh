#!/bin/bash
set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
ENV_FILE="$PROJECT/.bjob/daaam-cosmos-${SLURM_JOB_ID:-manual}.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

set +e +u
[[ -f ~/.bashrc ]] && source ~/.bashrc
set -euo pipefail

NODE="${SLURMD_NODENAME:-$(hostname -s)}"
BATCH_START="${DAAAM_AUTO_BATCH_START:-1}"
BATCH_END="${DAAAM_AUTO_BATCH_END:-7}"
READY_PATTERN="${DAAAM_AUTO_LAUNCH_READY_PATTERN:-Waiting for CameraInfo on topic}"
READY_FALLBACK_SECONDS="${DAAAM_AUTO_READY_FALLBACK_SECONDS:-480}"
DELAY_SECONDS="${DAAAM_AUTO_BAG_DELAY_SECONDS:-0}"
START_PAUSED="${DAAAM_AUTO_BAG_START_PAUSED:-0}"
STATE_DIR="${DAAAM_AUTO_STATE_DIR:-$PROJECT/.cache/daaam-cosmos-auto/${SLURM_JOB_ID:-manual}}"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

printf '\nDAAAM auto bag worker on %s\n' "$NODE"
printf '  batches: batch_%s..batch_%s\n' "$BATCH_START" "$BATCH_END"
printf '  readiness pattern: %s\n' "$READY_PATTERN"
printf '  readiness fallback: %s seconds\n' "$READY_FALLBACK_SECONDS"
printf '  post-ready delay:   %s seconds\n' "$DELAY_SECONDS"
printf '  paused:  %s\n' "$START_PAUSED"
printf '  state:   %s\n' "$STATE_DIR"
printf '  logs:    %s\n\n' "$LOG_DIR"

sleep_with_abort() {
    local total="$1" prefix="$2" waited=0 step=10
    while (( waited < total )); do
        if [[ -e "$STATE_DIR/auto.stop" || -e "$prefix.launch.done" ]]; then
            return 1
        fi
        if (( total - waited < step )); then
            sleep $((total - waited))
            waited="$total"
        else
            sleep "$step"
            waited=$((waited + step))
        fi
    done
    return 0
}

wait_for_ready() {
    local prefix="$1" batch_name="$2" waited=0 step=5
    while [[ ! -e "$prefix.launch.ready" ]]; do
        if [[ -e "$STATE_DIR/auto.stop" || -e "$prefix.launch.done" ]]; then
            return 1
        fi
        if (( waited >= READY_FALLBACK_SECONDS )); then
            printf '[%s] Readiness pattern not seen for %s after %s seconds; falling back to timeout.\n' \
                "$(date -Is)" "$batch_name" "$READY_FALLBACK_SECONDS" | tee -a "$LOG_DIR/auto_bag.log"
            return 0
        fi
        sleep "$step"
        waited=$((waited + step))
    done
    printf '[%s] Launch readiness marker seen for %s.\n' "$(date -Is)" "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
    return 0
}

for batch_num in $(seq "$BATCH_START" "$BATCH_END"); do
    batch_name="batch_${batch_num}"
    prefix="$STATE_DIR/$batch_name"
    log="$LOG_DIR/bag_${batch_name}.log"

    printf '[%s] Waiting for launch command to start for %s\n' "$(date -Is)" "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
    while [[ ! -e "$prefix.launch.started" ]]; do
        if [[ -e "$STATE_DIR/auto.stop" ]]; then
            printf 'Stopping bag worker because auto.stop exists.\n' | tee -a "$LOG_DIR/auto_bag.log"
            exit 1
        fi
        if [[ -e "$STATE_DIR/auto.done" ]]; then
            printf 'Launch worker completed before %s started; exiting.\n' "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
            exit 0
        fi
        sleep 5
    done

    printf '[%s] Launch command started for %s; waiting for readiness pattern: %s\n' \
        "$(date -Is)" "$batch_name" "$READY_PATTERN" | tee -a "$LOG_DIR/auto_bag.log"
    if ! wait_for_ready "$prefix" "$batch_name"; then
        printf 'Skipping %s bag because automation stopped or launch ended before readiness.\n' "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
        touch "$STATE_DIR/auto.stop"
        exit 1
    fi

    if ! sleep_with_abort "$DELAY_SECONDS" "$prefix"; then
        printf 'Skipping %s bag because automation stopped during post-ready delay.\n' "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
        touch "$STATE_DIR/auto.stop"
        exit 1
    fi

    date -Is > "$prefix.bag.started"
    printf '[%s] Starting ros2 bag play for %s\n' "$(date -Is)" "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
    printf '  log: %s\n' "$log" | tee -a "$LOG_DIR/auto_bag.log"

    set +e
    BATCH_NAME="$batch_name" DAAAM_AUTO_BAG_START_PAUSED="$START_PAUSED" PROJECT="$PROJECT" \
    apptainer exec --nv \
        -B "$PROJECT/ros2_ws:/ros2_ws" \
        -B "$PROJECT/rosbags:/rosbags" \
        "$PROJECT/containers/daaam.sif" \
        bash -lc '
            source /ros2_ws/setup_daaam.sh
            export PYTHONPATH=/ros2_ws/python_packages:$PYTHONPATH
            pause_args=()
            if [[ "${DAAAM_AUTO_BAG_START_PAUSED:-0}" == "1" ]]; then
                pause_args=(--start-paused)
            fi
            ros2 bag play /ros2_ws/data/EGG-Dataset/bags/egg_${BATCH_NAME}_full.bag \
              --clock \
              --qos-profile-overrides-path /ros2_ws/tools/egg_bag_qos_overrides.yaml \
              "${pause_args[@]}"
        ' > >(tee -a "$log") 2>&1
    status=$?
    set -e

    printf '%s\n' "$status" > "$prefix.bag.status"
    date -Is > "$prefix.bag.done"
    printf '[%s] ros2 bag play for %s exited with %s\n' "$(date -Is)" "$batch_name" "$status" | tee -a "$LOG_DIR/auto_bag.log"

    if [[ "$status" -ne 0 ]]; then
        printf 'Stopping automation because ros2 bag play failed for %s.\n' "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
        touch "$STATE_DIR/auto.stop"
        exit "$status"
    fi

done

printf '\nBag worker completed requested batches: batch_%s..batch_%s\n' "$BATCH_START" "$BATCH_END" | tee -a "$LOG_DIR/auto_bag.log"
