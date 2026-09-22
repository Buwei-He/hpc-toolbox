# Quickstart

`bjob` is the front-end for running things on Berzelius from this toolbox.
This page is the short version — for the deep design notes see
`HANDOFF_bjob.md`, and for the agent contract see the top-level `CLAUDE.md`.

## Running something

- `bjob` — no arguments — opens an interactive picker: choose a saved
  profile (`jobs/<name>/`), it launches and drops you into a shell on the
  node. Needs a real terminal.
- `bjob submit <profile>` — launches a profile **without** attaching to
  anything, for scripts or when you're not around. Only profiles marked
  `submit` in the `bjob` list support this (right now: `cosmos-reason2`,
  `llava`, `cosmos3-nano-reasoner`, `percorso`) — the rest still need a
  human at a terminal, at least once.
- `bjob connect <jobid>` — reattach to a job that's already running.
- `bjob power <jobid>` / `bjob logs <jobid>` / `bjob gpu <jobid>` — check on
  one from anywhere, no need to be inside it.

## Why a job sits "pending", and what to do about it

Berzelius is one shared cluster (79 GPU nodes) used by a lot of people.
Right now, as one example: 66 of those 79 nodes are busy and 350 jobs are
queued. A job sitting `PD` (pending) with reason `Priority` or `Resources`
in `squeue` isn't stuck or broken — it's waiting its turn behind other
people's jobs, like any shared queue. Whether that's seconds or hours
depends on how busy the cluster is *right now* — check with `squeue -u
$USER` or `sinfo`.

Live example while writing this: one job (`cosmos-reason2`) sat `PENDING`
in the normal queue, while another (`percorso`) was `RUNNING` within
seconds — because `percorso`'s profile uses a **reservation** (below).
Same cluster, same moment, very different wait.

**What actually gets you running faster, in order of how much it helps:**

1. **Use a reservation.** `safe` (5 nodes) and `devel` (1 node) are
   dedicated capacity that skips the general queue entirely. Set
   `D_RESERVATION="safe"` (or `"devel"`) in a profile's `config.sh`, or add
   `--reservation=safe` to any `srun`/`sbatch` by hand. They're small and
   shared with whoever else is using them — fine for a demo or a real test,
   not for parking a job for hours "just in case."
2. **For a quick interactive check, use NSC's own `interactive` command**
   (`interactive --gpus=1 -t 04:00:00`) instead of `bjob`. It tends to
   start fast and is exempt from the power-floor policy (next section) for
   under 8 hours, reservation or not. It's a plain shell, not one of this
   toolbox's saved profiles.
3. **Ask for as few GPUs as you actually need.** Every node here has 8
   GPUs. Requesting 1 lets the scheduler slot you onto a node that's
   already partly in use; requesting more shrinks the set of nodes that
   can take you, often by a lot. Most profiles here already default to 1.
4. **Don't switch to `berzelius-cpu` hoping it's faster.** It's a separate,
   much smaller partition (8 nodes total) that's frequently just as busy
   or busier, proportionally. A CPU-only job is not automatically cheaper
   to schedule — check `sinfo` before assuming.

## The other thing that can kill a job: idling too long

Separately from queueing, NSC also kills jobs whose **average power stays
below ~90 W** — i.e., a job that's allocated but not actually doing
anything. A reservation is one of the exemptions (see above); so is
keeping a job under an hour, which is why most saved profiles here default
to `00:59:59`. A profile that's meant to idle between bursts (like a live
demo waiting for a question) should set `D_RESERVATION` and can also set
`D_POWER_GUARD="1"` to watch its own power draw automatically. Full detail
in `CLAUDE.md`.

## A third thing that can kill a job: out of VRAM

You can't predict a model server's *peak* VRAM use precisely — it depends
on how many requests arrive at once and how long they are, not just the
model. But you can set a *ceiling*, and that's what actually matters:

- **Every server profile here (`cosmos-reason2`, `cosmos3-nano-reasoner`,
  `llava`, `daaam-cosmos`) already caps itself** via an env var —
  `COSMOS_GPU_MEMORY_UTILIZATION`, `COSMOS3_GPU_MEMORY_UTILIZATION`, or
  (for `llava`'s SGLang server) `--mem-fraction-static` — a *fraction* of
  the card's total VRAM, not an absolute size. The server refuses new
  requests once it hits that ceiling instead of overrunning it. Lower it
  (e.g. `COSMOS_GPU_MEMORY_UTILIZATION=0.6`) to trade capacity for
  headroom if you're still seeing OOMs.
- **Berzelius' cards aren't all the same size**: about 44 nodes have 40 GB
  ("thin") A100s and 33 have 80 GB ("fat") ones — same `--gpus` count,
  double the headroom on a fat one. Set `D_CONSTRAINT="fat"` in a
  profile's `config.sh` (or add `--constraint=fat` by hand) to land on one
  specifically, instead of leaving it to chance — this is what fixed
  `daaam-cosmos`, which used to OOM on some nodes and not others for
  exactly this reason. Trade-off: fewer candidate nodes (33 of 77), so
  potentially more `PENDING` time — same shape of trade-off as asking for
  more GPUs, above.
- **Watch it live**: `bjob gpu <jobid>` reports `memory.used`/`memory.total`
  alongside power, so you can see how close to the ceiling a real run
  actually gets.

## Checking what's actually going on

- `squeue -u $USER` — state (`R`/`PD`) and, for pending jobs, why.
- `bjob` (the TUI) shows the same thing, plus GPU/mem/time per profile.
- `bjob power <jobid>` — is a running job actually drawing power, or just
  sitting idle (and at risk of being killed)?
- `bjob gpu <jobid>` — is it close to running out of VRAM?
