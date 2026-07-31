# shellcheck shell=bash
# sched.sh - delayed and jittered execution.
#
# Replaces resumer.sh:245 and tracker.sh:784, which both run
# `run-shell -b "sleep N && ..."` (finding V7). The `-d` flag added in tmux
# 3.2 is a libevent timer on the server: no `sleep` child is forked, and the
# timer dies with the server exactly as a sleep child would.
#
# The floor is 3.0, so the 3.2+ gate is mandatory: on an older server the
# fallback is the pre-3.2 shape. This module is on the hot path (hooks call
# tk_after), so it lives in lib/toolkit.sh and must not fork more than it
# has to. tk_vers_ge is memoized in-process, so the version check costs one
# `tmux -V` per process, not per call.

# tk_after <secs> <cmd> - run <cmd> as a shell command after <secs> seconds.
#
# Fire-and-forget on both paths: run-shell returns immediately, and the
# fallback backgrounds a subshell so the hook that scheduled it never waits.
# <cmd> is a shell string, exactly as run-shell would receive it.
tk_after() {
    local secs="${1:-0}" cmd="${2:-}"
    [[ -n "$cmd" ]] || return 0
    if tk_vers_ge 3.2; then
        tk_tmux run-shell -b -d "$secs" "$cmd" 2>/dev/null || true
    else
        # 3.0/3.1 have no run-shell -d; keep the shape the plugins already
        # used there. The subshell detaches the sleep from the hook and
        # backgrounding it always succeeds, so nothing here can fail the
        # caller under set -e.
        ( sleep "$secs" && eval "$cmd" ) >/dev/null 2>&1 &
    fi
    return 0
}

# tk_jitter <max_secs> - sleep a random 0..max_secs.
#
# $RANDOM is 0..32767 in bash 3.2, which is older than the arithmetic this
# module is allowed to assume elsewhere, so the scaling keeps the top end
# honest for max values above 32767 without requiring bash 5's
# $SRANDOM. Sleeping zero seconds (the common case) does nothing.
tk_jitter() {
    local max="${1:-0}"
    [[ "$max" =~ ^[0-9]+$ ]] || return 0
    [[ "$max" -gt 0 ]] || return 0
    local n
    n=$(( (RANDOM * (max + 1)) / 32768 ))
    [[ "$n" -gt 0 ]] || return 0
    sleep "$n"
    return 0
}
