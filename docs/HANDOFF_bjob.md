# Handoff: `bjob`

**File:** `berzelius-toolbox/bin/bjob` — 1072 lines, 32 functions, bash. On `PATH` via `~/bin/bjob`.
**Audience:** whoever maintains or rewrites this tool next.
**Written:** 2026-08-21, from reading the code, not from memory of it.

---

## Update — 2026-08-21: risks #1 and #2 resolved

Both top-ranked risks below have since been fixed. The rest of this document is
left as-is (real history, still useful context) with inline notes where it's
now stale.

- **Risk #1 (cursor-arithmetic redraw, §3, §6.1)** — fixed via §8's Option A.
  `_main_screen` and `select_profile` now do a full `\033[H\033[2J` + reprint
  on every key press instead of `tput cuu`/`cud` row counting. No more
  `redrawn` variable, no more per-branch cursor restoration to get wrong.
- **Risk #2 (`daaam-cosmos` colonizing the tool, §6.2)** — fixed by extracting
  it, not by deleting it (the paper-reproduction constraint in §7 still
  applies; nothing about its behavior changed). `bin/bjob` now loses ~180
  lines and every `"$jobname" == "daaam-cosmos"` check.

**The mechanism:** an optional `jobs/<name>/bjob_hooks.sh`, sourced on demand
— the same pattern this tool already used for `setup.sh`, extended to let a
profile customize `bjob`'s own behavior instead of just the shell environment.
`load_hooks <name>` sources it and `unset -f`s the hook functions first, so
switching between profiles within one TUI session can't leak stale hooks from
whatever was active before.

| Hook | Called from | Contract |
|---|---|---|
| `hook_pick_role` | `connect_job` | stdout = chosen role name; return 1 = cancel |
| `hook_role_script <role>` | `connect_job` | stdout = script path, relative to the profile dir |
| `hook_role_env <role>` | `connect_job` | stdout = extra `NAME=value` lines (one per line) for the role's `srun` env |
| `hook_role_help` | `print_ide_commands` | extra help lines for a running job of this profile |
| `hook_launch <name>` | `handle_new_job` | replaces `launch_profile` entirely when defined |
| `hook_extra_log_globs` | `log_paths` | stdout = extra log paths/patterns to show |
| `hook_extend <jobid> <jobname>` | `cmd_extend` | submits a dependent (`--dependency=afterany:<jobid>`) follow-up job that resumes this job's checkpointed progress; called directly (not `$(...)`), only after `cmd_extend` has already confirmed the job is running and its GPU power is above NSC's floor |

All are optional — `bjob` checks `declare -f hook_x` before calling any of
them, so a profile with no `bjob_hooks.sh` behaves exactly like before this
change. `jobs/daaam-cosmos/bjob_hooks.sh` defines all six (it owns the
role picker, the afk sbatch launch flow, and the batch-range prompt, moved
here verbatim); `jobs/cosmos-reason2/bjob_hooks.sh` defines only
`hook_extra_log_globs` (three lines).

One behavior-preserving wrinkle: `hook_role_env` and `hook_launch` run inside
a `bin/bjob` shell that only sees their **stdout**, not their side effects —
a hook that needs to hand data back (e.g. the batch range it just prompted
for) must print it as `NAME=value` lines and let the caller parse those back
out, rather than relying on a global variable set inside the hook leaking
into `bin/bjob`'s scope. (It doesn't, because `"$(hook_role_env ...)"` runs in
a subshell.) See `connect_job`'s `_bstart`/`_bend` extraction from `role_env`
for the pattern if adding a hook that needs to do the same.

## Update — later same day: quota check, power guard, ports.conf contract

Three more additions, same session:

- **`toolbox-doctor quota`** wraps NSC's own `nscquota` (home + project
  block/file quota, `-w` for silent-unless-exceeded). `/proj` and `/home` are
  VAST-backed, not Lustre, so `lfs quota` was never going to work here.
- **`bin/lib/svc.sh`** — pulled the container-independent half of
  `percorso-demo`'s `svc_*` functions (pidfile/logfile/pid/start/stop/
  wait-port) out into a second sourced-only lib next to `bin/lib/power.sh`.
  `percorso-demo` keeps a thin `svc_start_container` wrapper on top for the
  one thing that's actually specific to it: every service there runs inside
  an apptainer container.
- **`D_POWER_GUARD="1"`** — a profile config key. `launch_profile` appends a
  line to the rc file it already builds for `setup.sh`, re-invoking `bjob
  __power-guard-start` (a hidden, undocumented subcommand — not part of the
  CLI contract) once inside the allocation. That starts a detached sampler
  via the two shared libs above, logged under `$PROJECT/.bjob/run/<node>/`.
  Enabled on `percorso` (the profile that legitimately idles). **Caught
  while testing:** `power_guard_start` had no guard against running outside
  a SLURM allocation, and this login node has a visible GPU — a direct
  invocation started a real unbounded `nvidia-smi -l 60` loop here before a
  `[[ -n "${SLURM_JOB_ID:-}" ]]` check was added. Exactly the class of bug
  `toolbox-doctor` exists to catch; if you touch this function again, retest
  with `bjob __power-guard-start` on a login node and confirm it no-ops.
- **`jobs/<name>/ports.conf`** — new, `<svc> <port> [priority]` per line,
  added to `percorso`/`cosmos-reason2`/`daaam-cosmos`. Nothing reads these
  yet; they exist so a future rewrite of `ssh-helper` (different repo,
  robot/laptop side) has a correct, single-sourced service/port declaration
  to consume instead of its own hardcoded job-name map. Known gap, called
  out in `jobs/daaam-cosmos/ports.conf`: the AFK/sbatch launch mode submits
  jobs named `cosmos-server`/`daaam-worker`, which have no `jobs/<name>/`
  directory to hold a declaration.

## Update — 2026-09-22: `bjob submit`, a non-interactive launch path

Every verb up to this point acts on a job that already exists — nothing
could *start* one without a TTY. `launch_profile` uses `srun --pty`
(allocates a pty, blocks until an interactive shell exits), and the only
thing that calls it is the TUI, which `main` refuses to run without one.

Why this isn't a thin `srun --pty` wrapper with a timeout slapped on: for
`percorso`/`daaam`, `setup.sh` itself ends by calling `tmux attach-session`
— it would hang on the allocated pty waiting for a human who was never
there (the same mechanism behind the power-guard-ordering bug fixed
earlier). For `cosmos-reason2`/`llava`/`cosmos3-nano-reasoner`, `setup.sh`
already backgrounds a server, polls until healthy, and **returns** — it
only "hangs" today because the interactive shell around it stays open for
someone to type into. Since which shape a given `setup.sh` has can't be
detected reliably (grepping for `tmux attach` is exactly the kind of guess
worth avoiding), it's a new explicit per-profile opt-in instead, same as
`D_RESERVATION`/`D_POWER_GUARD` before it:

**`D_SUBMITTABLE="1"`** in `config.sh` — the profile author's confirmation
that `setup.sh` is safe to source with nobody watching. `bjob submit
<profile>` refuses cleanly without it. Set on `cosmos-reason2`, `llava`,
`cosmos3-nano-reasoner`; **not** on `percorso`/`daaam` (tmux-attach tail) or
`daaam-cosmos` (already has its own sbatch path — `launch_afk` — but
reaching it goes through `hook_launch` → `prompt_afk_launch_mode`, an
interactive `read -rp` with no bypass; giving it a non-interactive entry
point is a smaller, separate follow-up, not folded in here).

`cmd_submit` builds an `sbatch` script (not `srun --pty`) from the same
account/partition/gpu/mem/reservation values `launch_profile` already
computes, sources `setup.sh`, optionally starts the power guard the same
way `launch_profile`'s rc file does, then `sleep infinity` — `setup.sh`
already backgrounded the real work and returned, so this just holds the
allocation open for `D_TIME`. No TTY guard needed: it never reads a key or
holds a pty, submits and returns, agent-safe by construction. Guards a
duplicate submit (`squeue -u $USER -h -o '%j' | grep -qx name` first) and
warns (doesn't block) when there's no `D_RESERVATION` — an unattended
server idling for requests is exactly what NSC's floor can kill.

`log_paths` picks up a submitted job's `--output` file via a plain jobid
glob on `$PROJECT/.bjob/launch-logs/<name>-<jobid>.log` — no registration
file needed, unlike `daaam-cosmos`'s two-job afk case, since a single
`sbatch` job has nothing else to coordinate.

**Noticed in passing, not touched:** `log_paths` (line ~887 as of this
writing) still reads `$PROJECT/.bjob/afk-session.<jobid>`, but
`jobs/daaam-cosmos/{bjob_hooks.sh,sbatch_*.sh}` write to
`$PROJECT/.bjob/smart-auto-session.<jobid>` instead — a rename in flight
from a different, concurrent session, not this round's to resolve. Whoever
reconciles it: `log_paths` is the stale side.

Tested against a stub `sbatch`/`squeue` on `PATH` (this repo's own
documented technique, §10) rather than a real allocation for the script-
generation and duplicate-guard logic; a real `bjob submit cosmos-reason2`
still needs running once, live, to confirm end to end.

## Update — later same day: `bjob extend` reviewed and finished

`cmd_extend`/`hook_extend` (§ above, `bin/bjob`, `jobs/daaam-cosmos/
bjob_hooks.sh`) arrived from a different, concurrent agent session that's
since gone unreachable — reviewed here and taken over, since there's no one
else to hand it back to.

**Real bug found and fixed: double resubmission.** `sbatch_daaam.sh`'s own
`_on_exit` trap already auto-resubmits *unconditionally* when it exits with
batches still remaining (that's its whole purpose — see §1's worker
description) — gated only on `auto.done`/`auto.stop` not being set. `bjob
extend` requires the job to still be `RUNNING` (checked via `squeue`), which
means by construction it can only ever be called *before* that trap has had
a chance to fire. Calling `bjob extend` on a healthy, running `daaam-worker`
job therefore queued a follow-up **and** left that job's own exit trap free
to queue a second, independent one later when it actually timed out — both
`--dependency=afterany:<same jobid>`, both trying to resume from the same
`current_batch` checkpoint.

Fixed with a per-job marker: `hook_extend`'s `daaam-worker` case now writes
`$state_dir/extended.<jobid>` right after successfully queuing its
follow-up (with the new job's id as its content, for traceability), and
`sbatch_daaam.sh`'s `_on_exit` checks `$STATE_DIR/extended.$SLURM_JOB_ID`
next to `auto.done`/`auto.stop` before resubmitting. It's deliberately
keyed by job id, not a single shared flag — a follow-up job's own eventual
timeout must still be free to auto-resubmit normally (or be extended again
itself); only the *specific* job that was manually extended should suppress
its own trap. Also added: `hook_extend` now refuses up front if `auto.done`
or `auto.stop` is already set (previously it would happily queue a
follow-up for already-finished or deliberately-stopped work) — the same
condition `_on_exit` already checked for itself, just never applied on the
`bjob extend` side.

Known residual risk, not solved: if `bjob extend` is called in the narrow
window while the target job is *actually* exiting (its own `_on_exit`
already past the `extended.<jobid>` check but before `bjob extend` writes
it), both still fire. File-based, not lock-based; acceptable for a
personal tool, not eliminated.

Verified with stubs (`scontrol`/`sbatch` on `PATH`, `_on_exit` extracted and
run in isolation with fake `STATE_DIR`/`SLURM_JOB_ID`): the marker gets
written after a successful queue; `auto.done`/`auto.stop` refuse cleanly;
`_on_exit` resubmits normally with no marker, stays silent with its own
job's marker present, and — the case worth actually checking, not assuming
— still resubmits normally for a *different* job id even while another
job's marker exists in the same `state_dir`.

Separately, closed out a pre-existing bug flagged two rounds ago and left
out of scope at the time: `connect_job` and `print_ide_commands` were
calling `job_name_for_id` without the `|| true` guard `log_paths` and this
round's `cmd_extend` already had — under `set -euo pipefail`, `squeue`
failing for a bad job id (not a pipeline failure, an actual squeue exit
code) aborted the whole script before the intended "could not find running
job" message could print. Same one-line fix, now applied at both remaining
call sites; confirmed `bjob connect`/`bjob cmds` against a nonexistent job
id now print the intended message instead of silently exiting.

## Update — later same day: `percorso` made submittable

A different agent hit `bjob submit percorso` refusing (correctly, at the
time) and asked a human to launch it by hand instead. Investigated whether
that refusal could be lifted properly rather than worked around.

It's more than the cosmetic `tmux attach-session` block it looked like at
first. `jobs/percorso/setup.sh` starts a **detached** tmux session (`tmux
new-session -d`) — the final `tmux attach-session` is only for a human's
convenience, not load-bearing. But the session runs
`enter_percorso_container.sh`, which enters the container and ends by
printing "next: percorso-demo doctor && zenoh && pipeline" and handing off
to an **interactive shell** for a human to type those three commands
themselves — unlike `cosmos-reason2`/`llava`/`cosmos3-nano-reasoner`, whose
`setup.sh` genuinely backgrounds the server itself. Just silencing the
`tmux attach` would have made `bjob submit percorso` "succeed" — job
running, no hang — while doing **nothing**: no zenoh, no pipeline, a GPU
allocation burned on an idle interactive shell nobody's watching. Worse
than the honest refusal it replaced.

Fixed properly instead of worked around, after confirming with the user
given the stakes (this profile faces a real robot eventually): tmux's
`pipe-pane` already logs the pane's output regardless of whether anyone's
attached, so running the pipeline in the foreground inside that same
detached session works headlessly. `percorso/setup.sh` now computes
`AUTOSTART` from `[[ -t 0 && -t 1 ]]` and threads it into the tmux session
as `PERCORSO_AUTOSTART`; `enter_percorso_container.sh` checks it and runs
`percorso-demo doctor && percorso-demo zenoh && exec percorso-demo
pipeline` in place of the interactive hand-off when set, falling through
to a clear error (not a silent hang or a silent no-op) if doctor or zenoh
fails. The interactive path is byte-for-byte unchanged, just now reached
via the `elif` branch instead of unconditionally — a human with a real TTY
still gets attached exactly as before.

`bjob submit`'s own `sleep infinity` (appended after `source setup.sh`,
generic across all `D_SUBMITTABLE` profiles) already covers holding the
allocation open here too — `setup.sh` returns quickly either way (creating
a detached tmux session doesn't block), so no changes were needed in
`bin/bjob` itself; `percorso` just became one more profile whose `setup.sh`
returns after backgrounding its real work.

**Real bug found and fixed along the way, unrelated to the above:**
`enter_percorso_container.sh`'s `cosmos_hint()` had no `|| true` on its
last line. Under `set -e`, `hint="$(cosmos_hint)"` aborted the *entire
script* — before the container even started — whenever there was no
running `cosmos-reason2` job to find by name *and* no cached
`$PROJECT/.cosmos_url` (e.g., the very first time anyone starts `percorso`
before `cosmos-reason2` has ever run). Silent and total: no error, the
script just stopped. Same one-line fix as the other `set -e` bugs found
this session — a missing hint isn't a failure, that function just
shouldn't be allowed to make it look like one.

Verified with stubs (`tmux`, `apptainer`, `sbatch`, `squeue`, plus manually
reconstructing and `bash -n`-checking the inner single-quoted `bash -lc`
payload that's opaque to a plain `bash -n` on the outer file): `AUTOSTART`
threads correctly into the tmux session command; the attach is correctly
skipped headless and correctly still fires when the diff shows the
original interactive lines untouched; `bjob submit percorso` now succeeds
and generates a correct `sbatch` script including `--reservation=safe`
(no more "no reservation set" warning, since `D_RESERVATION` was already
set on this profile). Not verified: an actual live run through `percorso-
demo doctor`/`zenoh`/`pipeline` inside a real allocation — that needs a
real GPU and a built overlay, out of reach from stubs.

## Update — 2026-09-22: `D_CONSTRAINT`, requesting a specific GPU size

Prompted by a genuinely dual-sided question: how do you predict a model
server's VRAM need before starting it, and how do you stop it OOMing when
you can't? Researched rather than guessed — checked what this repo
already does and what the cluster actually looks like before answering.

Turns out the "predict beforehand" half is largely unanswerable precisely
(KV-cache use scales with concurrent requests × context length, not just
the model) — but the profiles here already handle that by capping instead
of predicting: `COSMOS_GPU_MEMORY_UTILIZATION` / `COSMOS3_GPU_MEMORY_
UTILIZATION` / SGLang's `--mem-fraction-static` (all pre-existing, just
not written down anywhere central before now) bound a *fraction* of the
card's VRAM; the server refuses new requests at that ceiling instead of
overrunning it.

The other half — Berzelius' `berzelius` partition is not one uniform
hardware pool. Checked via `sinfo -N -o "%N %G %f"`: ~44 nodes carry 40 GB
A100s (`AVAIL_FEATURES=thin`), ~33 carry 80 GB ones (`fat`). Same
`--gpus` count either way — double the VRAM ceiling on a fat one. SLURM
already supports requesting a specific size (`--constraint=fat`/`thin`,
standard SLURM feature-constraint syntax); this toolbox never used it.

Added `D_CONSTRAINT` as a new profile `config.sh` key, same pattern as
`D_RESERVATION`/`D_POWER_GUARD`/`D_SUBMITTABLE`: threaded into
`launch_profile`'s `srun_args` and `cmd_submit`'s generated `#SBATCH`
lines (`--constraint="$D_CONSTRAINT"`), carried through `save_profile`'s
template so a wizard edit doesn't drop it, and surfaced directly (not
abbreviated) in `profile_line`'s FLAGS column — `fat`/`thin` reads fine
on its own, no `constraint:` prefix needed.

Set `D_CONSTRAINT="fat"` on `daaam-cosmos` — its own `config.sh` comment
already described "fine on an 80 GB card, OOM-prone on a 40 GB one" as an
accepted, unfixed limitation. It no longer has to be. (Also fixed that
comment's other claim while touching it: "bjob special-cases it in 12
places" predates the `bjob_hooks.sh` extraction two rounds back and was
stale.)

Verified: `srun --test-only` with `--constraint=fat` resolves to a real
node (`node090`), confirmed via `sinfo` to actually be an 80 GB `fat`
node — not just syntactically accepted. `bash -n` + `toolbox-doctor lint`
clean. Not verified: an actual `daaam-cosmos` run on the resulting node —
same "needs a real allocation" limitation as the `percorso` work above.

---

## 1. What it is for

A SLURM front-end for one user on Berzelius. Two halves:

- **A CLI**, safe for scripts and agents: `bjob connect <jobid>`, `bjob logs <jobid>`,
  `bjob gpu <jobid>`, `bjob cmds <jobid>`, `bjob --help`.
- **A TUI**, `bjob` with no arguments: list your jobs, launch a new one from a saved
  *profile*, connect to a running one, cancel, view logs/GPU.

A **profile** is a directory `berzelius-toolbox/jobs/<name>/` holding `config.sh`
(`D_ACCOUNT`, `D_PARTITION`, `D_GPUS`, `D_TIME`, `D_MEM`, `D_JOBNAME`, and now
`D_RESERVATION`), optionally `setup.sh` (sourced inside the allocation), and
optionally `bjob_hooks.sh` (sourced on demand to customize `bjob`'s own
behavior — see the update below). Profiles are discovered by listing that
directory — **the directory name becomes the SLURM job name**, not
`D_JOBNAME`. Other tools depend on those names (see §7).

---

## 2. Current state — section map

| Lines | Section | Notes |
|---:|---|---|
| 1–123 | header, helpers, `usage` | `term_cols`, `trunc_pad`, `get_jobs`, `detect_accounts` |
| 124–328 | `daaam-cosmos` roles + AFK/auto `sbatch` launch | **205 lines for one profile** |
| 329–384 | profile load/save/render | `save_profile` rewrites `config.sh` wholesale |
| 385–558 | `_draw`, `_sp_draw`, `select_profile` | the arrow-key TUI core |
| 559–631 | new-profile wizard | |
| 632–696 | `launch_profile` | builds `srun` args; generic, no per-profile logic |
| 697–872 | connect / ide-cmds / gpu / logs / cancel | |
| 873–1036 | `handle_new_job`, `_main_screen` | the main key loop |
| 1037–1072 | `main` + CLI dispatch | |

**Two UI paradigms already coexist.** The job list and profile selector are an
arrow-key TUI with in-place redraw. But `prompt_afk_launch_mode` (157) and the
confirm prompts use plain **numbered menus with `read -rp`**. So the "simpler" style
is not a new idea here — it is already in the file and has never caused a problem.

---

## 3. How the display worked, and why it was fragile (resolved — see update above)

`main` enters the **alternate screen** (`\033[?1049h`), hides the cursor, and loops
`_main_screen`. `_main_screen` clears once (`\033[H\033[2J`), prints a static header,
then prints the item block via `_draw`. The key loop then:

```
tput cuu $redrawn      # move cursor UP over the item block
read one key           # blocks
act on the key
_draw                  # reprint the block in place
```

with `redrawn=$((_NJOBS + 4))` — **a hardcoded row count**. The whole thing is correct
only while *printed rows exactly equal counted rows*. Known weaknesses:

- **Line wrap breaks it.** A line longer than the terminal occupies two rows, `cuu`
  moves too little, and every later repaint drifts. Mitigated — not eliminated — by
  `trunc_pad` clamping to `term_cols` (8 call sites); lines that skip it are exposed.
- **No `SIGWINCH` handler.** Resize during the key loop desynchronises the arithmetic.
- **Any stray output between repaints** (a hook, a warning, a subshell) shifts
  everything by however many lines it printed.
- The row count is computed once per `_main_screen`, so it is consistent within a
  screen — but every branch must remember to `tput cud $redrawn` before printing
  anything, and there are ~10 such branches. Missing one garbles the display.

Return convention in the key loop: **`return 0` = refresh and re-enter, `return 1` =
leave the TUI.** Worth knowing before editing; it is not written down anywhere else.

---

## 4. History you must not rediscover the hard way

**An earlier version pinned a CPU core for days and drew an admin warning from NSC.**
The cause, preserved in `bin/bjob.bak_20260629_cpu_spin`:

```bash
while true; do
    IFS= read -rsn1 key 2>/dev/null || true   # <-- returns instantly at EOF
    ...
done
```

A `while true` loop whose only pacing is a blocking `read`. When stdin is not a TTY
(or hits EOF), `read` stops blocking, `|| true` swallows the failure, and the loop
spins at 100%. Fixed at both loop-controlling reads (519, 962) by exiting on failure:

```bash
if ! IFS= read -rsn1 key 2>/dev/null; then ...restore cursor...; return 1; fi
```

plus a TTY guard in `main` (`[[ ! -t 0 || ! -t 1 ]]` → exit 2).

`toolbox-doctor lint` still prints one warning for this file. It is **not** a live bug:
the remaining flagged reads (184, 220, 889, 1019) are all *"press any key" → return*,
bounded, and the escape-sequence reads (527, 970) carry `-t 0.1`. Do not "fix" them by
deleting the guard, and do not dismiss the warning class — it is the one that caused
real damage. **Re-run `toolbox-doctor lint` after every edit** (contract in
`berzelius-toolbox/CLAUDE.md`).

---

## 5. Pros — keep these

- The **CLI/TUI split** is right. Agents and scripts use the CLI; only humans hit the
  TUI. `main`'s TTY guard enforces it.
- **`launch_profile` is generic** — no per-profile branching. Adding a profile needs
  zero code changes (verified: the `percorso` profile was added without touching `bjob`).
- **Profiles as directories** is a good, discoverable data model.
- `trunc_pad` + `term_cols` show the width problem was thought about.
- The alternate screen means the TUI never pollutes scrollback.
- `bjob logs` and the tmux session log (`~/.cache/bjob-tmux/<session>.log`) have
  already saved a real debugging session — that log is how a silent pipeline crash was
  diagnosed. Do not drop it.

## 6. Cons — ranked by risk

1. ~~**Cursor-arithmetic redraw** (§3).~~ **Resolved 2026-08-21** — see the update at the top.
2. ~~**205 lines for `daaam-cosmos`**~~ — role picker, launch-mode picker, auto-batch range,
   state dir, plus 12 name-equality checks scattered through `connect_job`,
   `print_ide_commands` and `log_paths`. **Resolved 2026-08-21** — extracted into
   `jobs/daaam-cosmos/bjob_hooks.sh`, see the update at the top.
3. **Global mutable render state** (`_SEL`, `_NJOBS`, `_JIDS[]`, `_SP_*`, `_RESULT`) —
   functions communicate by side effect, so nothing is testable in isolation.
4. **`save_profile` rewrites `config.sh` from a fixed template.** Any field not in that
   template is silently lost when a profile is edited through the wizard. `D_RESERVATION`
   was just added to it for this reason; the next added field must not forget.
5. **No automated test of any kind.** Every change is verified by hand on a login node.
6. `bin/*.bak_*` files sit next to the live tool. Harmless (lint skips non-executables)
   but confusing; they belong in git or in a subdirectory.

---

## 7. Constraints from outside this file

- **Job names are no longer an API** (changed 2026-08-25). The client tool that
  matched them exactly, `percorso-net`, has been removed; its replacement
  `ssh-helper` shows the raw `squeue` listing and takes a host and port, so
  renaming a profile directory no longer breaks anyone's discovery. One coupling
  fewer to respect — but `percorso-demo` on the server still matches
  `cosmos-reason2` exactly to find the Cosmos node, so that one name is load-bearing.
- **NSC kills jobs averaging under 90 W** (idle 52 W; rising to 100 W+). Exempt: a job's
  first hour, NSC `interactive` under 8 h, and reservations. **That is why almost every
  profile is `D_TIME="00:59:59"`** — it is a deliberate dodge, not an arbitrary choice.
  Anything longer needs `D_RESERVATION` (`safe` and `devel` are both usable; verified by
  running there). Never pad GPU load to defeat this policy.
- **`daaam-cosmos` is the paper-reproduction path.** It carries 12 automation scripts
  (`auto_all.sh`, `auto_ros_launch.sh`, `auto_bag_play.sh`, `postprocess_merge.sh`,
  `sbatch_*`). It also co-locates vLLM and the pipeline on one GPU and OOMs on 40 GB
  cards. **Do not delete it before the paper is submitted** — but removing it afterwards
  is the single biggest simplification available to this tool (§6.2).

---

## 8. The interactive-style question (Option A done — see update above)

Three options, in increasing order of change:

**A. Keep arrow keys, replace the redraw.** Repaint the whole screen each iteration
(`\033[H\033[2J` then reprint) instead of `tput cuu` arithmetic. Deletes the row-count
coupling and every `tput cud $redrawn` in the branches. At this size (tens of rows,
inside the alternate screen) full repaint is imperceptible.
*~30 lines touched, same UX, kills risk #1 outright.* **Recommended first move.**

**B. Numbered menu, `read -rp`.** Print a numbered list, read a whole line. No raw
mode, no cursor control, no alternate screen; survives a flaky ssh; readable when
piped; cannot spin (a line read from a TTY blocks, EOF exits). Costs arrow-key
navigation and one Enter per action. **The pattern already exists at line 157**, so
this is standardising on a proven local style rather than importing a new one.

**C. Both.** Numbered menu as the default and as the non-TTY fallback; arrow keys
behind `BJOB_TUI=1`. Best UX, most code — probably not worth it for one user.

**Suggestion:** do **A** now because it is cheap and removes the whole misalignment
class. Consider **B** if display bugs recur, or as part of the post-paper cleanup when
`daaam-cosmos` leaves and the file loses ~200 lines anyway. A rewrite justified only by
"the display is fiddly" is not worth the regression risk on a tool that works.

---

## 9. Quality checklist — before any merge

- [ ] `bash -n bin/bjob` passes.
- [ ] `toolbox-doctor lint` shows **no new** findings (one pre-existing warn on `bjob`,
      explained in §4).
- [ ] No `while`/`until` loop paced only by a `read` that can return without blocking.
      Every loop-controlling read exits on failure.
- [ ] `bjob` with stdin redirected from `/dev/null` exits promptly with a message, and
      **does not spin** (`timeout 5 bjob < /dev/null; echo $?` → 2, fast).
- [ ] `bjob --help`, `bjob connect` and `bjob logs` work with no TTY.
- [ ] TUI leaves the alternate screen and **restores the cursor** on every exit path,
      including `q`, EOF, and Ctrl-C (`cleanup`/`leave_alt_screen`).
- [ ] Display correct at 80 columns and at ~40 columns (the width most likely to wrap).
- [ ] A resize during the key loop does not corrupt the display.
- [ ] `save_profile` round-trip: edit a profile through the wizard and confirm **every**
      field survives, `D_RESERVATION` included.
- [ ] Adding a profile still needs no code change (`jobs/<name>/config.sh` only).
- [ ] If a profile is renamed, `cosmos-reason2` is left alone — `percorso-demo`
      matches it exactly to locate the Cosmos node.
- [ ] Verified without burning an allocation where possible: `srun --test-only` for
      argument construction, `sinfo`/`scontrol` for node facts, `--reservation=devel`
      for a genuinely short real run.

## 10. Testing without a cluster allocation

Most of this tool can be checked from a login node:

- `srun --test-only <args> true` validates account/partition/reservation/GPU
  combinations and prints where the job *would* start — no allocation consumed.
- `scontrol show reservations`, `sinfo -N -o "%N %f %G"` for node facts.
- A stub binary earlier on `PATH` (a script named `squeue` or `srun` echoing canned
  output) exercises parsing and menu logic end-to-end. This is how the now-removed
  `percorso-net`'s job-name priority was tested; the same trick applies here and is
  the closest thing to a unit test the tool can have. Consider committing such stubs.
- For a real GPU check, `--reservation=devel --time=00:02:00` starts immediately.

---

## Related files

`berzelius-toolbox/CLAUDE.md` (tool contract, agent-safety rules) ·
`berzelius-toolbox/docs/commands.md` (usage + the NSC power policy) ·
`berzelius-toolbox/bin/toolbox-doctor` (`lint`, `procs`) ·
`berzelius-toolbox/jobs/*/` (profiles) ·
`ros2_ws/src/percorso-perception/tools/ssh-helper` (robot/laptop client)
