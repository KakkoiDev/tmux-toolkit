# shellcheck shell=bash
# identity.sh - registry-based agent identity for tmux-toolkit.
#
# One TSV line per agent from tk_identity_list, using \x1f (unit separator) as
# the field delimiter. Tab is IFS whitespace and collapses runs/drops leading
# ones for optional fields (correction C3 in docs/plan.md).
#
# Columns:
#   agent_id | harness | session_id | pid | tty | pane_id | target |
#   cwd | project | branch | name | liveness | activity |
#   waiting_for | kind | host | source | observed_at | enrich
#
# Providers, strict precedence for liveness and activity:
#   1. tk_identity_provider_claude - authoritative for Claude
#   2. tk_identity_provider_ps - non-Claude harnesses + unseen Claude
#   3. Hooks - enrichment only; may sharpen activity, never create/delete rows

# \x1f (unit separator). TAB is IFS *whitespace*, so IFS=$'\t' read -r collapses
# runs and drops leading ones. \x1f is not whitespace; empty fields survive.
TK_US=$(printf '\037')

# ── paths ────────────────────────────────────────────────────────────

tk_identity_cache_file() { printf '%s/identity.tsv' "${TK_STATE:-${HOME}/.local/state/tmux-toolkit}"; }
tk_identity_meta_file()  { printf '%s/identity.tsv.meta' "${TK_STATE:-${HOME}/.local/state/tmux-toolkit}"; }
tk_identity_dirty_file() { printf '%s/identity.dirty' "${TK_STATE:-${HOME}/.local/state/tmux-toolkit}"; }
tk_identity_enrich_dir() { printf '%s/enrich' "${TK_STATE:-${HOME}/.local/state/tmux-toolkit}"; }

# ── ttl ──────────────────────────────────────────────────────────────

tk_identity_ttl() {
    tk_opt '@toolkit-identity-ttl' '2'
}

# ── staleness ────────────────────────────────────────────────────────

# tk_identity_stale - three independent signals:
#   1. mtime older than TTL
#   2. .meta server pid differs from current tmux pid (hard invalidate)
#   3. identity.dirty file exists (pane-exited touch)
tk_identity_stale() {
    local cache meta ttl server_pid meta_pid

    cache="$(tk_identity_cache_file)"
    [[ -r "$cache" ]] || return 0   # no cache → stale

    meta="$(tk_identity_meta_file)"
    ttl="$(tk_identity_ttl)"

    # Signal 1: mtime
    tk_fresh "$cache" "$ttl" || return 0

    # Signal 2: server pid changed (pane ids renumber across a restart)
    server_pid="$(tk_server_pid)"
    if [[ -r "$meta" ]]; then
        meta_pid="$(cut -f2 "$meta" 2>/dev/null || true)"
        [[ -n "$meta_pid" && "$meta_pid" != "$server_pid" ]] && return 0
    fi

    # Signal 3: dirty flag
    [[ -f "$(tk_identity_dirty_file)" ]] && return 0

    return 1  # fresh
}

# ── enrichment ───────────────────────────────────────────────────────

# tk_identity_enrich <agent_id> <k=v>... - append enrichment from a hook.
# One printf >> per agent: no sqlite, no lock, no tmux call.
tk_identity_enrich() {
    local agent_id="$1"; shift
    local dir
    dir="$(tk_identity_enrich_dir)"
    mkdir -p "$dir" 2>/dev/null || true
    printf '%s\037%s\n' "$(tk_now)" "$*" >> "$dir/$agent_id"
}

# tk_identity_read_enrich <agent_id> - latest enrichment for one agent.
tk_identity_read_enrich() {
    local f="$1" line
    [[ -r "$f" ]] || return 0
    # tail -1 and strip the epoch prefix
    line="$(tail -1 "$f" 2>/dev/null)"
    [[ -n "$line" ]] || return 0
    printf '%s' "$line" | cut -d"$TK_US" -f2-
}

# ── helpers ──────────────────────────────────────────────────────────

# tk_identity_escape_grep <str> - escape regex metacharacters for grep.
tk_identity_escape_grep() {
    printf '%s' "$1" | sed 's/[.[\*^$+?{|]/\\&/g'
}

# tk_identity_lookup_file <keyfile> <key> [field] - grep a TSV file by first field.
# keyfile is \x1f-separated with key in column 1. field 0 returns the whole line.
tk_identity_lookup_file() {
    local file="$1" key="$2" field="${3:-2}" escaped line
    [[ -s "$file" ]] || return 1
    escaped="$(tk_identity_escape_grep "$key")"
    line="$(grep "^${escaped}$(printf '\037')" "$file" 2>/dev/null | head -1)"
    [[ -n "$line" ]] || return 1
    if [[ "$field" == "0" ]]; then
        printf '%s' "$line"
    else
        printf '%s' "$line" | cut -d"$TK_US" -f"$field"
    fi
}

# ── provider: claude ─────────────────────────────────────────────────

# tk_identity_provider_claude - calls `claude agents --json`.
# Authoritative for Claude liveness + activity.
# status: busy→busy, idle→idle, blocked→blocked (with waitingFor).
#
# Output: \x1f-separated per agent:
#   pid | sessionId | cwd | name | kind | status | waitingFor
tk_identity_provider_claude() {
    command -v claude >/dev/null 2>&1 || return 0
    tk_jq || { tk_log warn "tk_identity_provider_claude: jq missing, cannot parse claude output"; return 0; }

    local json
    json="$(claude agents --json 2>/dev/null || true)"
    [[ -n "$json" ]] || return 0

    printf '%s' "$json" | jq -r '.[] | [
        (.pid // "" | tostring),
        (.sessionId // ""),
        (.cwd // ""),
        (.name // ""),
        (.kind // ""),
        (.status // ""),
        (.waitingFor // "")
    ] | join("\u001f")' 2>/dev/null || true
}

# ── provider: ps ─────────────────────────────────────────────────────

# tk_identity_provider_ps - detect agents via process tree in tmux panes.
# Non-Claude harnesses plus unseen Claude instances.
# Liveness only, activity=unknown.
#
# One ps call total; bash-based ancestor walk per pane.
#
# Output: \x1f-separated per agent:
#   pid | harness | pane_id | target | tty
tk_identity_provider_ps() {
    tk_tmux_ok || return 0

    local tmpdir procs pane_pids
    tmpdir="$(mktemp -d)"

    # Full process table: pid \037 ppid \037 comm
    procs="$tmpdir/procs"
    ps -eo pid,ppid,comm 2>/dev/null | while read -r pid ppid comm; do
        [[ "$pid" == "PID" ]] && continue
        [[ -z "$pid" ]] && continue
        printf '%s\037%s\037%s\n' "$pid" "$ppid" "$comm"
    done > "$procs"
    [[ -s "$procs" ]] || { rm -rf "$tmpdir"; return 0; }

    # All pane pids: pane_pid \037 pane_id \037 target \037 tty
    pane_pids="$tmpdir/pane_pids"
    tk_tmux list-panes -a -F '#{pane_pid} #{pane_id} #{session_name}:#{window_index}.#{pane_index} #{pane_tty}' 2>/dev/null | while read -r ppid pane_id target ptty; do
        [[ -n "$ppid" && "$ppid" != "0" ]] || continue
        printf '%s\037%s\037%s\037%s\n' "$ppid" "$pane_id" "$target" "${ptty#/dev/}"
    done > "$pane_pids"
    [[ -s "$pane_pids" ]] || { rm -rf "$tmpdir"; return 0; }

    # Harness names the ps provider knows about (non-Claude, or unseen Claude).
    # Claude is listed here too because the registry might miss sandbox/container
    # instances; tk_identity_provider_claude rows get deduplicated later by pid.
    local harnesses h
    harnesses="codex grok pi antigravity deer deerbox"

    while IFS="$TK_US" read -r pane_pid pane_id target ptty; do
        for h in $harnesses; do
            # Walk from pane_pid upward. If any ancestor's comm matches h → found.
            if tk_identity_match_harness "$h" "$pane_pid" "$procs"; then
                # This pane has a harness agent. Emit a row.
                # pid | harness | pane_id | target | tty
                printf '%s\037%s\037%s\037%s\037%s\n' \
                    "$pane_pid" "$h" "$pane_id" "$target" "$ptty"
                break
            fi
        done
    done < "$pane_pids"

    rm -rf "$tmpdir"
}

# tk_identity_match_harness <harness> <start_pid> <procs_file>
# Walk upward from start_pid (child→parent) via procs_file.
# Return 0 if any ancestor's comm starts with the harness name.
tk_identity_match_harness() {
    local harness="$1" pid="$2" procs="$3" current ppid comm
    current="$pid"
    while [[ "$current" -gt 1 ]]; do
        # Get parent and comm from procs table.
        # procs lines: pid\037ppid\037comm
        local line
        line="$(tk_identity_lookup_file "$procs" "$current" 0)"
        if [[ -z "$line" ]]; then
            # pid not in table; fall back to direct ps (should be rare)
            ppid="$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ')"
            comm="$(ps -o comm= -p "$current" 2>/dev/null)"
            [[ -z "$comm" ]] && break
        else
            ppid="$(printf '%s' "$line" | cut -d"$TK_US" -f2)"
            comm="$(printf '%s' "$line" | cut -d"$TK_US" -f3)"
        fi

        # Match: comm starts with harness name
        case "$comm" in
            "$harness"|"$harness"*) return 0 ;;
        esac

        [[ -z "$ppid" || "$ppid" == "$current" ]] && break
        current="$ppid"
    done
    return 1
}

# ── rebuild ──────────────────────────────────────────────────────────

# tk_identity_rebuild - the three-process join plus PS-provider rows.
#
# A = claude agents --json → pid, sessionId, cwd, status, name, kind
# B = ps -eo pid,tty       → pid-to-tty map
# C = tmux list-panes -a   → tty-to-pane + pane_pid map
#
# Join A→B on pid, B→C on tty. Apply 4 join-failure cases.
# Then add PS-provider rows for non-Claude agents.
tk_identity_rebuild() {
    local now tmpdir
    now="$(tk_now)"

    tmpdir="$(mktemp -d)"

    # B: pid → tty  (ps -eo pid,tty)
    local btty="$tmpdir/pid_tty"
    ps -eo pid,tty 2>/dev/null | while read -r pid tty; do
        [[ "$pid" == "PID" ]] && continue
        [[ -z "$pid" ]] && continue
        printf '%s\037%s\n' "$pid" "${tty#/dev/}" >> "$btty"
    done

    # C: tty → pane_id target
    # C_ppid: pane_pid → pane_id target (for ancestor walk, case 2)
    local cpane="$tmpdir/tty_pane"
    local cppid="$tmpdir/pane_pid"
    if tk_tmux_ok; then
        tk_tmux list-panes -a -F '#{pane_tty} #{pane_id} #{session_name}:#{window_index}.#{pane_index} #{pane_pid}' 2>/dev/null | while read -r tty pane_id target pane_pid; do
            [[ -z "$tty" || -z "$pane_id" ]] && continue
            local ts="${tty#/dev/}"
            printf '%s\037%s\037%s\n' "$ts" "$pane_id" "$target" >> "$cpane"
            printf '%s\037%s %s\n' "$pane_pid" "$pane_id" "$target" >> "$cppid"
        done
    fi

    # Track emitted pids so PS provider rows don't duplicate claude rows.
    local emitted="$tmpdir/emitted"

    # ── Claude provider rows ──────────────────────────────────────

    local pid sid cwd name kind status waitf
    local tty pane_id target activity agent_id project branch enrich

    tk_identity_provider_claude | while IFS="$TK_US" read -r pid sid cwd name kind status waitf; do
        [[ -z "$pid" || -z "$sid" ]] && continue

        # Case 4: pid not alive (ps is the tiebreak) → drop
        kill -0 "$pid" 2>/dev/null || continue

        # Map Claude status
        case "$status" in
            busy)    activity="busy" ;;
            idle)    activity="idle" ;;
            blocked) activity="blocked" ;;
            *)       activity="unknown" ;;
        esac

        # Look up tty from B
        tty="$(tk_identity_lookup_file "$btty" "$pid")"

        # Cases 1 & 3: background, no tty, or tty is ??
        if [[ "$kind" == "background" || -z "$tty" || "$tty" == "??" ]]; then
            pane_id=""
            target=""
        else
            # Look up pane from C via tty
            local pi rest
            pi="$(tk_identity_lookup_file "$cpane" "$tty")"
            if [[ -n "$pi" ]]; then
                pane_id="${pi%%$(printf '\037')*}"
                target="${pi#*$(printf '\037')}"
            else
                # Case 2: tty resolves, no pane owns it → ancestor walk
                local anc_rest
                anc_rest="$(tk_identity_lookup_file "$cppid" "$pid")"
                if [[ -z "$anc_rest" ]]; then
                    # Walk up the ancestor chain
                    anc_rest="$(tk_identity_ancestor_walk "$pid" "$cppid" "$btty")"
                fi
                if [[ -n "$anc_rest" ]]; then
                    pane_id="${anc_rest%% *}"
                    target="${anc_rest#* }"
                else
                    pane_id=""
                    target=""
                    enrich="${enrich}outside_tmux=1;"
                fi
            fi
        fi

        # project and branch from cwd
        project=""
        branch=""
        if [[ -n "$cwd" && -d "$cwd" ]]; then
            local git_top
            git_top="$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
            if [[ -n "$git_top" ]]; then
                project="$(basename "$git_top")"
                branch="$(cd "$cwd" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
            fi
        fi

        agent_id="claude:$sid"

        # Hook enrichment
        local hook_e
        hook_e="$(tk_identity_read_enrich "$agent_id")"
        [[ -n "$hook_e" ]] && enrich="${enrich}${hook_e}"

        # Mark this pid as emitted
        printf '%s\n' "$pid" >> "$emitted"

        # Output TSV row (19 fields)
        printf '%s' "$agent_id"
        printf '\037%s' "claude"
        printf '\037%s' "$sid"
        printf '\037%s' "$pid"
        printf '\037%s' "$tty"
        printf '\037%s' "$pane_id"
        printf '\037%s' "$target"
        printf '\037%s' "$cwd"
        printf '\037%s' "$project"
        printf '\037%s' "$branch"
        printf '\037%s' "$name"
        printf '\037%s' "live"
        printf '\037%s' "$activity"
        printf '\037%s' "$waitf"
        printf '\037%s' "$kind"
        printf '\037%s' ""          # host (reserved)
        printf '\037%s' "registry"  # source
        printf '\037%s' "$now"      # observed_at
        printf '\037%s' "${enrich%;}"
        printf '\n'
    done > "$tmpdir/claude_rows"

    # ── PS provider rows (non-Claude agents) ─────────────────────

    # Use the same procs table for efficiency
    local procs="$tmpdir/procs"
    ps -eo pid,ppid,comm 2>/dev/null | while read -r p pid ppid comm; do
        [[ "$p" == "PID" ]] && continue
        [[ -z "$p" ]] && continue
        printf '%s\037%s\037%s\n' "$p" "$ppid" "$comm"
    done > "$procs"

    if tk_tmux_ok; then
        local harnesses="codex grok pi antigravity deer deerbox"
        tk_tmux list-panes -a -F '#{pane_pid} #{pane_id} #{session_name}:#{window_index}.#{pane_index} #{pane_tty}' 2>/dev/null | while read -r ppid pane_id target ptty; do
            [[ -n "$ppid" && "$ppid" != "0" ]] || continue

            # Skip if this pid was already emitted by claude provider
            grep -qx "$ppid" "$emitted" 2>/dev/null && continue

            local h
            for h in $harnesses; do
                if tk_identity_match_harness "$h" "$ppid" "$procs"; then
                    local ts="${ptty#/dev/}"
                    printf '%s' "$h:$ppid"
                    printf '\037%s' "$h"
                    printf '\037%s' ""             # session_id
                    printf '\037%s' "$ppid"
                    printf '\037%s' "$ts"
                    printf '\037%s' "$pane_id"
                    printf '\037%s' "$target"
                    printf '\037%s' ""             # cwd
                    printf '\037%s' ""             # project
                    printf '\037%s' ""             # branch
                    printf '\037%s' "$h"           # name
                    printf '\037%s' "live"
                    printf '\037%s' "unknown"      # activity
                    printf '\037%s' ""             # waiting_for
                    printf '\037%s' "interactive"  # kind
                    printf '\037%s' ""             # host
                    printf '\037%s' "scan"         # source
                    printf '\037%s' "$now"
                    printf '\037%s' ""
                    printf '\n'
                    printf '%s\n' "$ppid" >> "$emitted"
                    break
                fi
            done
            # Don't emit "unknown" panes — PS provider only knows harnesses it
            # can match. A pane with no recognizable harness is not an agent.
        done >> "$tmpdir/ps_rows"
    fi

    # ── Write cache ──────────────────────────────────────────────
    local cache meta server_pid
    cache="$(tk_identity_cache_file)"
    meta="$(tk_identity_meta_file)"
    server_pid="$(tk_server_pid)"

    mkdir -p "$(dirname "$cache")" 2>/dev/null || true

    cat "$tmpdir/claude_rows" "$tmpdir/ps_rows" 2>/dev/null > "$cache.tmp"

    printf '%s\t%s\n' "$now" "$server_pid" > "$meta"
    mv "$cache.tmp" "$cache" 2>/dev/null || true
    rm -f "$(tk_identity_dirty_file)" 2>/dev/null || true

    rm -rf "$tmpdir"
}

# tk_identity_ancestor_walk <pid> <pane_pid_file> <pid_tty_file>
# Walk pid→parent chain looking for a pid that belongs to a tmux pane.
# Uses the pane_pid→pane_id+target map and pid_tty map.
tk_identity_ancestor_walk() {
    local pid="$1" ppid_file="$2" btty="$3" current pane_info ppid
    current="$pid"
    while [[ "$current" -gt 1 ]]; do
        # Check if current pid IS a pane_pid
        pane_info="$(tk_identity_lookup_file "$ppid_file" "$current")"
        if [[ -n "$pane_info" ]]; then
            printf '%s' "$pane_info"
            return 0
        fi
        # Walk to parent
        ppid="$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ')"
        [[ -z "$ppid" || "$ppid" == "$current" ]] && break
        current="$ppid"
    done
    return 1
}

# ── public API ───────────────────────────────────────────────────────

# tk_identity_list - output one TSV line per agent to stdout.
# Uses \x1f (unit separator) as field delimiter.
# Cache-first, non-blocking: lock loser uses stale data.
tk_identity_list() {
    local cache
    cache="$(tk_identity_cache_file)"

    # Fast path: cache exists and is fresh
    if ! tk_identity_stale && [[ -r "$cache" ]]; then
        cat "$cache"
        return 0
    fi

    # Try to rebuild under lock; loser serves stale without blocking
    if tk_lock identity 10; then
        tk_identity_rebuild
        tk_unlock identity
    fi

    # Always serve the cache (status rendering must never block)
    if [[ -r "$cache" ]]; then
        cat "$cache"
    fi
    return 0
}

# tk_identity_invalidate - touch the dirty flag.
# Called from pane-exited hooks.
tk_identity_invalidate() {
    touch "$(tk_identity_dirty_file)" 2>/dev/null || true
}

# tk_identity_pane_killed - hook handler for pane death.
tk_identity_pane_killed() {
    tk_identity_invalidate
}

# tk_identity_row <agent_id> - get one identity row.
tk_identity_row() {
    local escaped
    escaped="$(tk_identity_escape_grep "$1")"
    tk_identity_list | grep "^${escaped}$(printf '\037')" 2>/dev/null || true
}

# tk_identity_field <agent_id> <field_number> - extract one field.
# Fields: 1=agent_id 2=harness 3=session_id 4=pid 5=tty 6=pane_id 7=target
# 8=cwd 9=project 10=branch 11=name 12=liveness 13=activity 14=waiting_for
# 15=kind 16=host 17=source 18=observed_at 19=enrich
tk_identity_field() {
    local row
    row="$(tk_identity_row "$1")"
    [[ -n "$row" ]] || return 0
    printf '%s' "$row" | cut -d"$TK_US" -f"$2" 2>/dev/null || true
}
