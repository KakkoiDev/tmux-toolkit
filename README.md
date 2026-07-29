# tmux-toolkit

Shared bash core for tmux plugins. Extracted from five plugins that had
independently reimplemented the same plumbing 26 times.

There is no existing library for this. `get_tmux_option` is copy-pasted folklore
across the tmux-plugins org, TPM's internal helpers are not a public API, and
nothing on crates.io, npm or PyPI fills the gap. This is that library.

## Install

Vendored, via `git subtree`, into the plugin that uses it:

```sh
git subtree add --prefix=lib https://github.com/KakkoiDev/tmux-toolkit.git dist --squash
```

Note `dist`, not `main`. `dist` is a subtree split of this repo's `lib/`, so its
root *is* the library and the consumer gets `lib/core.sh`. Pulling `main` instead
puts the whole repo at `lib/`, giving you `lib/lib/core.sh` plus a copy of the
tests and the Makefile. `make dist` regenerates the branch.

Subtree and not submodule: a submodule leaves `lib/` empty on a plain
`git clone`, and TPM does not `--recurse-submodules`, so every hook would break
on a fresh install.

Then source it by relative path:

```sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/toolkit.sh"
tk_init agent-mesh "$MESH_DIR"
tk_require_version 0.1.0
```

Relative, never searched. A harness invokes a plugin's CLI from `settings.json`
with no `$TMUX`, no plugin env and no cwd guarantee, so a library that has to be
located is a failure mode rather than a convenience.

### Developing against all consumers at once

```sh
export TMUX_TOOLKIT_DEV=~/Code/tmux-toolkit
```

Every loader then resolves `lib/` from that checkout, so one edit is live in
every plugin after `prefix + r`, with no syncing. Never set in CI.

### Publishing a change

```sh
make fanout    # subtree pull + that plugin's own suite + commit, per consumer
```

Stops on the first red suite. Consumers are listed in `consumers.txt`.

`make sync-check` fails when a vendored `lib/` no longer matches its tagged
source. That guard is the point: editing `lib/` in place inside a consumer is
exactly how 26 duplicated capabilities accumulated.

## Entry points

Two, deliberately. A Claude Code hook fires around 12 times per turn, so the hot
path stays small.

| Entry | Modules |
|---|---|
| `lib/toolkit.sh` | `core tmux version opt log json sqlite config` |
| `lib/toolkit-ui.sh` | the above plus `target fmt menu status hook sched notify lock identity harness` |

## API

### core

| Function | Notes |
|---|---|
| `tk_init <ns> [dir]` | sets `TK_NS`, `TK_DIR`, `TK_STATE` |
| `tk_die <msg>` | stderr, exit 1 |
| `tk_require <cmd>...` | names every missing command, not just the first |
| `tk_have <cmd>` | |
| `tk_mtime <file>` | portable `stat`; fails on a missing file |
| `tk_age <file>` | seconds since mtime; a missing file reads as infinitely old |
| `tk_fresh <file> <ttl>` | |
| `tk_now`, `tk_fmt_time <epoch> [fmt]` | portable `date -r` vs `date -d @` |
| `tk_cq <value>` | single-quote for a file that will be sourced |
| `tk_lib_version`, `tk_require_version <min>` | |

### tmux

The single choke point. `TK_SOCKET` adds `-L`, `TK_TMUX_DISABLED=1` makes every
call a successful no-op, `TK_TMUX_BIN` redirects the binary.

| Function | Notes |
|---|---|
| `tk_tmux <args...>` | faithful: returns tmux's status |
| `tk_tmux_silent <args...>` | for cosmetic writes; never fails |
| `tk_tmux_ok` | `list-sessions`, not `tmux info` (see below) |
| `tk_in_tmux` | pane env, not server reachability |
| `tk_display <msg>`, `tk_server_pid` | |

`tmux info` exits non-zero with "no current client" when a server runs
unattached, which made install and doctor checks report no tmux on a perfectly
healthy server.

### opt

| Function | Notes |
|---|---|
| `tk_opt <option> [default]` | the drop-in for every `get_tmux_option` |
| `tk_opt_many <sep> <option>...` | N options, one round trip, no conditionals |
| `tk_opt_bulk <prefix>` | one `show-options -g` for a whole namespace |
| `tk_opt_bulk_save/_load <prefix> <file>` | share the single fork across processes |
| `tk_opt_cached <option> [default]` | reads the blob; forks only for escaped values |
| `tk_opt_names` | every option present, for contract tests |
| `tk_opt_set`, `tk_opt_set_quiet`, `tk_opt_unset` | |
| `tk_opt_into <varname> <option> [default]` | validates the varname first |

**There is deliberately no `tk_opt_fmt`.** The obvious one-round-trip form,
`#{?@o,#{@o},default}`, is wrong twice on tmux 3.5a: it yields the default for an
option set to empty *and* for one set to the string `"0"`, because `#{?X,a,b}` is
false for both. That silently defaults every `@ns-debug-log 0`. Use
`tk_opt_many` when the goal is one round trip.

`tk_opt_cached` falls back to a real `show-option -gqv` for any value whose
rendering carries escapes, because `show-options -g` uses an escaping scheme that
sequential substitution cannot undo: the value `a\tb` (backslash, t) renders as
`a\\tb` while a real tab renders as `a\tb`, so `\\`→`\` then `\t`→TAB turns the
first into the second.

### version

`tk_vers`, `tk_vers_ge <x.y[suffix]>`, `tk_vers_require <x.y> <plugin>`.

Encoding is `major*1000 + minor`. jaclu/tmux-menus' concatenated-digit trick
makes 3.10 → 310 and 3.9 → 39 and therefore reports 3.9 > 3.10; its `next-`
handling and memoization are worth having, its integer encoding is not.

### config

`tk_config_load <ns> <ttl> VAR:@option:default...` plus `tk_config_fresh`,
`tk_config_invalidate`. One fork for the whole namespace, an mtime TTL, an atomic
write, and a format marker so a cache from another lib version or namespace is
rebuilt instead of sourced.

Staleness is honoured on the fast path. The copy this replaces sourced its cache
unconditionally, so a live `tmux set -g @ns-option value` never took effect.

`bash -n` alone is not enough of a guard, which is why the marker exists:
verified on bash 3.2 and 5.3, `printf 'V=(a b\n' > f; bash -n f` exits **0**, and
sourcing that file aborts the caller. A syntax error cannot be trapped.

### log, json, sqlite

`tk_log <level> <msg>` with `tk_error/warn/info/debug`. Honours `DEBUG_LOG=0|1`
for compatibility. Trimming is sampled rather than checked per write, because the
implementations this replaces fork `wc -l` on every single log line.

`tk_json`, `tk_json_bool`, `tk_json_path`, `tk_json_str_or_obj`, `tk_json_esc`,
`tk_json_read`. jq-first with a documented degraded fallback that logs when it is
used.

`tk_sql <db> ...`, `tk_sql_sep`, `tk_sql_json`, `tk_sql_esc`, `tk_sql_init`,
`tk_sql_table_exists`, `tk_sql_has_column`. **The db is a parameter, not a
global**, which deletes the bug class that made one plugin's `$DB` point another
plugin at the wrong database. `tk_sql_init` refuses DDL containing `DROP TABLE`.

## Not in this library

`send-keys` and everything around it. tmux-agent-mesh's guarantee is that it
never types into a pane, pinned by a grep in its own test suite; it vendors this
library, so keystroke injection must not be reachable from here. A contract test
enforces it. Typing lives in `tmux-agent-resumer/scripts/keys.sh`.

Also out: Anthropic usage/OAuth/keychain access, the 429 classifier, git and
worktree operations, per-plugin menu navigation semantics, session-name
sanitization, and anything that reads `~/.claude/projects/**/*.jsonl` (an
internal format the vendor documents as unstable).

## Tests

```sh
make test          # unit + integration
make bash32        # the tier that catches things: system bash 3.2
make lint
```

Four tiers: T1 unit against a fake tmux on `PATH`, T2 integration against
`tmux -f /dev/null -L <socket>`, T3 nested-tmux plus `expect` for rendered menus
(`display-menu` is a client overlay that `capture-pane` cannot see), and T4
contract tests generated from the source.

Every assertion is a function call, never a bare `[[ ]]` or `! cmd`: on bash 3.2
neither trips `set -e` or the ERR trap unless it is the last statement of the
test body. A suite this rule was missing from stayed green across 227 tests while
one of them asserted a value the code had never written.

Every generated list passes through `assert_list_nonempty` first. A T4 test whose
extraction pattern matches nothing loops zero times and passes vacuously; that
happened upstream and hid three dead options inside a 318-test suite.

## Requirements

tmux 3.0+, bash 3.2+, `sqlite3`. `jq` is recommended and required for a few
commands; the library degrades and says so when it is missing.
