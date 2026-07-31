#!/usr/bin/env bats
# shellcheck shell=bats
#
# T1 for harness.sh: the jq add-if-absent predicate against real settings
# files. These use real jq (it is the tool the module shells out to) on
# throwaway files; the stub tmux is irrelevant here and nothing calls it.

load '../assert'

setup() {
    tk_setup
    # shellcheck source=../../lib/toolkit.sh
    source "$TK_LIB/toolkit.sh"
    tk_init toolkit-test "$TK_DIR"
}
teardown() { tk_teardown; }

_settings() { printf '%s\n' "$@" > "$TEST_TMPDIR/settings.json"; }

_hooks_install() { tk_hooks_install "$TEST_TMPDIR/settings.json" "$@"; }
_hooks_remove()  { tk_hooks_remove "$TEST_TMPDIR/settings.json" "$@"; }

@test "tk_hooks_install writes a hook entry with its matcher" {
    _settings '{ "env": { "keep": 1 } }'
    _hooks_install "tk-hook" "SessionStart:" "Notification:permission_prompt|elicitation_dialog"
    local doc
    doc="$(jq -c . "$TEST_TMPDIR/settings.json")"
    assert_contains "$doc" '"command":"tk-hook SessionStart"'
    assert_contains "$doc" '"matcher":"permission_prompt|elicitation_dialog"'
    assert_contains "$doc" '"command":"tk-hook Notification"'
    assert_contains "$doc" '"keep":1'
}

@test "tk_hooks_install is add-if-absent across calls" {
    # The predicate the tracker and mesh hand-rolled five times: an existing
    # entry with the same command means a reinstall must not duplicate it.
    _settings '{}'
    _hooks_install "tk-hook" "SessionStart:"
    _hooks_install "tk-hook" "SessionStart:" "Stop:"
    local count
    count="$(jq '.hooks.SessionStart | length' "$TEST_TMPDIR/settings.json")"
    assert_eq "$count" "1"
    count="$(jq '.hooks.Stop | length' "$TEST_TMPDIR/settings.json")"
    assert_eq "$count" "1"
}

@test "tk_hooks_install leaves another plugin's hooks alone" {
    _settings '{ "hooks": { "SessionStart": [ { "matcher": "", "hooks": [ { "type": "command", "command": "other hook SessionStart" } ] } ] } }'
    _hooks_install "tk-hook" "SessionStart:"
    local count
    count="$(jq '.hooks.SessionStart | length' "$TEST_TMPDIR/settings.json")"
    assert_eq "$count" "2"
    assert_contains "$(jq -c '.hooks.SessionStart[0].hooks[0].command' "$TEST_TMPDIR/settings.json")" '"other hook SessionStart"'
}

@test "tk_hooks_install creates a missing file" {
    rm -f "$TEST_TMPDIR/settings.json"
    _hooks_install "tk-hook" "Stop:"
    assert_file "$TEST_TMPDIR/settings.json"
    assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].command' "$TEST_TMPDIR/settings.json")" "tk-hook Stop"
}

@test "tk_hooks_install writes through a symlink, preserving it" {
    # V6: `mv` over a dotfiles-managed settings file replaces the link with a
    # regular file and the real file silently keeps its old contents.
    printf '{ "hooks": {} }\n' > "$TEST_TMPDIR/real.json"
    ln -s real.json "$TEST_TMPDIR/settings.json"
    _hooks_install "tk-hook" "Start:"
    assert_symlink "$TEST_TMPDIR/settings.json"
    assert_contains "$(cat "$TEST_TMPDIR/real.json")" 'tk-hook Start'
}

@test "tk_hooks_install with no events touches nothing" {
    _settings '{"x":1}'
    _hooks_install "tk-hook"
    assert_eq "$(cat "$TEST_TMPDIR/settings.json")" '{"x":1}'
}

@test "tk_hooks_remove drops entries matching the prefix" {
    _settings '{ "hooks": { "A": [ { "matcher": "", "hooks": [ { "type": "command", "command": "tk-hook A" } ] } ], "B": [ { "matcher": "", "hooks": [ { "type": "command", "command": "other B" } ] } ] } }'
    _hooks_remove "tk-hook"
    refute_contains "$(jq -c . "$TEST_TMPDIR/settings.json")" 'tk-hook'
    assert_eq "$(jq -r '.hooks.B[0].hooks[0].command' "$TEST_TMPDIR/settings.json")" "other B"
}

@test "tk_hooks_remove prunes empty arrays and finally the hooks key" {
    _settings '{ "hooks": { "A": [ { "matcher": "", "hooks": [ { "type": "command", "command": "tk-hook A" } ] } ] } }'
    _hooks_remove "tk-hook"
    local doc
    doc="$(jq -c . "$TEST_TMPDIR/settings.json")"
    assert_eq "$doc" '{}'
}

@test "tk_hooks_remove is a no-op when nothing matches" {
    _settings '{ "hooks": { "A": [ { "matcher": "", "hooks": [ { "type": "command", "command": "other A" } ] } ] } }'
    _hooks_remove "tk-hook"
    assert_eq "$(jq -r '.hooks.A[0].hooks[0].command' "$TEST_TMPDIR/settings.json")" "other A"
}

@test "tk_hooks_remove on a missing file returns 0" {
    rm -f "$TEST_TMPDIR/settings.json"
    _hooks_remove "tk-hook"
}

@test "tk_hooks_remove writes through a symlink, preserving it" {
    printf '{ "hooks": { "A": [ { "matcher": "", "hooks": [ { "type": "command", "command": "tk-hook A" } ] } ] } }\n' > "$TEST_TMPDIR/real.json"
    ln -s real.json "$TEST_TMPDIR/settings.json"
    _hooks_remove "tk-hook"
    assert_symlink "$TEST_TMPDIR/settings.json"
    refute_contains "$(cat "$TEST_TMPDIR/real.json")" 'tk-hook'
}

@test "an upgrade pre-clean removes only the old command prefix" {
    # The tracker rename removed entries whose command contained the old
    # name, leaving freshly written new-name entries untouched.
    _settings '{ "hooks": { "A": [ { "matcher": "", "hooks": [ { "type": "command", "command": "tk-claude-agent-tracker hook A" } ] } ], "B": [ { "matcher": "", "hooks": [ { "type": "command", "command": "tk-agent-tracker hook B" } ] } ] } }'
    _hooks_remove "tk-claude-agent-tracker hook"
    local doc
    doc="$(jq -c . "$TEST_TMPDIR/settings.json")"
    refute_contains "$doc" 'tk-claude-agent-tracker'
    assert_contains "$doc" 'tk-agent-tracker hook B'
}
