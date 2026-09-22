#!/bin/bash
# setup.sh for profile: daaam-cosmos
# Holds one GPU allocation open. Use `bjob connect <jobid>` from IDE
# terminals to choose Cosmos, a prepared DAAAM shell, plain shell, or GPU status.

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
export HOI_FPS="${HOI_FPS:-4.0}"
export COSMOS_GPU_MEMORY_UTILIZATION="${COSMOS_GPU_MEMORY_UTILIZATION:-0.75}"
export COSMOS_URL_FILE="${COSMOS_URL_FILE:-$PROJECT/.cosmos_url.${SLURM_JOB_ID:-manual}}"

mkdir -p "$PROJECT/.bjob" "$PROJECT/.cache"
ENV_FILE="$PROJECT/.bjob/daaam-cosmos-${SLURM_JOB_ID:-manual}.env"
cat > "$ENV_FILE" <<EOF
export PROJECT="$PROJECT"
export HOI_FPS="$HOI_FPS"
export COSMOS_GPU_MEMORY_UTILIZATION="$COSMOS_GPU_MEMORY_UTILIZATION"
export COSMOS_URL_FILE="$COSMOS_URL_FILE"
EOF

NODE="${SLURMD_NODENAME:-$(hostname -s)}"

echo "DAAAM + Cosmos allocation is ready on node: $NODE"
echo "Job ID: ${SLURM_JOB_ID:-unknown}"
echo "Environment: $ENV_FILE"
echo ""
echo "Open each IDE terminal with:"
echo "  bjob connect ${SLURM_JOB_ID:-<jobid>}"
echo ""
echo "Then choose: cosmos, daaam, shell, or gpu."
echo "The daaam choice prepares ROS env, HOI_FPS, and COSMOS_URL; set BATCH_NAME manually."
echo ""
echo "Keep this allocation shell open. Exiting it ends the node allocation."
