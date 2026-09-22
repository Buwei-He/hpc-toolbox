# site.sh — loads this user's local, gitignored site config (SLURM account,
# project group) so nothing account/group-identifying has to live in tracked
# source. Sourced only by the three entry points (bjob, percorso-demo,
# toolbox-doctor doesn't need PROJECT so it doesn't source this) — everything
# downstream inherits PROJECT via the environment: plain export, an explicit
# --export=ALL,... on a sbatch/srun call, or an explicit PROJECT='$PROJECT'
# passthrough into a detached tmux session. All three already happen at
# every call site that needs PROJECT, so one load here is enough.
#
# Copy local.config.json.example to local.config.json (gitignored) and fill
# in your own values; missing the file is not an error here, it just means
# SITE_ACCOUNT stays empty and PROJECT stays whatever it already was —
# callers that actually need either already say so clearly when they're
# missing (bjob's account auto-detect, or the PROJECT:? guards in jobs/*/*.sh).

_SITE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../bin/lib
SITE_CONFIG="${SITE_CONFIG:-$(dirname "$(dirname "$_SITE_LIB_DIR")")/local.config.json}"

SITE_ACCOUNT=""
if [[ -f "$SITE_CONFIG" ]]; then
    if command -v jq >/dev/null 2>&1; then
        SITE_ACCOUNT="$(jq -r '.slurm_account // empty' "$SITE_CONFIG" 2>/dev/null)"
        _site_group="$(jq -r '.project_group // empty' "$SITE_CONFIG" 2>/dev/null)"
        [[ -z "${PROJECT:-}" && -n "$_site_group" ]] && export PROJECT="/proj/$_site_group/users/$USER"
        unset _site_group
    else
        printf 'warn: %s exists but jq is not on PATH — ignoring it\n' "$SITE_CONFIG" >&2
    fi
fi
