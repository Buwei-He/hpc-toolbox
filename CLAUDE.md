# berzelius-toolbox

Ops tooling for Berzelius (NSC/LiU). Cluster-specific glue lives here — **never**
inside application repos like `daaam` / `percorso-perception`.

## Cluster facts you need before running anything

- **Login nodes** (`berzelius1/2.nsc.liu.se`) have public IPs and outbound internet.
  They must **not** host long-running services or computation.
- **Compute nodes** (`node0NN`, 10.81.x.x) are private — unreachable from outside.
  Reach a service on one with `ssh -N -L localhost:P:nodeNN:P user@berzelius1...`,
  which is NSC's documented pattern.
- Partitions: `berzelius` (78 nodes, A100) and `berzelius-cpu` (**only 8 nodes**).
  CPU allocations often queue *longer* than GPU ones — do not assume a CPU-only
  job is cheaper to schedule.
- Node assignment changes every allocation. Never hardcode a node name; ask SLURM.
- **NSC kills jobs averaging under 90 W** (idle 52 W; rising to 100 W+). Exempt: a
  job's first hour, NSC `interactive` under 8 h, and reservations (`safe`, `devel` —
  both usable by us). That is why the profiles are `00:59:59`; anything longer needs
  `D_RESERVATION`. Never pad GPU load to defeat this — it is a shared-resource policy
  and we have already had one warning. Check with `percorso-demo power`.

## Tools

| Command | Agent-safe? | Purpose |
|---|---|---|
| `toolbox-doctor` | yes | lint scripts for CPU-spin hazards + find runaway processes |
| `percorso-demo where` / `doctor` / `status` | yes | locate paths, verify the overlay, see what is running |
| `percorso-demo zenoh` / `logs <svc>` / `stop <svc>` | yes | detaching service control — returns promptly |
| `percorso-demo pipeline` / `bag` | **no — long-running** | run the live demo against an EGG rosbag |

`percorso-demo logs <svc> -f` is the one exception: `-f` blocks forever by design.
Agents should call it without `-f` (a line count instead).
| `bjob <jobid> …` subcommands | yes | `connect`, `logs` |
| `bjob` (no args) | **no — needs TTY** | interactive job manager |

**`percorso-net` lives elsewhere and is not for this side.** It is the robot/laptop
client, shipped in the **percorso-perception** repo (`tools/percorso-net`) because
the robot must be able to git-clone it and this toolbox is not a git repo. On the
cluster there is nothing to forward — use `percorso-demo status` to find a service.
A `percorso-net` verb run here refuses with that pointer.

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
