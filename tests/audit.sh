#!/usr/bin/env bash
# audit.sh - status of every known bug across the five plugins.
#
# Greps CODE, not prose. An earlier version of this audit matched the comment
# that explains a fix and reported the fixed bug as still open, which is the same
# mistake that made a generative test upstream pass vacuously. Every pattern here
# runs against a comment-stripped view of the file.
set -uo pipefail

CODE_ROOT="${CODE_ROOT:-$HOME/Code}"
TR="$CODE_ROOT/tmux-agent-tracker"
RS="$CODE_ROOT/tmux-agent-resumer"
MS="$CODE_ROOT/tmux-agent-mesh"
WT="$CODE_ROOT/tmux-worktree"
SO="$CODE_ROOT/tmux-session-order"

open=0 fixed=0

# code_grep <pattern> <file>... - count matches outside comments.
#
# Note the `|| true` rather than `|| printf 0`: `grep -c` prints its count AND
# exits 1 when the count is zero, so a printf fallback appends a second zero and
# the caller's arithmetic sees "0\n0".
code_grep() {
    local pat="$1"; shift
    local f n total=0
    for f in "$@"; do
        [[ -r "$f" ]] || continue
        n=$( { sed 's/[[:space:]]*#.*$//' "$f" | grep -cE "$pat"; } 2>/dev/null || true )
        n="${n//[^0-9]/}"
        total=$(( total + ${n:-0} ))
    done
    printf '%s' "$total"
}

# report <id> <expect-zero|expect-nonzero> <count> <description>
report() {
    local id="$1" mode="$2" n="$3" desc="$4" state
    case "$mode" in
        zero)    [[ "$n" -eq 0 ]] && state=fixed || state=OPEN ;;
        nonzero) [[ "$n" -gt 0 ]] && state=fixed || state=OPEN ;;
    esac
    if [[ "$state" == OPEN ]]; then open=$(( open + 1 )); else fixed=$(( fixed + 1 )); fi
    printf '%-5s %-6s %-56s (n=%s)\n' "$id" "$state" "$desc" "$n"
}

printf '%-5s %-6s %-56s %s\n' "ID" "STATE" "FINDING" "COUNT"
printf '%-5s %-6s %-56s %s\n' "-----" "------" "$(printf '%.0s-' {1..56})" "-----"

# Two halves, because the fix both removes and adds. The old pattern was
# `set-hook .*pane-died`, which now matches the `set-hook -gu "pane-died[N]"`
# that *removes* the dead binding on upgrade, so the audit reported a fixed bug
# as open. `-ga` is the registering form; `-gu` is the unsetting one.
#
# The positive half is not optional. `pane-exited` alone was the original
# proposed fix and it is insufficient: measured on 3.5a, kill-pane fires only
# after-kill-pane, kill-window only window-unlinked, and kill-session
# session-closed. A probe that checked for any hook but pane-died would have
# called that half-fix done.
report V4  zero    "$(code_grep 'set-hook -ga[^"]*pane-died' "$MS/agent-mesh.tmux")" \
    "mesh registers cleanup on pane-died, which never fires"
report V4b nonzero "$(code_grep 'MESH_CLEANUP_HOOKS=.*pane-exited.*after-kill-pane.*window-unlinked.*session-closed' "$MS/agent-mesh.tmux")" \
    "mesh cleanup covers every teardown hook, not just pane-exited"
report V5  zero    "$(code_grep 'set-hook -g [a-z]' "$TR/agent-tracker.tmux")" \
    "tracker set-hook -g clobbers sibling plugins"
report V6  zero    "$(code_grep 'mv "\$tmp"' "$TR/install.sh")" \
    "tracker install.sh mv breaks a symlinked settings.json"
report V11 zero    "$(code_grep 'DROP TABLE' "$TR/scripts/tracker.sh")" \
    "tracker DROP TABLE wipes state on every plugin load"
report V12 zero    "$(code_grep "grep -oE '\^\[A-Z_\]\+=" "$MS/tests/isolation.bats")" \
    "mesh generative test anchored so it matches nothing"
report V13 zero    "$(( $(code_grep 'pgrep -P' "$TR/scripts/helpers.sh") - $(code_grep 'pgrep -P' "$RS/scripts/helpers.sh") ))" \
    "_has_agent_child Linux name list drifted between repos"
report V14 nonzero "$(code_grep 'refresh-client' "$RS/scripts/resumer.sh")" \
    "resumer never pushes a status refresh"
report V15 zero    "$(ls "$MS"/internal/store/*.go 2>/dev/null | wc -l | tr -d ' ')" \
    "mesh dead internal/store Go package"
report C6  zero    "$(code_grep 'mv "\$tmp"' "$SO/uninstall.sh" "$WT/uninstall.sh")" \
    "uninstall mv breaks a symlinked tmux.conf"

# NG-3, from the first external consumer. _load_config_fast sourced the config
# cache with no staleness check, so no @agent-tracker-* option ever took effect
# once the cache existed. Both halves are needed: the negative alone would pass on
# a version that simply deleted the fast path, and the positive alone would pass on
# one that called load_config *after* sourcing the cache.
report NG3 zero    "$(code_grep 'source "\$_cc"' "$TR/scripts/tracker.sh")" \
    "tracker sources its config cache without a staleness check"
report NG3b nonzero "$(code_grep 'tk_config_load agent-tracker' "$TR/scripts/helpers.sh")" \
    "tracker config loading goes through tk_config_load"

# The socket fork this replaced was hand-copied eleven times in worktree, and
# every copy was a place a later edit could touch one branch and not the other.
report V16 zero    "$(code_grep 'tmux -L "?\$TMUX_SOCKET' "$WT/scripts/helpers.sh" "$WT/scripts/worktree_manager.sh" "$WT/worktrees.tmux")" \
    "worktree hand-copies the -L TMUX_SOCKET fork per call site"

# Vendoring status, informational rather than pass/fail.
printf '\nvendored lib/ per consumer:\n'
for d in "$TR" "$RS" "$MS" "$WT" "$SO"; do
    if [[ -r "$d/lib/VERSION" ]]; then
        printf '  %-8s %s\n' "$(<"$d/lib/VERSION")" "$(basename "$d")"
    else
        printf '  %-8s %s\n' "-" "$(basename "$d")"
    fi
done

printf '\n%s open, %s fixed\n' "$open" "$fixed"
[[ "$open" -eq 0 ]]
