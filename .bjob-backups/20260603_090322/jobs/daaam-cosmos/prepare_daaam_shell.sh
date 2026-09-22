#!/bin/bash
set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
ENV_FILE="$PROJECT/.bjob/daaam-cosmos-${SLURM_JOB_ID:-manual}.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

set +e +u
[[ -f ~/.bashrc ]] && source ~/.bashrc
set -euo pipefail

NODE="${SLURMD_NODENAME:-$(hostname -s)}"
export HOI_FPS="${HOI_FPS:-4.0}"
export COSMOS_URL="${COSMOS_URL:-http://${NODE}:8000/v1}"

echo "Opening prepared DAAAM shell on $NODE"
echo "  PROJECT=$PROJECT"
echo "  HOI_FPS=$HOI_FPS"
echo "  COSMOS_URL=$COSMOS_URL"
echo ""
echo "Inside the container, set BATCH_NAME manually, then run ros2 launch or ros2 bag play."
echo ""

apptainer exec --nv \
    -B "$PROJECT/ros2_ws:/ros2_ws" \
    -B "$PROJECT/rosbags:/rosbags" \
    "$PROJECT/containers/daaam.sif" \
    bash -lc '
        source /ros2_ws/setup_daaam.sh
        export PYTHONPATH=/ros2_ws/python_packages:$PYTHONPATH
        export HOI_FPS="${HOI_FPS:-4.0}"
        export COSMOS_URL="${COSMOS_URL}"
        echo "DAAAM environment ready."
        echo "  export BATCH_NAME=batch_2"
        echo "  echo COSMOS_URL=$COSMOS_URL"
        echo ""
        exec bash --norc --noprofile -i
    '
