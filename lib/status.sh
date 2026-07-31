# shellcheck shell=bash
# status.sh - one status-right engine, N plugin segments.
#
# Replaces three different injection strategies: the tracker's two literal
# subshells plus a four-pattern sed, resumer's substring guard, and mesh
# refusing to touch status-right at all. The V10 state was three independent
# `#()` shellouts in status-right, each showing a *previous* result on tmux's
# own status-interval cadence.
#
# The replacement splits the two jobs:
#   * tk_status_set writes the plugin's segment into @<ns>-status and fires
#     `refresh-client -S`, so the bar updates immediately instead of on the
#     next interval. This alone fixes V14 (resumer had zero refresh-client,
#     so its badge appeared up to 15 seconds late).
#   * tk_status_register puts the literal `#{E:@<ns>-status}` token into
#     status-right exactly once. `#{E:}` matters: it expands the option's
#     value *as a format*, so a segment can carry its own #{...} pieces, and
#     an unset option renders empty rather than the literal token.
#   * tk_status_engine_register owns the single `#(tmux-toolkit tick)` that
#     updates every plugin's option on the server cadence. There is exactly
#     one of these no matter how many plugins register it, and registering a
#     segment never adds a `#()` of its own.
#
# Everything is idempotent: plugin loads run register again, and a reload
# must not accumulate tokens. Tokens are deduped as well as guarded, because
# the legacy ~/.tmux.conf strings this migrates may already hold duplicates.

# tk_status_ensure_token <token> - idempotent append with dedupe.
#
# Shared by register and engine_register. The token is inserted verbatim:
# formats are never expanded at set time, so a `#{E:@...}` or `#(...)` in the
# value is stored literally and evaluated by tmux at render time.
tk_status_ensure_token() {
    local token="${1:?tk_status_ensure_token: token required}" right
    right="$(tk_tmux show-option -gqv status-right 2>/dev/null || true)"
    if [[ "$right" == *"$token"* ]]; then
        # Present at least once. Collapse to exactly one when a legacy string
        # holds several, keeping the first occurrence in place and dropping
        # the rest so nothing else in the string is disturbed. Removing a
        # space-delimited token leaves a double space at each seam; status-right
        # is a space-joined list of segments, so collapsing runs of spaces to
        # one at this point is safe.
        if [[ "${right#*"$token"}" == *"$token"* ]]; then
            local pre="${right%%"$token"*}" rest="${right#*"$token"}"
            pre="${pre% }"
            rest="${rest//"$token"/}"
            rest="${rest# }"
            local rebuilt="${pre:+$pre }${token}${rest:+ $rest}"
            rebuilt="${rebuilt//  / }"
            tk_tmux_silent set-option -g status-right "$rebuilt"
        fi
        return 0
    fi
    tk_tmux_silent set-option -g status-right "${right:+$right }$token"
}

# tk_status_register <ns> - ensure `#{E:@<ns>-status}` in status-right.
#
# Adds the segment token if missing, dedupes if a legacy string holds
# several, and never adds a `#()` of its own: the engine is registered
# separately and exactly once. The option itself is left untouched; it is
# written by tk_status_set.
tk_status_register() {
    local ns="${1:?tk_status_register: namespace required}"
    tk_status_ensure_token "#{E:@${ns}-status}"
}

# tk_status_set <ns> <value> - update the segment and repaint now.
#
# refresh-client -S is the V14 fix: without it the badge waits for tmux's
# own status-interval. Both calls are quiet — a hook or engine tick must
# never fail because the status line was transiently unrefreshable.
tk_status_set() {
    local ns="${1:?tk_status_set: namespace required}" value="${2:-}"
    tk_opt_set_quiet "@${ns}-status" "$value"
    tk_tmux_silent refresh-client -S
}

# tk_status_engine_register [ns] - ensure the single tick engine.
#
# <ns> is accepted for symmetry with the other status functions; the engine
# is server-global, so the first plugin to register it wins and every later
# load is a no-op. The #() runs `tmux-toolkit tick` on tmux's own
# status-interval and updates each plugin's @<ns>-status option.
tk_status_engine_register() {
    tk_status_ensure_token '#(tmux-toolkit tick)'
}

# tk_status_strip <ns> - remove a registered segment.
#
# Removes the `#{E:@<ns>-status}` token and unsets the option. When no
# #{E:@...} segment survives, the engine is removed too, so an uninstall
# that leaves no toolkit segment does not leave a dead #() ticking on every
# interval. Other plugins' #() (e.g. tmux-continuum's) are not ours and are
# never touched.
tk_status_strip() {
    local ns="${1:?tk_status_strip: namespace required}"
    # token is built from ns, so it needs its own local: `local a=1 b=$a`
    # expands every RHS before any assignment, which would empty ${ns} here.
    local token="#{E:@${ns}-status}"
    local right
    tk_opt_unset "@${ns}-status"
    right="$(tk_tmux show-option -gqv status-right 2>/dev/null || true)"
    [[ "$right" == *"$token"* ]] || return 0
    local pre="${right%%"$token"*}" post="${right##*"$token"}"
    pre="${pre% }"
    post="${post# }"
    right="${pre:+$pre }${post}"
    # No #{E:@...} segment left means nothing feeds the engine; drop it and
    # collapse the gap its removal left between two space-joined segments.
    if [[ "$right" != *'#{E:@'* ]]; then
        right="${right//#(tmux-toolkit tick)/}"
        right="${right//  / }"
    fi
    right="${right# }"
    right="${right% }"
    tk_tmux_silent set-option -g status-right "$right"
}
