#!/bin/bash
# setup.sh for profile: cosmos-reason2
# Sourced automatically by bjob after the SLURM allocation starts.
# Activates the vLLM env, starts the Cosmos-Reason2-8B server in the
# background on 0.0.0.0:8000, then drops you to an interactive shell.

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"

# Environment
module load Miniforge3/24.7.1-2-hpc1-bdist
module load buildenv-gcccuda/12.1.1-gcc12.3.0
mamba activate qwen8b-vllm312

export HF_HOME=$PROJECT/.hf_cache
export XDG_CACHE_HOME=$PROJECT/.cache
export VLLM_CACHE_ROOT=$PROJECT/.cache/vllm
export TORCHINDUCTOR_CACHE_DIR=$PROJECT/.cache/torchinductor
export TRITON_CACHE_DIR=$PROJECT/.triton_cache
mkdir -p "$HF_HOME" "$XDG_CACHE_HOME" "$VLLM_CACHE_ROOT" "$TORCHINDUCTOR_CACHE_DIR" "$TRITON_CACHE_DIR"

# Prefer an already-exported token; otherwise use the HF cache token if present.
if [[ -z "${HUGGING_FACE_HUB_TOKEN:-}" && -f "$HF_HOME/token" ]]; then
    export HUGGING_FACE_HUB_TOKEN="$(cat "$HF_HOME/token")"
fi

COSMOS_LOG=$PROJECT/.cache/cosmos-reason2-vllm.log
MODEL="${COSMOS_MODEL:-nvidia/Cosmos-Reason2-8B}"
GPU_MEMORY_UTILIZATION="${COSMOS_GPU_MEMORY_UTILIZATION:-0.90}"
NODE=$(hostname -s)

_cosmos_setup_done() {
    return 0 2>/dev/null || exit 0
}

if curl -sf http://127.0.0.1:8000/health > /dev/null 2>&1; then
    echo "Cosmos-Reason2 server is already running on node: $NODE"
    echo "http://${NODE}:8000/v1" > "$PROJECT/.cosmos_url"
    echo "Cosmos URL written to $PROJECT/.cosmos_url"
    _cosmos_setup_done
fi

echo "Starting Cosmos-Reason2 server ($MODEL) on node: $NODE"
echo "  Log: $COSMOS_LOG"
echo ""
echo "  Remote access:"
echo "    ssh -L 8000:${NODE}:8000 berzelius1.nsc.liu.se"
echo "    http://127.0.0.1:8000/v1"
echo ""

vllm serve "$MODEL"     --host 0.0.0.0     --port 8000     --served-model-name cosmos-reason2     --allowed-local-media-path "$PROJECT"     --limit-mm-per-prompt '{"image":4,"video":1}'     --media-io-kwargs '{"video": {"num_frames": -1}}'     --reasoning-parser qwen3     --max-model-len 16384     --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"     > "$COSMOS_LOG" 2>&1 &

VLLM_PID=$!
echo "  PID=$VLLM_PID  (kill with: kill $VLLM_PID)"
echo "  Waiting for server to become ready..."

for _ in $(seq 1 120); do
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        echo "ERROR: vLLM server exited unexpectedly. Check $COSMOS_LOG"
        break
    fi
    if curl -sf http://127.0.0.1:8000/health > /dev/null 2>&1; then
        echo "  Server is ready on http://${NODE}:8000  (or via tunnel: http://127.0.0.1:8000)"
        echo "http://${NODE}:8000/v1" > "$PROJECT/.cosmos_url"
        echo "  Cosmos URL written to $PROJECT/.cosmos_url"
        echo "  Tail server log: tail -f $COSMOS_LOG"
        break
    fi
    sleep 5
done
