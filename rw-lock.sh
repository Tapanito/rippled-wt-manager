#!/usr/bin/env bash
# rw-lock.sh — serialise heavy xrpld work across concurrently-running agents.
#
# Multiple agents work in separate worktrees but share one machine. Two
# simultaneous builds (or full test runs) exhaust RAM and take the box down, so
# every heavy command must run under this mutex.
#
#   rw-lock.sh -- rw make                       # block until free, then build
#   rw-lock.sh --label "A: build" -- rw make    # same, with a label for --status
#   rw-lock.sh --wait 0 -- rw make              # fail fast (exit 75) if busy
#   rw-lock.sh --wait 300 -- rw make            # give up after 5 min (exit 75)
#   rw-lock.sh --status                         # who holds it, since when
#
# Correctness comes from flock(2), held on a file descriptor. The kernel
# releases it once every process holding that descriptor has exited — for any
# reason, including SIGKILL and OOM-kill. So there is nothing to reap, and the
# .info sidecar is for humans only: it is never consulted to decide whether the
# lock is free.
#
# Note the exact semantics, which were verified rather than assumed: the child
# command inherits the descriptor, so killing THIS wrapper does not release the
# lock while the build it started is still running. That is the behaviour you
# want — the machine is still busy — and the lock does drop as soon as the last
# descendant exits. A genuinely wedged descendant is bounded by
# RW_LOCK_MAX_RUN, which is enforced by a `timeout` that survives the wrapper's
# death. To clear a lock by hand, kill the recorded process group
# (`kill -9 -<pgid>` from --status), not just the pid.
#
# Long builds exceed a 10-minute foreground tool timeout. Run this in the
# background and let the harness notify you on completion, rather than raising
# the timeout or polling in a tight loop.

set -uo pipefail

LOCK_FILE="${RW_LOCK_FILE:-$HOME/.cache/rippled-build.lock}"
INFO_FILE="${LOCK_FILE}.info"
# Hard ceiling on the critical section, so one wedged build cannot block the
# other agent forever. Generous: a clean Debug build plus a full test run.
MAX_RUN="${RW_LOCK_MAX_RUN:-5400}"

wait_secs=""     # empty => block indefinitely
label=""
mode="run"

die() { printf 'rw-lock: %s\n' "$*" >&2; exit 64; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)      mode="status"; shift ;;
        --wait)        shift; [[ $# -gt 0 ]] || die "--wait needs a value"; wait_secs="$1"; shift ;;
        --wait=*)      wait_secs="${1#--wait=}"; shift ;;
        --label)       shift; [[ $# -gt 0 ]] || die "--label needs a value"; label="$1"; shift ;;
        --label=*)     label="${1#--label=}"; shift ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        --)            shift; break ;;
        *)             die "unknown option '$1' (did you forget '--' before the command?)" ;;
    esac
done

mkdir -p -- "$(dirname -- "$LOCK_FILE")" || die "cannot create lock directory"

if [[ "$mode" == "status" ]]; then
    exec 9>>"$LOCK_FILE" || die "cannot open $LOCK_FILE"
    if flock -n 9; then
        echo "rw-lock: FREE"
        flock -u 9
        exit 0
    fi
    echo "rw-lock: HELD"
    [[ -s "$INFO_FILE" ]] && sed 's/^/  /' "$INFO_FILE"
    exit 1
fi

[[ $# -gt 0 ]] || die "no command given (use: rw-lock.sh [opts] -- <command>)"

# Re-entrancy: a command run under the lock may itself invoke this wrapper
# (e.g. a script that builds then tests). Nesting would self-deadlock, so pass
# straight through instead.
if [[ "${RW_LOCK_HELD:-}" == "1" ]]; then
    exec "$@"
fi

exec 9>>"$LOCK_FILE" || die "cannot open $LOCK_FILE"

if [[ -n "$wait_secs" ]]; then
    if ! flock -w "$wait_secs" 9; then
        printf 'rw-lock: busy, gave up after %ss. Holder:\n' "$wait_secs" >&2
        [[ -s "$INFO_FILE" ]] && sed 's/^/  /' "$INFO_FILE" >&2
        exit 75   # EX_TEMPFAIL — retry later, this is not a build failure
    fi
else
    if ! flock -n 9; then
        printf 'rw-lock: busy, waiting. Holder:\n' >&2
        [[ -s "$INFO_FILE" ]] && sed 's/^/  /' "$INFO_FILE" >&2
        flock 9 || die "failed to acquire lock"
    fi
fi

{
    printf 'label   : %s\n' "${label:-<none>}"
    printf 'pid     : %s\n' "$$"
    printf 'pgid    : %s\n' "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    printf 'started : %s\n' "$(date -Is)"
    printf 'worktree: %s\n' "$PWD"
    printf 'branch  : %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '<not a repo>')"
    printf 'command : %s\n' "$*"
} >"$INFO_FILE" 2>/dev/null || true

start=$SECONDS
RW_LOCK_HELD=1 timeout --signal=TERM --kill-after=60s "$MAX_RUN" "$@"
rc=$?
elapsed=$(( SECONDS - start ))

: >"$INFO_FILE" 2>/dev/null || true

if [[ $rc -eq 124 ]]; then
    printf 'rw-lock: command exceeded RW_LOCK_MAX_RUN=%ss and was killed after %ss\n' \
        "$MAX_RUN" "$elapsed" >&2
else
    printf 'rw-lock: released after %ss (exit %s)\n' "$elapsed" "$rc" >&2
fi
exit $rc
