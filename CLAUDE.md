# berzelius-toolbox

Ops tooling for Berzelius (NSC/LiU). Cluster-specific glue lives here — **never**
inside application repos like `daaam` / `percorso-perception`.

**Job sitting `PENDING` and not sure why, or whether that's even a
problem?** Read `docs/quickstart.md` first — short, covers reservations,
`interactive`, and why `berzelius-cpu` is not a faster fallback — before
concluding something is broken or retrying blindly.

## Cluster facts you need before running anything

- **Login nodes** (`berzelius1/2.nsc.liu.se`) have public IPs and outbound internet.
  They must **not** host long-running services or computation.
- **Compute nodes** (`node0NN`, 10.81.x.x) are private — unreachable from outside.
  Reach a service on one with `ssh -N -L localhost:P:nodeNN:P user@berzelius1...`,
  which is NSC's documented pattern.
- Partitions: `berzelius` (78 nodes, A100) and `berzelius-cpu` (**only 8 nodes**).
  CPU allocations often queue *longer* than GPU ones — do not assume a CPU-only
  job is cheaper to schedule.
- **GPU cards on `berzelius` are not uniform**: ~44 nodes are 40 GB ("thin"), ~33
  are 80 GB ("fat") — same `--gpus` count, very different VRAM headroom. Request
  a size with `--constraint=fat`/`thin`, or `D_CONSTRAINT="fat"` in a profile's
  `config.sh` (see `daaam-cosmos`, which used to OOM on some nodes and not
  others for exactly this reason). Costs queue time: only ~40% of nodes are fat.
- Node assignment changes every allocation. Never hardcode a node name; ask SLURM.
- **NSC kills jobs averaging under 90 W** (idle 52 W; rising to 100 W+). Exempt: a
  job's first hour, NSC `interactive` under 8 h, and reservations (`safe`, `devel` —
  both usable by us). That is why the profiles are `00:59:59`; anything longer needs
  `D_RESERVATION`. Never pad GPU load to defeat this — it is a shared-resource policy
  and we have already had one warning. Check with `percorso-demo power` (inside a
  job) or `bjob power <jobid>` (from anywhere); or set `D_RESERVATION`/`D_POWER_GUARD`
  on the profile so it watches itself.
- **Login nodes have a visible GPU too.** Discovered the hard way: an unguarded
  background `nvidia-smi` sampler run directly (not through `srun`) started for real
  on `berzelius2` — no allocation required to see or poll it. Anything that starts a
  detached loop against `nvidia-smi` must check `[[ -n "${SLURM_JOB_ID:-}" ]]` first
  (see `bjob`'s `power_guard_start`), the same way `percorso-demo`'s `require_job`
  already does for its own services.

## Tools

| Command | Agent-safe? | Purpose |
|---|---|---|
| `toolbox-doctor` | yes | lint scripts for CPU-spin hazards + find runaway processes + check disk/file quota |
| `percorso-demo where` / `doctor` / `status` | yes | locate paths, verify the overlay, see what is running |
| `percorso-demo stream` / `snapshot` / `logs <svc>` / `stop <svc>` | yes | detaching service control — returns promptly |
| `percorso-demo pipeline` / `bag` / `run bag\|live` | **no — long-running** | run the live demo (mock or real) |

`percorso-demo logs <svc> -f` is the one exception: `-f` blocks forever by design.
Agents should call it without `-f` (a line count instead).
| `bjob <jobid> …` subcommands | yes | `connect`, `logs`, `gpu`, `power` (sample GPU power against NSC's kill floor for any job) |
| `bjob submit <profile>` | yes — gated on `D_SUBMITTABLE` | non-interactive launch via `sbatch` (not `srun --pty`, no TTY needed); only profiles whose `config.sh` sets `D_SUBMITTABLE="1"` (a human's one-time confirmation that `setup.sh` doesn't hand off to a human, e.g. via `tmux attach`) — currently `cosmos-reason2`/`llava`/`cosmos3-nano-reasoner`/`percorso` |
| `bjob extend <jobid>` | **ask first — submits a job** | one-click extend past 00:59:59: gated on a live power check, queues a dependent follow-up job (`hook_extend`); only profiles that checkpoint their own progress support it (currently daaam-cosmos's `cosmos-server`/`daaam-worker`) |
| `bjob` (no args) | **no — needs TTY** | interactive job manager |

**`ssh-helper` lives elsewhere and is not for this side.** It is the robot/laptop
client, shipped in the **percorso-perception** repo (`tools/ssh-helper`) because
the robot must be able to git-clone it, and this toolbox lives only on the
cluster's `/proj` filesystem — the robot has no path to it regardless of git. On
the cluster there is nothing to forward — use `percorso-demo status` to find a
service. A `ssh-helper` verb run here refuses with that pointer.

This toolbox is otherwise server-side only: it needs SLURM and `/proj`.

## Contract for tools in `bin/`

Follow this and a new tool is automatically agent-usable. Add a row to the table
above when you add one.

1. **No busy-wait.** Every wait loop either `sleep`s or blocks on a real syscall.
   This is not theoretical: `bjob` once spun a core for *days* and drew an admin
   warning, because `IFS= read -rsn1 key || true` inside `while true` returns
   instantly when stdin is not a TTY, and `|| true` hid the failure.
2. **Guard interactive modes.** Anything that reads keys or holds a connection
   open must check `[ -t 0 ] && [ -t 1 ]` and exit with guidance otherwise.
   Agents always run non-interactively, so an unguarded TUI is a hang or a spin.
3. **Offer a non-interactive path.** If a command is inherently long-running, give
   it a `--verify` / one-shot mode that an agent can call.
4. **Machine-readable twin.** Human output is fine, but expose a parseable form
   (`locate` next to `resolve`) so scripts don't scrape colored text.
5. **Exit codes:** `0` success · `1` expected failure, with the next command to try
   printed on stderr · `2` wrong environment (no TTY, not on a cluster node).
6. **Fail with directions.** Every error says what is wrong *and* what to run next.
   The thing being debugged weeks later is usually "which node is it on today".

## Safety check

Run `toolbox-doctor` before and after editing anything in `bin/`. It lints for the
spin hazard above and reports processes whose CPU time is tracking wall-clock time
(the signature of a runaway loop — long elapsed time alone is normal and harmless).
