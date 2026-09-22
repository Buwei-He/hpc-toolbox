#!/bin/bash
# setup.sh for profile: llava
# Sourced automatically by bjob after the SLURM allocation starts.
# Starts LLaVA-OneVision through the upstream SGLang container. Apptainer is
# the default runtime; build/pull the SIF on a compute node, where Docker-to-SIF
# conversion works on this cluster.

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"

module load buildenv-gcccuda/12.1.1-gcc12.3.0

export HF_HOME="${HF_HOME:-$PROJECT/.hf_cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$PROJECT/.cache}"
export ENROOT_CACHE_PATH="${ENROOT_CACHE_PATH:-$PROJECT/.cache/enroot}"
export ENROOT_SQUASH_OPTIONS="${ENROOT_SQUASH_OPTIONS:--comp lz4 -noD}"
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$PROJECT/.cache/apptainer}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$PROJECT/.cache/apptainer-tmp}"
export PROOT_NO_SECCOMP="${PROOT_NO_SECCOMP:-1}"
export SGLANG_CACHE_DIR="${SGLANG_CACHE_DIR:-$PROJECT/.cache/sglang}"
SGLANG_PATCH_DIR="${SGLANG_PATCH_DIR:-$PROJECT/berzelius-toolbox/jobs/llava/patches/sglang}"
SGLANG_CONTAINER_PYTHONPATH="$SGLANG_PATCH_DIR${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$HF_HOME" "$XDG_CACHE_HOME" "$ENROOT_CACHE_PATH" "$APPTAINER_CACHEDIR" \
    "$APPTAINER_TMPDIR" "$SGLANG_CACHE_DIR" "$PROJECT/containers/enroot"

# Prefer an already-exported token; otherwise use the HF cache token if present.
if [[ -z "${HUGGING_FACE_HUB_TOKEN:-}" && -f "$HF_HOME/token" ]]; then
    HUGGING_FACE_HUB_TOKEN="$(cat "$HF_HOME/token")"
    export HUGGING_FACE_HUB_TOKEN
fi
if [[ -z "${HF_TOKEN:-}" && -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    HF_TOKEN="$HUGGING_FACE_HUB_TOKEN"
    export HF_TOKEN
fi

LLAVA_LOG="${LLAVA_LOG:-$PROJECT/.cache/llava-onevision-sglang.log}"
MODEL="${LLAVA_MODEL:-lmms-lab-encoder/LLaVA-OneVision-2-8B-Instruct}"
SERVED_MODEL_NAME="${LLAVA_SERVED_MODEL_NAME:-llava-onevision}"
NODE="${SLURMD_NODENAME:-$(hostname -s)}"
PORT="${LLAVA_PORT:-8000}"
CONTAINER_RUNTIME="${LLAVA_CONTAINER_RUNTIME:-apptainer}"
CONTAINER_IMAGE="${LLAVA_CONTAINER_IMAGE:-docker://lmsysorg/sglang:latest}"
ENROOT_IMAGE="${LLAVA_ENROOT_IMAGE:-$PROJECT/containers/enroot/llava-sglang_latest.sqsh}"
APPTAINER_IMAGE="${LLAVA_APPTAINER_IMAGE:-$PROJECT/containers/llava-sglang_latest.sif}"
TP_SIZE="${LLAVA_TP_SIZE:-1}"
MEM_FRACTION="${LLAVA_MEM_FRACTION:-0.90}"
MAX_MODEL_LEN="${LLAVA_MAX_MODEL_LEN:-16384}"

_llava_setup_done() {
    return 0 2>/dev/null || exit 0
}

llava_health_ok() {
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 ||
        curl -sf "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1
}

if llava_health_ok; then
    echo "LLaVA-OneVision server is already running on node: $NODE"
    echo "http://${NODE}:${PORT}/v1" > "$PROJECT/.llava_url"
    echo "LLaVA URL written to $PROJECT/.llava_url"
    _llava_setup_done
fi

if [[ "$CONTAINER_RUNTIME" == "enroot" ]]; then
    if [[ ! -s "$ENROOT_IMAGE" ]]; then
        echo "Importing SGLang container with Enroot:"
        echo "  $CONTAINER_IMAGE"
        echo "  -> $ENROOT_IMAGE"
        enroot import -o "$ENROOT_IMAGE" "$CONTAINER_IMAGE"
    fi
    CONTAINER_DESC="$ENROOT_IMAGE"
elif [[ "$CONTAINER_RUNTIME" == "apptainer" ]]; then
    if [[ ! -s "$APPTAINER_IMAGE" ]]; then
        echo "Pulling SGLang container with Apptainer:"
        echo "  $CONTAINER_IMAGE"
        echo "  -> $APPTAINER_IMAGE"
        env -u SINGULARITY_CACHEDIR apptainer pull "$APPTAINER_IMAGE" "$CONTAINER_IMAGE"
    fi
    CONTAINER_DESC="$APPTAINER_IMAGE"
else
    echo "ERROR: Unsupported LLAVA_CONTAINER_RUNTIME=$CONTAINER_RUNTIME"
    return 1 2>/dev/null || exit 1
fi

echo "Starting LLaVA-OneVision server ($MODEL) on node: $NODE"
echo "  Backend: SGLang in $CONTAINER_RUNTIME"
echo "  Container: $CONTAINER_DESC"
echo "  Log: $LLAVA_LOG"
echo ""
echo "  Remote access:"
echo "    ssh -L ${PORT}:${NODE}:${PORT} berzelius1.nsc.liu.se"
echo "    http://127.0.0.1:${PORT}/v1"
echo ""

sglang_cmd=(
    python3 -m sglang.launch_server
    --model-path "$MODEL"
    --served-model-name "$SERVED_MODEL_NAME"
    --host 0.0.0.0
    --port "$PORT"
    --tensor-parallel-size "$TP_SIZE"
    --mem-fraction-static "$MEM_FRACTION"
    --context-length "$MAX_MODEL_LEN"
    --enable-multimodal
    --trust-remote-code
)

if [[ "$CONTAINER_RUNTIME" == "enroot" ]]; then
    enroot start \
        -m "$PROJECT:$PROJECT" \
        -e "HF_HOME=$HF_HOME" \
        -e "XDG_CACHE_HOME=$XDG_CACHE_HOME" \
        -e "HF_TOKEN=${HF_TOKEN:-}" \
        -e "HUGGING_FACE_HUB_TOKEN=${HUGGING_FACE_HUB_TOKEN:-}" \
        -e "SGLANG_CACHE_DIR=$SGLANG_CACHE_DIR" \
        -e "PYTHONPATH=$SGLANG_CONTAINER_PYTHONPATH" \
        "$ENROOT_IMAGE" \
        "${sglang_cmd[@]}" \
        > "$LLAVA_LOG" 2>&1 &
else
    apptainer exec --nv \
        -B "$PROJECT:$PROJECT" \
        --env "HF_HOME=$HF_HOME" \
        --env "XDG_CACHE_HOME=$XDG_CACHE_HOME" \
        --env "HF_TOKEN=${HF_TOKEN:-}" \
        --env "HUGGING_FACE_HUB_TOKEN=${HUGGING_FACE_HUB_TOKEN:-}" \
        --env "SGLANG_CACHE_DIR=$SGLANG_CACHE_DIR" \
        --env "PYTHONPATH=$SGLANG_CONTAINER_PYTHONPATH" \
        "$APPTAINER_IMAGE" \
        "${sglang_cmd[@]}" \
        > "$LLAVA_LOG" 2>&1 &
fi

SERVER_PID=$!
LLAVA_SERVER_PID="$SERVER_PID"
export LLAVA_SERVER_PID
echo "  PID=$SERVER_PID  (kill with: kill $SERVER_PID)"
echo "  Waiting for server to become ready..."

LLAVA_READY=0
for _ in $(seq 1 180); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: LLaVA server exited unexpectedly. Check $LLAVA_LOG"
        break
    fi
    if llava_health_ok; then
        echo "  Server is ready on http://${NODE}:${PORT}  (or via tunnel: http://127.0.0.1:${PORT})"
        echo "http://${NODE}:${PORT}/v1" > "$PROJECT/.llava_url"
        echo "  LLaVA URL written to $PROJECT/.llava_url"
        echo "  Tail server log: tail -f $LLAVA_LOG"
        LLAVA_READY=1
        break
    fi
    sleep 5
done

if [[ "$LLAVA_READY" != "1" ]]; then
    echo "ERROR: LLaVA did not become healthy. Check $LLAVA_LOG"
    return 1 2>/dev/null || exit 1
fi
