#!/bin/bash
# DAAAM worker — dedicated sbatch allocation (smart-auto mode).
# Submitted by bjob; automatically resubmits itself if the time limit
# expires before all batches complete.
#
# Required env (set via --export by bjob or by resubmission):
#   DAAAM_AUTO_STATE_DIR    shared state dir (same session as the cosmos job)
#   DAAAM_AUTO_BATCH_START  first batch number to process
#   DAAAM_AUTO_BATCH_END    last batch number to process
#   DAAAM_SBATCH_MEM        mem for resubmissions (e.g. "80G")
#   DAAAM_SBATCH_GPUS       GPU count for resubmissions (e.g. "1")

set -euo pipefail

export PROJECT="${PROJECT:?PROJECT not set -- run this via bjob or percorso-demo, or export PROJECT yourself}"
# SLURM copies scripts to a temp dir, so BASH_SOURCE[0] won't point here.
# bjob passes the real path via --export=...,DAAAM_PROFILE_DIR=...
PROFILE_DIR="${DAAAM_PROFILE_DIR:?DAAAM_PROFILE_DIR must be set via --export}"

STATE_DIR="${DAAAM_AUTO_STATE_DIR:?ERROR: DAAAM_AUTO_STATE_DIR must be set via --export}"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

# Register state dir so 'bjob logs <jobid>' can find it
mkdir -p "$PROJECT/.bjob"
printf '%s\n' "$STATE_DIR" > "$PROJECT/.bjob/smart-auto-session.${SLURM_JOB_ID:-manual}"

BATCH_START="${DAAAM_AUTO_BATCH_START:-1}"
BATCH_END="${DAAAM_AUTO_BATCH_END:-7}"

# Persist the target end once, so 'bjob extend' (a separate process, run
# after this job has already exited) can recover it — it only has this
# state dir to go on, not our env vars.
[[ -f "$STATE_DIR/batch_end" ]] || printf '%s\n' "$BATCH_END" > "$STATE_DIR/batch_end"

# Export so auto_ros_launch.sh and auto_bag_play.sh pick them up
export DAAAM_AUTO_STATE_DIR="$STATE_DIR"
export DAAAM_AUTO_BATCH_START="$BATCH_START"
export DAAAM_AUTO_BATCH_END="$BATCH_END"

# Resubmit params — inherited by --export=ALL in the resubmission sbatch call
export DAAAM_SBATCH_MEM="${DAAAM_SBATCH_MEM:-80G}"
export DAAAM_SBATCH_GPUS="${DAAAM_SBATCH_GPUS:-1}"

cd "$PROJECT"
set +e +u; [[ -f ~/.bashrc ]] && source ~/.bashrc; set -euo pipefail

NODE="${SLURMD_NODENAME:-$(hostname -s)}"
printf '[%s] DAAAM worker job %s starting on %s\n' "$(date -Is)" "${SLURM_JOB_ID:-manual}" "$NODE"
printf '  State:   %s\n' "$STATE_DIR"
printf '  Batches: batch_%s..batch_%s\n\n' "$BATCH_START" "$BATCH_END"

# Fresh start: clear stale stop flag only when not continuing a previous job
if [[ ! -f "$STATE_DIR/current_batch" ]]; then
    rm -f "$STATE_DIR/auto.stop" "$STATE_DIR/auto.done"
fi

# ── Exit trap: resubmit if time expired before all batches finished ────────────
_on_exit() {
    # Kill any lingering bag worker (best-effort)
    [[ -n "${bag_pid:-}" ]] && kill "$bag_pid" 2>/dev/null || true

    if [[ -e "$STATE_DIR/auto.done" || -e "$STATE_DIR/auto.stop" ]]; then
        return  # Completed normally or stopped on error — no resubmit
    fi
    if [[ -e "$STATE_DIR/extended.${SLURM_JOB_ID:-manual}" ]]; then
        return  # 'bjob extend' already queued a follow-up for THIS job id
                # (checked power and submitted early, ahead of the time
                # limit) — resubmitting here too would double it up.
    fi

    local resume_batch="$BATCH_START"
    if [[ -f "$STATE_DIR/current_batch" ]]; then
        local cb; cb=$(cat "$STATE_DIR/current_batch")
        resume_batch="${cb#batch_}"
    fi
    if (( resume_batch > BATCH_END )); then
        return
    fi

    printf '[%s] DAAAM worker %s expiring at batch_%s. Resubmitting batch_%s..batch_%s.\n' \
        "$(date -Is)" "${SLURM_JOB_ID:-manual}" "$resume_batch" "$resume_batch" "$BATCH_END" \
        | tee -a "$LOG_DIR/auto_launch.log"

    sbatch \
        --account="${SLURM_JOB_ACCOUNT:?SLURM_JOB_ACCOUNT should always be set inside a running job}" \
        --partition="${SLURM_JOB_PARTITION:-berzelius}" \
        --gpus="${DAAAM_SBATCH_GPUS}" \
        --time=00:59:59 \
        --mem="${DAAAM_SBATCH_MEM}" \
        --job-name=daaam-worker \
        --output="$LOG_DIR/daaam_slurm-%j.log" \
        --export=ALL,DAAAM_AUTO_STATE_DIR="$STATE_DIR",DAAAM_AUTO_BATCH_START="$resume_batch",DAAAM_AUTO_BATCH_END="$BATCH_END" \
        "$PROFILE_DIR/sbatch_daaam.sh" \
        | tee -a "$LOG_DIR/auto_launch.log"
}
trap _on_exit EXIT

bag_pid=""

printf '[%s] Starting bag worker\n' "$(date -Is)" | tee -a "$LOG_DIR/auto_all.log"
setsid bash "$PROFILE_DIR/auto_bag_play.sh" > >(tee -a "$LOG_DIR/auto_bag_terminal.log") 2>&1 &
bag_pid=$!

printf '[%s] Starting launch worker\n' "$(date -Is)" | tee -a "$LOG_DIR/auto_all.log"
set +e
bash "$PROFILE_DIR/auto_ros_launch.sh" > >(tee -a "$LOG_DIR/auto_launch_terminal.log") 2>&1
launch_status=$?
set -e

kill "$bag_pid" 2>/dev/null || true
wait "$bag_pid" 2>/dev/null || true

printf '[%s] DAAAM worker finished: launch_status=%s\n' "$(date -Is)" "$launch_status" \
    | tee -a "$LOG_DIR/auto_all.log"
exit "$launch_status"
