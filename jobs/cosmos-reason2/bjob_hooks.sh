# bjob_hooks.sh — cosmos-reason2's bjob extension.
# Points `bjob logs` at the vLLM log this profile's setup.sh writes.

hook_extra_log_globs() {
    printf '%s\n' "$PROJECT/.cache/cosmos-reason2-vllm.log"
}
