# percorso — the live-demo profile (percorso-perception).
#
# One GPU, for the perception pipeline ONLY. Cosmos runs as a SEPARATE job on a
# SEPARATE node; percorso-demo finds it through $PROJECT/.cosmos_url.
#
# That separation is the point. The 'daaam-cosmos' profile co-locates vLLM and the
# pipeline on ONE GPU at COSMOS_GPU_MEMORY_UTILIZATION=0.75, leaving DAAAM ~25% —
# 20 GB on an 80 GB card but only 10 GB on a 40 GB one, which is why it OOMs on
# some nodes and not others. Two jobs cost one extra allocation and remove the
# whole failure mode.
#
# Time: 4 h, not the 59 min of the 'daaam' profile — a demo session outlives a
# dataset run, and an expiring allocation takes the live query bridge with it.
#
# D_RESERVATION is what makes 4 h legal. NSC terminates jobs whose moving-average
# power stays under 90 W (idle is 52 W; the limit is rising to 100 W+), and the only
# exemptions are: the first hour of any job, NSC `interactive` jobs under 8 h, and
# jobs inside a reservation. The 59-min profiles dodge it by never reaching the
# one-hour mark. A demo cannot: it idles between questions by nature, so without a
# reservation it gets killed somewhere after the first hour.
# Reservation nodes are thin (A100 40 GB) — ample for the pipeline alone, and another
# reason not to co-locate vLLM here.
# Mem: above 'daaam' (40G) for the rolling buffer, the query bridge and the
# mid-run event refresh; below 'daaam-cosmos' (80G) because vLLM is not here.
D_ACCOUNT="berzelius-2026-211"
D_PARTITION="berzelius"
D_GPUS="1"
D_TIME="04:00:00"
D_MEM="64G"
D_JOBNAME="percorso"
D_RESERVATION="safe"
# A demo idles by nature — the one profile that should sample itself instead
# of relying on someone remembering to run 'bjob power'/'percorso-demo power'.
D_POWER_GUARD="1"
# setup.sh no longer hangs on tmux attach-session without a TTY: it passes
# PERCORSO_AUTOSTART into the detached session, and enter_percorso_container.sh
# runs 'percorso-demo doctor && run live' in place of the interactive
# shell hand-off when there's nobody there to type it. Verified safe to run
# with 'bjob submit', nobody watching.
D_SUBMITTABLE="1"
