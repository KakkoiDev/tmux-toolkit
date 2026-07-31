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
    # modules must not be on that path. sched is on it deliberately (hooks
    # schedule trailing passes through tk_after) and harness rides along so
    # an installer that sources toolkit.sh needs no second file; everything
    # else interactive lives in toolkit-ui.sh.
    local hot="core.sh tmux.sh version.sh opt.sh log.sh json.sh sqlite.sh config.sh sched.sh harness.sh"
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

@test "send-keys appears only in toolkit-pane.sh" {
    # tmux-agent-mesh's whole thesis is that it never types into a pane, pinned
    # by tests/isolation.bats:74, and it vendors this library - so keystroke
    # injection must not be reachable from the hot set or the ui set, both of
    # which the mesh sources. toolkit-pane.sh is the deliberate exception: an
    # opt-in module only toolkit-ui.sh loads, and only a plugin that calls a
    # pane function ever reaches it. Every other module, in particular the hot
    # set that a hook sources ~12x per turn, must stay clean.
    local hits
    hits=$(grep -rn 'send-keys' "$TK_LIB" | grep -v '/toolkit-pane.sh' || true)
    assert_empty "$hits"
    # Non-vacuous: the exception module really does carry the primitives.
    grep -q 'send-keys' "$TK_LIB/toolkit-pane.sh"
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

@test "a dismissed menu is not an error" {
    # display-menu exits 1 when the user dismisses without selecting (Esc,
    # click-away). From a run-shell keybinding tmux then prints "returned 1"
    # in the status bar, which reads as a failure. Contract: tk_menu_show must
    # never propagate that 1. The stub is taught to answer 1 for every
    # display-menu, and tk_menu_show must still return success.
    unset TK_UI_LOADED
    # shellcheck source=../lib/toolkit-ui.sh
    source "$TK_LIB/toolkit-ui.sh"
    tk_fixture 'display-menu *' '' 1
    tk_menu_title T
    tk_menu_item a 1 c
    run tk_menu_show
    assert_ok
    assert_called 'display-menu -T T a 1 c'
}

@test "lib/VERSION is a semver triple" {
    assert_match "$(tk_lib_version)" '[0-9]*.[0-9]*.[0-9]*'
    refute_contains "$(tk_lib_version)" " "
}

# ── the README may not describe code that does not exist ─────────────
#
# An earlier README listed ten modules for toolkit-ui.sh when three existed, and
# another session went looking for the file itself and found nothing. These tests
# make that failure mode impossible rather than a matter of diligence.

@test "every module an entry point sources is present on disk" {
    local entry base missing="" sourced
    for entry in "$TK_LIB/toolkit.sh" "$TK_LIB/toolkit-ui.sh"; do
        assert_file "$entry"
        sourced=$(grep -oE 'source "\$_tk[a-z_]*_src/[a-z-]+\.sh"' "$entry" | sed 's|.*/||; s|"||')
        assert_list_nonempty "$(basename "$entry") sources" $sourced
        for base in $sourced; do
            [[ -f "$TK_LIB/$base" ]] || missing="$missing $(basename "$entry"):$base"
        done
    done
    assert_eq "$missing" ""
}

@test "every lib module the README names in the entry-point table exists" {
    local readme="$TK_ROOT/README.md" table mods m missing=""
    assert_file "$readme"
    # The three entry-point table rows only; the "Not built yet" paragraph
    # below them is allowed, and required, to name files that do not exist.
    table=$(grep -E '^\| `lib/toolkit(-ui|-pane)?\.sh`' "$readme")
    assert_list_nonempty "entry-point table rows" $table
    mods=$(printf '%s' "$table" | grep -oE '`[a-z ]+`' | tr -d '`' | tr ' ' '\n' | sort -u)
    assert_list_nonempty "modules named in the table" $mods
    for m in $mods; do
        case "$m" in
            ''|lib|toolkit|toolkit-ui|the|above|plus) continue ;;
            pane) m=toolkit-pane ;;  # the README calls the module `pane`; the file is toolkit-pane.sh
        esac
        [[ -f "$TK_LIB/$m.sh" ]] || missing="$missing $m"
    done
    assert_eq "$missing" ""
}

@test "every tk_ function the README names is defined" {
    local named defined f missing=""
    named=$(grep -oE '\btk_[a-z_]+' "$TK_ROOT/README.md" | sort -u)
    assert_list_nonempty "tk_ functions named in README" $named
    defined=$(grep -hoE '^tk_[a-z_]+\(\)' "$TK_LIB"/*.sh | tr -d '()' | sort -u)
    # Names the README documents as deliberately absent. tk_opt_fmt has a whole
    # section explaining why it is not offered, and that explanation is more
    # valuable than the symbol would be.
    local negated="tk_opt_fmt tk_watch"
    for f in $named; do
        case " $negated " in *" $f "*) continue ;; esac
        printf '%s\n' "$defined" | grep -qx "$f" || missing="$missing $f"
    done
    assert_eq "$missing" ""
}

@test "every make target the README names exists" {
    local mk="$TK_ROOT/Makefile" t missing=""
    assert_file "$mk"
    # [a-z0-9-]+, or the pattern truncates `make bash32` to `bash` and reports a
    # target that was never named.
    for t in $(grep -oE 'make [a-z0-9-]+' "$TK_ROOT/README.md" | awk '{print $2}' | sort -u); do
        grep -qE "^$t:" "$mk" || missing="$missing $t"
    done
    assert_eq "$missing" ""
}

@test "every tmux-toolkit subcommand the README names is dispatched" {
    local cli="$TK_ROOT/bin/tmux-toolkit" c missing=""
    assert_file "$cli"
    for c in version doctor consumers; do
        grep -qE "^\s+$c[|)]" "$cli" || missing="$missing $c"
    done
    assert_eq "$missing" ""
}
