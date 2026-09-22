#!/bin/bash
# setup.sh for profile: percorso
# Sourced automatically after your SLURM allocation starts.
# Starts a tmux session so bjob/SLURM context is not lost when entering the
# Apptainer container. New bjob connections get distinct sessions by default.
#
# With a TTY (bjob's interactive launch), this attaches you to it, same as
# always. Without one (bjob submit — no human to hand off to), the pipeline
# starts itself instead of waiting at an interactive prompt: AUTOSTART=1 is
# passed into the tmux session, and enter_percorso_container.sh runs
# 'percorso-demo doctor && run live' in place of the interactive shell it
# would otherwise exec into. The session it's started in is still
# detached either way — see enter_percorso_container.sh for the actual
# pipeline start; this file only ever creates the session and (maybe) attaches.

export PROJECT="${PROJECT:?PROJECT not set -- run this via bjob or percorso-demo, or export PROJECT yourself}"
PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${SLURMD_NODENAME:-$(hostname -s)}"
LOG_DIR="$PROJECT/.cache/bjob-tmux"
[[ -t 0 && -t 1 ]] && AUTOSTART=0 || AUTOSTART=1
mkdir -p "$LOG_DIR"
JOB_ID="${SLURM_JOB_ID:-manual}"
STEP_ID="${SLURM_STEP_ID:-main}"

if [[ -n "${PERCORSO_TMUX_SESSION:-}" ]]; then
    SESSION="$PERCORSO_TMUX_SESSION"
elif [[ "$STEP_ID" == "0" || "$STEP_ID" == "batch" || "$STEP_ID" == "extern" ]]; then
    SESSION="percorso-${JOB_ID}-main"
else
    SESSION="percorso-${JOB_ID}-${STEP_ID}-$$"
fi

LOG_FILE="$LOG_DIR/${SESSION}.log"
touch "$LOG_FILE"

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is not available; opening the percorso demo container directly."
    PERCORSO_AUTOSTART="$AUTOSTART" exec bash "$PROFILE_DIR/enter_percorso_container.sh"
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Attaching existing tmux session: $SESSION"
else
    tmux new-session -d -s "$SESSION" -n percorso         "PROJECT='$PROJECT' SLURMD_NODENAME='$NODE' PERCORSO_AUTOSTART='$AUTOSTART' bash '$PROFILE_DIR/enter_percorso_container.sh'"
    tmux set-option -t "$SESSION" history-limit 50000 >/dev/null 2>&1 || true
    echo "Started tmux session: $SESSION"
fi

tmux pipe-pane -o -t "$SESSION:percorso" "cat >> '$LOG_FILE'" 2>/dev/null || true

echo "Node: $NODE"
echo "Session: $SESSION"
echo "Log: $LOG_FILE"
echo "Detach with Ctrl-b d. Reattach with: tmux attach -t $SESSION"
echo "List sessions with: tmux ls"
echo "From another IDE terminal: bjob connect ${JOB_ID}"
echo "Set PERCORSO_TMUX_SESSION=<name> before bjob connect if you intentionally want to reattach one."
echo ""

if [[ "$AUTOSTART" == "1" ]]; then
    echo "No TTY — not attaching. Session '$SESSION' is running detached and will"
    echo "start the pipeline itself (doctor && run live) with nobody watching."
elif [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$SESSION" 2>/dev/null || true
else
    tmux attach-session -t "$SESSION"
fi
