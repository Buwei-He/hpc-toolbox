#!/bin/bash
# setup.sh for profile: cosmos3-nano-reasoner
# Sourced automatically by bjob after the SLURM allocation starts.
# Starts the Cosmos3 Reasoner server in the background, then drops you to a shell.
#
# HOW THIS DIFFERS FROM THE cosmos-reason2 PROFILE (all deliberate):
#
#  1. Apptainer, not conda.  Berzelius is RHEL8 => glibc 2.28, so pip can only
#     use manylinux_2_28 wheels; modern vLLM needs llguidance>=1.8 which ships
#     only manylinux_2_31, so a native install fails building Rust from source.
#     The SIF carries its own glibc + vLLM 0.27.1.  (0.11.2 in qwen8b-vllm312
#     does not know this architecture at all.)
#     Note enroot is NOT usable: it exists only on the login node.
#
#  2. NO --reasoning-parser.  With the qwen3 parser this model's entire output
#     is routed to the `reasoning` field and `content` comes back EMPTY, which
#     silently breaks any client reading message.content (daaam
#     cosmos_client.query does exactly that).  Verified: the model emits no
#     <think> tags and ignores chat_template_kwargs enable_thinking, so nothing
#     is lost by omitting the parser.
#
#  3. NO --hf-overrides.  The vLLM recipe suggests forcing
#     Cosmos3ReasonerForConditionalGeneration, but that name is absent from
#     vLLM 0.27.1's registry and serving would fail.  The checkpoint's native
#     Cosmos3ForConditionalGeneration already IS the reasoner: vLLM implements
#     it as a Qwen3VL subclass whose WeightsMapper drops the generation tower
#     and whose allow_patterns_overrides fetch only transformer/ +
#     vision_encoder/.  Measured: 16.65 GiB of weights load, not the full 30 GB.
#
#  4. Port 8001 by default, and the URL goes to .cosmos3_url, so this can run
#     alongside the cosmos-reason2 profile without clashing (SLURM will happily
#     put both on one node, where a shared port 8000 gives
#     "OSError: [Errno 98] Address already in use").

export PROJECT="${PROJECT:?PROJECT not set -- run this via bjob or percorso-demo, or export PROJECT yourself}"

SIF="${COSMOS3_SIF:-$PROJECT/llm/images/vllm-openai-v0.27.1.sif}"
MODEL="${COSMOS3_MODEL:-nvidia/Cosmos3-Nano}"
SERVED="${COSMOS3_SERVED_NAME:-cosmos3-nano-reasoner}"
PORT="${COSMOS3_PORT:-8001}"
GPU_MEMORY_UTILIZATION="${COSMOS3_GPU_MEMORY_UTILIZATION:-0.90}"
MAX_MODEL_LEN="${COSMOS3_MAX_MODEL_LEN:-16384}"
COSMOS3_LOG="${COSMOS3_LOG:-$PROJECT/.cache/cosmos3-nano-reasoner-vllm.log}"
NODE=$(hostname -s)

export HF_HOME=$PROJECT/.hf_cache
export VLLM_CACHE_ROOT=$PROJECT/.cache/vllm
mkdir -p "$HF_HOME" "$VLLM_CACHE_ROOT" "$PROJECT/.cache" "$PROJECT/.cache/apptainer_home"

if [[ -z "${HUGGING_FACE_HUB_TOKEN:-}" && -f "$HF_HOME/token" ]]; then
    export HUGGING_FACE_HUB_TOKEN="$(cat "$HF_HOME/token")"
fi

_cosmos3_setup_done() {
    return 0 2>/dev/null || exit 0
}

if [[ ! -f "$SIF" ]]; then
    echo "ERROR: image not found: $SIF"
    echo "  Build it with:  JOBID=<a running job> bash \$PROJECT/llm/images/build_vllm_sif.sh"
    return 1 2>/dev/null || exit 1
fi

if curl -sf "http://127.0.0.1:${PORT}/health" > /dev/null 2>&1; then
    echo "Cosmos3 Reasoner already running on node: $NODE"
    echo "http://${NODE}:${PORT}/v1" > "$PROJECT/.cosmos3_url"
    echo "URL written to $PROJECT/.cosmos3_url"
    _cosmos3_setup_done
fi

echo "Starting Cosmos3 Reasoner ($MODEL) on node: $NODE"
echo "  Image: $SIF"
echo "  Log:   $COSMOS3_LOG"
echo ""
echo "  Remote access:"
echo "    ssh -L ${PORT}:${NODE}:${PORT} berzelius1.nsc.liu.se"
echo "    http://127.0.0.1:${PORT}/v1"
echo ""

# --cleanenv keeps a ROS PYTHONPATH / ~/.local site-packages from shadowing the
#   container's vLLM; it also drops PATH, hence the explicit --env PATH.
# --home must point somewhere writable: apptainer refuses --env HOME, and with
#   --no-home flashinfer dies creating its JIT workspace under a read-only
#   /home ("OSError: [Errno 30] Read-only file system").
apptainer exec --nv --cleanenv \
    --home "$PROJECT/.cache/apptainer_home" \
    --bind "$PROJECT:$PROJECT" \
    --env PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin \
    --env HF_HOME="$HF_HOME" \
    --env HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-}" \
    --env VLLM_CACHE_ROOT="$VLLM_CACHE_ROOT" \
    --env OMP_NUM_THREADS=1 \
    "$SIF" vllm serve "$MODEL" \
      --host 0.0.0.0 \
      --port "$PORT" \
      --served-model-name "$SERVED" \
      --allowed-local-media-path "$PROJECT" \
      --limit-mm-per-prompt '{"image":8,"video":1}' \
      --media-io-kwargs '{"video": {"num_frames": -1}}' \
      --max-model-len "$MAX_MODEL_LEN" \
      --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
      > "$COSMOS3_LOG" 2>&1 &

VLLM_PID=$!
COSMOS3_VLLM_PID="$VLLM_PID"
export COSMOS3_VLLM_PID
echo "  PID=$VLLM_PID  (kill with: kill $VLLM_PID)"
echo "  Waiting for server to become ready (first run downloads ~30 GB)..."

COSMOS3_READY=0
for _ in $(seq 1 240); do
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        echo "ERROR: vLLM exited unexpectedly. Check $COSMOS3_LOG"
        break
    fi
    if curl -sf "http://127.0.0.1:${PORT}/health" > /dev/null 2>&1; then
        echo "  Server ready on http://${NODE}:${PORT}  (tunnel: http://127.0.0.1:${PORT})"
        echo "http://${NODE}:${PORT}/v1" > "$PROJECT/.cosmos3_url"
        echo "  URL written to $PROJECT/.cosmos3_url"
        echo "  Tail server log: tail -f $COSMOS3_LOG"
        echo "  Smoke test: python \$PROJECT/llm/test/smoke_test.py \\"
        echo "                --base-url http://${NODE}:${PORT}/v1 --model $SERVED"
        COSMOS3_READY=1
        break
    fi
    sleep 5
done

if [[ "${COSMOS3_READY:-0}" != "1" ]]; then
    echo "ERROR: Cosmos3 did not become healthy. Check $COSMOS3_LOG"
    return 1 2>/dev/null || exit 1
fi
