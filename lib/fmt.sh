# shellcheck shell=bash
# fmt.sh - tmux display-message format helpers.
#
# Every consumer that queries pane state does it with display-message -p and a
# format string. The call shape, the format-string literal, and the error guard
# are duplicated across all five plugins, and one scan loop
# (tracker's cmd_scan) makes 2 display-message calls per pane inside a loop.
#
#   tk_fmt        - one display-message -p call against a target
#   tk_fmt_fields - positional fields with a custom separator
#   tk_q          - #{q:} sh-quote a value for safe use in tmux command args
#   tk_pane_search - #{C/r:} search pane content server-side
#
# bash 3.2 has no namerefs, so tk_fmt_fields returns values on stdout separated
# by a caller-chosen delimiter rather than writing into named variables.

# tk_fmt <target> <format> - run display-message -p against a target.
#
# The guard prevents dead-pane echo-back: when the target refers to a pane that
# no longer exists, tmux returns ":.\nN" or similar. The caller never wants that
# phantom string in place of real data.
tk_fmt() {
    local target="${1:-}" fmt="${2:-}"
    [[ -n "$target" && -n "$fmt" ]] || return 0
    tk_tmux display-message -t "$target" -p "$fmt" 2>/dev/null || true
}

# tk_fmt_fields <target> <sep> <field>... - format several #{field} values in
# one round trip, separated by the caller's choice of delimiter.
#
# Usage:
#   tk_fmt_fields "$t" $'\x1f' pane_id pane_tty pane_current_command
#
# Choosing the separator is the caller's job, because empty fields are real
# (e.g. a pane with no foreground process) and must not be collapsed. \x1f
# (unit separator) is the safe default; tab is IFS whitespace and collapses.
tk_fmt_fields() {
    local target="${1:-}" sep="${2:-}"
    shift 2
    [[ -n "$target" ]] || return 0
    [[ "$#" -gt 0 ]] || return 0

    local parts=() first=1 f
    for f in "$@"; do
        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            parts+=("$sep")
        fi
        parts+=("#{$f}")
    done

    local fmt_str
    fmt_str="$(printf '%s' "${parts[@]}")"
    tk_tmux display-message -t "$target" -p "$fmt_str" 2>/dev/null || true
}

# tk_q <value> - sh-quote a bash value for safe use in tmux command arguments.
#
# Uses tmux's own #{q:} format modifier to produce a shell-quoted string. The
# value is routed through a temporary per-process option to reach the format
# engine; the option is cleaned up before returning.
#
# The per-process guard ($$) means two calls within the same shell are safe as
# long as they are not concurrent. A sub-shell or signal-handler race would need
# a counter; in practice these calls are always sequential.
tk_q() {
    local val="${1:-}"
    # The empty string quotes to '' even from #{q:}. Return that directly.
    if [[ -z "$val" ]]; then
        # Two single quotes: tmux with a leading quote gets confused without -F.
        printf "''"
        return 0
    fi
    local opt="@tk_q_$$"
    if ! tk_tmux set-option -g "$opt" "$val" 2>/dev/null; then
        # set-option may fail for values tmux cannot store (e.g. newlines in
        # string options on older tmux). Fall back to bash-level quoting.
        tk_q_bash "$val"
        return 0
    fi
    local result
    result="$(tk_tmux display-message -p "#{q:$opt}" 2>/dev/null || true)"
    tk_tmux set-option -gu "$opt" 2>/dev/null
    if [[ -n "$result" ]]; then
        printf '%s' "$result"
    else
        tk_q_bash "$val"
    fi
}

# tk_q_bash <value> - fallback sh-quoting without tmux.
# Single-quotes the value, replacing any embedded single quotes with '"'"'.
# Used when tmux is unavailable or cannot store the value.
tk_q_bash() {
    local val="${1:-}"
    local q="'"
    printf '%s' "$q${val//$q/$q\"$q\"$q}$q"
}

# tk_pane_search <target> <pattern> - search pane content server-side with
# #{C/r:}. Returns true (0) when the pattern is found, false (1) otherwise.
#
# This is a server-side regex over the pane's visible content plus scrollback,
# so it is far cheaper than capture-pane | grep, which forks twice and ships the
# full pane content through a pipe.
tk_pane_search() {
    local target="${1:-}" pattern="${2:-}"
    [[ -n "$target" && -n "$pattern" ]] || return 1
    local result
    result="$(tk_tmux display-message -t "$target" -p "#{C/r:$pattern}" 2>/dev/null || true)"
    [[ "$result" == "1" ]]
}
