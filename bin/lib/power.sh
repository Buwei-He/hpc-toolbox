# power.sh — shared GPU-power sampling against NSC's kill-floor policy.
#
# Sourced by bin/bjob and bin/percorso-demo; not a standalone tool (no
# shebang, not linked into ~/bin, not scanned by toolbox-doctor's lint,
# which only walks direct children of bin/).
#
# NSC kills jobs whose moving-average power stays below 90 W (idle is 52 W,
# announced to rise to 100 W+). Exempt: a job's first hour, NSC `interactive`
# jobs under 8 h, and jobs inside a reservation. sacct cannot help — energy
# accounting is off on this cluster (ConsumedEnergyRaw is 0 for every job) —
# so it has to be sampled live, which is what this does.
#
# Callers provide their own color vars (R/G/Y/DIM/NC) — both bjob and
# percorso-demo already define the same escape codes, so this file doesn't
# redefine or depend on either tool's own ok/warn/note/die helper names.
POWER_FLOOR="${PERCORSO_POWER_FLOOR:-90}"     # NSC's current kill threshold, watts
POWER_WARN="${PERCORSO_POWER_WARN:-120}"      # our own margin above the announced 100 W

power_advice() {
    printf "${DIM}        exempt paths, in order of preference:${NC}\n"
    printf "${DIM}          1. a reservation — set D_RESERVATION in the profile's config.sh${NC}\n"
    printf "${DIM}          2. NSC's own tool, under 8h:  interactive --gpus=1 -t 04:00:00${NC}\n"
    printf "${DIM}          3. keep jobs under one hour (what most profiles do)${NC}\n"
    printf "${DIM}        and: do not hold the allocation while nobody is interacting${NC}\n"
}

# Emitted as a shell fragment so every caller (one-shot, detached watcher, or
# a remote srun --overlap) runs exactly the same sampler. nvidia-smi does its
# own sleeping with -l, so there is no polling loop of ours to get wrong.
power_sample_cmd() {
    local ngpu="$1" interval="$2" mode="$3"
    printf '%s' "nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits -l $interval 2>/dev/null \
      | awk -v n=$ngpu -v mode=$mode -v floor=$POWER_FLOOR '
          { s += \$1; c++ }
          c % n == 0 {
              k++; tot += s; if (s > max || k == 1) max = s; if (s < min || k == 1) min = s
              if (mode == \"watch\")
                  printf \"sample %d  now=%.0fW  mean=%.0fW  %s\n\", k, s, tot/k, (tot/k < floor ? \"BELOW FLOOR\" : \"ok\")
              else
                  printf \"  sample %d  now=%.0fW  mean=%.0fW  min=%.0fW  max=%.0fW\n\", k, s, tot/k, min, max
              fflush(); s = 0
          }'"
}
