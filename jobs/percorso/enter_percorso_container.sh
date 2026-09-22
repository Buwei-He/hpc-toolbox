#!/bin/bash
# Enter the container with the DEMO environment already applied.
#
# This is the one real difference from jobs/daaam: that profile deliberately gives
# you the PAPER environment, so a hand-typed `ros2 launch ...` there runs paper
# code. Here the overlay is sourced and the demo lib is prepended, so what you type
# matches what percorso-demo runs. Verify any time with: percorso-demo doctor
set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
NODE="${SLURMD_NODENAME:-$(hostname -s)}"
# Same defaults as percorso-demo, so there is one truth about where things live.
OVERLAY="${PERCORSO_OVERLAY:-$PROJECT/percorso_overlay}"
DEMO_LIB="${PERCORSO_DEMO_LIB:-/ros2_ws/src/percorso-perception/src}"

cosmos_hint() {
    local job nodes
    if command -v squeue >/dev/null 2>&1; then
        while IFS='|' read -r job nodes; do
            [[ -z "$nodes" || "$nodes" == "(null)" || "$nodes" == "None" ]] && continue
            [[ "$job" == cosmos-* ]] && { printf 'http://%s:8000/v1' "$nodes"; return 0; }
        done < <(squeue -u "$USER" -h -t RUNNING -o '%j|%N' 2>/dev/null || true)
    fi
    [[ -s "$PROJECT/.cosmos_url" ]] && tr -d '\n' < "$PROJECT/.cosmos_url"
    return 0   # a missing hint is not a failure -- under set -e, hint="$(cosmos_hint)"
               # would otherwise abort this whole script before the container even starts
}

printf '\npercorso demo shell on %s\n' "$NODE"
printf '  PROJECT   %s\n' "$PROJECT"
printf '  overlay   %s\n' "$OVERLAY"
printf '  demo lib  %s\n' "$DEMO_LIB"
hint="$(cosmos_hint)"
if [ -n "$hint" ]; then
    printf '  cosmos    %s\n' "$hint"
else
    printf '  cosmos    not running — start the cosmos-reason2 profile in another job\n'
fi
printf '\nnext:  percorso-demo doctor  &&  percorso-demo run live\n\n'

# -B $PROJECT explicitly: /proj happens to be auto-bound by the site config, but
# the demo needs the overlay and .cosmos_url from there, so it should not depend
# on that staying true.
exec apptainer exec --nv \
    -B "$PROJECT/ros2_ws:/ros2_ws" \
    -B "$PROJECT/rosbags:/rosbags" \
    -B "$PROJECT:$PROJECT" \
    "$PROJECT/containers/daaam.sif" \
    bash -lc '
        source /ros2_ws/setup_daaam.sh
        if [ -f "'"$OVERLAY"'/install/setup.bash" ]; then
            source "'"$OVERLAY"'/install/setup.bash"
        else
            echo "WARNING: no overlay at '"$OVERLAY"' — run: percorso-demo overlay"
        fi
        export PYTHONPATH="'"$DEMO_LIB"'":/ros2_ws/python_packages:$PYTHONPATH
        echo "demo environment ready (percorso_perception_ros + demo daaam lib)."
        if [ "${PERCORSO_AUTOSTART:-0}" = "1" ]; then
            echo "PERCORSO_AUTOSTART=1 — no TTY to hand off to, starting the pipeline automatically."
            percorso-demo doctor && exec percorso-demo run live
            echo "ERROR: doctor or run failed (see above) — not starting the pipeline." >&2
            exit 1
        fi
        exec bash --norc --noprofile -i
    '
