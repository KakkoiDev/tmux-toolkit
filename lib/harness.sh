# shellcheck shell=bash
# harness.sh - install and remove Claude/Gemini/Pi harness hooks in a JSON
# settings file.
#
# Replaces the jq add-if-absent predicate duplicated five times inside
# tmux-agent-tracker's install.sh alone (Claude, Gemini, Pi, Antigravity and
# the pre-clean) plus once in tmux-agent-mesh's installer. The tracker's
# settings.json is a *symlink* into claude-profiles; writing with `mv` (its
# lines 253/369/501/568) replaces the link with a regular file, and the real
# file silently keeps its old contents (finding V6). Every write here goes
# through `cat "$tmp" > "$target"`, which writes through the link.
#
# The settings file shapes differ per harness but share the Claude shape:
#
#   { "hooks": { "SessionStart": [
#       { "matcher": "", "hooks": [ { "type": "command",
#                                     "command": "tmux-agent-tracker hook SessionStart" } ] }
#   ] } }
#
# Sourced from lib/toolkit.sh so an installer that already loads the hot set
# gets it for free; nothing on a hook path ever calls it.

# tk_hooks_install <file> <cmd_prefix> <event:matcher>...
#
# For each <event:matcher> pair, ensure the file has one hook entry under
# <event> whose command is "<cmd_prefix> <event>" (the tracker's command
# shape is exactly "tmux-agent-tracker hook <event>"), carrying the given
# matcher verbatim (empty for most events, "permission_prompt|..." for
# Notification). Add-if-absent: an existing entry with the same command is
# left alone, so a reinstall never accumulates duplicates, and entries other
# plugins installed survive. A missing file is created with a bare
# `{"hooks": {}}`; the $schema and harness-specific keys stay plugin-owned.
#
# Returns 1 without touching the file when jq is missing (the installer is
# expected to print its own manual-hooks fallback then).
tk_hooks_install() {
    local file="${1:?tk_hooks_install: settings file required}"
    local prefix="${2:?tk_hooks_install: command prefix required}"
    shift 2
    [[ "$#" -gt 0 ]] || return 0
    tk_have jq || {
        tk_log warn "tk_hooks_install: jq missing; hooks for '$prefix' left unconfigured"
        return 1
    }

    local tmp pair event matcher cmd changed=0
    tmp="$(mktemp)" || return 1
    if [[ -f "$file" ]]; then
        cp "$file" "$tmp"
    else
        printf '%s\n' '{' '  "hooks": {}' '}' > "$tmp"
    fi

    for pair in "$@"; do
        event="${pair%%:*}"
        matcher="${pair#*:}"
        [[ -n "$event" ]] || continue
        cmd="$prefix $event"
        # Add-if-absent: the exact command already present under this event
        # means a previous install (or this one) got there first.
        if jq -e --arg e "$event" --arg c "$cmd" \
            '((.hooks // {})[$e] // []) | map(.hooks[]? | select(.command == $c)) | length > 0' \
            "$tmp" >/dev/null 2>&1; then
            continue
        fi
        if ! jq --arg e "$event" --arg c "$cmd" --arg m "$matcher" \
            '.hooks //= {} |
             .hooks[$e] = ((.hooks[$e] // []) + [{matcher: $m, hooks: [{type: "command", command: $c}]}])' \
            "$tmp" > "${tmp}.2"; then
            rm -f "$tmp" "${tmp}.2"
            return 1
        fi
        mv "${tmp}.2" "$tmp"
        changed=1
    done

    if [[ "$changed" -eq 1 ]]; then
        # Write through any symlink. `mv` over a dotfiles-managed settings
        # file would replace the link and detach the real file (V6).
        cat "$tmp" > "$file"
    fi
    rm -f "$tmp"
    return 0
}

# tk_hooks_remove <file> <cmd_prefix> - remove every entry matching the prefix.
#
# Drops each hook entry whose command starts with <cmd_prefix>, then prunes
# empty matcher arrays and empty event keys, and finally the hooks key
# itself when nothing is left. An upgrade-time pre-clean calls this with the
# old command name so the renamed tracker's entries are not touched. Writes
# through symlinks like install; a file with no matching entries is not
# rewritten at all.
tk_hooks_remove() {
    local file="${1:?tk_hooks_remove: settings file required}"
    local prefix="${2:?tk_hooks_remove: command prefix required}"
    [[ -f "$file" ]] || return 0
    tk_have jq || return 1

    local tmp
    tmp="$(mktemp)" || return 1
    if ! jq --arg p "$prefix" '
        if has("hooks") and (.hooks | type) == "object" and (.hooks | length) > 0 then
            .hooks |= with_entries(
                .value |= map(
                    .hooks |= map(select(.command | startswith($p) | not))
                    | select(.hooks | length > 0)
                )
                | select(.value | length > 0)
            )
            | if (.hooks | length) == 0 then del(.hooks) else . end
        else . end
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 0
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"
    return 0
}
