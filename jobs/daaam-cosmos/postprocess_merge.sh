#!/bin/bash
# postprocess_merge.sh — Organise, post-process, and merge EGG batch outputs.
#
# Usage:
#   bash postprocess_merge.sh [-i|--interactive] <group> [batch_dir ...]
#   INTERACTIVE=1 bash postprocess_merge.sh [group] [batch_dir ...]
#
#   group        Label for the run folder (e.g. "20260608").
#                Output lands in output/egg/<group>/merged_egg.
#                Also used as a date filter for auto-discovery when no dirs given.
#   batch_dir    Explicit host-side batch dirs. Auto-discovered by date if omitted.
#
# Skip entire steps by setting SKIP_* to 1 (e.g. SKIP_CLUSTER=1):
#   SKIP_EVENT_GROUPER  skip event_grouper.py
#   SKIP_SEMANTIC       skip semantic_post_processing
#   SKIP_POSTPROCESS    skip postprocess_scene_graph.py
#   SKIP_CLUSTER        skip cluster_places ros2 launch
#   SKIP_SUMMARIZE      skip summarize_regions.py
#   SKIP_MERGE          skip final merge_dsgs.py
#
# Each step auto-skips per batch when its output already exists.
# Force re-run even when output exists with FORCE_* flags (e.g. FORCE_CLUSTER=1):
#   FORCE_GROUP_EVENTS  re-run event_grouper even if events.yaml exists
#   FORCE_SEMANTIC      re-run even if events_semantic.yaml exists
#   FORCE_POSTPROCESS   re-run even if dsg_updated.json exists
#   FORCE_CLUSTER       re-run even if clustered_dsg.json exists
#   FORCE_SUMMARIZE     re-run even if region_summaries.yaml exists
#
# Other env vars:
#   PROJECT           default: /proj/rpl-soro/users/$USER
#   OPENAI_API_KEY    required for GPT semantic judge and summarize step;
#                     summarize is skipped if unset
#   SUMMARIZE_MODEL   default: gpt-5.4-mini
#   SENTENCE_MODEL    default: sentence-transformers/sentence-t5-xl
#   SEMANTIC_BASE_URL default: $OPENAI_BASE_URL from ~/.bashrc, else https://api.openai.com/v1
#   SEMANTIC_MODEL    default: gpt-5.4-mini
#   GROUPER_MODEL     default: $SEMANTIC_MODEL
#   GROUPER_OUTPUT_NAME
#                     default: events.yaml
#   BATCH_HOURS       include only start hours, comma/range list (e.g. 00,08,11-12)
#   EXCLUDE_HOURS     exclude start hours, comma/range list
#   SELECT_BATCHES    include only egg_batch numbers, comma/range list (e.g. 1,3-5)
#   DESELECT_BATCHES  exclude egg_batch numbers, comma/range list
#   INTERACTIVE       set to 1 for fzf/typed batch and step selection
#   POSTPROCESS_INTERACTIVE
#                     alias for INTERACTIVE that is not affected by ~/.bashrc
#   DAAAM_RUN_DIRECT  set to 1 to run commands in the current shell/container
#                     instead of nesting apptainer exec. Auto-enabled inside Apptainer.
#   MERGE_JUDGE       default: llm. Set to none to avoid LLM merge judging.

set -euo pipefail

export PROJECT="${PROJECT:-/proj/rpl-soro/users/$USER}"
_SCRIPT_PROJECT="$PROJECT"
_REQUESTED_INTERACTIVE="${INTERACTIVE:-1}"

# Load user-provided API keys/endpoints. Some .bashrc files assume an
# interactive shell or reference unset variables, so source it defensively.
if [[ -f "$HOME/.bashrc" ]]; then
    set +e +u
    source "$HOME/.bashrc" >/dev/null 2>&1 || true
    set -euo pipefail
fi
PROJECT="$_SCRIPT_PROJECT"
export PROJECT

# If .bashrc assigned but did not export these, export them for apptainer.
[[ -n "${OPENAI_API_KEY:-}" ]] && export OPENAI_API_KEY
[[ -n "${COSMOS_API_KEY:-}" ]] && export COSMOS_API_KEY
[[ -n "${OPENAI_BASE_URL:-}" ]] && export OPENAI_BASE_URL
[[ -n "${SEMANTIC_BASE_URL:-}" ]] && export SEMANTIC_BASE_URL
[[ -n "${SEMANTIC_MODEL:-}" ]] && export SEMANTIC_MODEL

DAAAM_SIF="$PROJECT/containers/daaam.sif"
EGG_BASE_HOST="$PROJECT/ros2_ws/src/daaam/output/egg"
EGG_BASE_CONT="/ros2_ws/src/daaam/output/egg"
SCRIPTS_CONT="/ros2_ws/src/daaam/scripts"
DAAAM_RUN_DIRECT="${DAAAM_RUN_DIRECT:-0}"
if [[ -n "${APPTAINER_CONTAINER:-}${SINGULARITY_CONTAINER:-}" || -d "/.singularity.d" ]]; then
    DAAAM_RUN_DIRECT=1
fi
if [[ "$DAAAM_RUN_DIRECT" == "1" && ! -d "/ros2_ws/src/daaam" ]]; then
    EGG_BASE_CONT="$EGG_BASE_HOST"
    SCRIPTS_CONT="$PROJECT/ros2_ws/src/daaam/scripts"
fi

SUMMARIZE_MODEL="${SUMMARIZE_MODEL:-gpt-5.4-mini}"
SENTENCE_MODEL="${SENTENCE_MODEL:-sentence-transformers/sentence-t5-xl}"
SEMANTIC_BASE_URL="${SEMANTIC_BASE_URL:-${OPENAI_BASE_URL:-https://api.openai.com/v1}}"
SEMANTIC_MODEL="${SEMANTIC_MODEL:-gpt-5.4-mini}"
GROUPER_BASE_URL="${GROUPER_BASE_URL:-$SEMANTIC_BASE_URL}"
GROUPER_MODEL="${GROUPER_MODEL:-$SEMANTIC_MODEL}"
GROUPER_OUTPUT_NAME="${GROUPER_OUTPUT_NAME:-events.yaml}"
BATCH_HOURS="${BATCH_HOURS:-${INCLUDE_HOURS:-${HOUR_FILTER:-}}}"
EXCLUDE_HOURS="${EXCLUDE_HOURS:-${DESELECT_HOURS:-}}"
SELECT_BATCHES="${SELECT_BATCHES:-${INCLUDE_BATCHES:-}}"
DESELECT_BATCHES="${DESELECT_BATCHES:-${EXCLUDE_BATCHES:-}}"
INTERACTIVE="${POSTPROCESS_INTERACTIVE:-$_REQUESTED_INTERACTIVE}"
export SEMANTIC_BASE_URL SEMANTIC_MODEL GROUPER_BASE_URL GROUPER_MODEL
SEMANTIC_MERGE_JUDGE="${MERGE_JUDGE:-llm}"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

usage() {
    grep '^#' "$0" | sed 's/^# \?//' | head -24 >&2
    exit 1
}

_read_answer() {
    local prompt="$1" answer=""
    if [[ -t 0 ]]; then
        read -r -p "$prompt" answer || answer=""
    elif { true </dev/tty >/dev/tty; } 2>/dev/null; then
        read -r -p "$prompt" answer </dev/tty || answer=""
    else
        read -r -p "$prompt" answer || answer=""
    fi
    printf '%s' "$answer"
}

_confirm_yes() {
    local prompt="$1" default="${2:-Y}" answer norm
    while true; do
        answer="$(_read_answer "$prompt")"
        norm="${answer,,}"
        norm="${norm//[[:space:]]/}"
        case "$norm" in
            "")
                [[ "${default^^}" == "Y" ]]
                return
                ;;
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                printf "  Please answer y/yes or n/no.\n" >&2
                ;;
        esac
    done
}

if [[ "${1:-}" == "-i" || "${1:-}" == "--interactive" ]]; then
    INTERACTIVE=1
    shift
fi

if [[ $# -lt 1 ]]; then
    if [[ "$INTERACTIVE" == "1" ]]; then
        GROUP="$(_read_answer "  Group/date label (e.g. 20260615): ")"
        [[ -n "$GROUP" ]] || usage
    else
        usage
    fi
else
    GROUP="$1"
    shift
fi
declare -a INPUT_DIRS=("$@")

_semantic_needed_from_inputs() {
    local d
    [[ "${SKIP_SEMANTIC:-0}" != "1" ]] || return 1
    for d in "${INPUT_DIRS[@]}"; do
        [[ -f "$d/events.yaml" ]] || continue
        [[ -f "$d/events_semantic.yaml" && "${FORCE_SEMANTIC:-0}" != "1" ]] && continue
        return 0
    done
    return 1
}

_force_group_events() {
    [[ "${FORCE_GROUP_EVENTS:-0}" == "1" || "${FORCE_EVENT_GROUPER:-0}" == "1" ]]
}

_has_hoi_clips() {
    local d="$1"
    [[ -d "$d/human_clips" ]] || return 1
    find "$d/human_clips" -maxdepth 1 -type f -name '*_cosmos_hoi.yaml' -print -quit 2>/dev/null | grep -q .
}

_event_grouper_needed_from_inputs() {
    local d
    [[ "${SKIP_EVENT_GROUPER:-0}" != "1" ]] || return 1
    for d in "${INPUT_DIRS[@]}"; do
        _has_hoi_clips "$d" || continue
        _force_group_events || [[ ! -f "$d/$GROUPER_OUTPUT_NAME" ]] || continue
        return 0
    done
    return 1
}

_llm_api_key_available() {
    [[ -n "${OPENAI_API_KEY:-}" || -n "${COSMOS_API_KEY:-}" ]]
}

_number_in_spec() {
    local value="$1" spec="$2" token start end
    [[ -n "$spec" ]] || return 1
    value=$((10#$value))
    for token in ${spec//,/ }; do
        [[ -n "$token" ]] || continue
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=$((10#${BASH_REMATCH[1]}))
            end=$((10#${BASH_REMATCH[2]}))
            if (( start <= value && value <= end )); then
                return 0
            fi
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            if (( value == 10#$token )); then
                return 0
            fi
        fi
    done
    return 1
}

_batch_hour() {
    local base
    base="$(basename "$1")"
    if [[ "$base" =~ _out_[0-9]{8}_([0-9]{2})[0-9]{4}$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

_batch_number() {
    local base
    base="$(basename "$1")"
    if [[ "$base" =~ ^egg_batch_([0-9]+)_ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

_dir_passes_filters() {
    local d="$1" hour batch_num
    if [[ -n "$BATCH_HOURS$EXCLUDE_HOURS" ]]; then
        hour="$(_batch_hour "$d")" || return 1
        [[ -z "$BATCH_HOURS" ]] || _number_in_spec "$hour" "$BATCH_HOURS" || return 1
        [[ -z "$EXCLUDE_HOURS" ]] || ! _number_in_spec "$hour" "$EXCLUDE_HOURS" || return 1
    fi
    if [[ -n "$SELECT_BATCHES$DESELECT_BATCHES" ]]; then
        batch_num="$(_batch_number "$d")" || return 1
        [[ -z "$SELECT_BATCHES" ]] || _number_in_spec "$batch_num" "$SELECT_BATCHES" || return 1
        [[ -z "$DESELECT_BATCHES" ]] || ! _number_in_spec "$batch_num" "$DESELECT_BATCHES" || return 1
    fi
    return 0
}

_apply_batch_filters() {
    local d
    local -a filtered=()
    for d in "${INPUT_DIRS[@]}"; do
        if _dir_passes_filters "$d"; then
            filtered+=("$d")
        fi
    done
    INPUT_DIRS=("${filtered[@]}")
}

_sort_input_dirs_by_date() {
    local d base stamp batch_num
    local -a sorted=()
    mapfile -t sorted < <(
        for d in "${INPUT_DIRS[@]}"; do
            base="$(basename "$d")"
            if [[ "$base" =~ _out_([0-9]{8})_([0-9]{6})$ ]]; then
                stamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
            else
                stamp="99999999999999"
            fi
            if [[ "$base" =~ ^egg_batch_([0-9]+)_ ]]; then
                batch_num="$(printf '%04d' "${BASH_REMATCH[1]}")"
            else
                batch_num="9999"
            fi
            printf '%s\t%s\t%s\n' "$stamp" "$batch_num" "$d"
        done | sort -k1,1 -k2,2 | cut -f3-
    )
    INPUT_DIRS=("${sorted[@]}")
}

_tty_available() {
    [[ -t 0 ]] || { true </dev/tty >/dev/tty; } 2>/dev/null
}

_set_step_skips_from_keys() {
    local key
    SKIP_EVENT_GROUPER=1
    SKIP_SEMANTIC=1
    SKIP_POSTPROCESS=1
    SKIP_CLUSTER=1
    SKIP_SUMMARIZE=1
    SKIP_MERGE=1
    for key in "$@"; do
        case "$key" in
            event_grouper) SKIP_EVENT_GROUPER=0 ;;
            semantic) SKIP_SEMANTIC=0 ;;
            postprocess) SKIP_POSTPROCESS=0 ;;
            cluster) SKIP_CLUSTER=0 ;;
            summarize) SKIP_SUMMARIZE=0 ;;
            merge) SKIP_MERGE=0 ;;
        esac
    done
}

_interactive_select_batches() {
    local selected answer i d
    local -a chosen=()
    [[ "$INTERACTIVE" == "1" ]] || return 0
    if ! _tty_available; then
        printf "${Y}Interactive batch selection requested, but no TTY is available; keeping discovered batches.${NC}\n" >&2
        return 0
    fi
    [[ ${#INPUT_DIRS[@]} -gt 0 ]] || return 0

    printf "\n${BOLD}${C}  Select batches${NC}\n"
    if command -v fzf >/dev/null 2>&1; then
        selected="$(printf '%s\n' "${INPUT_DIRS[@]}" | fzf --multi --height=80% --border \
            --prompt='batches> ' \
            --header='TAB toggles, arrows move, ENTER accepts. Empty selection keeps all discovered batches.' \
            --preview='basename {}')" || selected=""
        if [[ -n "$selected" ]]; then
            mapfile -t INPUT_DIRS <<< "$selected"
        else
            printf "  Keeping all %d discovered batch(es).\n" "${#INPUT_DIRS[@]}"
        fi
        return 0
    fi

    printf "  fzf not found; using typed fallback.\n"
    for i in "${!INPUT_DIRS[@]}"; do
        printf "    %2d  %s\n" "$((i + 1))" "$(basename "${INPUT_DIRS[$i]}")"
    done
    answer="$(_read_answer "  Select batch rows [default all, e.g. 1,3-5]: ")"
    [[ -n "$answer" ]] || return 0
    for i in "${!INPUT_DIRS[@]}"; do
        if _number_in_spec "$((i + 1))" "$answer"; then
            chosen+=("${INPUT_DIRS[$i]}")
        fi
    done
    if [[ ${#chosen[@]} -gt 0 ]]; then
        INPUT_DIRS=("${chosen[@]}")
    else
        printf "  No rows matched; keeping all discovered batches.\n"
    fi
}

_interactive_select_steps() {
    local selected answer i key
    local -a keys=(event_grouper semantic postprocess cluster summarize merge)
    local -a labels=(
        $'event_grouper	event_grouper'
        $'semantic	semantic_post_processing'
        $'postprocess	postprocess_scene_graph'
        $'cluster	cluster_places'
        $'summarize	summarize_regions'
        $'merge	merge_dsgs'
    )
    local -a selected_keys=()
    [[ "$INTERACTIVE" == "1" ]] || return 0
    if ! _tty_available; then
        printf "${Y}Interactive step selection requested, but no TTY is available; keeping env-selected steps.${NC}\n" >&2
        return 0
    fi

    printf "\n${BOLD}${C}  Select steps/functions${NC}\n"
    if command -v fzf >/dev/null 2>&1; then
        selected="$(printf '%s\n' "${labels[@]}" | fzf --multi --height=60% --border \
            --delimiter=$'\t' --with-nth=2 \
            --prompt='steps> ' \
            --header='TAB toggles, arrows move, ENTER accepts. Empty selection keeps all steps.')" || selected=""
        if [[ -n "$selected" ]]; then
            while IFS=$'	' read -r key _; do
                [[ -n "$key" ]] && selected_keys+=("$key")
            done <<< "$selected"
            _set_step_skips_from_keys "${selected_keys[@]}"
        else
            printf "  Keeping all steps enabled.\n"
        fi
        return 0
    fi

    printf "  fzf not found; using typed fallback.\n"
    printf "    1  event_grouper\n"
    printf "    2  semantic_post_processing\n"
    printf "    3  postprocess_scene_graph\n"
    printf "    4  cluster_places\n"
    printf "    5  summarize_regions\n"
    printf "    6  merge_dsgs\n"
    answer="$(_read_answer "  Select step rows [default all, e.g. 1,2,6]: ")"
    [[ -n "$answer" ]] || return 0
    for i in "${!keys[@]}"; do
        if _number_in_spec "$((i + 1))" "$answer"; then
            selected_keys+=("${keys[$i]}")
        fi
    done
    if [[ ${#selected_keys[@]} -gt 0 ]]; then
        _set_step_skips_from_keys "${selected_keys[@]}"
    else
        printf "  No rows matched; keeping all steps enabled.\n"
    fi
}

# ── Auto-discover batch dirs (top level + already-grouped) ───────────────────
if [[ ${#INPUT_DIRS[@]} -eq 0 ]]; then
    mapfile -t INPUT_DIRS < <(
        {
            # Not yet grouped (fresh run)
            find "$EGG_BASE_HOST" -maxdepth 1 -type d \
                -name "egg_batch_*_out_${GROUP}_*" 2>/dev/null
            # Already moved into group dir (resume after failure)
            find "$EGG_BASE_HOST/$GROUP" -maxdepth 1 -type d \
                -name "egg_batch_*" 2>/dev/null
        } | sort -V | uniq
    )
fi

_apply_batch_filters
_sort_input_dirs_by_date
_interactive_select_batches
_interactive_select_steps

if [[ ${#INPUT_DIRS[@]} -eq 0 ]]; then
    printf "${R}No batch dirs found for group \"%s\" under %s${NC}\n" "$GROUP" "$EGG_BASE_HOST" >&2
    printf "Provide explicit dirs or use a GROUP matching the date in batch dir names.\n" >&2
    exit 1
fi

if _event_grouper_needed_from_inputs && ! _llm_api_key_available; then
    printf "${R}OPENAI_API_KEY or COSMOS_API_KEY is required for event_grouper.${NC}\n" >&2
    exit 1
fi
if _semantic_needed_from_inputs && [[ "$SEMANTIC_MERGE_JUDGE" == "llm" ]] && ! _llm_api_key_available; then
    printf "${R}OPENAI_API_KEY or COSMOS_API_KEY is required for semantic_post_processing with MERGE_JUDGE=llm.${NC}\n" >&2
    printf "Set OPENAI_API_KEY, or set MERGE_JUDGE=none to run without LLM merge judging.\n" >&2
    exit 1
fi

# ── Group dir and merged output name ────────────────────────────────────────
GROUP_DIR_HOST="$EGG_BASE_HOST/$GROUP"
mkdir -p "$GROUP_DIR_HOST"

MERGED_NAME="merged_egg"
n=1
while [[ -d "$GROUP_DIR_HOST/$MERGED_NAME" ]]; do
    n=$(( n + 1 ))
    MERGED_NAME="merged_egg_$n"
done
MERGED_DIR_HOST="$GROUP_DIR_HOST/$MERGED_NAME"
MERGED_DIR_CONT="$EGG_BASE_CONT/$GROUP/$MERGED_NAME"

# ── Print plan ───────────────────────────────────────────────────────────────
printf "\n${BOLD}${C}  Post-process + merge: %s${NC}\n\n" "$GROUP"
printf "  Group dir:  %s\n" "$GROUP_DIR_HOST"
printf "  Merged out: %s\n" "$MERGED_DIR_HOST"
printf "  Runner:     "
if [[ "$DAAAM_RUN_DIRECT" == "1" ]]; then
    printf "current shell/container\n"
else
    printf "apptainer exec %s\n" "$DAAAM_SIF"
fi
[[ "$n" -gt 1 ]] && printf "  ${Y}(merged_egg already exists; using %s)${NC}\n" "$MERGED_NAME"
[[ "$INTERACTIVE" == "1" ]] && printf "  Interactive: enabled\n"
printf "\n  Batches (%d):\n" "${#INPUT_DIRS[@]}"
for d in "${INPUT_DIRS[@]}"; do printf "    %s\n" "$(basename "$d")"; done
if [[ -n "$BATCH_HOURS$EXCLUDE_HOURS$SELECT_BATCHES$DESELECT_BATCHES" ]]; then
    printf "\n  Filters:\n"
    [[ -n "$BATCH_HOURS" ]] && printf "    include hours:  %s\n" "$BATCH_HOURS"
    [[ -n "$EXCLUDE_HOURS" ]] && printf "    exclude hours:  %s\n" "$EXCLUDE_HOURS"
    [[ -n "$SELECT_BATCHES" ]] && printf "    select batches: %s\n" "$SELECT_BATCHES"
    [[ -n "$DESELECT_BATCHES" ]] && printf "    deselect batches: %s\n" "$DESELECT_BATCHES"
fi
printf "\n  Steps:\n"
[[ "${SKIP_EVENT_GROUPER:-0}" == "1" ]] && printf "    ${Y}[SKIP]${NC}" || printf "    [RUN] "
printf " event_grouper            (model: %s, output: %s)\n" "$GROUPER_MODEL" "$GROUPER_OUTPUT_NAME"
[[ "${SKIP_SEMANTIC:-0}" == "1" ]] && printf "    ${Y}[SKIP]${NC}" || printf "    [RUN] "
printf " semantic_post_processing (model: %s, endpoint: %s)\n" "$SEMANTIC_MODEL" "$SEMANTIC_BASE_URL"
[[ "${SKIP_POSTPROCESS:-0}" == "1" ]] && printf "    ${Y}[SKIP]${NC}" || printf "    [RUN] "
printf " postprocess_scene_graph  (sentence: %s)\n" "$SENTENCE_MODEL"
[[ "${SKIP_CLUSTER:-0}" == "1" ]] && printf "    ${Y}[SKIP]${NC}" || printf "    [RUN] "
printf " cluster_places\n"
[[ "${SKIP_SUMMARIZE:-0}" == "1" ]] && printf "    ${Y}[SKIP]${NC}" || {
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        printf "    ${Y}[SKIP]${NC}"
    else
        printf "    [RUN] "
    fi
}
printf " summarize_regions        (model: %s, n=%s)\n" "$SUMMARIZE_MODEL" "${N_SUMMARIZE_SAMPLES:-20}"
[[ "${SKIP_MERGE:-0}" == "1" ]] && printf "    ${Y}[SKIP]${NC}" || printf "    [RUN] "
printf " merge_dsgs\n"
[[ -z "${OPENAI_API_KEY:-}" && "${SKIP_SUMMARIZE:-0}" != "1" ]] && \
    printf "\n  ${Y}Note: OPENAI_API_KEY not set — summarize step will be skipped.${NC}\n"
printf "\n"
if ! _confirm_yes "  Proceed? [Y/n]: " Y; then
    exit 0
fi
printf "\n"

# ── Move batch dirs into group dir (no-clobber) ──────────────────────────────
declare -a BATCH_DIRS=()
for src in "${INPUT_DIRS[@]}"; do
    name="$(basename "$src")"
    dst="$GROUP_DIR_HOST/$name"
    if [[ "$src" == "$dst" ]]; then
        # Already in the right place
        BATCH_DIRS+=("$dst")
    elif [[ -d "$dst" ]]; then
        printf "  ${Y}Already exists, skipping move: %s${NC}\n" "$name"
        BATCH_DIRS+=("$dst")
    else
        printf "  Moving %s → %s/\n" "$name" "$GROUP"
        mv "$src" "$dst"
        BATCH_DIRS+=("$dst")
    fi
done
printf "\n"

# ── Command runner ───────────────────────────────────────────────────────────
_daaam_inner_prelude() {
    cat <<'RUNNER_PRELUDE'
        if [[ -f /ros2_ws/setup_daaam.sh ]]; then
            source /ros2_ws/setup_daaam.sh
        elif [[ -f "$PROJECT/ros2_ws/setup_daaam.sh" ]]; then
            source "$PROJECT/ros2_ws/setup_daaam.sh"
        fi
        if [[ -d /ros2_ws/python_packages ]]; then
            export PYTHONPATH=/ros2_ws/python_packages:${PYTHONPATH:-}
        elif [[ -d "$PROJECT/ros2_ws/python_packages" ]]; then
            export PYTHONPATH="$PROJECT/ros2_ws/python_packages:${PYTHONPATH:-}"
        fi
RUNNER_PRELUDE
}

_run() {
    # _run "<inner bash command string>"
    local prelude
    prelude="$(_daaam_inner_prelude)"
    if [[ "$DAAAM_RUN_DIRECT" == "1" ]]; then
        bash -lc "$prelude
            $1
        "
    else
        apptainer exec --nv             -B "$PROJECT/ros2_ws:/ros2_ws"             -B "$PROJECT:$PROJECT"             "$DAAAM_SIF"             bash -lc "$prelude
                $1
            "
    fi
}

# Map host batch dir → container path
_cont() { printf '%s/%s/%s' "$EGG_BASE_CONT" "$GROUP" "$(basename "$1")"; }

declare -A EVENT_GROUPER_RAN=()

# ── Step 0: event_grouper ────────────────────────────────────────────────────
if [[ "${SKIP_EVENT_GROUPER:-0}" != "1" ]]; then
    printf "${BOLD}=== [0/5] event_grouper ===${NC}\n\n"
    GROUPER_FAILED=0
    for d in "${BATCH_DIRS[@]}"; do
        batch_name="$(basename "$d")"
        host_out="$d/$GROUPER_OUTPUT_NAME"
        if [[ -f "$host_out" ]] && ! _force_group_events; then
            printf "[%s] %s — %s exists, skipping\n" "$(date +%H:%M:%S)" "$batch_name" "$GROUPER_OUTPUT_NAME"
            continue
        fi
        if ! _has_hoi_clips "$d"; then
            printf "[%s] %s — no *_cosmos_hoi.yaml clips, skipping\n" "$(date +%H:%M:%S)" "$batch_name"
            continue
        fi
        cont_dir="$(_cont "$d")"
        printf "[%s] %s\n" "$(date +%H:%M:%S)" "$batch_name"
        if _run "python3 -m daaam.human_reason.event_grouper \
            '$cont_dir' \
            --base-url '$GROUPER_BASE_URL' \
            --model '$GROUPER_MODEL' \
            --output-name '$GROUPER_OUTPUT_NAME'"; then
            printf "  OK: %s\n" "$batch_name"
            EVENT_GROUPER_RAN["$d"]=1
        else
            printf "${R}  FAILED: %s${NC}\n" "$batch_name" >&2
            GROUPER_FAILED=1
        fi
    done
    if [[ "$GROUPER_FAILED" == "1" ]]; then
        printf "${R}  Some batches failed during event_grouper.${NC}\n" >&2
    fi
    printf "\n"
fi

# ── Step 1: semantic_post_processing ─────────────────────────────────────────
if [[ "${SKIP_SEMANTIC:-0}" != "1" ]]; then
    printf "${BOLD}=== [1/5] semantic_post_processing ===${NC}\n\n"

    # Build the list of batch dirs that still need processing.
    SEMANTIC_DIRS=()
    for d in "${BATCH_DIRS[@]}"; do
        [[ -f "$d/events_semantic.yaml" && "${FORCE_SEMANTIC:-0}" != "1" && "${EVENT_GROUPER_RAN[$d]:-0}" != "1" ]] && { printf "  already done, skipping: %s\n" "$(basename "$d")"; continue; }
        [[ -f "$d/events.yaml" ]] || { printf "  no events.yaml, skipping: %s\n" "$(basename "$d")"; continue; }
        SEMANTIC_DIRS+=("$d")
    done

    if [[ ${#SEMANTIC_DIRS[@]} -eq 0 ]]; then
        printf "  All batches already have events_semantic.yaml — nothing to do.\n\n"
    else
        SEMANTIC_FAILED=0
        for d in "${SEMANTIC_DIRS[@]}"; do
            cont_dir="$(_cont "$d")"
            batch_name="$(basename "$d")"
            printf "[%s] %s\n" "$(date +%H:%M:%S)" "$batch_name"
            if _run "python3 -m daaam.human_reason.semantic_post_processing \
                '$cont_dir' \
                --base-url '$SEMANTIC_BASE_URL' \
                --model '$SEMANTIC_MODEL' \
                --merge-judge '$SEMANTIC_MERGE_JUDGE'"; then
                printf "  OK: %s\n" "$batch_name"
            else
                printf "${R}  FAILED: %s${NC}\n" "$batch_name" >&2
                SEMANTIC_FAILED=1
            fi
        done
        if [[ "$SEMANTIC_FAILED" == "1" ]]; then
            printf "${R}  Some batches failed during semantic_post_processing.${NC}\n" >&2
        else
            printf "${G}  All batches succeeded.${NC}\n"
        fi
        printf "\n"
    fi
fi

# ── Step 1: postprocess_scene_graph ─────────────────────────────────────────
if [[ "${SKIP_POSTPROCESS:-0}" != "1" ]]; then
    printf "${BOLD}=== [2/5] postprocess_scene_graph ===${NC}\n\n"
    for d in "${BATCH_DIRS[@]}"; do
        if [[ -f "$d/dsg_updated.json" && "${FORCE_POSTPROCESS:-0}" != "1" ]]; then
            printf "[%s] %s — dsg_updated.json exists, skipping\n" "$(date +%H:%M:%S)" "$(basename "$d")"
            continue
        fi
        cont_dir="$(_cont "$d")"
        printf "[%s] %s\n" "$(date +%H:%M:%S)" "$(basename "$d")"
        _run "python3 $SCRIPTS_CONT/postprocess_scene_graph.py \
            --data-dir $cont_dir \
            --sentence-model-name $SENTENCE_MODEL"
    done
    printf "\n"
fi

# ── Step 2: cluster_places ────────────────────────────────────────────────────
if [[ "${SKIP_CLUSTER:-0}" != "1" ]]; then
    printf "${BOLD}=== [3/5] cluster_places ===${NC}\n\n"
    for d in "${BATCH_DIRS[@]}"; do
        host_out="$d/clustered_dsg.json"
        if [[ -f "$host_out" && "${FORCE_CLUSTER:-0}" != "1" ]]; then
            printf "[%s] %s — clustered_dsg.json exists, skipping\n" "$(date +%H:%M:%S)" "$(basename "$d")"
            continue
        fi
        cont_dir="$(_cont "$d")"
        printf "[%s] %s\n" "$(date +%H:%M:%S)" "$(basename "$d")"
        # ros2 launch keeps the executor alive after the node finishes.
        # Background the command runner and poll the host-side output file,
        # then kill the container process once the file appears.
        _run "ros2 launch daaam_ros cluster_places.launch.yaml data_dir:=$cont_dir" &
        _rpid=$!
        while kill -0 "$_rpid" 2>/dev/null && [[ ! -f "$host_out" ]]; do
            sleep 3
        done
        sleep 2
        kill "$_rpid" 2>/dev/null || true
        wait "$_rpid" 2>/dev/null || true
        if [[ ! -f "$host_out" ]]; then
            printf "${R}  ERROR: clustered_dsg.json not found: %s${NC}\n" "$d" >&2
            exit 1
        fi
    done
    printf "\n"
fi

# ── Step 3: summarize_regions ─────────────────────────────────────────────────
if [[ "${SKIP_SUMMARIZE:-0}" != "1" && -n "${OPENAI_API_KEY:-}" ]]; then
    printf "${BOLD}=== [4/5] summarize_regions ===${NC}\n\n"
    for d in "${BATCH_DIRS[@]}"; do
        if [[ -f "$d/region_summaries.yaml" && "${FORCE_SUMMARIZE:-0}" != "1" ]]; then
            printf "[%s] %s — region_summaries.yaml exists, skipping\n" "$(date +%H:%M:%S)" "$(basename "$d")"
            continue
        fi
        cont_dir="$(_cont "$d")"
        printf "[%s] %s\n" "$(date +%H:%M:%S)" "$(basename "$d")"
        _run "python3 $SCRIPTS_CONT/summarize_regions.py \
            --data-dir $cont_dir \
            --model-name $SUMMARIZE_MODEL \
            --n-samples ${N_SUMMARIZE_SAMPLES:-20}" \
            || printf "${Y}  WARNING: summarize_regions failed for %s (no traversability places?) — skipping${NC}\n" "$(basename "$d")"
    done
    printf "\n"
else
    [[ "${SKIP_SUMMARIZE:-0}" != "1" ]] && \
        printf "${BOLD}=== [4/5] summarize_regions ===${NC} ${Y}[skipped — OPENAI_API_KEY unset]${NC}\n\n"
fi

# ── Step 4: merge_dsgs ────────────────────────────────────────────────────────
if [[ "${SKIP_MERGE:-0}" != "1" ]]; then
    printf "${BOLD}=== [5/5] merge_dsgs ===${NC}\n\n"
    printf "[%s] %d batches → %s\n\n" "$(date +%H:%M:%S)" "${#BATCH_DIRS[@]}" "$MERGED_DIR_HOST"
    CONT_DIRS=()
    for d in "${BATCH_DIRS[@]}"; do CONT_DIRS+=("$(_cont "$d")"); done
    _run "python3 $SCRIPTS_CONT/merge_dsgs.py ${CONT_DIRS[*]} --output $MERGED_DIR_CONT"
    printf "\n"
fi

printf "${G}Done.${NC}  %s\n\n" "$MERGED_DIR_HOST"
