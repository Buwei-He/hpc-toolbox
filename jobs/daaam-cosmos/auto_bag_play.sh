#!/bin/bash
set -euo pipefail

export PROJECT="${PROJECT:?PROJECT not set -- run this via bjob or percorso-demo, or export PROJECT yourself}"
ENV_FILE="$PROJECT/.bjob/daaam-cosmos-${SLURM_JOB_ID:-manual}.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "${BJOB_DAAAM_AUTO_BATCH_START:-}" ]] && export DAAAM_AUTO_BATCH_START="$BJOB_DAAAM_AUTO_BATCH_START"
[[ -n "${BJOB_DAAAM_AUTO_BATCH_END:-}" ]] && export DAAAM_AUTO_BATCH_END="$BJOB_DAAAM_AUTO_BATCH_END"
cd "$PROJECT"

set +e +u
[[ -f ~/.bashrc ]] && source ~/.bashrc
set -euo pipefail

NODE="${SLURMD_NODENAME:-$(hostname -s)}"
BATCH_START="${DAAAM_AUTO_BATCH_START:-1}"
BATCH_END="${DAAAM_AUTO_BATCH_END:-7}"
READY_PATTERN="${DAAAM_AUTO_LAUNCH_READY_PATTERN:-Waiting for CameraInfo on}"
READY_FALLBACK_SECONDS="${DAAAM_AUTO_READY_FALLBACK_SECONDS:-480}"
COSMOS_MODELS_WAIT_SECONDS="${DAAAM_AUTO_COSMOS_MODELS_WAIT_SECONDS:-1800}"
DELAY_SECONDS="${DAAAM_AUTO_BAG_DELAY_SECONDS:-0}"
START_PAUSED="${DAAAM_AUTO_BAG_START_PAUSED:-0}"
STATE_DIR="${DAAAM_AUTO_STATE_DIR:-$PROJECT/.cache/daaam-cosmos-auto/${SLURM_JOB_ID:-manual}}"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

printf '\nDAAAM auto bag worker on %s\n' "$NODE"
printf '  batches: batch_%s..batch_%s\n' "$BATCH_START" "$BATCH_END"
printf '  readiness pattern: %s\n' "$READY_PATTERN"
printf '  readiness fallback: %s seconds\n' "$READY_FALLBACK_SECONDS"
printf '  Cosmos /v1/models wait: %s seconds\n' "$COSMOS_MODELS_WAIT_SECONDS"
printf '  post-ready delay:   %s seconds\n' "$DELAY_SECONDS"
printf '  paused:  %s\n' "$START_PAUSED"
printf '  state:   %s\n' "$STATE_DIR"
printf '  logs:    %s\n\n' "$LOG_DIR"

marker_mtime_epoch() {
    local path="$1"
    [[ -e "$path" ]] || return 1
    stat -c %Y "$path" 2>/dev/null || stat -f %m "$path"
}

marker_is_fresh() {
    local path="$1" min_epoch="$2" mtime
    mtime="$(marker_mtime_epoch "$path")" || return 1
    [[ "$mtime" -ge "$min_epoch" ]]
}

sleep_with_abort() {
    local total="$1" prefix="$2" min_epoch="$3" waited=0 step=10
    while (( waited < total )); do
        if [[ -e "$STATE_DIR/auto.stop" ]] || marker_is_fresh "$prefix.launch.done" "$min_epoch"; then
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
    local prefix="$1" batch_name="$2" min_epoch="$3" waited=0 step=5
    while ! marker_is_fresh "$prefix.launch.ready" "$min_epoch"; do
        if [[ -e "$STATE_DIR/auto.stop" ]] || marker_is_fresh "$prefix.launch.done" "$min_epoch"; then
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
    printf '[%s] Fresh launch readiness marker seen for %s.\n' "$(date -Is)" "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
    return 0
}

read_cosmos_url() {
    if [[ -s "$STATE_DIR/cosmos_url" ]]; then
        tr -d '\n' < "$STATE_DIR/cosmos_url"
    elif [[ -s "${COSMOS_URL_FILE:-}" ]]; then
        tr -d '\n' < "$COSMOS_URL_FILE"
    elif [[ -s "$PROJECT/.cosmos_url" ]]; then
        tr -d '\n' < "$PROJECT/.cosmos_url"
    else
        printf 'http://%s:8000/v1' "$NODE"
    fi
}

wait_for_cosmos_models() {
    local waited=0 step=5 cosmos_url models_url
    while (( waited <= COSMOS_MODELS_WAIT_SECONDS )); do
        if [[ -e "$STATE_DIR/auto.stop" ]]; then
            return 1
        fi
        cosmos_url="$(read_cosmos_url)"
        models_url="${cosmos_url%/}/models"
        if curl -sf "$models_url" >/dev/null 2>&1; then
            printf '%s\n' "$cosmos_url" > "$STATE_DIR/cosmos_url"
            printf '[%s] Cosmos models endpoint ready: %s\n' "$(date -Is)" "$models_url" | tee -a "$LOG_DIR/auto_bag.log"
            return 0
        fi
        sleep "$step"
        waited=$((waited + step))
    done
    printf '[%s] Cosmos models endpoint did not respond within %s seconds. Last URL: %s\n' \
        "$(date -Is)" "$COSMOS_MODELS_WAIT_SECONDS" "${models_url:-unknown}" | tee -a "$LOG_DIR/auto_bag.log"
    return 1
}

for batch_num in $(seq "$BATCH_START" "$BATCH_END"); do
    batch_name="batch_${batch_num}"
    prefix="$STATE_DIR/$batch_name"
    log="$LOG_DIR/bag_${batch_name}.log"

    printf '[%s] Waiting for fresh launch command to start for %s\n' "$(date -Is)" "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
    batch_wait_epoch="$(date +%s)"
    batch_wait_epoch=$((batch_wait_epoch - 1))
    while ! marker_is_fresh "$prefix.launch.started" "$batch_wait_epoch"; do
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
    launch_started_epoch="$(marker_mtime_epoch "$prefix.launch.started")"

    printf '[%s] Fresh launch command started for %s; waiting for readiness pattern: %s\n' \
        "$(date -Is)" "$batch_name" "$READY_PATTERN" | tee -a "$LOG_DIR/auto_bag.log"
    if ! wait_for_ready "$prefix" "$batch_name" "$launch_started_epoch"; then
        printf 'Skipping %s bag because automation stopped or launch ended before readiness.\n' "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
        touch "$STATE_DIR/auto.stop"
        exit 1
    fi

    if ! wait_for_cosmos_models; then
        printf 'Skipping %s bag because Cosmos /v1/models is not reachable.\n' "$batch_name" | tee -a "$LOG_DIR/auto_bag.log"
        touch "$STATE_DIR/auto.stop"
        exit 1
    fi

    if ! sleep_with_abort "$DELAY_SECONDS" "$prefix" "$launch_started_epoch"; then
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
        -B "$PROJECT:$PROJECT" \
        "$PROJECT/containers/daaam.sif" \
        bash -lc '
            cd "$PROJECT" 2>/dev/null || true
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
