# berzelius-toolbox

Personal scripts and notes for working on Berzelius (NSC/LiU).

Stored in project space to avoid home-dir quota limits.

## Layout

```
berzelius-toolbox/
├── CLAUDE.md         # Contract for agents + tool index (read this first)
├── bin/
│   ├── bjob          # Interactive SLURM job manager (needs a TTY)
│   ├── percorso-demo # Live-demo service manager (zenoh/pipeline/bag/power)
│   ├── toolbox-doctor# Lint for CPU-spin hazards + find runaway processes
│   └── lib/          # Sourced-only helpers shared between tools (not linked into ~/bin)
├── docs/
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
# percorso-net is the robot/laptop side and lives in a different repo — see
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

For the DAAAM workflow, launch `daaam-cosmos`, then run `bjob connect <jobid>` from IDE terminals and choose `cosmos`, `daaam`, `shell`, or `gpu`. The `daaam` option opens a prepared container shell with ROS sourced, `PYTHONPATH`, `HOI_FPS`, and `COSMOS_URL` set. Set `BATCH_NAME` manually inside that shell.
