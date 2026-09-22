#!/bin/bash
set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
NODE="${SLURMD_NODENAME:-$(hostname -s)}"

suggest_cosmos_url() {
    local current="$1" first_other="" job nodes

    if command -v squeue >/dev/null 2>&1; then
        while IFS='|' read -r job nodes; do
            [[ -z "$nodes" || "$nodes" == "$current" || "$nodes" == "(null)" || "$nodes" == "None" ]] && continue
            if [[ "$job" == *cosmos* || "$job" == *Cosmos* ]]; then
                printf 'http://%s:8000/v1' "$nodes"
                return 0
            fi
            [[ -z "$first_other" ]] && first_other="$nodes"
        done < <(squeue -u "$USER" -h -t RUNNING -o '%j|%N' 2>/dev/null || true)
    fi

    if [[ -n "$first_other" ]]; then
        printf 'http://%s:8000/v1' "$first_other"
    elif [[ -s "$PROJECT/.cosmos_url" ]]; then
        tr -d '\n' < "$PROJECT/.cosmos_url"
    else
        printf 'http://%s:8000/v1' "$current"
    fi
}

COSMOS_URL_SUGGESTION="$(suggest_cosmos_url "$NODE")"

printf '\nDAAAM container shell on %s\n' "$NODE"
printf '  PROJECT=%s\n' "$PROJECT"
printf '  Container=%s/containers/daaam.sif\n' "$PROJECT"
printf '\nInside this shell ROS is already sourced and PYTHONPATH is set.\n'
printf 'Useful next steps:\n'
printf '  export BATCH_NAME=batch_2\n'
printf '  export COSMOS_URL=%s\n' "$COSMOS_URL_SUGGESTION"
printf '\n'

apptainer exec --nv \
    -B "$PROJECT/ros2_ws:/ros2_ws" \
    -B "$PROJECT/rosbags:/rosbags" \
    "$PROJECT/containers/daaam.sif" \
    bash -lc '
        source /ros2_ws/setup_daaam.sh
        export PYTHONPATH=/ros2_ws/python_packages:$PYTHONPATH
        echo "DAAAM environment ready."
        exec bash --norc --noprofile -i
    '
