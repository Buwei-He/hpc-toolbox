# berzelius-toolbox

Personal scripts and notes for working on Berzelius (NSC/LiU).

Stored in project space to avoid home-dir quota limits.

**New here, or a job stuck pending?** Start with `docs/quickstart.md` —
short, human-first, covers running a profile and what to actually do about
a job that won't start.

## Layout

```
berzelius-toolbox/
├── CLAUDE.md         # Contract for agents + tool index (read this first)
├── bin/
│   ├── bjob          # Interactive SLURM job manager (needs a TTY)
│   ├── percorso-demo # Live-demo service manager (run bag|live, stream/pipeline/bag/snapshot/power)
│   ├── toolbox-doctor# Lint for CPU-spin hazards, runaway processes, quota
│   └── lib/          # Sourced-only helpers shared between tools (not linked into ~/bin)
├── docs/
│   ├── quickstart.md # Short, human-first: running a profile, why jobs pend, how to get unstuck
│   └── commands.md   # Common commands / workflow notes
└── jobs/             # Saved bjob profiles
```

Version-controlled with git since 2026-08-21. Manual pre-edit copies
(`.bak_*` files, `.bjob-backups/`) predate that and are kept for history, but
going forward a git commit replaces them — no need for a new one before a
risky edit.

## Setup

```bash
export PATH="$HOME/bin:$PATH"
PROJECT=/proj/rpl-soro/users/$USER
ln -sf $PROJECT/berzelius-toolbox/bin/bjob           ~/bin/bjob
ln -sf $PROJECT/berzelius-toolbox/bin/percorso-demo  ~/bin/percorso-demo
ln -sf $PROJECT/berzelius-toolbox/bin/toolbox-doctor ~/bin/toolbox-doctor
# ssh-helper is the robot/laptop side and lives in a different repo — see
# ros2_ws/src/percorso-perception/tools/README.md, not this toolbox.
```

## Adding a tool

Follow the contract in `CLAUDE.md` (no busy-wait, guard TTY-only modes, offer a
non-interactive path, exit 0/1/2), symlink it into `~/bin`, add a row to the tool
table in `CLAUDE.md`, then run `toolbox-doctor`.

## bjob

Run `bjob` from anywhere to:

- See current SLURM jobs
- Launch saved profiles
- Connect to running jobs with `srun --overlap`
- Show GPU power/utilization, or sample power against NSC's kill floor
  (`bjob power <jobid>`) for any job — not just the one you're inside
- Submit a profile non-interactively — `bjob submit <profile>` — for
  scripts/agents, no TTY needed. Only profiles with `D_SUBMITTABLE="1"` in
  `config.sh` (currently `cosmos-reason2`, `llava`, `cosmos3-nano-reasoner`,
  `percorso`); everything else still needs the TUI or `bjob connect`, since
  their `setup.sh` hands off to a human (tmux) rather than running unattended.

A profile (`jobs/<name>/`) can set `D_POWER_GUARD="1"` in `config.sh` to get
that power sampling automatically, in the background, for the job's whole
lifetime — no need to remember to check by hand — and `D_CONSTRAINT="fat"`
(or `"thin"`) to request an 80 GB or 40 GB A100 specifically, instead of
whichever one SLURM happens to hand it (see `docs/quickstart.md` for why
that matters for out-of-memory errors). It can also carry an optional
`bjob_hooks.sh` (custom connect roles/launch flow — see
`docs/HANDOFF_bjob.md`) and a `ports.conf` declaring `<svc> <port>
[priority]` for any service it exposes (not consumed by anything in this
repo yet — it's there for a future rewrite of `ssh-helper`, which lives in
the `percorso-perception` repo).

For the DAAAM workflow, launch `daaam-cosmos`, then run `bjob connect <jobid>` from IDE terminals and choose `cosmos`, `daaam`, `shell`, or `gpu`. The `daaam` option opens a prepared container shell with ROS sourced, `PYTHONPATH`, `HOI_FPS`, and `COSMOS_URL` set. Set `BATCH_NAME` manually inside that shell.
