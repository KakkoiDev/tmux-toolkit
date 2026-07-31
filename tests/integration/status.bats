#!/usr/bin/env bats
# shellcheck shell=bats
#
# T2 for status.sh against a real tmux on a private socket: the D-14
# composition — one #(), N #{E:@...} tokens, no duplicates across reloads or
# load orders, and real #{E:} rendering. refresh-client -S is headless-fatal
# ("no current client") so the V14 write side is pinned in the T1 stub log
# instead; here the option write and the tokens are the assertions.

load '../assert'

setup() {
    tk_skip_no_tmux
    tk_setup_real
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
}
teardown() { tk_teardown_real; }

_status_right() { tk_tmux show-option -gqv status-right 2>/dev/null || true; }
_count()        { printf '%s' "$1" | grep -oF -- "$2" | wc -l | tr -d ' '; }

@test "tk_status_register adds exactly one token and a reload adds none" {
    tk_status_register tk
    tk_status_register tk
    assert_eq "$(_count "$(_status_right)" '#{E:@tk-status}')" "1"
}

@test "tk_status_engine_register adds exactly one engine across reloads" {
    tk_status_engine_register tk
    tk_status_engine_register tk
    assert_eq "$(_count "$(_status_right)" '#(tmux-toolkit tick)')" "1"
}

@test "registering a segment never adds a #() shellout" {
    tk_status_register tk
    refute_contains "$(_status_right)" '#('
}

@test "three plugins in every load order compose to one #() and three tokens" {
    # The D-14 cross-plugin gate: all 6 orders of loading three plugins must
    # produce the same status-right shape, and a second pass over the whole
    # sequence (reload) must not duplicate anything.
    local orders=(
        "a b c" "a c b" "b a c" "b c a" "c a b" "c b a"
    )
    local order ns
    for order in "${orders[@]}"; do
        tk_tmux set-option -g status-right ""
        for ns in $order; do
            tk_status_engine_register "$ns"
            tk_status_register "$ns"
        done
        assert_eq "$(_count "$(_status_right)" '#(tmux-toolkit tick)')" "1"
        assert_eq "$(_count "$(_status_right)" '#{E:@')" "3"
        # Reload: the same plugin set loads again with no accumulation.
        for ns in $order; do
            tk_status_engine_register "$ns"
            tk_status_register "$ns"
        done
        assert_eq "$(_count "$(_status_right)" '#(tmux-toolkit tick)')" "1"
        assert_eq "$(_count "$(_status_right)" '#{E:@')" "3"
    done
}

@test "tk_status_set writes the option and #{E:} renders it" {
    tk_status_register tk
    tk_status_set tk "badge-42"
    assert_eq "$(tk_tmux show-option -gqv @tk-status)" "badge-42"
    assert_eq "$(tk_tmux display-message -p '#{E:@tk-status}')" "badge-42"
}

@test "a segment value may itself carry formats" {
    # #{E:} expands the option's value as a format; a plain #{@...} would
    # render the nested pieces literally. This is why E: is the token.
    tk_status_set tk "win:#{window_index}"
    assert_eq "$(tk_tmux display-message -p '#{E:@tk-status}')" \
        "$(tk_tmux display-message -p 'win:#{window_index}')"
}

@test "tk_status_strip removes a segment and the engine when it is the last" {
    tk_status_register tk
    tk_status_engine_register tk
    tk_status_strip tk
    refute_contains "$(_status_right)" '#{E:@tk-status}'
    refute_contains "$(_status_right)" '#(tmux-toolkit tick)'
    assert_empty "$(tk_tmux show-option -gqv @tk-status 2>/dev/null || true)"
}

@test "tk_status_strip keeps the engine while another segment survives" {
    tk_status_register a
    tk_status_register tk
    tk_status_engine_register tk
    tk_status_strip tk
    refute_contains "$(_status_right)" '#{E:@tk-status}'
    assert_contains "$(_status_right)" '#{E:@a-status}'
    assert_contains "$(_status_right)" '#(tmux-toolkit tick)'
}

@test "a foreign #() (continuum's) survives strip" {
    tk_tmux set-option -g status-right "#(continuum save) #{E:@tk-status}"
    tk_status_strip tk
    assert_contains "$(_status_right)" '#(continuum save)'
    refute_contains "$(_status_right)" '#{E:@tk-status}'
}
