# svc.sh — shared detached-service mechanics: pidfile/logfile bookkeeping,
# start/stop, and a bounded wait for a port to start answering.
#
# Sourced by bin/bjob and bin/percorso-demo; not a standalone tool (no
# shebang, not linked into ~/bin, not scanned by toolbox-doctor's lint,
# which only walks direct children of bin/).
#
# Callers set SVC_RUN_DIR before calling any of these, and provide their own
# ok/warn/note helpers (bjob and percorso-demo both already define the same
# ones, same as bin/lib/power.sh assumes for its color vars).
#
# Runtime state should live per-node, under $PROJECT: compute nodes are
# ephemeral, so a pidfile from a different node describes a process that
# cannot exist, and treating it as live would be worse than no state at all.

svc_pidfile() { printf '%s/%s.pid' "$SVC_RUN_DIR" "$1"; }
svc_logfile() { printf '%s/%s.log' "$SVC_RUN_DIR" "$1"; }

# Prints a live pid, or fails. Deletes a pidfile whose process is gone, so a
# service that crashed never reports itself as running.
svc_pid() {
    local f pid; f=$(svc_pidfile "$1")
    [ -s "$f" ] || return 1
    pid=$(cat "$f" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then printf '%s' "$pid"; return 0; fi
    rm -f "$f"; return 1
}

# No /dev/tcp here: bash's builtin cannot be given a timeout without a
# subshell dance, and `timeout` + exec redirection is the readable version.
tcp_open() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

# svc_start <name> <shell-command> <preamble> [launcher-argv...]
#
# <shell-command> becomes the script's final `exec` line; <preamble> (may be
# "") is written verbatim above it — a caller that needs to source an
# environment or set up a container bakes that in here instead of into
# <shell-command>, since exec must be the last statement. [launcher-argv...]
# runs in front of `bash <script>` — e.g. an apptainer invocation; omit it to
# run the script directly.
#
# The child writes its OWN pid rather than relying on `$!` after setsid:
# `$!` is only the payload's pid when setsid happens not to fork, which
# depends on process-group state callers do not control.
svc_start() {
    local name="$1" cmd="$2" preamble="$3"; shift 3
    local -a launcher=("$@")
    local pid pf lf sh
    mkdir -p "$SVC_RUN_DIR"
    pf=$(svc_pidfile "$name"); lf=$(svc_logfile "$name"); sh="$SVC_RUN_DIR/$name.cmd.sh"
    if pid=$(svc_pid "$name"); then
        ok "$name is already running (pid $pid)"
        note "logs:  tail -f $lf      stop:  svc_stop $name"
        return 0
    fi
    { [ -n "$preamble" ] && printf '%s\n' "$preamble"; printf 'exec %s\n' "$cmd"; } > "$sh"
    : > "$lf"
    # setsid gives the payload its own process group, so `kill -- -pid` in
    # svc_stop reaches a launcher wrapper AND the real binary under it.
    setsid nohup bash -c 'echo $$ > "$1"; shift; exec "$@"' _ "$pf" \
           "${launcher[@]}" bash "$sh" >>"$lf" 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$pf" ] && break
        sleep 0.2
    done
    if ! pid=$(svc_pid "$name"); then
        warn "$name did not start"
        svc_log_tail "$name" 15
        return 1
    fi
    note "$name launched (pid $pid) → $lf"
    return 0
}

# Bounded wait for a service to actually answer. Without this a caller would
# report "started" for a process about to exit one line later.
svc_wait_port() {
    local name="$1" port="$2" tries="${3:-15}" i
    for ((i = 0; i < tries; i++)); do
        if ! svc_pid "$name" >/dev/null; then
            warn "$name exited during startup"
            svc_log_tail "$name" 15
            return 1
        fi
        tcp_open "$port" && return 0
        sleep 1
    done
    warn "$name is running but nothing is listening on 127.0.0.1:$port after ${tries}s"
    svc_log_tail "$name" 15
    return 1
}

svc_log_tail() {
    local lf; lf=$(svc_logfile "$1")
    [ -s "$lf" ] || { note "log is empty ($lf)"; return 0; }
    printf "${DIM}        ── %s (last %s lines) ──${NC}\n" "$lf" "${2:-20}"
    sed -e 's/^/          /' <(tail -n "${2:-20}" "$lf")
}

svc_stop() {
    local name="$1" pid i
    if ! pid=$(svc_pid "$name"); then
        note "$name is not running"
        return 0
    fi
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    for ((i = 0; i < 10; i++)); do
        svc_pid "$name" >/dev/null || { ok "$name stopped"; return 0; }
        sleep 0.5
    done
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    sleep 0.5
    svc_pid "$name" >/dev/null && { warn "$name (pid $pid) will not die"; return 1; }
    ok "$name killed"
}
