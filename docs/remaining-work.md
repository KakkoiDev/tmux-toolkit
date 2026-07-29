# Remaining work

Handoff state for the tmux toolkit extraction. Written to be executable cold,
after a context reset, without re-reading the original plan.

Original plan: `~/.claude/plans/we-have-powerful-tmux-eventual-sky.md` (steps
D-0..D-21, plus corrections C1..C7 found during implementation).
Agent-surface assessment: `docs/agent-surface-assessment.md`.
Bug state, reproducible on demand: `tests/audit.sh`.

## Ground truth as of 2026-07-29

| Repo | Tests | Published | lib/ vendored |
|---|---|---|---|
| `tmux-toolkit` | 189 unit + 20 integration | public, 0.2.0 | n/a (source) |
| `tmux-agent-mesh` | 319/319 | public | **yes, 0.1.0** |
| `tmux-agent-tracker` | 263/263 | public | no |
| `tmux-agent-resumer` | 33/33 | public | no |
| `tmux-worktree` | ~570 | public, 24 stars | no |
| `tmux-session-order` | 12/12 | public | no |

Every suite green on bash 5 **and** bash 3.2. `shellcheck -S warning` clean in
toolkit, mesh, resumer, session-order, worktree. The tracker has 15 pre-existing
warnings and no CI.

**Bugs: 8 of 9 fixed.** Only V4 open. Run `tests/audit.sh` for current state.

**Environment still pending:** tmux is **3.5a**; an attempted 3.7b install did not
take (`brew list --versions tmux` shows 3.5a only). Upgrading needs a server
restart, which kills every live agent session, so it is the human's call.

## Built in the toolkit

`lib/toolkit.sh` (hot path, for harness hooks): `core tmux version opt log json
sqlite config`.
`lib/toolkit-ui.sh` (interactive/install): the above plus `lock menu notify`.

**Not built:** `target.sh fmt.sh status.sh hook.sh sched.sh identity.sh
harness.sh`. The README names them as unbuilt, and five contract tests in
`tests/unit/contract.bats` fail if it ever claims otherwise.

## Next steps, in order

### 1. V4 - mesh cleanup is bound to a hook that never fires

`agent-mesh.tmux:66-68` registers cleanup on `pane-died`. That hook only fires
when `remain-on-exit` is on, and it is off globally, so mesh's **only** cleanup
path is dead code and dead agents linger in the roster forever.

The fix is one word: `pane-exited`. It is not shipped because it needs a
measurement first. `pane-exited` fires on **every** pane close server-wide, and
`mesh.sh cleanup` does a full `list-panes -a` prune, so it becomes hot.

Do:
1. Measure `mesh.sh cleanup` wall time on a realistic roster. If it is cheap,
   ship the rename alone.
2. Otherwise debounce with `tk_config_fresh mesh-cleanup 2` before the prune.
3. Regression test: register an agent on a pane running `sleep 100`,
   `kill-pane`, assert the row is gone. **That test cannot pass today**, which is
   why the bug survived 319 tests. It must fail on the current commit.
4. Also drop the `pane-died` hook on upgrade, and fix `mesh.sh:1524`'s doctor
   probe which checks for the old hook name.

### 2. Convert the tracker's 476 bare `[[ ]]` assertions to functions

On bash 3.2 a bare `[[ ]]` that is not the last statement of a bats body trips
neither `set -e` nor the ERR trap, so only ~263 of the tracker's 476 assertions
are load-bearing. **This is the mechanism that hid 11 bugs found this session.**

A scratch-copy experiment currently reports 263/263 clean, so no known false
assertion remains, but the suite will rot again silently.

Do: vendor `tmux-toolkit/tests/assert.bash` into the tracker and convert
mechanically. `tmux-agent-mesh/tests/helpers.bash` already does this and
documents why. Mechanical, low risk.

The experiment worth keeping as a tool:

```sh
# In a scratch copy, make every bare assertion decisive, then run the suite.
python3 - <<'PY'
import re,glob
pat=re.compile(r'^(\s+)(\[\[ .* \]\])\s*(#.*)?$')
for f in glob.glob('tests/*.bats'):
    out=[]
    for i,l in enumerate(open(f).read().split('\n'),1):
        m=pat.match(l)
        out.append(f"{m.group(1)}if ! {m.group(2)}; then printf 'BARE-FAIL %s:%d\\n' '{f}' {i} >&2; exit 1; fi" if m else l)
    open(f,'w').write('\n'.join(out))
PY
```

### 3. Investigate: tracker `SessionStart` creates no row

`cmd_hook` says `SessionStart) ;; # _ensure_session already created as idle`, but
in the bats environment `SessionStart` leaves **0 rows**; the row first appears on
`UserPromptSubmit`. Verified pre-existing, identical before and after the V13
change, tested both directions.

If it also happens in production, an agent that starts and never prompts is
invisible to the tracker. Likely cause: `_reap_dead` runs on `SessionStart` and
deletes the fresh row because `_has_agent_child` finds no agent under the pane.
Determine whether production is affected, and if so whether the reap should skip
a row created in the same invocation.

### 4. D-2b - vendor `lib/` into the remaining four plugins

Mesh is done and is the worked example: see its `scripts/helpers.sh` (a shim) and
commit `6b6942c`.

```sh
cd <plugin> && git subtree add --prefix=lib ~/Code/tmux-toolkit dist --squash
```

**`dist`, not `main`.** `dist` is a subtree split of `lib/`, so its root *is* the
library. Pulling `main` gives you `lib/lib/core.sh` plus a copy of the tests.
`make dist` regenerates it. Never `subtree split --rejoin`, which writes a merge
commit back onto main and duplicates every release commit there.

Gate: each repo's existing suite must pass **unchanged**.

Per-plugin notes:

- **tracker** - largest consumer. Needs `TK_TMUX_DISABLED` wired to its
  `_SANDBOX` mode (`tracker.sh:90 _tmux` is exactly `tk_tmux`'s no-op path).
  Its `helpers.sh` also holds `_agent_client_type`, which belongs with
  `_has_agent_child` in a future `identity.sh`.
- **resumer** - now unblocked, since `lock.sh` exists. Its `_try_lock`/`_unlock`
  map onto `tk_lock`/`tk_unlock`, and it gains PID-validated stale stealing
  instead of a flat 120s wait.
- **worktree** - has **10 hand-copied `if [ -n "$TMUX_SOCKET" ]` forks** that all
  collapse onto `tk_tmux` with `TK_SOCKET`. No Makefile `test` target that
  `make fanout` can call; it has `test`, so check it works from fanout.
- **session-order** - smallest. Its `get_opt` is a third dialect of
  `get_tmux_option`.

Two things learned doing mesh, which will recur:

- A test fixture that writes the config cache must include the format marker
  (`# tk-config v1 <ns>`), or the loader treats it as foreign and rebuilds it,
  silently discarding everything planted.
- A fake tmux must answer `show-options` (plural) as well as `show-option`.
  Config loading now reads a whole namespace in one call, so a fake that knows
  only the singular form reports every option unset and the suite quietly tests
  defaults.

### 5. D-4 - worktree menus emit TSV, and `menu.sh` renders them

`worktree_manager.sh:560` is `eval "tmux display-menu -T '$title' $options"`, and
ten awk scripts assemble that string with six layers of quoting
(`awk/worktree_data.awk:47` is the worst). Rewrite the awk to emit **TSV data
only** and build the args with `tk_menu_*`.

This is the highest-regression-risk step in the whole plan and should go last
among the refactors. Human re-verify: open all six screens, filter with a pattern
containing a space and an apostrophe, switch to a branch whose worktree path
contains a space.

It also unblocks the agent surface, because the agent CLI then renders the same
data instead of parsing menu-command strings.

## Landmines, all verified on this machine

- `#{?@opt,#{@opt},default}` is **not** an option-with-default. It returns the
  default for an option set to `""` **and** for one set to the string `"0"`,
  because `#{?X,a,b}` is false for both. Would silently default every
  `@ns-debug-log 0`. Use `tk_opt` or `tk_opt_many`.
- `show-options -g` escaping cannot be undone by sequential substitution: the
  value `a\tb` renders as `a\\tb` and a real tab renders as `a\tb`.
  `tk_opt_cached` reforks for any value carrying escapes.
- A **tab is IFS whitespace**, so `IFS=$'\t' read -r a b c` collapses runs of
  tabs and drops leading ones. Any record format with optional fields must use
  `\x1f`. This will bite `identity.tsv`, whose `pane_id`, `target`, `tty` and
  `waiting_for` are all optional.
- `bash -n` passes `V=(a b`, and sourcing that file aborts the caller. A syntax
  error cannot be trapped, so provenance is checked via the cache format marker.
- `mv tmp config` **destroys a symlink**; `cat tmp > config` writes through. Both
  `~/.tmux.conf` and `~/.claude/settings.json` are dotfiles symlinks here. BSD
  `sed -i` refuses a symlink outright and aborts under `set -e`.
- `#{pane_current_command}` for a Claude pane is literally `2.1.220`, because
  claude rewrites argv[0]. Use a `ps -eo ppid,comm` child walk.
- `grep -c` prints its count **and** exits 1 when the count is zero, so
  `$(grep -c ... || printf 0)` yields `"0\n0"`.
- A unix socket path caps at ~104 bytes, and `mktemp -d` under a deep `TMPDIR`
  plus tmux's own `tmux-$UID/<name>` can exceed it. Failure reads as a broken
  library ("File name too long"), not a broken path.
- `read -r x < file` returns non-zero at EOF with no trailing newline **even
  though it assigned x**. Do not treat its status as "no value".
- A comment line starting with `# shellcheck` is parsed as a directive and fails
  with SC1072.
- `tracker.sh cmd_refresh` runs from `status-right` every status-interval and
  used to ATTACH a world-writable `/tmp` file into the real database. Now
  overridable and ownership-checked. Any future code that reads a shared `/tmp`
  path into production state needs the same guard.

## Do not do

- Do not require or wait for tmux 3.8. Unreleased, no RC, git-master only. Its
  headline (`set-hook -B` monitor hooks) is content scraping that
  `claude agents --json` already beats with an official API. Gate it behind
  `tk_vers_ge 3.8` if built at all.
- Do not put `send-keys` in `lib/`. Mesh's whole thesis is that it never types
  into a pane, pinned by a grep over its own tree, and it vendors this library. A
  contract test enforces this.
- Do not read `~/.claude/projects/**/*.jsonl`. The vendor documents the format as
  internal and unstable, and `CLAUDE_CONFIG_DIR` relocates it.
- Do not ship a schema-migration ladder before a migration is needed. The
  constraint is byte-identical to every existing database;
  `_ensure_schema` documents the rebuild procedure instead.
- Do not build the agent CLI (`mux`) before step 5. It would parse menu-command
  strings and get rewritten. The `tmux-fleet` skill already documents the
  existing CLIs, which was the actual ask.
