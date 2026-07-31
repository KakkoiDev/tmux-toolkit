#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for status.sh against the recording tmux stub: the tokens the functions
# emit and the V14 refresh. The real-server composition (token rendering via
# #{E:}, engine dedupe across plugins) is pinned in tests/integration/status.bats.

load '../assert'

setup() {
    tk_setup
    unset TK_UI_LOADED
    # shellcheck source=../../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_init toolkit-test "$TK_DIR"
}
teardown() { tk_teardown; }

# tk_status_register ──────────────────────────────────────────────────

@test "tk_status_register appends the #{E:@ns-status} token" {
    tk_status_register tk
    assert_called "set-option -g status-right #{E:@tk-status}"
}

@test "tk_status_register does not add a #() of its own" {
    # The engine is a separate, single registration; a segment must never
    # shell out on the status cadence.
    tk_status_register tk
    refute_called 'status-right #('
}

@test "tk_status_register keeps an existing status-right intact" {
    tk_fixture 'show-option -gqv status-right' 'left | right'
    tk_status_register tk
    assert_called "set-option -g status-right left | right #{E:@tk-status}"
}

@test "tk_status_register is a no-op when the token is already there" {
    tk_fixture 'show-option -gqv status-right' "#{E:@tk-status}"
    tk_status_register tk
    refute_called 'set-option -g status-right'
}

@test "tk_status_register collapses duplicates from a legacy string" {
    # The strings this migrates could already hold the token twice (the D-14
    # "manual cleanup of the accumulated ~/.tmux.conf string").
    tk_fixture 'show-option -gqv status-right' "a #{E:@tk-status} #{E:@tk-status} b"
    tk_status_register tk
    assert_called "set-option -g status-right a #{E:@tk-status} b"
}

@test "two namespaces register two tokens and stay distinct" {
    tk_status_register a
    # The stub is stateless: it cannot remember the first set-option, so
    # simulate tmux having applied it before the second register runs.
    tk_fixture 'show-option -gqv status-right' '#{E:@a-status}'
    tk_status_register b
    assert_called 'status-right #{E:@a-status}'
    assert_called 'status-right #{E:@a-status} #{E:@b-status}'
}

# tk_status_engine_register ───────────────────────────────────────────

@test "tk_status_engine_register adds the single tick engine" {
    tk_status_engine_register tk
    assert_called 'status-right #(tmux-toolkit tick)'
}

@test "tk_status_engine_register is a no-op when the engine exists" {
    tk_fixture 'show-option -gqv status-right' '#(tmux-toolkit tick)'
    tk_status_engine_register tk
    refute_called 'set-option -g status-right'
}

# tk_status_set ───────────────────────────────────────────────────────

@test "tk_status_set writes the option and fires refresh-client -S" {
    # V14: without refresh-client -S the badge waits for tmux's own
    # status-interval, which is exactly the latency the tracker solved and
    # the resumer never did.
    tk_status_set tk "badge"
    assert_called "set-option -gq @tk-status badge"
    assert_called 'refresh-client -S'
}

# tk_status_strip ─────────────────────────────────────────────────────

@test "tk_status_strip removes the token and unsets the option" {
    tk_fixture 'show-option -gqv status-right' "left #{E:@tk-status} right"
    tk_status_strip tk
    assert_called "set-option -gu @tk-status"
    assert_called 'set-option -g status-right left right'
}

@test "tk_status_strip keeps the engine while another segment survives" {
    tk_fixture 'show-option -gqv status-right' \
        "#{E:@a-status} #{E:@tk-status} #(tmux-toolkit tick)"
    tk_status_strip tk
    assert_called "set-option -g status-right #{E:@a-status} #(tmux-toolkit tick)"
}

@test "tk_status_strip drops the engine when it is the last segment" {
    tk_fixture 'show-option -gqv status-right' "#{E:@tk-status} #(tmux-toolkit tick)"
    tk_status_strip tk
    assert_called 'set-option -g status-right'
    refute_contains "$(tk_calls | tail -1)" '#(tmux-toolkit tick)'
}

@test "tk_status_strip is a no-op when the token is absent" {
    tk_fixture 'show-option -gqv status-right' 'plain'
    tk_status_strip tk
    refute_called 'set-option -g status-right'
}
