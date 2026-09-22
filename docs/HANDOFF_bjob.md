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

- **Job names are an API.** `percorso-net` matches job names *exactly, in priority
  order* (`percorso`, `daaam-worker`, `daaam`, `daaam-cosmos`; `cosmos-server`,
  `cosmos-reason2`) to locate services. Renaming a profile directory breaks discovery.
  Substring matching was tried and resolved to the wrong node.
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
- [ ] Profile/job names unchanged, or `percorso-net`'s `svc_jobs()` updated to match.
- [ ] Verified without burning an allocation where possible: `srun --test-only` for
      argument construction, `sinfo`/`scontrol` for node facts, `--reservation=devel`
      for a genuinely short real run.

## 10. Testing without a cluster allocation

Most of this tool can be checked from a login node:

- `srun --test-only <args> true` validates account/partition/reservation/GPU
  combinations and prints where the job *would* start — no allocation consumed.
- `scontrol show reservations`, `sinfo -N -o "%N %f %G"` for node facts.
- A stub binary earlier on `PATH` (a script named `squeue` or `srun` echoing canned
  output) exercises parsing and menu logic end-to-end. This is how `percorso-net`'s
  job-name priority was tested; the same trick applies here and is the closest thing to
  a unit test the tool can have. Consider committing such stubs.
- For a real GPU check, `--reservation=devel --time=00:02:00` starts immediately.

---

## Related files

`berzelius-toolbox/CLAUDE.md` (tool contract, agent-safety rules) ·
`berzelius-toolbox/docs/commands.md` (usage + the NSC power policy) ·
`berzelius-toolbox/bin/toolbox-doctor` (`lint`, `procs`) ·
`berzelius-toolbox/jobs/*/` (profiles) ·
`ros2_ws/src/percorso-perception/tools/percorso-net` (consumes job names)
