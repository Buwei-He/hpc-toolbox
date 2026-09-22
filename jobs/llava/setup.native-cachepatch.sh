#!/bin/bash
# setup.sh for profile: llava
# Sourced automatically by bjob after the SLURM allocation starts.
# Activates the vLLM env, starts the LLaVA-OneVision-2-8B server in the
# background on 0.0.0.0:8000, then drops you to an interactive shell.

export PROJECT="${PROJECT:?PROJECT not set -- run this via bjob or percorso-demo, or export PROJECT yourself}"

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
    HUGGING_FACE_HUB_TOKEN="$(cat "$HF_HOME/token")"
    export HUGGING_FACE_HUB_TOKEN
fi

LLAVA_LOG="${LLAVA_LOG:-$PROJECT/.cache/llava-onevision-vllm.log}"
MODEL="${LLAVA_MODEL:-lmms-lab-encoder/LLaVA-OneVision-2-8B-Instruct}"
GPU_MEMORY_UTILIZATION="${LLAVA_GPU_MEMORY_UTILIZATION:-0.90}"
NODE=$(hostname -s)

patch_llava_onevision_config_cache() {
    [[ "$MODEL" == "lmms-lab-encoder/LLaVA-OneVision-2-8B-Instruct" ]] || return 0

    # The current model repo uses a few APIs differently from the versions in
    # this vLLM env. Patch only the local trusted-code cache.
    if command -v hf > /dev/null 2>&1; then
        hf download "$MODEL" configuration_llava_onevision2.py > /dev/null 2>&1 || true
        hf download "$MODEL" modeling_llava_onevision2.py > /dev/null 2>&1 || true
        hf download "$MODEL" processing_llava_onevision2.py > /dev/null 2>&1 || true
    fi

    python3 <<'PY'
import os
import shutil
from pathlib import Path

hf_home = Path(os.environ["HF_HOME"])
roots = [
    hf_home / "hub/models--lmms-lab-encoder--LLaVA-OneVision-2-8B-Instruct",
    hf_home / "modules/transformers_modules/lmms_hyphen_lab_hyphen_encoder/LLaVA_hyphen_OneVision_hyphen_2_hyphen_8B_hyphen_Instruct",
]
patched = False

for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("configuration_llava_onevision2.py"):
        target = path.resolve()
        text = target.read_text()
        new_text = text
        new_text = new_text.replace("PreTrainedConfig", "PretrainedConfig")
        new_text = new_text.replace("from huggingface_hub.dataclasses import strict\n\n", "")
        new_text = new_text.replace("\n@strict\nclass ", "\nclass ")
        new_text = new_text.replace(
            "    def __post_init__(self, **kwargs):\n",
            "    def __init__(self, **kwargs):\n        super().__init__(**kwargs)\n",
        )
        new_text = new_text.replace("\n        super().__post_init__(**kwargs)\n", "\n")
        new_text = new_text.replace(
            "from transformers import CONFIG_MAPPING, AutoConfig\nfrom transformers.configuration_utils import PretrainedConfig\n",
            "from transformers.configuration_utils import PretrainedConfig\nfrom transformers.models.qwen3.configuration_qwen3 import Qwen3Config\n",
        )
        new_text = new_text.replace(
            '    # `text_config` is resolved dynamically based on its `model_type` (defaults to `qwen3`),\n'
            '    # so we use `AutoConfig` here as a placeholder; `__post_init__` swaps it for the\n'
            '    # concrete config class via `CONFIG_MAPPING`.\n'
            '    sub_configs = {"vision_config": LlavaOnevision2VisionConfig, "text_config": AutoConfig}\n',
            '    sub_configs = {"vision_config": LlavaOnevision2VisionConfig, "text_config": Qwen3Config}\n',
        )
        new_text = new_text.replace(
            '    sub_configs = {"vision_config": LlavaOnevision2VisionConfig, "text_config": AutoConfig}\n',
            '    sub_configs = {"vision_config": LlavaOnevision2VisionConfig, "text_config": Qwen3Config}\n',
        )
        new_text = new_text.replace(
            "    def __init__(self, **kwargs):\n        super().__init__(**kwargs)\n        # Resolve vision_config\n",
            "    def __init__(self, **kwargs):\n        super().__init__(**kwargs)\n        # Resolve vision_config\n",
        )
        new_text = new_text.replace(
            '        # Resolve text_config dynamically via CONFIG_MAPPING (defaults to qwen3)\n'
            '        if isinstance(self.text_config, dict):\n'
            '            text_model_type = self.text_config.get("model_type", "qwen3")\n'
            '            self.text_config["model_type"] = text_model_type\n'
            '            text_config_cls = CONFIG_MAPPING[text_model_type]\n'
            '            self.sub_configs["text_config"] = text_config_cls\n'
            '            self.text_config = text_config_cls(**self.text_config)\n'
            '        elif self.text_config is None:\n'
            '            text_config_cls = CONFIG_MAPPING["qwen3"]\n'
            '            self.sub_configs["text_config"] = text_config_cls\n'
            '            self.text_config = text_config_cls()\n',
            '        # Resolve text_config directly. The model card ships Qwen3 text weights,\n'
            '        # and avoiding AutoConfig/CONFIG_MAPPING keeps this config pickle-safe for vLLM.\n'
            '        if isinstance(self.text_config, dict):\n'
            '            text_model_type = self.text_config.get("model_type", "qwen3")\n'
            '            if text_model_type != "qwen3":\n'
            '                raise ValueError(f"Unsupported text_config model_type for this patch: {text_model_type!r}")\n'
            '            self.text_config["model_type"] = text_model_type\n'
            '            self.text_config = Qwen3Config(**self.text_config)\n'
            '        elif self.text_config is None:\n'
            '            self.text_config = Qwen3Config()\n',
        )
        if new_text != text:
            target.write_text(new_text)
            patched = True

fallback_import = (
    "try:\n"
    "    from transformers.utils.generic import is_flash_attention_requested\n"
    "except ImportError:\n"
    "    def is_flash_attention_requested(config):\n"
    "        return getattr(config, '_attn_implementation', None) == 'flash_attention_2'\n"
)
config_import = "from .configuration_llava_onevision2 import LlavaOnevision2Config, LlavaOnevision2VisionConfig"

for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("processing_llava_onevision2.py"):
        target = path.resolve()
        text = target.read_text()
        new_text = text
        if "from transformers.processing_utils import ProcessorMixin" not in new_text:
            new_text = new_text.replace("import torch\n", "import torch\nfrom transformers.processing_utils import MultiModalData, ProcessorMixin\n")
        new_text = new_text.replace(
            "from transformers.processing_utils import ProcessorMixin\n",
            "from transformers.processing_utils import MultiModalData, ProcessorMixin\n",
        )
        new_text = new_text.replace("class LlavaOnevision2Processor:\n", "class LlavaOnevision2Processor(ProcessorMixin):\n")
        new_text = new_text.replace(
            "    NOTE: We deliberately do NOT inherit ``transformers.ProcessorMixin``.\n",
            "    NOTE: This local cache patch inherits ``transformers.ProcessorMixin`` for vLLM compatibility.\n",
        )
        if 'out["mm_token_type_ids"]' not in new_text:
            new_text = new_text.replace(
                '        out["attention_mask"] = encoding.get(\n'
                '            "attention_mask",\n'
                '            torch.ones_like(encoding["input_ids"]),\n'
                '        )\n\n'
                '        try:\n',
                '        out["attention_mask"] = encoding.get(\n'
                '            "attention_mask",\n'
                '            torch.ones_like(encoding["input_ids"]),\n'
                '        )\n'
                '        image_token_id = getattr(self, "image_token_id", None)\n'
                '        if image_token_id is None and self.tokenizer is not None:\n'
                '            image_token_id = self.tokenizer.convert_tokens_to_ids(IMAGE_PAD)\n'
                '        if image_token_id is not None:\n'
                '            out["mm_token_type_ids"] = (encoding["input_ids"] == image_token_id).long()\n\n'
                '        try:\n',
            )
        if "def _get_num_multimodal_tokens" not in new_text:
            method = '\n    def _get_num_multimodal_tokens(self, image_sizes=None, video_sizes=None, **kwargs):\n        vision_data = {}\n        if image_sizes is not None:\n            images_kwargs = dict(kwargs)\n            merge_size = images_kwargs.get("merge_size", None) or getattr(self.image_processor, "merge_size", 2)\n            num_image_patches = [\n                self.image_processor.get_number_of_image_patches(height, width, images_kwargs)\n                for height, width in image_sizes\n            ]\n            num_image_tokens = [num_patches // (merge_size ** 2) for num_patches in num_image_patches]\n            vision_data.update({"num_image_tokens": num_image_tokens, "num_image_patches": num_image_patches})\n\n        if video_sizes is not None:\n            vision_data.setdefault("num_video_tokens", [0 for _ in video_sizes])\n\n        return MultiModalData(**vision_data)\n\n'
            new_text = new_text.replace(
                "    # ------------------------------------------------------------- chat helpers\n",
                method + "    # ------------------------------------------------------------- chat helpers\n",
            )
        if new_text != text:
            target.write_text(new_text)
            patched = True

for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("modeling_llava_onevision2.py"):
        target = path.resolve()
        text = target.read_text()
        new_text = text
        if "is_flash_attention_requested" in new_text and config_import in new_text:
            prefix, rest = new_text.split("from transformers.utils import (", 1)
            utils_block, suffix = rest.split(config_import, 1)
            new_text = prefix + "from transformers.utils import (" + utils_block.split(")", 1)[0] + ")\n" + fallback_import + "\n" + config_import + suffix
        if "_supports_sdpa = True\n" in new_text and "_supports_attention_backend" not in new_text:
            new_text = new_text.replace("_supports_sdpa = True\n", "_supports_sdpa = True\n    _supports_attention_backend = True\n")
        if new_text != text:
            target.write_text(new_text)
            patched = True

for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("__pycache__"):
        shutil.rmtree(path, ignore_errors=True)

if patched:
    print("  Patched local LLaVA remote-code cache for this Transformers version.")
PY
}

if curl -sf http://127.0.0.1:8000/health > /dev/null 2>&1; then
    echo "LLaVA-OneVision server is already running on node: $NODE"
    echo "http://${NODE}:8000/v1" > "$PROJECT/.llava_url"
    echo "LLaVA URL written to $PROJECT/.llava_url"
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 0
    fi
    exit 0
fi

echo "Starting LLaVA-OneVision server ($MODEL) on node: $NODE"
echo "  Log: $LLAVA_LOG"
echo ""
echo "  Remote access:"
echo "    ssh -L 8000:${NODE}:8000 berzelius1.nsc.liu.se"
echo "    http://127.0.0.1:8000/v1"
echo ""

patch_llava_onevision_config_cache

vllm serve "$MODEL" \
    --host 0.0.0.0 \
    --port 8000 \
    --served-model-name llava-onevision \
    --trust-remote-code \
    --model-impl transformers \
    --allowed-local-media-path "$PROJECT" \
    --limit-mm-per-prompt '{"image":4,"video":1}' \
    --max-model-len 16384 \
    --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
    > "$LLAVA_LOG" 2>&1 &

VLLM_PID=$!
LLAVA_VLLM_PID="$VLLM_PID"
export LLAVA_VLLM_PID
echo "  PID=$VLLM_PID  (kill with: kill $VLLM_PID)"
echo "  Waiting for server to become ready..."

LLAVA_READY=0
for _ in $(seq 1 120); do
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        echo "ERROR: vLLM server exited unexpectedly. Check $LLAVA_LOG"
        break
    fi
    if curl -sf http://127.0.0.1:8000/health > /dev/null 2>&1; then
        echo "  Server is ready on http://${NODE}:8000  (or via tunnel: http://127.0.0.1:8000)"
        echo "http://${NODE}:8000/v1" > "$PROJECT/.llava_url"
        echo "  LLaVA URL written to $PROJECT/.llava_url"
        echo "  Tail server log: tail -f $LLAVA_LOG"
        LLAVA_READY=1
        break
    fi
    sleep 5
done

if [[ "${LLAVA_READY:-0}" != "1" ]]; then
    echo "ERROR: LLaVA did not become healthy. Check $LLAVA_LOG"
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 1
    fi
    exit 1
fi
