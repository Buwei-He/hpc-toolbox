# bjob_hooks.sh — daaam-cosmos's bjob extension.
#
# Sourced by bin/bjob (via load_hooks) when this profile is the active job or
# profile. Defines the optional hook_* functions bjob looks for; everything
# else here is private plumbing for those hooks. Behavior is unchanged from
# when this lived inline in bin/bjob — only the location moved, so the
# general tool no longer special-cases the name "daaam-cosmos".

hook_role_help() {
    printf "\n  ${DIM}Pick cosmos, daaam, shell, gpu, logs, auto-launch, auto-bag, or auto from the menu.${NC}\n"
}

hook_pick_role() {
    local choice
    printf "\n${BOLD}${Y}  Select daaam-cosmos terminal${NC}\n\n" >&2
    printf "  1) cosmos  Start Cosmos-Reason2 server\n" >&2
    printf "  2) daaam   Prepared DAAAM shell for ROS launch or bag play\n" >&2
    printf "  3) shell   Plain shell in allocation\n" >&2
    printf "  4) gpu          Show GPU power/utilization\n" >&2
    printf "  5) logs         Print tmux/log file paths\n" >&2
    printf "  6) auto-launch  Run selected batch range ROS launch worker\n" >&2
    printf "  7) auto-bag     Run selected batch range rosbag worker\n" >&2
    printf "  8) auto         Run Cosmos + launch + bag workers together\n" >&2
    printf "  q) cancel\n\n" >&2
    read -rp "  Choice [shell]: " choice
    case "${choice:-3}" in
        1|cosmos|server) printf "cosmos" ;;
        2|daaam|ros|launch|bag|play) printf "daaam" ;;
        3|shell|sh|"")   printf "shell" ;;
        4|gpu)           printf "gpu" ;;
        5|log|logs)      printf "logs" ;;
        6|auto-launch|launch-auto|batch-launch|launch-batches) printf "auto-launch" ;;
        7|auto-bag|bag-auto|batch-bag|play-batches)             printf "auto-bag" ;;
        8|auto|auto-all|batch-auto|all)                            printf "auto" ;;
        q|Q|quit|cancel) return 1 ;;
        *)
            printf "${R}  Unknown choice: %s${NC}\n" "$choice" >&2
            return 1 ;;
    esac
}

hook_role_script() {
    case "$1" in
        cosmos|server) printf 'start_cosmos.sh' ;;
        daaam|ros|launch|bag|play) printf 'prepare_daaam_shell.sh' ;;
        auto-launch|launch-auto|batch-launch|launch-batches) printf 'auto_ros_launch.sh' ;;
        auto-bag|bag-auto|batch-bag|play-batches) printf 'auto_bag_play.sh' ;;
        auto|auto-all|batch-auto|all) printf 'auto_all.sh' ;;
    esac
}

hook_role_env() {
    case "$1" in
        auto-launch|launch-auto|batch-launch|launch-batches|auto-bag|bag-auto|batch-bag|play-batches|auto|auto-all|batch-auto|all)
            if [[ -t 0 && "${BJOB_AUTO_BATCH_PROMPT:-1}" != "0" ]]; then
                prompt_auto_batch_range || return 1
            else
                _AUTO_BATCH_START="${DAAAM_AUTO_BATCH_START:-1}"
                _AUTO_BATCH_END="${DAAAM_AUTO_BATCH_END:-7}"
            fi
            printf 'DAAAM_AUTO_BATCH_START=%s\n' "$_AUTO_BATCH_START"
            printf 'DAAAM_AUTO_BATCH_END=%s\n' "$_AUTO_BATCH_END"
            printf 'BJOB_DAAAM_AUTO_BATCH_START=%s\n' "$_AUTO_BATCH_START"
            printf 'BJOB_DAAAM_AUTO_BATCH_END=%s\n' "$_AUTO_BATCH_END"
            ;;
    esac
}

hook_extra_log_globs() {
    printf '%s\n' "$PROJECT/.cache/cosmos-reason2-vllm.log"
}

# hook_extend — one-click extend for our own sbatch sub-jobs (cosmos-server,
# daaam-worker). Called by cmd_extend only after it has already confirmed the
# job is running and its GPU power is above NSC's floor right now — this
# function's job is just "resubmit the same work as a dependent follow-up
# job", not to re-check load itself.
hook_extend() {
    local jobid="$1" jobname="$2"

    local reg_file="$PROJECT/.bjob/smart-auto-session.$jobid"
    if [[ ! -f "$reg_file" ]]; then
        printf "${R}  No session state registered for job %s — can't extend.${NC}\n" "$jobid"
        printf "  ${DIM}(only jobs launched via the daaam-cosmos 'afk' launch mode register one)${NC}\n"
        return 1
    fi
    local state_dir; state_dir=$(cat "$reg_file")

    # Recover what this job was actually granted, so the follow-up matches —
    # don't trust config.sh, the job may have been submitted with overrides.
    local info account partition gpus mem
    info=$(scontrol show job "$jobid" 2>/dev/null) || info=""
    account=$(grep -oP '(?<= Account=)\S+' <<<"$info" | head -1)
    partition=$(grep -oP '(?<= Partition=)\S+' <<<"$info" | head -1)
    gpus=$(grep -oP 'gpu[:=]\K[0-9]+' <<<"$info" | head -1); gpus="${gpus:-1}"
    mem=$(grep -oP '(?<= Mem=)[0-9A-Za-z]+' <<<"$info" | head -1)
    if [[ -z "$account" || -z "$partition" ]]; then
        printf "${R}  Could not read job %s's account/partition via scontrol — can't extend.${NC}\n" "$jobid"
        return 1
    fi

    local out jid
    case "$jobname" in
        cosmos-server)
            out=$(sbatch \
                --account="$account" --partition="$partition" --gpus="$gpus" \
                --time=00:59:59 --mem="${mem:-80G}" --job-name=cosmos-server \
                --dependency="afterany:$jobid" \
                --output="$state_dir/logs/cosmos_slurm-%j.log" \
                --export=ALL,DAAAM_PROFILE_DIR="$JOBS_DIR/daaam-cosmos",DAAAM_AUTO_STATE_DIR="$state_dir" \
                "$JOBS_DIR/daaam-cosmos/sbatch_cosmos.sh" 2>&1) || {
                printf "${R}  Failed to queue follow-up cosmos-server job:\n  %s${NC}\n" "$out"
                return 1
            }
            jid=$(awk '{print $NF}' <<<"$out")
            printf "${G}  Queued cosmos-server follow-up: job %s (starts once %s ends).${NC}\n" "$jid" "$jobid"
            ;;
        daaam-worker)
            # sbatch_daaam.sh's own _on_exit trap ALREADY auto-resubmits
            # unconditionally when it exits with batches still remaining
            # (that's its whole job) -- unless auto.done/auto.stop is set.
            # A running job hasn't hit either yet, so without a coordination
            # marker, extending here would queue a follow-up AND let that
            # trap queue its own independent one when this job later times
            # out -- two dependent jobs racing over the same current_batch
            # checkpoint. extended.$jobid below is that marker; sbatch_daaam.sh
            # checks it next to auto.done/auto.stop.
            if [[ -e "$state_dir/auto.done" ]]; then
                printf "${R}  Job %s already finished all its batches (auto.done set) — nothing to extend.${NC}\n" "$jobid"
                return 1
            fi
            if [[ -e "$state_dir/auto.stop" ]]; then
                printf "${R}  Job %s was stopped deliberately (auto.stop set) — not resubmitting blindly.${NC}\n" "$jobid"
                printf "  ${DIM}check %s/logs/auto_launch.log for why, then remove auto.stop if you want to continue.${NC}\n" "$state_dir"
                return 1
            fi

            local resume_batch batch_end
            resume_batch=$(sed 's/^batch_//' "$state_dir/current_batch" 2>/dev/null)
            batch_end=$(cat "$state_dir/batch_end" 2>/dev/null)
            if [[ -z "$resume_batch" || -z "$batch_end" ]]; then
                printf "${R}  No checkpoint (current_batch/batch_end) in %s — can't tell where to resume.${NC}\n" "$state_dir"
                return 1
            fi
            out=$(sbatch \
                --account="$account" --partition="$partition" --gpus="$gpus" \
                --time=00:59:59 --mem="${mem:-80G}" --job-name=daaam-worker \
                --dependency="afterany:$jobid" \
                --output="$state_dir/logs/daaam_slurm-%j.log" \
                --export=ALL,DAAAM_PROFILE_DIR="$JOBS_DIR/daaam-cosmos",DAAAM_AUTO_STATE_DIR="$state_dir",DAAAM_AUTO_BATCH_START="$resume_batch",DAAAM_AUTO_BATCH_END="$batch_end",DAAAM_SBATCH_MEM="${mem:-80G}",DAAAM_SBATCH_GPUS="$gpus" \
                "$JOBS_DIR/daaam-cosmos/sbatch_daaam.sh" 2>&1) || {
                printf "${R}  Failed to queue follow-up daaam-worker job:\n  %s${NC}\n" "$out"
                return 1
            }
            jid=$(awk '{print $NF}' <<<"$out")
            # Suppress $jobid's own auto-resubmit now that we've queued one
            # by hand -- must be written before returning, not best-effort
            # skipped, or the double-submit this exists to prevent still happens.
            if ! printf '%s\n' "$jid" > "$state_dir/extended.$jobid"; then
                printf "${Y}  warn${NC}  Queued follow-up job %s, but could not write %s/extended.%s.\n" \
                    "$jid" "$state_dir" "$jobid"
                printf "  ${DIM}%s's own exit trap will now ALSO resubmit when it times out --\n" "$jobid"
                printf "        cancel one of the two duplicate follow-ups once both exist.${NC}\n"
            fi
            printf "${G}  Queued daaam-worker follow-up: job %s, resuming batch_%s..batch_%s once %s ends.${NC}\n" \
                "$jid" "$resume_batch" "$batch_end" "$jobid"
            ;;
        *)
            printf "${R}  Unknown daaam-cosmos job name '%s' — can't extend.${NC}\n" "$jobname"
            return 1
            ;;
    esac
}

hook_launch() {
    local name="$1" mode
    if mode="$(prompt_afk_launch_mode)"; then
        if [[ "$mode" == "afk" ]]; then
            launch_afk "$name"
        else
            launch_profile "$name"
        fi
    fi
}

# ── private plumbing for the hooks above ──────────────────────────────────

_AUTO_BATCH_START=""
_AUTO_BATCH_END=""

prompt_afk_launch_mode() {
    printf "\n${BOLD}${Y}  daaam-cosmos launch mode${NC}\n\n" >&2
    printf "  1) interactive   srun — one shared allocation (cosmos + DAAAM share one GPU)\n" >&2
    printf "  2) afk           sbatch — separate cosmos and DAAAM allocations, both 59:59.\n" >&2
    printf "                   DAAAM auto-resubmits until all batches finish; run\n" >&2
    printf "                   'bjob extend <jobid>' on either job to push it further\n" >&2
    printf "  q) cancel\n\n" >&2
    local choice
    read -rp "  Choice [1]: " choice
    case "${choice:-1}" in
        1|i|interactive) printf "interactive" ;;
        2|s|smart|afk) printf "afk" ;;
        q|Q) return 1 ;;
        *) printf "interactive" ;;
    esac
}

prompt_auto_batch_range() {
    local default_start="${DAAAM_AUTO_BATCH_START:-1}"
    local default_end="${DAAAM_AUTO_BATCH_END:-7}"
    local input cleaned start end

    printf "\n${BOLD}${Y}  Automated batch range${NC}\n" >&2
    printf "  Examples: 1-7, 3-5, 6, batch_4-batch_7\n" >&2
    read -rp "  Batch range [${default_start}-${default_end}]: " input

    if [[ -z "$input" ]]; then
        start="$default_start"
        end="$default_end"
    elif [[ "$input" =~ ^[[:space:]]*(batch_?)?([0-9]+)[[:space:]]+[[:space:]]*(batch_?)?([0-9]+)[[:space:]]*$ ]]; then
        start="${BASH_REMATCH[2]}"
        end="${BASH_REMATCH[4]}"
    else
        cleaned="${input,,}"
        cleaned="${cleaned//batch_/}"
        cleaned="${cleaned//batch/}"
        cleaned="${cleaned//[[:space:]]/}"
        cleaned="${cleaned//,/-}"
        cleaned="${cleaned//--/-}"
        if [[ "$cleaned" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
        elif [[ "$cleaned" =~ ^([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="$start"
        else
            printf "${R}  Could not parse batch range: %s${NC}\n" "$input" >&2
            return 1
        fi
    fi

    if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
        printf "${R}  Batch range must be numeric.${NC}\n" >&2
        return 1
    fi
    if (( start < 1 || end < 1 || start > end )); then
        printf "${R}  Invalid batch range: %s-%s${NC}\n" "$start" "$end" >&2
        return 1
    fi

    _AUTO_BATCH_START="$start"
    _AUTO_BATCH_END="$end"
    printf "${C}  Using batch_%s..batch_%s${NC}\n" "$start" "$end" >&2
}

launch_afk() {
    local name="$1"
    load_profile "$name"

    if [[ -z "${D_ACCOUNT:-}" ]]; then
        local detected; detected=$(detect_accounts)
        D_ACCOUNT=$(awk '{print $1}' <<< "$detected")
    fi
    if [[ -z "${D_ACCOUNT:-}" ]]; then
        printf "\n${R}  Could not detect a SLURM account for user '%s'.${NC}\n" "$USER"
        printf "\n  ${DIM}Press any key to return...${NC}"
        IFS= read -rsn1 2>/dev/null || true
        return 1
    fi

    prompt_auto_batch_range || return 1

    # Session ID keyed by launch time — shared by cosmos and DAAAM jobs
    local session_id state_dir
    session_id="$(date +%Y%m%d_%H%M%S)"
    state_dir="$PROJECT/.cache/daaam-cosmos-auto/$session_id"

    # Cosmos: 4 h, lighter memory (same partition/account as DAAAM)
    local cosmos_mem="40G"
    local cosmos_cfg="$JOBS_DIR/cosmos-reason2/config.sh"
    [[ -f "$cosmos_cfg" ]] && cosmos_mem=$(bash -c "source \"$cosmos_cfg\" 2>/dev/null; printf '%s' \"\${D_MEM:-40G}\"")

    # DAAAM: 59:59, daaam-cosmos mem
    local daaam_mem="${D_MEM:-80G}"
    local daaam_gpus="${D_GPUS:-1}"

    printf "\n${BOLD}${Y}  afk launch — %s${NC}\n" "$session_id"
    printf "  State dir:  %s\n" "$state_dir"
    printf "  Batches:    batch_%s..batch_%s\n" "$_AUTO_BATCH_START" "$_AUTO_BATCH_END"
    printf "  Cosmos:     59:59 · %s GPU · %s · %s (bjob extend to push further)\n" "$daaam_gpus" "$cosmos_mem" "$D_PARTITION"
    printf "  DAAAM:      59:59 · %s GPU · %s · %s (auto-resubmit)\n" "$daaam_gpus" "$daaam_mem" "$D_PARTITION"
    printf "\n"
    local confirm
    read -rp "  Submit both jobs? [Y/n]: " confirm
    [[ "${confirm:-Y}" =~ ^[Nn]$ ]] && return 1

    local cosmos_script="$JOBS_DIR/$name/sbatch_cosmos.sh"
    local daaam_script="$JOBS_DIR/$name/sbatch_daaam.sh"
    for f in "$cosmos_script" "$daaam_script"; do
        if [[ ! -f "$f" ]]; then
            printf "${R}  Missing: %s${NC}\n" "$f"
            printf "\n  ${DIM}Press any key to return...${NC}"
            IFS= read -rsn1 2>/dev/null || true
            return 1
        fi
    done

    mkdir -p "$state_dir/logs"

    local profile_dir="$JOBS_DIR/$name"

    # Submit cosmos server (59:59 — same power-floor exemption as everything
    # else; use 'bjob extend <jobid>' once it's genuinely serving requests)
    local cosmos_out
    if ! cosmos_out=$(sbatch \
            --account="$D_ACCOUNT" \
            --partition="$D_PARTITION" \
            --gpus="$daaam_gpus" \
            --time=00:59:59 \
            --mem="$cosmos_mem" \
            --job-name=cosmos-server \
            --output="$state_dir/logs/cosmos_slurm-%j.log" \
            --export=ALL,DAAAM_PROFILE_DIR="$profile_dir",DAAAM_AUTO_STATE_DIR="$state_dir" \
            "$cosmos_script" 2>&1); then
        printf "${R}  Failed to submit cosmos job:\n  %s${NC}\n" "$cosmos_out"
        printf "\n  ${DIM}Press any key to return...${NC}"
        IFS= read -rsn1 2>/dev/null || true
        return 1
    fi
    local cosmos_jobid
    cosmos_jobid=$(awk '{print $NF}' <<< "$cosmos_out")
    printf "${G}  Cosmos server submitted: job %s${NC}\n" "$cosmos_jobid"

    # Submit DAAAM worker (59:59, starts after cosmos job begins)
    local daaam_out
    if ! daaam_out=$(sbatch \
            --account="$D_ACCOUNT" \
            --partition="$D_PARTITION" \
            --gpus="$daaam_gpus" \
            --time=00:59:59 \
            --mem="$daaam_mem" \
            --job-name=daaam-worker \
            --output="$state_dir/logs/daaam_slurm-%j.log" \
            --dependency="after:$cosmos_jobid" \
            --export=ALL,DAAAM_PROFILE_DIR="$profile_dir",DAAAM_AUTO_STATE_DIR="$state_dir",DAAAM_AUTO_BATCH_START="$_AUTO_BATCH_START",DAAAM_AUTO_BATCH_END="$_AUTO_BATCH_END",DAAAM_SBATCH_MEM="$daaam_mem",DAAAM_SBATCH_GPUS="$daaam_gpus",COSMOS_JOB_ID="$cosmos_jobid" \
            "$daaam_script" 2>&1); then
        printf "${R}  Failed to submit DAAAM job:\n  %s${NC}\n" "$daaam_out"
        printf "\n  ${DIM}Press any key to return...${NC}"
        IFS= read -rsn1 2>/dev/null || true
        return 1
    fi
    local daaam_jobid
    daaam_jobid=$(awk '{print $NF}' <<< "$daaam_out")
    printf "${G}  DAAAM worker submitted:  job %s (starts after cosmos begins)${NC}\n" "$daaam_jobid"

    printf "\n${C}  Monitor:${NC}\n"
    printf "    squeue -u %s\n" "$USER"
    printf "    tail -f %s/logs/auto_launch.log\n" "$state_dir"
    printf "    tail -f %s/logs/cosmos-reason2-vllm.log\n" "$state_dir"
    printf "\n  ${DIM}Press any key to return...${NC}"
    IFS= read -rsn1 2>/dev/null || true
}
