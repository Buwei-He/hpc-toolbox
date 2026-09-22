#!/bin/bash
set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
ENV_FILE="$PROJECT/.bjob/daaam-cosmos-${SLURM_JOB_ID:-manual}.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "${BJOB_DAAAM_AUTO_BATCH_START:-}" ]] && export DAAAM_AUTO_BATCH_START="$BJOB_DAAAM_AUTO_BATCH_START"
[[ -n "${BJOB_DAAAM_AUTO_BATCH_END:-}" ]] && export DAAAM_AUTO_BATCH_END="$BJOB_DAAAM_AUTO_BATCH_END"


set +e +u
[[ -f ~/.bashrc ]] && source ~/.bashrc
set -euo pipefail

NODE="${SLURMD_NODENAME:-$(hostname -s)}"
BATCH_START="${DAAAM_AUTO_BATCH_START:-1}"
BATCH_END="${DAAAM_AUTO_BATCH_END:-7}"
COSMOS_WAIT_SECONDS="${DAAAM_AUTO_COSMOS_WAIT_SECONDS:-1800}"
READY_PATTERN="${DAAAM_AUTO_LAUNCH_READY_PATTERN:-Waiting for CameraInfo on topic}"
STATE_DIR="${DAAAM_AUTO_STATE_DIR:-$PROJECT/.cache/daaam-cosmos-auto/${SLURM_JOB_ID:-manual}}"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

read_cosmos_url() {
    if [[ -s "${COSMOS_URL_FILE:-}" ]]; then
        tr -d '\n' < "$COSMOS_URL_FILE"
    elif [[ -s "$PROJECT/.cosmos_url" ]]; then
        tr -d '\n' < "$PROJECT/.cosmos_url"
    else
        printf 'http://%s:8000/v1' "$NODE"
    fi
}

wait_for_cosmos() {
    local waited=0 url health_url
    while (( waited <= COSMOS_WAIT_SECONDS )); do
        url="$(read_cosmos_url)"
        health_url="${url%/v1}/health"
        if command -v curl >/dev/null 2>&1; then
            if curl -sf "$health_url" >/dev/null 2>&1; then
                printf '%s' "$url"
                return 0
            fi
        elif [[ -s "${COSMOS_URL_FILE:-}" || -s "$PROJECT/.cosmos_url" ]]; then
            printf '%s' "$url"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}


printf '\nDAAAM auto launch worker on %s\n' "$NODE"
printf '  batches: batch_%s..batch_%s\n' "$BATCH_START" "$BATCH_END"
printf '  readiness pattern: %s\n' "$READY_PATTERN"
printf '  state: %s\n' "$STATE_DIR"
printf '  logs:  %s\n\n' "$LOG_DIR"

if ! COSMOS_URL="$(wait_for_cosmos)"; then
    printf 'ERROR: Cosmos did not become healthy within %s seconds.\n' "$COSMOS_WAIT_SECONDS" | tee -a "$LOG_DIR/auto_launch.log"
    touch "$STATE_DIR/auto.stop"
    exit 1
fi
printf '%s\n' "$COSMOS_URL" > "$STATE_DIR/cosmos_url"
printf 'Cosmos URL: %s\n\n' "$COSMOS_URL" | tee -a "$LOG_DIR/auto_launch.log"

for batch_num in $(seq "$BATCH_START" "$BATCH_END"); do
    if [[ -e "$STATE_DIR/auto.stop" ]]; then
        printf 'Stopping launch worker because auto.stop exists.\n' | tee -a "$LOG_DIR/auto_launch.log"
        exit 1
    fi
    batch_name="batch_${batch_num}"
    prefix="$STATE_DIR/$batch_name"
    log="$LOG_DIR/launch_${batch_name}.log"

    rm -f "$prefix.launch.started" "$prefix.launch.ready" "$prefix.launch.done" "$prefix.launch.status" \
          "$prefix.bag.started" "$prefix.bag.done" "$prefix.bag.status"

    printf '%s\n' "$batch_name" > "$STATE_DIR/current_batch"
    date -Is > "$prefix.launch.started"
    : > "$log"
    printf '\n[%s] Starting ROS launch for %s\n' "$(date -Is)" "$batch_name" | tee -a "$LOG_DIR/auto_launch.log"
    printf '  log: %s\n' "$log" | tee -a "$LOG_DIR/auto_launch.log"
    printf '  readiness pattern: %s\n' "$READY_PATTERN" | tee -a "$LOG_DIR/auto_launch.log"

    (
        tail -n +1 -F "$log" 2>/dev/null | while IFS= read -r line; do
            if [[ "$line" == *"$READY_PATTERN"* ]]; then
                date -Is > "$prefix.launch.ready"
                printf '[%s] ROS launch readiness detected for %s: %s\n' \
                    "$(date -Is)" "$batch_name" "$READY_PATTERN" >> "$LOG_DIR/auto_launch.log"
                break
            fi
        done
    ) &
    ready_watch_pid=$!

    set +e
    BATCH_NAME="$batch_name" COSMOS_URL="$COSMOS_URL" HOI_FPS="${HOI_FPS:-4.0}" PROJECT="$PROJECT" \
    apptainer exec --nv \
        -B "$PROJECT/ros2_ws:/ros2_ws" \
        -B "$PROJECT/rosbags:/rosbags" \
        "$PROJECT/containers/daaam.sif" \
        bash -lc '
            source /ros2_ws/setup_daaam.sh
            export PYTHONPATH=/ros2_ws/python_packages:$PYTHONPATH
            ros2 launch daaam_ros egg_daaam_hydra.launch.yaml \
              scene:=egg_${BATCH_NAME}_dynamic \
              hydra_config_path:=/ros2_ws/src/daaam_ros/config/hydra_config/egg_dataset_khronos_dynamic.yaml \
              input_config_path:=/ros2_ws/src/daaam_ros/config/hydra_ros_config/egg_dataset_input_config.yaml \
              depth_scale:=1000.0 \
              exit_after_clock:=true \
              verbosity:=1 \
              save_human_clips:=true \
              enable_cosmos_hoi_processing:=true \
              cosmos_hoi_debug_preview:=true \
              cosmos_hoi_base_url:=${COSMOS_URL} \
              cosmos_hoi_media_root:=$PROJECT \
              output_run_prefix:=egg_${BATCH_NAME}_
        ' > >(tee -a "$log") 2>&1
    status=$?
    set -e
    kill "$ready_watch_pid" 2>/dev/null || true
    wait "$ready_watch_pid" 2>/dev/null || true

    printf '%s\n' "$status" > "$prefix.launch.status"
    date -Is > "$prefix.launch.done"
    printf '[%s] ROS launch for %s exited with %s\n' "$(date -Is)" "$batch_name" "$status" | tee -a "$LOG_DIR/auto_launch.log"

    if [[ "$status" -ne 0 ]]; then
        printf 'Stopping automation because ROS launch failed for %s.\n' "$batch_name" | tee -a "$LOG_DIR/auto_launch.log"
        touch "$STATE_DIR/auto.stop"
        exit "$status"
    fi

    if [[ ! -e "$prefix.bag.started" ]]; then
        printf 'Stopping automation because ROS launch ended before bag playback started for %s.\n' "$batch_name" | tee -a "$LOG_DIR/auto_launch.log"
        touch "$STATE_DIR/auto.stop"
        exit 1
    fi

    if [[ -e "$prefix.bag.started" && ! -e "$prefix.bag.done" ]]; then
        printf 'Waiting for bag worker to finish %s before continuing.\n' "$batch_name" | tee -a "$LOG_DIR/auto_launch.log"
        while [[ ! -e "$prefix.bag.done" ]]; do
            sleep 5
        done
    fi

done

date -Is > "$STATE_DIR/auto.done"
printf '\nAll requested batches completed: batch_%s..batch_%s\n' "$BATCH_START" "$BATCH_END" | tee -a "$LOG_DIR/auto_launch.log"
