#!/usr/bin/env bats
# shellcheck shell=bats
#
# T4: contract tests generated from the source.
#
# This tier is the one tmux-agent-mesh invented and then broke. Its
# tests/isolation.bats:80 greps for '^[A-Z_]+=\$\(get_tmux_option' against a
# file where every such line is indented four spaces, so the pattern matches
# zero lines, the loop body never runs, and the test passes vacuously. Three
# dead options hid behind it inside a 318-test suite.
#
# Hence the rule enforced here: every generated list goes through
# assert_list_nonempty before it is looped over.

load '../assert'

setup()    { tk_setup; }
teardown() { tk_teardown; }

@test "the extraction patterns used by this file actually match something" {
    # Meta-test: the guard is only a guard if it is itself exercised against a
    # known-positive and a known-negative line.
    local fixture="$TEST_TMPDIR/fix.sh"
    printf 'tk_positive() {\n' > "$fixture"
    printf '    not_a_function=1\n' >> "$fixture"
    local found
    found=$(grep -oE '^tk_[a-z_]+\(\)' "$fixture" | tr -d '()')
    assert_eq "$found" "tk_positive"
    assert_empty "$(grep -oE '^tk_zzz[a-z_]*\(\)' "$fixture" || true)"
}

@test "every lib module is sourced by an entry point" {
    local mods entry f base missing=""
    mods=$(find "$TK_LIB" -name '*.sh' ! -name 'toolkit.sh' ! -name 'toolkit-ui.sh' -exec basename {} \; | sort)
    # shellcheck disable=SC2086
    assert_list_nonempty "lib modules" $mods

    entry=""
    for f in "$TK_LIB"/toolkit.sh "$TK_LIB"/toolkit-ui.sh; do
        [[ -r "$f" ]] && entry="$entry$(cat "$f")"
    done

    for base in $mods; do
        case "$entry" in
            *"$base"*) ;;
            *) missing="$missing $base" ;;
        esac
    done
    assert_eq "$missing" ""
}

@test "toolkit.sh sources only the hot set" {
    # A Claude hook fires ~12x per turn. The interactive and install-time
    # modules must not be on that path.
    local hot="core.sh tmux.sh version.sh opt.sh log.sh json.sh sqlite.sh config.sh"
    local sourced base
    sourced=$(grep -oE 'source "\$_tk_src/[a-z]+\.sh"' "$TK_LIB/toolkit.sh" | sed 's|.*/||; s|"||')
    # shellcheck disable=SC2086
    assert_list_nonempty "toolkit.sh sources" $sourced

    for base in $sourced; do
        case " $hot " in
            *" $base "*) ;;
            *) _afail "toolkit.sh sources '$base', which is not in the hot set" ;;
        esac
    done
}

@test "no lib module sources another by absolute path" {
    # Vendored copies live at an unpredictable prefix, and a hook has no plugin
    # env to resolve one from.
    local hits
    hits=$(grep -nE 'source[[:space:]]+/' "$TK_LIB"/*.sh || true)
    assert_empty "$hits"
}

@test "send-keys appears nowhere in lib/" {
    # tmux-agent-mesh's whole thesis is that it never types into a pane, pinned
    # by tests/isolation.bats:74. It will vendor this library, so the guarantee
    # has to hold here or that test becomes a lie after D-2. Keystroke injection
    # lives in tmux-agent-resumer/scripts/keys.sh and nowhere else.
    local hits
    hits=$(grep -rn 'send-keys' "$TK_LIB" || true)
    assert_empty "$hits"
}

@test "no lib module emits DROP TABLE in code" {
    # The tracker's DROP-on-every-load is the bug D-9 removes; a shared helper
    # must not make it reachable. Comment lines are stripped first: sqlite.sh
    # documents the refusal at length, and a test that cannot tell prose from
    # code would force that explanation out of the file.
    local hits
    hits=$(grep -rnE 'drop[[:space:]]+table' "$TK_LIB" \
            | grep -viE '^[^:]+:[0-9]+:[[:space:]]*#' \
            | grep -viE 'refusing DDL' || true)
    assert_empty "$hits"
}

@test "every exported function is tk_-prefixed" {
    # The prefix is what lets a plugin source this library alongside its own
    # helpers.sh during migration without either shadowing the other.
    local defs bad=""
    defs=$(grep -hoE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$TK_LIB"/*.sh | tr -d '()' | sort -u)
    # shellcheck disable=SC2086
    assert_list_nonempty "function definitions" $defs

    local f
    for f in $defs; do
        case "$f" in tk_*) ;; *) bad="$bad $f" ;; esac
    done
    assert_eq "$bad" ""
}

@test "every global the library sets is TK_-prefixed" {
    local vars bad="" v
    vars=$(grep -hoE '^[A-Z][A-Z0-9_]*=' "$TK_LIB"/*.sh | tr -d '=' | sort -u)
    # shellcheck disable=SC2086
    assert_list_nonempty "global assignments" $vars
    for v in $vars; do
        case "$v" in TK_*) ;; *) bad="$bad $v" ;; esac
    done
    assert_eq "$bad" ""
}

@test "every lib module carries a shellcheck shell directive" {
    # They are sourced fragments with no shebang, so shellcheck cannot infer the
    # dialect and silently checks them as sh.
    local f missing=""
    for f in "$TK_LIB"/*.sh; do
        head -3 "$f" | grep -q 'shellcheck shell=bash' || missing="$missing $(basename "$f")"
    done
    assert_eq "$missing" ""
}

@test "the library is bash 3.2 clean of constructs it cannot use" {
    # macOS ships bash 3.2 and it is a supported tier: no associative arrays,
    # no namerefs, no mapfile/readarray, no ${var^^}.
    local hits
    hits=$(grep -nE 'declare -A|local -n|mapfile|readarray|\$\{[A-Za-z_]+\^\^' "$TK_LIB"/*.sh || true)
    assert_empty "$hits"
}

@test "lib/VERSION is a semver triple" {
    assert_match "$(tk_lib_version)" '[0-9]*.[0-9]*.[0-9]*'
    refute_contains "$(tk_lib_version)" " "
}
