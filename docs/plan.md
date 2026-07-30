# tmux-toolkit: extract a shared core from five tmux plugins

## Status as of 2026-07-30

Measured, not remembered. Test counts are `grep -c '^@test'`; sync state is
`git rev-list --left-right`.

| Repo | Tests | Bare `[[ ]]` | Dirty | Pushed |
|---|---|---|---|---|
| `tmux-toolkit` | 209 | 0 | 1 untracked | main yes, **`dist` NO** |
| `tmux-agent-mesh` | 327 | 0 | **3 (V4 fix)** | yes |
| `tmux-agent-tracker` | 263 | **476** | 0 | yes |
| `tmux-agent-resumer` | 33 | **7** | 0 | yes |
| `tmux-worktree` | 508 | **49** | 0 | yes |
| `tmux-session-order` | 12 | 0 | 0 | yes |

**Environment: tmux 3.7b is installed and linked.** Verified non-destructive
before installing: `PROTOCOL_VERSION` is 8 in both 3.5a and 3.7b, and a relocated
3.7b binary was tested driving the live 3.5a server (`list-sessions`,
`display-message`, `list-panes`, `show-hooks` all correct) before anything was
relinked. The live server is untouched: pid 9420, still 3.5a, 6 sessions, 11
agents. The 3.5a keg is kept, so rollback is
`ln -sf ../Cellar/tmux/3.5a/bin/tmux /opt/homebrew/bin/tmux`. **The server
restart (D-0.5) is still outstanding and is the human's call.**

### Done, all pushed. Audit: 0 open, 10 fixed.

| Repo | Tests now | Was |
|---|---|---|
| `tmux-toolkit` | 209 | 209 |
| `tmux-agent-mesh` | 327 | 319 |
| `tmux-agent-tracker` | 268 | 263 |
| `tmux-agent-resumer` | 33 | 33 |
| `tmux-worktree` | 493 | 493 |

1. **tmux 3.7b installed and linked.** Non-destructive, verified before touching
   anything: `PROTOCOL_VERSION` is 8 in both 3.5a and 3.7b, and a relocated 3.7b
   binary was test-driven against the live 3.5a server first. Live server
   untouched. 3.5a keg kept.
2. **V4 fixed**, and the plan's recorded fix for it was wrong. See C8.
3. **`dist` pushed** and a `make dist-check` guard added, wired into CI. It was
   verified decisive against all three failure modes (stale tree, unpushed,
   missing branch). This was NG-1 from the first external consumer.
4. **532 bare `[[ ]]` assertions converted** across tracker, worktree and resumer.
   Instrumented first: all 532 were currently true, so this prevents rot rather
   than fixing a live bug. Five worktree tautologies were replaced with real
   assertions rather than mechanically converted.
5. **A new bug found and fixed while investigating step 4 of the old list:**
   `_has_agent_child` matched ppid only, so a pane whose own process is the
   harness - what `mesh dispatch` creates - looked agentless. The tracker reaped
   those rows within 10s and the resumer marked them "gaveup". Second defect in
   the same line: `ps -o comm` prints the executable as invoked, so an agent
   started by absolute path never matched the bare name.

Measured while doing this, and worth keeping: on bash 3.2 a bare `[[ ]]` and a
negated `! cmd` are both inert mid-body, but a bare `[ ]` **is** decisive, because
`[[` is a compound command and errexit does not apply to it inside a function.
bats runs test bodies under `/bin/bash` 3.2.57 here, so every suite run is already
the 3.2 tier. There is **no bash 5 on this machine**; that tier is CI only.

### D-2b is done. Left to do: D-4, and D-15 which I would now do first.

**D-2b landed.** All five plugins vendor `lib/` at 0.2.0
(`tmux-toolkit consumers` confirms), every suite is green and larger, and the
audit is **0 open, 13 fixed**. Per-repo results:

| Repo | Tests now | Was | Commit |
|---|---|---|---|
| `tmux-session-order` | 12 | 12 | `c88c3c8` |
| `tmux-agent-resumer` | 36 | 33 | `e1e76ed` |
| `tmux-agent-tracker` | 274 | 268 | `e088b4e` |
| `tmux-worktree` | 494 | 493 | `8ce7386` |
| `tmux-agent-mesh` | 327 | 327 | re-pulled 0.1.0 -> 0.2.0 |

What it actually fixed, beyond the deduplication:

- **NG-3 was real and is fixed.** `_load_config_fast` sourced
  `$TRACKER_DIR/config_cache` with **no staleness check at all**, and called
  `load_config` only when the file did not exist. So the first hook after install
  wrote the cache and every later read took it verbatim, forever: no
  `@agent-tracker-*` option has ever taken effect on any machine after the first
  minute. Three tests pin it; two fail on the pre-fix code, and the third ("a
  fresh cache is still used") passes on both so an over-correction that reads
  tmux every time cannot pass either. New audit probes NG3/NG3b.
- **The tracker's sandbox no-op covered 5 call sites out of 43.** `_tmux` checked
  `_SANDBOX` per call, but 38 bare `tmux` calls in `tracker.sh` bypassed it, and
  `tk_opt` was one of the things it did not cover. `TK_TMUX_DISABLED` is now
  wired once, which also deleted the sandbox branch's second hand-written copy of
  the config defaults; that copy had already drifted by omitting `KEYBINDING`,
  the three key bindings and `SHOW_PROJECT`.
- **A worktree test was passing for the wrong reason.** Both version-check stubs
  matched `-V` at `$1`, and the suite exports `TMUX_SOCKET=test-worktrees`, so
  once the call went through `tk_tmux` the argv started with `-L` and the stub
  answered nothing. "fails for tmux 2.x" was green because *no version at all*
  reads as too old. Fixed, plus a 3.10 case that the old major-only comparator
  got wrong.
- **The resumer's lock steals immediately** when the holder pid is gone, instead
  of after a flat 120s.

Two things NOT delegated, both with the reason recorded at the call site so the
next reader does not "finish the job" and break them:

- **`_json_val` stays local in tracker and resumer.** Two of the resumer's three
  call sites look up a key that is *nested*: `_json_val "$line" text` digs
  `.message.content[0].text` purely because a substring slice ignores depth, and
  `tk_json` evaluates `.text`, which is null on that record. It would have made
  `_classify_limit` report every 429 as "unknown". Separately, the tracker's
  `cmd_hook_generic` reads its payload with `read -r`, which takes only the first
  line, so a pretty-printed payload arrives as `{` and no extractor can recover
  it. Both belong to D-15.
- **The resumer's four `python3` heredocs stay.** They are single-copy resumer
  logic, not duplication. `tk_json_path` is jq-only, so swapping them trades an
  optional python3 dependency for an optional jq one and silently disables the
  credit guard on a box without it, and two of them need ISO-8601 date arithmetic
  that jq's `fromdateiso8601` does not cover for offset forms.

Also done in this step: `consumers.txt` describes reality (NG-2), the audit
reports each consumer's vendored version, every consumer's CI runs the
`lib/.checksum` drift guard (verified decisive by appending a line to
`lib/core.sh`), and the tracker got a CI workflow, which it had none of. That CI
has **no shellcheck gate** on purpose: the tree has 11 pre-existing findings, down
from 14, and a gate that is red on arrival gets ignored rather than fixed.

Traps that recurred and will recur again:

- **The test harness strips `^source ` lines.** Both mesh's
  `source_mesh_functions` and the tracker's `source_tracker_functions` awk out
  every `source` line before evaluating `*.sh`, so the vendored library
  disappears along with `helpers.sh` and every `tk_*` call fails with 127. The fix
  is to source `lib/toolkit.sh` in the test helper itself. Load the real library,
  not stubs: a stubbed `tk_sql` would let `lib/` break with every suite green.
- **`"$TK_TMUX_BIN"` resolves to a shell function.** Measured: bash looks up the
  command word after expansion and finds a function before PATH, so every
  existing in-process `tmux() { ... }` stub keeps working through `tk_tmux`. That
  is what made routing call sites through the choke point safe.
- A fixture that writes the config cache must include the `# tk-config v1 <ns>`
  marker, or the loader treats it as foreign and rebuilds it, silently
  discarding everything planted.
- A fake tmux must answer `show-options` (plural) as well as `show-option`.
  Config loading reads a whole namespace in one call, so a fake that knows only
  the singular form reports every option unset and the suite quietly tests
  defaults. This is NG-5's class and it cost the voice agent two false greens.

---

**Order note, and it disagrees with the table below.** D-4 is a quoting refactor
with no user-visible benefit. **D-15 is what fixes the roster noise the human has
complained about twice**, and there is now live evidence it is needed. Measured
2026-07-30: `mesh.db` held three rows with an empty `tmux_pane`, of which
`claude agents --json` reported two dead and one **live**. `cmd_cleanup` skips any
row with an empty `tmux_pane` (`[[ -z "$pane" ]] && continue`), so the dead ones
can never be reaped by any path, and the obvious fix is a trap: tracker's
"reap paneless rows older than 10 minutes" would have deleted the live one. The
only safe discriminator is the registry, which is exactly D-15. **Do D-15 before
D-4.**

The specific session ids are deliberately not recorded: they are per-machine and
change on every server restart, so they would be wrong for anyone reading this.
`docs/RESUME.md` carries the query to re-measure.

**The registry integration does not exist yet.** Grepped 2026-07-30:
`claude agents --json` is called **nowhere** in any of the six repos. Decision 3
("the registry becomes authoritative for liveness") and finding V1 are entirely
unimplemented, so D-15 is not "swap the liveness source", it is "build it from
zero". That also means the mesh paneless-row reap is **not** a separable small
fix: it would be the first registry consumer, so it either hand-rolls a registry
call inside mesh, which is the exact duplication this project exists to delete, or
it is the front half of `tk_identity_*`. Do it as the front half.

**Three open items in section H gate D-15 and are the human's to answer, not
mine: H.1 (the badge goes from 4 agents to 7 - are all 7 badge-worthy, or do
`kind:"background"` and subagent-spawned sessions get filtered?), H.3 (does the
identity provider need a sandbox path at all?), and H.5 (the `XDG_STATE_HOME`
move, which must happen once in D-15 or never).** Building against an assumed
answer to H.1 risks rewriting the filtering logic and its tests.

1. **D-4: worktree menus emit TSV, `menu.sh` renders them.**

   `worktree_manager.sh:560` is `eval "tmux display-menu -T '$title' $options"`,
   and ten awk scripts assemble that string through six layers of quoting
   (`awk/worktree_data.awk:47` is the worst). Rewrite the awk to emit **TSV data
   only** and build the argument vector with `tk_menu_*`.

   Highest regression risk in the plan; goes last. Human re-verify: open all six
   screens, filter with a pattern containing a space and an apostrophe, and switch
   to a branch whose worktree path contains a space.

   It also unblocks the agent surface, because the agent CLI can then render the
   same data instead of parsing menu-command strings.

**Still outstanding and not mine to take: the tmux server restart (D-0.5).** 3.7b
is linked but the running server is still 3.5a. Expect `%N` pane ids to renumber
from `%0`, which is what the tracker's pane-invalidation handles.

Deferred with a reason: **NG-4** wants `tk_lock_steal`/`--preempt` for newest-wins
barge-in. Two consumers would use it (`tmux-agent-voice`, and whatever replaces
resumer's `_try_lock`), but not before D-2b shows the second one wants that shape.

Deferred, with a reason: **NG-4** asks for `tk_lock_steal`/`--preempt` for
newest-wins barge-in. Two consumers would use it (`tmux-agent-voice`, and
whatever replaces resumer's `_try_lock`), so it is worth building, but not before
step 5 proves the second consumer actually wants that shape.

## Context

Five home-grown tmux plugins in `~/Code` (all bash, all loaded via `run-shell` from `~/.tmux.conf`) each re-implement the same tmux plumbing. A full inventory found **26 duplicated capabilities**, several byte-identical, several *drifted so that the copy holds the bugfix and the original holds the bug*. The overlap the user named, Claude instance identification, is the worst case: three plugins identify agents three different ways and one reads another's sqlite table directly.

Prior-art research found **no shared bash library for tmux plugins exists anywhere** (checked the tmux-plugins org, TPM internals, oh-my-tmux, powerline, catppuccin, crates.io/npm/PyPI). `get_tmux_option` is copy-pasted folklore. So the library is a genuine gap, not a reinvention. What does exist and should be adopted is narrower and specific: official Claude Code CLI/hook surfaces, tmux format modifiers we are currently doing in shell, and one technique each from jaclu/tmux-menus, firstmate, and craftzdog/tmux-claude-session-manager.

Outcome: one vendored `lib/` shared by all five, each plugin reduced to its own domain logic, and 8 verified bugs fixed as separate steps.

### The five plugins

| Plugin | Domain | Size |
|---|---|---|
| `tmux-agent-tracker` | agent state to sqlite to status badge + jump menu; 12 Claude hooks, 5 harnesses | 2.8k-line `tracker.sh` |
| `tmux-agent-resumer` | 429 detect, queue, then `send-keys` a resume prompt behind guards | 1.1k-line `resumer.sh` |
| `tmux-agent-mesh` | agent-to-agent mail via the *recipient's own* hook stdout; zero `send-keys` (pinned by test) | 1.9k-line `mesh.sh`, 318 bats tests |
| `tmux-worktree` | git-worktree-per-branch equals tmux session; 6 menus from 10 awk scripts | 2.3k shell + 10 awk, ~570 tests |
| `tmux-session-order` | session ordering by `NN_` rename | 196 lines, not a git repo |

Also in `~/Code` but not ours and not loaded: clean read-only clones of `jaclu/tmux-menus` (mature; steal two ideas) and `pwittchen/tmux-plugin-spotify` (dead since 2021; ignore).

## Verified findings (probed live on this machine, not inferred)

| # | Finding | Evidence |
|---|---|---|
| V1 | `claude agents --json` sees **7** live sessions; tracker's sqlite holds **4**. Tracker also reports synthetic `blocked`/`completed` that do not reconcile. | `claude` 2.1.220; fields `pid, cwd, kind, startedAt, sessionId, name, status(idle\|busy)` |
| V2 | pid to tty to pane join succeeds **7/7** | `ps -eo pid,tty` + `tmux list-panes -a -F '#{pane_tty} #{pane_id} #{session_name}:#{window_index}.#{pane_index}'` |
| V3 | `#{pane_current_command}` for a Claude pane is literally `2.1.220`; claude rewrites argv[0]. Useless for detection, so `comm`-based child-walk is the only process route. | all 6 agent panes |
| V4 | `remain-on-exit` is **off**, and `pane-died` only fires when it is on, so **mesh's only cleanup path is dead code**. `pane-exited` is the correct hook. | `tmux show-option -gqv remain-on-exit`; tmux 3.5a man |
| V5 | `agent-tracker.tmux:45-47` uses `set-hook -g` (not `-ga`) on three hooks, so it **clobbers any other plugin's handler on every load** | mesh uses `-ga` + guard; worktree uses `-ag` |
| V6 | `~/.claude/settings.json` is a **symlink** into `claude-profiles/main/`. `tracker/install.sh` writes with `mv "$tmp"` at lines 253/369/501/568, replacing the symlink with a regular file. resumer + mesh use `cat "$tmp" >` and are correct. | `ls -la` |
| V7 | `run-shell -d <delay>` exists in 3.5a: a libevent timer, no `sleep` child. Both plugins use `run-shell -b "sleep N && ..."`. | 3.5a man page |
| V8 | Hook-name validation must be per-name: `show-hooks -g <name>` returns rc 0; `show-hooks -g bogus` returns rc 1 + `invalid option`. Bare `show-hooks -g` **omits** valid names; `show-options -g` lists zero hooks. | probed both |
| V9 | These all work on 3.5a and delete shell code: `#{q:}` (sh-quote), `#{E:@o}` (unset expands to empty), `list-panes -f` (server-side filter), `#{C/r:}` (search pane content server-side), `#{b:}`/`#{d:}`, `#{cursor_y}`. **See C1: the `#{?@o,#{@o},def}` claim in this row was wrong.** | probed each |
| V10 | Live `status-right` holds **3** `#()` shellouts (continuum, resumer, tracker) + 2 `#{@...}`; `status-interval` is 15. Per tmux(1) each `#()` displays the *previous* result, so that is three independently-stale caches. | `show-option -gqv status-right` |
| V11 | `tracker.sh:143` does `DROP TABLE IF EXISTS sessions`, called from `agent-tracker.tmux:14` on every load. `prefix+r` is bound to `source-file ~/.tmux.conf`, so every config reload wipes `prompt_summary`/`task_count` that no hook resends. | code + `.tmux.conf:16` |
| V12 | `mesh/tests/isolation.bats:80` greps `'^[A-Z_]+=\$\(get_tmux_option'` but every such line in `helpers.sh` is indented 4 spaces, giving **0 matches, loop body never runs**. That is why 3 dead options survived 318 tests. | verified 0 vs 15 matches |
| V13 | `_has_agent_child` Linux branch: tracker lists 8 agent names, resumer only 5 (drops `deer`, `deerbox`, `agy`). Darwin branches are byte-identical. | both `helpers.sh` |
| V14 | resumer has **zero** `refresh-client` occurrences, so its badge only appears on tmux's own 15s cadence, the exact latency the tracker solved. | repo-wide grep |
| V15 | mesh's Go `internal/store` (1664 lines) is unreachable by construction: no `package main`, and `internal/` is unimportable outside the module. Its `schema.sql` and bash `_SCHEMA_SQL` both target `mesh.db` with **incompatible** definitions. | `go.mod`, grep |

Upstream facts worth designing against: Claude Code docs state **"Hooks cannot initiate new turns"**; transcript parsing is explicitly discouraged (internal format, relocatable via `CLAUDE_CONFIG_DIR`); `StopFailure` has a `rate_limit` matcher with `{error_type, error_message}`, the official 429 trigger; `SessionStart` output supports `initialUserMessage`; Channels can push into a *running* session but not wake an idle one (open bug #44380). So `send-keys` remains the only way to start a turn in an idle interactive pane.

### tmux version policy

| Fact | Source |
|---|---|
| Installed and linked here: **3.5a** only (`/opt/homebrew/Cellar/tmux/3.5a`). Running server started 2026-07-29 09:46 with that binary. | `brew info tmux`, `readlink`, `ps` |
| Newest **released** tmux is **3.7b**, bottled in brew. So this machine is two releases behind for no reason. | `brew info tmux`; github.com/tmux/tmux/releases |
| **3.8 does not exist as a release.** No tag, no prerelease, no RC. The CHANGES section is titled "CHANGES FROM 3.7b TO 3.8" with no date, i.e. in progress. Only reachable via `brew install tmux --HEAD` (no bottle, builds from git master). | tmux/tmux CHANGES on master; releases page |
| 3.8 adds, verbatim: hooks and control-mode notifications "handled internally by using events, each of which may carry keys and values as a payload"; `set-hook -B` monitor hooks "using the same subscription syntax as refresh-client -B", `show-hooks -B` to list, `-T` to run "only when the format is true"; `wait-for -E` waits for hooks/notifications/user events and `set-hook -E` fires one; `wait-for -v` shows the keys; and OSC 133 triggering `pane-command-started`, `pane-command-finished`, `pane-shell-prompt`. | CHANGES on master |

**Policy: floor stays 3.0, target 3.7b, gate 3.8.** Concretely:
- **Upgrade this machine to 3.7b** (D-0.5). Nothing in this plan needs it, but two releases of fixes and format work are free, and every `T2` assertion in section E should be made against the version actually in use.
- **Keep the published floor at 3.0.** `tmux-worktree` has **24 stars**; the three agent-* repos have 0. Raising the floor is only free for the ones nobody uses.
- **Do not require 3.8.** Requiring a git-master multiplexer for tooling whose job is babysitting agent sessions makes the watcher the most likely thing to break everything. HEAD has no bottle, `brew upgrade` pulls whatever master is that day, and a rollback means another server kill on a server currently holding 7 live sessions.
- **What 3.8 actually buys us, honestly ranked.** Its apparent headline (`set-hook -B busy:%*:'#{C/r:esc to interrupt}'` for push-based busy detection with zero forks) is *content scraping*, and D-15 already gets `busy|idle|blocked` authoritatively from `claude agents --json` for 3 forks behind a 2s cache. An official API beats a regex over a screen. Note also that `-B` is still a 1-second poll, just inside tmux: a cost win, not a latency win. The OSC 133 hooks fire on **shell command** boundaries, so for a long-running `claude` process they give liveness, not per-turn state, and zsh emits OSC 133 only with a prompt hook. That leaves three real wins, all narrow: (1) busy/idle for **codex/gemini/pi**, which have no `agents --json` equivalent and are the only places we would still scrape; (2) `wait-for -E` as a genuine bash event loop, retiring the last `#()` polling path; (3) push cleanup on pane death without a full `list-panes -a` prune.
- **Therefore:** one function, `tk_watch <name> <scope> <format> <command>`, registers a `status-interval` poll when `! tk_vers_ge 3.8` and `set-hook -B` when it is available. That is the entire 3.8 surface area, flipped by one gate on the day it ships.

## Corrections found while implementing (these override the text above)

| # | Correction |
|---|---|
| **C1** | **`#{?@o,#{@o},default}` is not a usable option-with-default and `tk_opt_fmt` was not built.** Probed on 3.5a: it yields the default for an option set to empty **and** for one set to the string `"0"`, because `#{?X,a,b}` is false for both. It would have silently defaulted every `@ns-debug-log 0` and `@ns-completed-delay 0`. It also does **not** distinguish set-empty from unset, contrary to V9. The replacement is `tk_opt_many` (one `display-message` round trip, no conditionals) plus `tk_opt_bulk` (one `show-options -g` per namespace), and the bulk read is the only thing that *can* tell unset from set-empty, because an unset user option is absent from the listing entirely. |
| **C2** | **`show-options -g` escaping cannot be undone by sequential substitution.** The value `a\tb` (backslash, t) renders as `a\\tb`; a real tab renders as `a\tb`. So `\\`→`\` then `\t`→TAB turns the first into the second. `tk_opt_cached` therefore reforks to `show-option -gqv` for any value whose rendering carries a backslash or a quote, keeping the one-fork path for the ~95% of values (keys, colours, icons, numbers, on/off) that need no escaping. |
| **C3** | **A tab is a terrible record separator for the identity record, and this affects D-15.** Tab is IFS *whitespace*, so `IFS=$'\t' read -r a b c` collapses runs of tabs and drops leading ones. The identity record in section C has several optional fields (`pane_id`, `target`, `tty`, `waiting_for`), so a tab-separated line for a background session would silently shift every later field. **Use `\x1f` (unit separator) for `identity.tsv`, not a tab.** Found the hard way in the test stub, where an empty stdout field shifted the exit code into it. |
| **C4** | **`bash -n` is a weaker cache guard than mesh's comment implies.** Verified on bash 3.2 and 5.3: `printf 'V=(a b\n' > f; bash -n f` exits **0**, and sourcing that file aborts the caller. A syntax error cannot be trapped in the current shell. The config cache therefore carries a `# tk-config v1 <ns>` marker and provenance is checked rather than trusted; that also makes a format change across a vendored `lib/` version safe, which is the failure mode that actually matters. |
| **C5** | **Consumers must subtree from a `dist` branch, not `main`.** `git subtree add --prefix=lib <toolkit> main` puts the repo *root* at `lib/`, producing `lib/lib/core.sh` plus a copy of the tests and Makefile. `dist` is a subtree split of `lib/`. Also: never `subtree split --rejoin`, which writes a merge commit back onto `main` and duplicates every release commit there. `make dist` does the clean thing. |
| **C6** | **A ninth bug, same class as V6:** `tmux-session-order/uninstall.sh` used `mv "$tmp" "$CONF"`, which replaces a symlinked `~/.tmux.conf` with a regular file. Yours *is* a symlink into `dotfiles/packages/tmux/`. Verified both directions: `mv` destroys the link and leaves the real file stale, `cat "$tmp" > "$CONF"` writes through. Fixed. |
| **C8** | **"The fix is one word: `pane-exited`" was wrong, and V4 is bigger than V4 said.** Probed on 3.5a with `remain-on-exit` off, registering a marker on each candidate hook and then tearing panes down four different ways: a pane whose process exits fires `pane-exited`; `kill-pane` on a multi-pane window fires **only** `after-kill-pane`; `kill-pane` on the last pane fires `after-kill-pane` + `window-unlinked`; `kill-window` fires **only** `window-unlinked`; `kill-session` fires `session-closed` + `window-unlinked`; `pane-died` fires never. So `pane-exited` alone still misses every `kill-*`, which is how a human closes a pane and how `tmux-worktree` tears down a session. The covering set is `pane-exited after-kill-pane window-unlinked session-closed`, registered with per-name `show-hooks -g <name>` validation because the published floor is 3.0 and an unknown name makes `set-hook` fail under `set -e`. `window-layout-changed` is excluded on purpose: it also fires on every split and resize. Also measured, which the plan asked for and got: `cleanup` is **188ms** on a 14-pane server with 14 agents, of which 55ms is sourcing `mesh.sh` and 122ms is nine forks. Four hooks at that price needs the debounce, so `cmd_cleanup` gained one with a **scheduled trailing pass** (`run-shell -b -d`) plus a pending marker, because a debounce that merely returns loses the last death in a burst and nothing else would ever notice that pane. |
| **C7** | Two mesh test fixtures had to follow the intended implementation change, and neither is an assertion change: `plant_config` now writes the format marker (without it, planted config was rebuilt away), and `fake_tmux` now answers `show-options` as well as `show-option` (a fake that knows only the singular form reports every option unset, so the suite would quietly test defaults). Also fixed: mesh's harness leaked 25 socket files per run into `/tmp/tmux-$UID`, and a socket path under a deep `mktemp` dir can exceed the ~104-byte unix limit and fail with "File name too long". |

## Decisions taken

1. **Distribution: standalone `KakkoiDev/tmux-toolkit`, vendored into each plugin as `lib/` via `git subtree`**, plus `make sync` and a checksum guard.
2. **Scope: all five repos. Extract behavior-preserving first (D-0..D-7), then upgrades and bug fixes one step at a time (D-8..D-20).**
3. **Identity: `claude agents --json` becomes authoritative for liveness.** Hooks demote to enrichment.
4. **`tmux-session-order`: rewrite to store order in a session option**, and stop renaming sessions.

## A. Module decomposition

Every exported symbol is **`tk_`-prefixed**. Non-negotiable: it lets the library be sourced *alongside* today's `helpers.sh` during migration without either shadowing the other, and unprefixed `sql`/`_debug_log`/`_json_val`/`_file_mtime` collide with plugin-locals.

**Two entry points on purpose**, since a Claude hook fires ~12x per turn and the hot path must stay small:
- `lib/toolkit.sh` (hot): `core tmux opt version log config json sqlite`
- `lib/toolkit-ui.sh` (interactive/install): hot set plus `target fmt menu status hook sched notify lock identity harness`

```
tmux-toolkit/
  lib/{core,tmux,opt,version,target,fmt,hook,sched,menu,status,sqlite,
       config,lock,log,json,harness,notify,identity}.sh
  lib/{toolkit,toolkit-ui}.sh   lib/VERSION   lib/.checksum
  bin/tmux-toolkit              # tick | identity | doctor | version
  tests/{assert.bash,stub/tmux,unit/,integration/}
  Makefile                      # test | fanout | sync-check
  consumers.txt
```

| Module | Key exports | Replaces (with duplication count) |
|---|---|---|
| `core.sh` | `tk_init <ns>`, `tk_plugin_dir`, `tk_require`, `tk_die`, `tk_mtime`, `tk_now` | loader preamble x5; `_file_mtime` x3 identical plus worktree's `$OSTYPE` variant; worktree's 3-way plugin-dir fallback (`helpers.sh:41-49`) |
| `tmux.sh` | `tk_tmux` (single choke point: applies `-L $TK_SOCKET`, honours `TK_TMUX_DISABLED=1`), `tk_display`, `tk_server_pid` | `tracker.sh:90 _tmux` sandbox no-op **and** worktree's 10 hand-copied `if [ -n "$TMUX_SOCKET" ]` forks. Both needs are literally the same choke point, hence one module |
| `opt.sh` | `tk_opt`, `tk_opt_fmt` (the `#{?@o,#{@o},def}` form), `tk_opt_bulk`/`tk_opt_cached` (one `show-options -g \| grep ^@ns` into a builtin `case` scan), `tk_opt_set`, `tk_opt_into` | `get_tmux_option` x3 identical, plus worktree's socket variant, plus `session-order.tmux:13`'s third dialect. Resumer's cold config load is **25 forks** today and becomes 1. Idea from `tmux-menus/scripts/utils/tmux.sh:106,121` |
| `version.sh` | `tk_vers`, `tk_vers_ge`, `tk_vers_require` | `check_tmux_version`/`ensure_tmux_version` x4. Steal jaclu's `next-`/suffix handling and memoization but **reject its integer encoding**: `tpt_digits_from_string` turns 3.10 into 310 and 3.9 into 39, comparing backwards. Use `major*1000+minor` |
| `target.sh` | `TK_TARGET_FMT` constant, `tk_pane_target` (with the mesh's dead-pane echo-back guard), `tk_target_split`, `tk_goto`/`tk_goto_pane`, `tk_pane_alive`, `tk_panes_alive` | the target format literal x6; the `${t%%:*}`/`${t%.*}` parse x3; the switch-client/select-window/select-pane triple x4; `\| grep -qx` liveness x5. Promoting the echo-back guard fixes the tracker storing `":."` for dead panes |
| `fmt.sh` | `tk_fmt`, `tk_fmt_fields` (positional array, since bash 3.2 has no nameref), `tk_q`, `tk_pane_search` (`#{C/r:}`) | collapses N-round-trip queries: `cmd_scan` does 2 `display-message` calls **per pane** inside a loop. Heuristic *word lists* stay plugin-local |
| `hook.sh` | `tk_hook_valid` (per V8), `tk_hook_add` (validate, `grep -qF` guard, `-ga`), `tk_hook_remove` (index-aware `set-hook -gu 'n[0]'`) | mesh's hand-rolled guard, worktree's `-ag`, and fixes V5 for free. **No plugin has removal today**; all three uninstalls either clobber or leave junk |
| `sched.sh` | `tk_after <secs> <cmd>` using `run-shell -b -d`, falling back to `sleep` only when `! tk_vers_ge 3.2`; `tk_jitter` | `resumer.sh:245`, `tracker.sh:784` (V7) |
| `menu.sh` | `tk_menu_reset/title/item/sep/quit/show`, `tk_menu_cmd` (single-quotes each arg, wraps in `run-shell`), `tk_menu_page`, `TK_MENU_DRYRUN=1` | the args-array convention x3 (tracker/mesh/session-order), and **deletes** `worktree_manager.sh:560`'s `eval "tmux display-menu ..."`. `tk_menu_cmd` kills the 6-layer awk to bash to eval to tmux to run-shell to bash chain: awk emits **TSV only** and bash builds the args. See `awk/worktree_data.awk:47` for what dies |
| `status.sh` | `tk_status_register <ns>` (ensure exactly `#{E:@ns-status}` and no `#()`), `tk_status_set` (**set plus `refresh-client -S`**), `tk_status_engine_register`, `tk_status_strip` | three different injection strategies (tracker's 2 literal subs plus a 4-pattern sed; resumer's substring guard; mesh refusing to touch it). `tk_status_set` alone fixes V14. Net effect: `status-right` goes from 3 `#()` to **1**, plus N `#{E:@ns-status}` |
| `sqlite.sh` | `tk_sql <db> ...`, `tk_sql_sep`, `tk_sql_json`, `tk_sql_esc`, `tk_sql_init` (WAL + busy_timeout preamble) | `sql`/`sql_esc` x3, WAL preamble x4. **db is a parameter, not a global**: today all three close over `$DB`, which is why `mesh.sh:9-11` carries a 6-line comment about `DB` leaking and `isolation.bats` has 4 tests policing it. No bind layer, because the sqlite3 CLI has none |
| `config.sh` | `tk_config_load <ns> <ttl> VAR:@opt:default...`, `tk_config_fresh`, `tk_config_fast`, `tk_config_invalidate` | the 60s-mtime plus atomic-mv pattern x4 (~70 hand-written cache lines) and the staleness idiom x7 across 7 TTLs. **Ship the resumer's `_load_config_fast` semantics**: the tracker's (`tracker.sh:618`) sources unconditionally, so `tmux set -g @agent-tracker-color-idle red` never takes effect. Use mesh's `_cq` escaper and `bash -n` cache validation, the only correct pair of the four |
| `lock.sh` | `tk_lock <name> [stale]`, `tk_unlock`, `tk_with_lock` | `resumer.sh:40`, the only locking anywhere. Adds **PID plus `kill -0`** staleness, since today a dead holder blocks for 120s. `mkdir` is the universal path; `flock -n` opportunistic on Linux; **reject `lockf(1)`** because it runs a command under the lock and does not compose with a shell function |
| `log.sh` | `tk_log <level> <msg>` | `_debug_log` x3 identical plus worktree's `debug_log`/`error_log`. **Change:** trim on a counter, not every write. Current code runs `wc -l` per log line on a path that fires 12x per turn |
| `json.sh` | `tk_json`, `tk_json_bool`, `tk_json_path`, `tk_json_esc` | `_json_val` x3 (tracker's and resumer's are slice-only and silently return empty for pretty-printed payloads; mesh's is jq-first). `tk_json_path` deletes the resumer's **three python3 heredocs** (`resumer.sh:499,635,664`, ~40ms spawn each, called from the status engine) |
| `harness.sh` | `tk_hooks_install <file> <cmd_prefix> <event:matcher>...`, `tk_hooks_remove` | the jq add-if-absent predicate duplicated **5x inside `tracker/install.sh` alone** plus once in mesh. Writes **through** symlinks (`cat "$tmp" >`), fixing V6. Sourced by install.sh only, never at hook time |
| `notify.sh` | `tk_notify <ns> <event> <title> <body>` | `tracker:_fire_transition_hook`, `mesh:_fire_mail_hook`, `resumer:_notify`. One place for `(eval "$cmd" &)` on a user-supplied string instead of three |
| `identity.sh` | see section C | the whole overlap the user asked about |

### Explicitly NOT in the library

- **Any `send-keys` primitive** (`_type_prompt`, `_prep_input`, `_interrupt_pane`, `_pane_is_vim`). `mesh/tests/isolation.bats:74` pins `refute grep -rn "send-keys" $SCRIPTS_DIR agent-mesh.tmux pi-extension`. If keystroke injection enters a library the mesh sources, that guarantee dies. They live in `tmux-agent-resumer/scripts/keys.sh`, and toolkit CI asserts `send-keys` appears nowhere in `lib/`. **This is also the main reason the monorepo option was wrong.**
- Anthropic usage/OAuth/keychain (one consumer, vendor-specific, handles a secret); the 429 classifier (one consumer, and D-16 deletes most of it); git/worktree ops; nav-row semantics (three plugins, three meanings, and mesh's are dead); session-name sanitization (5 copies, and the answer is to stop renaming rather than share the renamer); **anything reading `~/.claude/projects/**/*.jsonl`**.

## B. Distribution and local dev

`git subtree add --prefix=lib https://github.com/KakkoiDev/tmux-toolkit.git main --squash` in each plugin. **Subtree, not submodule**: a submodule ships an empty `lib/` on plain `git clone` and TPM does not `--recurse-submodules`.

The failure that must never happen is *a hook that cannot find its library*. Claude invokes `tmux-agent-tracker hook X` from `settings.json` with no tmux context at all. Vendoring makes resolution `$(dirname "${BASH_SOURCE[0]}")/../lib/toolkit.sh`: zero search, zero env, zero ordering.

**Local iteration (answers "do I re-install on every update?", and the answer is no):** all five load from `~/Code/*` via `run-shell`, so the working tree *is* the installed copy. Each loader resolves `lib/` from `$TMUX_TOOLKIT_DEV` when set, else its vendored copy. Set `TMUX_TOOLKIT_DEV=~/Code/tmux-toolkit` once, and one lib edit is live in all five after `prefix+r`. No syncing while iterating.

**Publishing:** `make fanout` in tmux-toolkit loops `consumers.txt` and per consumer runs `git subtree pull --prefix=lib --squash`, regenerates `lib/.checksum`, runs that plugin's bats suite, commits `chore: sync tmux-toolkit vN`, and stops on the first red. One command, five commits.

**Guards:** `lib/VERSION` (semver) checked by `tk_require_version <min>` at source time. `lib/.checksum` equals `find lib -name '*.sh' | sort | xargs shasum | shasum`, verified by `make sync-check` in each plugin's CI. **That checksum is what stops "I edited lib/ inside the plugin" drift, which is exactly how 26 duplicates formed.** CI never sets `TMUX_TOOLKIT_DEV`. `tmux-toolkit doctor` prints the `lib/VERSION` found under each consumer so drift is seen rather than inferred.

Prerequisites: `tmux-session-order` must become a git repo (D-0), and `tmux-worktree` needs an `install.sh`/`uninstall.sh` since it has none.

## C. Agent identity

One TSV line per agent from `tk_identity_list`:

```
agent_id "<harness>:<session_id>" | harness | session_id | pid | tty | pane_id | target |
cwd | project | branch | name | liveness live|dead | activity busy|idle|blocked|unknown |
waiting_for | kind interactive|background | host (reserved "") | source registry|scan|hook |
observed_at | enrich k=v;k=v
```

**Providers, strict precedence for liveness and activity:**

1. `tk_identity_provider_claude`: `claude agents --json`. Authoritative for Claude. `status` maps 1:1, so `busy` to busy, `idle` to idle, `blocked` to blocked plus `waitingFor`.
2. `tk_identity_provider_ps`: the `ps -eo ppid,comm` child walk for codex/gemini/pi/antigravity/deer, **plus** Claude instances the registry cannot see (sandbox, containers). Liveness only, with `activity=unknown` unless a hook sharpened it. Required because of V3.
3. **Hooks are enrichment only.** They may add `enrich` fields and *sharpen* activity (`PermissionRequest` and `Notification(permission_prompt|elicitation_dialog)` to blocked; `UserPromptSubmit` to busy). They may **never** create a row, delete a row, or assert liveness. Rationale: V1 (registry 7 vs hooks 4) plus the documented fact that hooks are observers.

**The join, 3 processes total and independent of agent count** (V2): `A = claude agents --json` (pid, sessionId, cwd, status, name, kind); `B = ps -eo pid,tty`; `C = tmux list-panes -a -F '#{pane_tty} #{pane_id} #{session_name}:#{window_index}.#{pane_index}'`. Then join A to B on pid to get tty, and join to C on tty (stripping `/dev/`) to get pane_id and target.

**Join-failure policy, four distinct cases:**
1. `kind:"background"`, no tty: emit with empty `pane_id`/`target` and `liveness=live`. It counts in the badge; its menu row gets a label and an **empty command** (the tracker already has that branch). Never synthesize a pane.
2. pid alive, tty resolves, but no pane owns that tty (plain terminal, or a nested tmux whose panes live on another server): second chance, walk the pid's ancestors via `ps -eo pid,ppid` looking for one that *is* some `#{pane_pid}` in C. If that also fails, empty `pane_id`, `enrich outside_tmux=1`, and **stop guessing**.
3. tty is `??`: same as case 1.
4. Registry lists a pid `ps` does not have: **drop the row**. The daemon roster can be stale; `ps` is the tiebreak.

Remote/ssh is out of scope for v1. `host` exists as `""` so the record shape does not churn later.

**Cache:** `$TK_STATE/identity.tsv` where `TK_STATE=${XDG_STATE_HOME:-$HOME/.local/state}/tmux-toolkit`, plus `.meta` holding `epoch<TAB>tmux_server_pid`. **TTL 2s** (`@toolkit-identity-ttl`): producers cost 3 forks, and consumers are the status engine (1x per interval), the menu (1x per keypress), and the resumer's guard (1x per tick), so 2s dedupes one refresh hit by three plugins without ever displaying stale liveness. Staleness has three independent signals: mtime older than TTL; `.meta` server pid differing from `#{pid}` now, which **hard invalidates** because a server restart invalidates every `%N`; and a `pane-exited` hook touching `identity.dirty`. Rebuild under `tk_lock identity 10`, and a lock loser uses the stale file, because **status rendering must never block**.

**A hook never triggers a rebuild.** `tk_identity_enrich <agent_id> <k=v>...` is one `printf >>` to `$TK_STATE/enrich/<agent_id>`: no sqlite, no lock, no tmux call. That is why hook latency stops mattering. Today one hook costs `_ensure_schema` plus `_load_config_fast` plus 3-5 `sql` calls plus `display-message` plus `refresh-client`.

**sqlite: keep it, shrink it, make it non-authoritative.** Moves to `identity.tsv` because it is recomputable in 3 forks: liveness, activity, pane_id, target, cwd, project, branch, name, pid, tty. Stays in sqlite because it is history or derived state that cannot be recomputed: `transitions(session_id, from, to, at)`, `prompt_summary`, `task_count`, `subagent_count`, `parent_session_id`, and the `completed` bookkeeping. Rename `sessions` to `agent_state` so nothing keys on the old name by accident. The resumer keeps its own `limited` table, which is genuine queue state.

**State mapping:** `working` maps to `busy`, `idle` to `idle`, and `blocked` to registry `blocked` plus `waitingFor` (registry wins; a hook may set it when the registry says idle *and* the hook event is newer than `observed_at`). **`completed` has no registry equivalent**, so derive it plugin-locally as `activity==idle AND there exists a Stop/TaskCompleted enrich event newer than last_focus_at(pane)`, cleared by `pane-focus`. It is a UI notion ("finished since you last looked") and belongs in the tracker, not the library. `kind:"background"` renders as `bg` with no jump action.

**Kill the `DROP TABLE`** (V11): use `CREATE TABLE IF NOT EXISTS` plus the existing `.schema_v2..v4` marker ladder; for the CHECK-constraint change that motivated the drop, use the standard sqlite 12-step rename/create/insert/drop behind `.schema_v5`; and for the *actual* safety it provided (pane ids are meaningless across a server restart), on load compare the recorded tmux pid and `UPDATE agent_state SET tmux_pane='', tmux_target=''`. Same protection, zero data loss.

**Delete the resumer's cross-repo reads** (`resumer.sh:481-495,520-561,899`, `TRACKER_DB:33`, and the doctor line at `:1050`). The coupling is **6 columns**, not 4. Replace with `tmux-toolkit identity --json --harness claude --activity busy`. The resumer gets *more* correct at the same time, because it starts seeing the 3 sessions the tracker's DB misses.

## D. Migration sequence

**D-0 through D-7 are behavior-preserving. D-8 onward are behavior changes needing human re-verification.** Each step is independently shippable. Test tiers T1-T4 are defined in section E.

| Step | Repo(s) | Change | Verify | Regression risk |
|---|---|---|---|---|
| **D-0** | session-order, worktree | `git init` and publish session-order with CI; give worktree an install/uninstall | CI green | none |
| **D-0.5** | machine, not a repo | `brew upgrade tmux` to **3.7b**, then restart the tmux server. Independent of everything else | `tmux -V` reports 3.7b; re-run the section G item 2 smoke on the new server | **a server restart kills every session.** Do it when no agent is mid-task, and expect `%N` pane ids to be renumbered from `%0`, which is exactly the case D-9's pane-invalidation handles. Old clients cannot attach across the protocol change, so detach everything first |
| **D-1** | toolkit | create the repo: `core tmux opt version log json sqlite` plus tests | T1 on ubuntu and macos; `shellcheck -S warning`; a `/bin/bash -n` 3.2 gate | none |
| **D-2** | all 5 | `subtree add lib/`; `helpers.sh` becomes a shim (`get_tmux_option(){ tk_opt "$@"; }` and friends); add `make sync-check` | **each repo's existing suite, unchanged, must pass**. Mesh's 318 tests are the canary | mesh's `source_mesh_functions` awk strips `/^source /`, so a sourcing shim vanishes in-process. One-line fix in `tests/helpers.bash` |
| **D-3** | tracker, resumer, mesh, worktree | config loaders become `tk_config_load` spec lists | T2: set real `@ns-*` on a private socket, assert loaded values and cache contents, plus an apostrophe round-trip | a mis-escaped value breaks every hook via `source` under `set -euo pipefail`, mitigated by mesh's `bash -n` validation. **Technically a behavior change for the tracker**: options now take effect within 60s where previously never |
| **D-4** | session-order, then mesh, then tracker, then **worktree last** | menus become `tk_menu_*`; worktree's 10 awk scripts emit TSV only | T1 with `TK_MENU_DRYRUN=1` asserting the exact arg vector; **T3** for worktree's main menu and the tracker's agent menu | highest. Worktree's 6 screens have hand-tuned quoting for branch names containing `/`. **Human re-verify:** open all 6 screens, filter with a pattern containing a space and a `'`, switch to a branch whose path contains a space |
| **D-5** | the 4 hook-setting repos | `tk_hook_add` plus install-time name validation; silently fixes V5 | T2: set a decoy hook, load the plugin, assert both survive and a reload adds no duplicate; assert a bogus name returns non-zero | `-ga` where `-g` was means stale duplicates accumulate if the command string changes. Mitigate with `tk_hook_remove <name> <script-dir>` before add |
| **D-6** | tracker, resumer, mesh | `tk_target_*`, `tk_pane_*`, `tk_fmt`; echo-back guard everywhere; `-f` filters replace `\| grep -qx` | T2: register against a real pane, kill it, assert the stored target is `""` and not `":."` | `tk_pane_alive ""` differs from `grep -qx ""`, so assert the empty case |
| **D-7** | all | `tk_lock`, `tk_notify`, and `tk_sql_*` with an explicit db | existing suites, plus assert a stale lock with a dead pid is stolen **immediately** rather than after 120s | retires mesh's 4 env-leak tests as obsolete |
| | | **the library has now landed with no behavior change** | | |
| **D-8** | mesh | `pane-died` becomes `pane-exited` (V4) | T2: register on a pane running `sleep 100`, `kill-pane`, assert the row is gone. **That test cannot pass today**, which is why the bug survived 318 tests | `pane-exited` fires on every pane close server-wide, making `mesh.sh cleanup`'s full `list-panes -a` prune hot. Debounce with `tk_config_fresh mesh-cleanup 2` and **measure before shipping** |
| **D-9** | tracker | kill `DROP TABLE`; add the `.schema_v5` ladder and pane-invalidation on tmux-pid change (V11) | T2: insert a row, run `init` twice, assert survival; assert a changed tmux pid blanks `tmux_pane` but keeps `prompt_summary` | an old DB retains the old CHECK constraint, so the ladder must run before the first insert. **Human re-verify:** `prefix+r` with 4 live agents, and the badge must not reset |
| **D-10** | toolkit, tracker, resumer | fix the `_has_agent_child` drift (V13): Linux 5 names to 8, and collapse both branches to the single `ps -eo ppid,comm \| awk` form | T1 with a stubbed `ps` per name under `uname` stubs for Darwin **and** Linux; assert a name longer than 15 chars, since `comm` truncation differs BSD vs GNU | none |
| **D-11** | mesh | fix the vacuous test (V12): `^` becomes `^ *` and it also scans `agent-mesh.tmux`; delete the dead `ITEMS_PER_PAGE`/`KEY_NEXT`/`KEY_PREV` | the fixed test must **fail on the current tree** and pass after the deletion | the real defect is a loop silently iterating zero times, so add a non-empty guard and apply it to the sibling generative tests (`isolation.bats:34,65`, `pi.bats:299,326`) |
| **D-12** | resumer | the missing `refresh-client -S` (V14), which arrives free via `tk_status_set` | T2: attach a client, run `refresh`, assert the option is set and that `refresh-client -S` was issued | **Human re-verify:** trip the credit guard and the badge should appear immediately instead of up to 15s later |
| **D-13** | resumer, tracker | `run-shell -b -d N` replaces `sleep N &&` (V7) | T2 with `-d 1` and a 2s poll; T1 gate test that `! tk_vers_ge 3.2` takes the sleep path | none new. A `-d` timer dies with the server exactly as a `sleep` child does |
| **D-14** | tracker, resumer, mesh | one status engine: `#{E:@ns-status}` plus a single `#(tmux-toolkit tick)`, plus a manual cleanup of the accumulated `~/.tmux.conf` string | T2: load all three in all **6** orders and assert exactly one `#(`, three `#{E:@`, and no duplicates after reload | tmux-continuum's `#()` is **not ours** and must survive. **Human re-verify:** reload, look at the bar, confirm continuum still saves |
| **D-15** | toolkit, tracker, resumer, mesh | registry-based identity (section C) | T1 with a stubbed `claude` fixture, stubbed `ps`, and a real private server for the pane list, asserting **all four** join-failure cases. One live test against real `claude agents --json`, skipped unless `TK_LIVE=1` | **the badge goes from 4 to 7.** Confirm that is desired before shipping (open item 1) |
| **D-16** | resumer | `StopFailure` with matcher `rate_limit` replaces transcript scraping; delete `_detect_limit_line` and `_transcript_for` | T1 piping a fixture payload into `resumer.sh hook StopFailure` and asserting a `limited` row | unverifiable without a real 429. Keep the transcript detector behind `@agent-resumer-transcript-fallback` (default `off`) for one release and **log when it would have fired but the hook did not**, which is the reconciliation signal |
| **D-17** | resumer (mesh benefits) | `SessionStart.initialUserMessage` for the *restart* resume path (`claude --session-id <uuid> -n <name>`), with zero keystrokes | launch a scratch session with the hook and assert the first turn carries the prompt | **Scope honestly: this does not remove `send-keys`.** Waking an already-idle interactive pane still has no other mechanism (#44380) |
| **D-18** | all, worst in worktree | `#{q:}` at every generated-command boundary | T2 with a repo path and a branch name containing a space and a `'` | `#{q:}` quotes for `sh`, so it must **not** be applied to strings tmux re-parses as a tmux command. Assert both layers |
| **D-19** | mesh | delete `internal/store`, `go.mod`, `go.sum`, and the `go` CI job (V15); move the channels-model rationale and the `host` column idea into `ROADMAP.md` | CI green without the go job | keeping it costs a Go toolchain in CI and 1664 lines the next reader will treat as authoritative, and if anyone wired it up it would corrupt the live `mesh.db` |
| **D-20** | session-order | rewrite: order stored in `set -t <sess> @so-order N`, sorted menu, and `cmd_reset` becomes a one-time prefix-stripping migration | T1 dry-run arg vector; T2 assert the option survives a `rename-session` | until this lands, session-order should not be loaded alongside tracker/mesh |
| **D-21 (spike, optional, no dependents)** | toolkit only | Build tmux master into `~/.local/bin/tmux-next` (**not** `brew install --HEAD`, which relinks over stable) and answer three questions on a private socket: does `set-hook -B` scope globally or inherit `refresh-client -B`'s attached-session scoping? does `-B` with a `#{C/r:}` content format fire reliably per pane with `%*`? what does `wait-for -v` report as the payload keys? Then implement `tk_watch`'s 3.8 branch behind `tk_vers_ge 3.8` | T2 against `tmux-next -L spike`, skipped unless `TK_NEXT=1`. Nothing in the default suite may depend on it | none, by construction: the daily-driver server is never touched and no plugin requires the branch. **If the scoping answer is "client-scoped", the 3.8 monitor-hook idea is dead for our use and the spike has paid for itself** |

## E. Test strategy

Four incompatible tmux stubs exist today: `export -f tmux` with a UI allowlist (`worktree/tests/test_helper.bash:31`); a fake binary on PATH (`mesh/tests/config.bats:26`); real tmux on a private socket behind a PATH wrapper injecting `-L` (`mesh/tests/helpers.bash`); and in-process `tmux(){ return 1; }`.

**Canonical stub for the library: the fake binary on PATH, and it *is* the recording wrapper.** The library's only tmux entry point is `tk_tmux`, and a fake binary is the only stub that survives into subprocesses (`run-shell` handlers, `bin/tmux-toolkit`, the `#()` engine), which `export -f` does not do reliably across bash/`sh` combinations. `tests/stub/tmux` appends its full argv to `$TK_STUB_LOG` and answers from `$TK_STUB_FIXTURE`, a file of `pattern<TAB>stdout<TAB>exit` lines. Every assertion is then either "the log contains this argv" or "the function returned this value".

- **T1 unit:** bats, fake tmux, no server. `tk_opt`, `tk_vers_ge` (fixtures `3.0`, `3.2`, `3.5a`, `3.10`, `next-3.8`), `tk_sql_esc`, `tk_json*`, `tk_target_split`, `tk_menu_*` under dry-run, `tk_hook_add` guard logic, and the identity join. Must run on macOS `/bin/bash` 3.2. This is the bulk.
- **T2 integration:** bats, real tmux, `tmux -f /dev/null -L tk-test-$$-$BATS_TEST_NUMBER`. Anything whose correctness *is* tmux's behavior: option round-trip including empty-vs-unset, `#{?}`, `#{E:}`, `#{q:}`, `#{C/r:}`, `-f`, hook add/remove/idempotence and the validator, `run-shell -d`, `refresh-client -S`, dead-pane echo-back, and `status-right` composition in all load orders. `-f /dev/null` is mandatory, plus a `_keepalive` second session (worktree's trick) so the server cannot die mid-file.
- **T3 client/overlay:** bats plus `expect` plus nested tmux. The only tier that can assert a *rendered* menu, because `display-menu` and `display-popup` are client overlays that `capture-pane` cannot see. Reuse `worktree/tests/expect_helper.bash` and `fixtures/expect_menu.exp` verbatim: outer server, inner client in a pane, `expect` drives the pty, and `capture-pane` reads the **outer** pane. Scope is 1-2 smoke tests per screen (title, row count, Quit row, arrow plus Enter selects the right row). Never the full matrix, which is slow and flaky by nature.
- **T4 contract/generative:** the class mesh invented and then broke (V12). **Two mandatory rules:** every generative test asserts its extracted list is non-empty before looping, and the extraction pattern is itself tested against a fixture holding a known-positive and a known-negative line. Instances: every `tk_*` appears in the README API table; every `@toolkit-*` option is read somewhere; **`send-keys` appears nowhere in `lib/`**.

**Assertions:** vendor `mesh/tests/helpers.bash`'s assertion set as `tmux-toolkit/tests/assert.bash`. Its own comment is load-bearing: on bash 3.2 a bare `[[ ]]` or `! cmd` that is not the last statement does **not** trip `set -e` or the ERR trap, and 227 mesh tests were green while one asserted a value the code never wrote. **Every assertion must be a function call.** With five suites sourcing this library, that is the single highest-leverage test decision here.

**CI matrix:** `ubuntu-latest` times tmux {3.2, 3.4, 3.5a, latest} built from source (lift `worktree/.github/workflows/test.yml`, which already does this) times bash 5; plus `macos-latest` times system tmux times **explicitly `/bin/bash` 3.2**, because bats on macOS may pick brew's bash 5 and defeat the point, so pin it. T3 on ubuntu only. `shellcheck -S warning` over all of `lib/` with `# shellcheck shell=bash` headers, since these are sourced fragments.

## F. Non-goals

- **Rewriting the core in Go or Rust: no.** A static binary would actually be *faster* per invocation than sourcing bash, but the plugins' value is that they are `run-shell`-able text you can read and patch in place; a compiled artifact means a build step or per-platform release assets and a "did you `make`?" failure mode in `~/.tmux.conf`. Every binding shells out to `tmux` anyway, so the win is process startup only. If startup ever measurably hurts, replace **just** `tmux-toolkit tick` and `identity` with one Go binary and keep the library in bash.
- **libtmux: no.** Pre-1.0 with an API the maintainers say will churn through 2026, plus ~40ms of Python per hook. The resumer already pays that three times, and that is a wart to delete via `tk_json_path`, not a pattern to extend.
- **Vendoring jaclu/tmux-menus: no.** Steal exactly two ideas and cite them: bulk `show-options -g | grep ^@ns` into a builtin-scanned cache, and memoized version compare with good/bad lists. Do not adopt its architecture, which is POSIX sh with an assign-by-varname calling convention, a `D_TM_BASE_PATH`-rooted sourcing scheme, and its own menu DSL. It is a menu framework, not a plugin library, and `eval "$varname=..."` is a bash-3.2 footgun with five callers.
- **A control-mode (`tmux -CC`) daemon: no, not now.** It would give real push events and `%output`-based pane watching, but it is a long-lived process to supervise, restart, and reconcile after a server restart, and it duplicates what 3.8's `set-hook -B` and `wait-for -E` do natively. Building it now means maintaining it *and then* migrating off it. Revisit only if the 2s identity cache proves insufficient in practice.
- **Requiring or waiting for tmux 3.8: no.** Full reasoning is in the version-policy table above. Short form: it is unreleased with no RC, it is only reachable by building git master, its headline win is content scraping that D-15 already beats with an official API, and `tmux-worktree`'s 24 users cannot be asked to build a multiplexer from source. Design for it (`tk_watch`, one gate), spike it in isolation (D-21), ship on 3.7b. **Do upgrade to 3.7b (D-0.5)**, which is a different question and has no downside beyond one scheduled server restart.
- Also not doing: a plugin-manager abstraction (TPM has no dependency mechanism and will not get one); `tmux-plugins/tmux-test` (dead since 2019, Vagrant plus Travis); any coordination protocol with tmux-continuum or third-party plugins, since we can be *polite* to `status-right` without being coordinated.

## G. Verification, end to end

1. **Per step:** the tier named in the D table. D-2's gate is that all five existing suites pass **unchanged**, which is the definition of behavior-preserving.
2. **Cross-plugin smoke, run after D-7 and again after D-14 and D-15**, on a private socket with all five loaded in each of the 6 relevant orders: `status-right` has exactly one `#(` and N `#{E:@`; continuum's segment survives; `prefix+r` twice adds no duplicate hooks and no duplicate status segments; `tmux show-hooks -g` shows one entry per plugin per event.
3. **Live identity check, the headline number:** `tmux-toolkit identity --json | jq length` must equal `claude agents --json | jq length` for Claude-harness rows, and every row with a non-empty `pane_id` must resolve via `tmux display-message -t <pane> -p '#{pane_id}'`. Today the equivalent comparison is 4 vs 7.
4. **Bug-fix regression tests, each of which must fail on the pre-fix commit:** D-8 (kill a mesh-registered pane, row gone), D-9 (`init` twice, row survives), D-11 (the fixed generative test), D-12 (`refresh-client -S` present in the stub log), D-6 (dead pane yields `""` not `":."`).
5. **Human re-verify checklist**, covering the steps that change what you see: D-4 all 6 worktree screens including a space-and-quote filter and a space-containing path; D-9 `prefix+r` with live agents and the badge must not reset; D-12 credit-guard badge latency; D-14 the bar after reload; D-15 the badge count change.

## H. Open items

1. **D-15 blocker:** the badge goes from 4 to 7. Are all 7 badge-worthy, or should `kind:"background"` and subagent-spawned sessions be filtered out? Product decision, and it must be answered before D-15 ships.
2. **`pane-exited` cost** (D-8) needs a measurement rather than an assumption, since it fires on every pane close server-wide.
3. **Sandbox (deer/deerbox):** the tracker's `_SANDBOX` mode (write probe, `/tmp` DB, `_tmux` no-op, `cmd_merge_sandbox`'s `ATTACH`) is real complexity on the hot path. Does the identity provider need a sandbox path at all, given the host-side `ps` provider already sees the process? Decide before D-15, because it determines whether `tk_tmux`'s no-op mode is a library concern or stays tracker-local.
4. **Who owns `status-interval`?** Today the tracker lowers it to 60 unless already lower. With one engine, the engine should own it and the per-plugin interval options become advisory.
5. **`XDG_STATE_HOME` migration:** moving from `~/.tmux-agent-*/` to `~/.local/state/tmux-toolkit/` is user-visible, and the tracker already carries one legacy-dir migration. Do it **once, in D-15, or not at all**, because two migrations is worse than a bad path.
6. **The `send-keys` boundary:** the resumer's typing path is the only way to wake an idle interactive pane and it is inherently unsafe. Does `@agent-resumer-enabled` stay `off` forever? If #44380 is fixed upstream the whole path can be deleted, which is worth watching but not worth waiting for. Separately, adopt firstmate's three-state composer verdict (`empty`, `pending`, **`unknown`**), since we currently lack `unknown`, the state that protects a user who dropped to a shell in that pane.
7. **`worktree`'s adopter versus `session-order`'s normalizer:** both rename sessions. D-20 removes the conflict, but until then do not load both.
8. **When to take the 3.7b server restart** (D-0.5). It is the only step that costs you live sessions, and it should happen before D-9 so that D-9's pane-invalidation logic is written against renumbered pane ids you have actually seen.
9. **Is the D-21 spike worth doing at all now?** It only pays off for codex/gemini/pi busy-state, and only if `set-hook -B` turns out to be globally scoped. Defer it until at least one non-Claude harness is actually in daily use, because Claude is covered by the registry and scraping the others buys nothing today.
