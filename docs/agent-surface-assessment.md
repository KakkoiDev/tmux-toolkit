# Assessment: an agent-facing surface over the tmux toolkit

Requested: a report on how firstmate works, and an assessment of building a
firstmate-like layer on tmux-toolkit that can reach every worktree, spin them up
on demand, inspect and restart the agents in them, and talk to them. No
implementation.

Written 2026-07-29. Every claim about an external project was fetched, and the
URL is cited. Every claim about our own repos was read from the source.

---

## 0. Two corrections first

**"Axie" does not exist.** The project is **AXI**, "Agent eXperience Interface"
([axi.md](https://axi.md/),
[github.com/kunchenguid/axi](https://github.com/kunchenguid/axi), TS, MIT, 1,675
stars, pushed 2026-07-29). It is not a tmux tool. It is a spec of ten principles
for CLIs that agents shell out to, plus a benchmark. That is *more* relevant to
what you asked for than a tmux tool would have been, because it answers the
interface question directly. A GitHub search for `axie + agent + tmux` returns
zero repos; everything under that spelling is the crypto game.

**The worktree layer you object to is `treehouse`**
([github.com/kunchenguid/treehouse](https://github.com/kunchenguid/treehouse),
Go, worktree pool with leases). Your objection is correct on the facts:
firstmate does not merely suggest it, it is wired in. `bin/fm-spawn.sh:1242`
literally types the string `treehouse get` into the new pane and then polls for
the pane's cwd to move off the project root (`:1244-1284`); `bin/fm-teardown.sh`
calls `treehouse return` with its own lock-retry logic; there is a
`bin/fm-install-treehouse.sh`. There is no documented plugin point for a
different worktree provider.

But the coupling is **shallow in mechanism even though it is hard in code**. The
contract firstmate actually depends on is two steps: "run a command that leaves
this pane inside a fresh worktree" and "detect that the cwd changed". Anything
that cd's into a worktree satisfies it, and `fm-spawn.sh` already carries a
second, different path for Orca-managed worktrees. So this is swappable at
roughly one function. It is not a reason to reject firstmate. The reasons to
reject firstmate are in section 3.

---

## 1. How firstmate works

Sources: [README](https://github.com/kunchenguid/firstmate),
[AGENTS.md](https://raw.githubusercontent.com/kunchenguid/firstmate/main/AGENTS.md),
[docs/tmux-backend.md](https://raw.githubusercontent.com/kunchenguid/firstmate/main/docs/tmux-backend.md),
and the `bin/` and `docs/` listings.

### What it is, in its own words

"firstmate is not a model, not a harness, not a skill, not an MCP server, and not
a CLI. firstmate is an **agent distro**." A cloned repo *is* the product: an
`AGENTS.md` operating contract, bundled skills, and helper scripts. You launch a
harness inside the clone and that instance becomes "the first mate"; you are "the
captain".

### The shape

| Layer | What it is |
|---|---|
| **Contract** | `AGENTS.md` (also symlinked as `CLAUDE.md`). A very long prose specification: hard rules in priority order, layout, state conventions, escalation style. This is the actual product. |
| **Roles** | One *first mate* talks to you. *Crewmates* are spawned per task, work in their own worktree and their own tmux window, and are forbidden from addressing you directly. Optional *secondmates* are persistent crewmates with their own isolated `FM_HOME`. |
| **Backends** | tmux is the verified reference. herdr, zellij, orca, cmux are experimental. Selected by `config/backend`, else auto-detected, else tmux. |
| **State** | All on disk. `data/` durable (backlog, per-task briefs, reports, captain preferences, learnings), `state/` volatile (`<id>.status` append-only wake events, `<id>.meta`, `<id>.turn-ended`, watcher internals, locks), `config/` local choices, `projects/` read-only clones. |
| **Supervision** | A bash watcher sleeps on the fleet and wakes the first mate only when something needs a human. Claude Code uses a tracked Stop hook to re-arm it; Grok uses background-notify; Pi uses an extension. Plus a turn-end backstop that blocks a "blind stop" while work is under way. |
| **Task shapes** | *ship* tasks deliver authorized changes. *scout* tasks produce a standalone report and their worktree is declared scratch. |
| **Merge authority** | Per project: `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` autonomy flag. Never merges without explicit approval. |

### The hard rules that make it safe

Verbatim in substance from `AGENTS.md` section 1:

1. **Never write to a project.** The first mate is read-only over `projects/`;
   crewmates make every change. Narrow guarded exceptions (init, fleet sync,
   self-update, approved local merges) each owned by a named script.
2. **Never merge a PR without explicit approval.**
3. **Never tear down unlanded work.** `fm-teardown.sh` owns the landed-work test;
   `--force` requires explicit authorization.
4. **Crewmates never address the captain.** All communication flows through the
   first mate.
5. **Report outcomes faithfully.** If work failed, say so with the evidence.

### The tmux mechanics worth stealing

Three scripts, and they are the transferable part:

- `bin/fm-peek.sh` (892 bytes) reads a **bounded tail** of a task's output so the
  supervisor can look without attaching.
- `bin/fm-send.sh` (14 KB) steers a recorded endpoint, and **fails closed unless
  `FM_HOME` is explicit** so a steer cannot resolve against the wrong home.
- `bin/fm-composer-lib.sh` (11.6 KB) owns type-and-submit. It types the message
  **once**, then retries **Enter only** until the composer clears. Its rule:
  *only a proven empty composer is a positive delivery acknowledgement*. An
  ambiguous state is reported as a failure rather than retyped.

Plus a liveness probe that reads `#{pane_current_command}` and classifies
harness processes as alive and shells as dead, so a prompt is never typed into
bash. Note for us: **that probe does not work for Claude Code on this machine.**
`#{pane_current_command}` for a Claude pane here is literally `2.1.220`, because
claude rewrites argv[0] to its version. A `comm`-based child-process walk is the
only reliable route (verified; recorded as V3 in the migration plan).

### The size, which is the point

`bin/` holds **90 scripts**. Sizes are not incidental:

| Script | Size |
|---|---|
| `fm-fleet-snapshot.sh` | 68 KB |
| `fm-config-inherit-lib.sh` | 44 KB |
| `fm-backend.sh` | 43 KB |
| `fm-pr-check-migrate.sh` | 43 KB |
| `fm-pending-reply-lib.sh` | 40 KB |
| `fm-arm-command-policy.mjs` | 38 KB |

Roughly 700 KB of shell, plus 28 docs, plus an `AGENTS.md` that is itself a
substantial specification. There are scripts for X/Twitter mention handling, a
wedge alarm, Pi "calm mode" presentation preferences, GitLab merge watching, and
a PR-check migration with quarantine.

**This is not a lean system, and it is not trying to be.** It is one person's
full-time orchestration product. That matters for your ask.

---

## 2. What you already have

Before designing anything, here is your existing surface against the four
capabilities you named. This is the part that changes the recommendation.

| You asked for | Status today | Where |
|---|---|---|
| Access all the worktrees | **Built.** One worktree per branch mapped 1:1 to a tmux session, six menu screens, adopt-on-create hook, recent-branch ordering, stale sweep. | `tmux-worktree` |
| Spin them up on demand | **Built, and better than you may realise.** `tmux-agent-mesh dispatch --worktree <branch> --task "..."` creates the worktree at `~/.tmux-worktree/<project>/<branch>`, opens a pane or window there, launches the harness with the task on argv, and records it for claim-on-start. | `mesh.sh:1271-1331` |
| Inspect all the agents working there | **Built twice, and the better one is not ours.** `tmux-agent-tracker` tracks state via hooks into sqlite. But `claude agents --json` is authoritative and more accurate: measured 7 live sessions vs the tracker's 4 rows. | tracker; `claude` 2.1.220 |
| Have a chat with them | **Built, with a known ceiling.** `tmux-agent-mesh` delivers agent-to-agent mail through the recipient's own hook stdout. | `tmux-agent-mesh` |
| Restart them | **Not built.** The nearest thing is `tmux-agent-resumer`, which types a resume prompt after a 429. | gap |

Two findings inside that table deserve emphasis.

**The composite call the field is missing, you have.** The prior-art sweep found
that nobody ships "create a worktree, open a session, launch an agent in it" as
one call. worktrunk does not. gwq does not. treehouse does not (no tmux
integration at all, despite the same author as firstmate). `mesh dispatch
--worktree` does. It is undocumented as an agent-facing capability, which is why
it does not feel like it exists.

**It is also duplication item 27.** `mesh dispatch` reimplements
`~/.tmux-worktree/<project>/<branch>` and `git worktree add` inline, which is
`tmux-worktree`'s job. Same path convention, second implementation. That is
exactly the class of overlap this whole toolkit effort exists to remove.

**The chat ceiling is upstream and not fixable by us.** Mail reaches an agent
that is *working* (its hook continues the turn) but not one sitting *idle*.
Claude Code's docs state plainly that "hooks cannot initiate new turns", and
Channels, the official push mechanism, has an open bug
([#44380](https://github.com/anthropics/claude-code/issues/44380), still open
2026-07-26) where events do not wake an idle session. So `send-keys` remains the
only way to start a turn in an idle interactive pane. Any "chat with them"
feature inherits that, and any "restart them" feature is *built on it*.

---

## 3. The assessment

### Do not build a firstmate

You already have roughly 70% of firstmate's useful surface, spread across four
plugins. What you are missing is not a supervision framework. It is:

1. **A single agent-facing command surface** over the four plugins you own.
2. **Respawn/restart**, which does not exist anywhere in your stack.
3. **Supervision and escalation**, which is the only place firstmate's design is
   genuinely ahead of yours.

Building a firstmate means signing up for items 3 plus the 90-script apparatus
around it. Building items 1 and 2 is a few hundred lines on top of what exists.

The parts of firstmate actually worth copying are narrow and none of them require
adopting it:

- The type-once/retry-Enter-only delivery discipline and "only a proven empty
  composer counts as delivered".
- The three-state composer verdict, `empty` / `pending` / **`unknown`**. We
  currently lack `unknown`, which is the state that protects a user who dropped
  to a shell in that pane.
- The bounded-tail read instead of a full scrollback dump.
- The zero-token event-driven watcher instead of a polling loop.
- The "one liaison" model: crewmates never address the human directly.

### The `AGENTS.md` insight, which is the real lesson

firstmate's product is a **prose contract**, not code. The 90 scripts are
plumbing for a specification that lives in `AGENTS.md`. That is worth internalising
because it means the hard part of what you want is not something tmux-toolkit can
give you. tmux-toolkit gives you correct primitives. The behaviour ("never write
to a project", "escalate only real decisions", "report failure with evidence") is
a skill artifact, and it is where the leverage is.

---

## 4. On "GitHub plumbing, machine-readable, not menus"

Your framing is right, it has a name, and there is a benchmark.

### The name is AXI, and the evidence favours your instinct

AXI's ten principles, condensed
([SKILL.md](https://raw.githubusercontent.com/kunchenguid/axi/main/.agents/skills/axi/SKILL.md)):
token-oriented output; 3 to 4 fields per list item with `--fields` to widen;
truncate long text with a size hint and a `--full` escape; pre-computed
aggregates; **definitive empty states** so the agent does not retry with
different flags; structured errors on **stdout** with exit 0/1/2 and loud failure
on unknown flags listing the valid ones; **ambient context via session hooks**,
with the skill as the secondary discovery path; bare invocation prints live state
rather than `--help`; every output ends with 2 to 3 next-step command templates
using placeholders; consistent per-subcommand `--help`.

Their benchmark
([STUDY.md](https://raw.githubusercontent.com/kunchenguid/axi/main/bench-github/published-results/STUDY.md),
17 tasks x 5 repeats = 425 runs):

| Condition | Success | $/task | Input tokens |
|---|---|---|---|
| AXI-style CLI | **100%** | **$0.050** | 46K |
| raw CLI (`gh`) | 86% | $0.054 | 47K |
| MCP (eager) | 87% | $0.148 | 137-176K |
| MCP (ToolSearch) | 82% | $0.147 | 137-176K |

Caveat honestly: this is vendor-authored, and the author's tool is both subject
and judge. But the mechanism is real and independently checkable, because an MCP
server pays for every tool's JSON Schema in the system prompt on every turn
whether used or not. The ToolSearch row is the interesting one: lazy loading
scores *worst*, because per-task discovery turns cost more than the schema they
save.

**Conclusion: CLI plus a skill, not an MCP server.** Also relevant, and
decisive on its own: agents already have `tmux` through the Bash tool, so a CLI
needs no install ceremony, no `mcp add`, no restart, and works identically in
Claude Code, Codex, OpenCode and a plain shell script.

### Where I disagree with you

**"All the tmux commands usable by the agents" is the wrong target, and your own
word "lean" is the right one.** Those two sentences point in opposite directions,
so here is the evidence for the second one.

The exhaustive approach exists and has been built twice.
[bnomei/tmux-mcp](https://github.com/bnomei/tmux-mcp) exposes ~70 tools,
including 18 separate tools for individual keys. `tmux-python/libtmux-mcp`
exposes ~60. Those are the projects the benchmark above measures as costing 2.9x
the tokens and scoring *lower*. A thin passthrough over all of tmux adds nothing
an agent cannot already do with Bash, and charges rent for it.

The wrapper earns its place only where it prevents a specific failure. The ones
attested by real projects:

| Failure | Prevented by |
|---|---|
| Quoting and literal-send bugs; agents forget `send-keys -l --` | taking text as one argument and handling it once |
| **The type-then-submit race.** `send-keys "text" Enter` in one call often submits before the composer ingested the text, or twice. | separate `send` and `submit`; type once, retry Enter only |
| Target resolution: `%3` vs `main:0.1` vs `2` vs a name, `base-index` differences | labels resolved internally |
| Typing into a busy pane, where input queues invisibly or interleaves | liveness plus composer-state check before writing |
| Blind writes | a **read-before-write guard**: writing fails until the agent has read that pane |
| Killing your own pane, or the human's session | knowing self-identity and refusing |
| Owning the human's tmux: resize, relayout, `kill-server` | a **private socket**, so the agent's tmux world is disjoint |
| Unbounded spawning: a fan-out loop opening 40 paid agents | a pane-count cap. **No tmux project surveyed has one.** |
| Completion detection by polling `capture-pane` in a loop | a `wait` verb with idle/text/timeout strategies |
| Dumping thousands of scrollback lines into context | a default bounded tail, `-J` for wrapped lines, incremental cursors |

### Where the menus fit, and my second disagreement

You said "instead of outputting menus". **Do not remove the menus.** They are
your human surface and they are the reason `tmux-worktree` is pleasant to use.
The agent surface is *additive*.

The correct structure is that both surfaces sit on one data layer and differ only
in rendering:

```
                   tmux-toolkit lib/      <- primitives, correctness
                           |
              +------------+------------+
              |                         |
   display-menu (human)         mux CLI + SKILL.md (agent)
   prefix+W, prefix+g            machine-readable output
```

That is already the direction D-4 of the migration plan takes: the awk scripts
stop emitting tmux menu syntax and emit **TSV data**, and bash builds the menu
from it. The moment the data layer is separate from the rendering, the agent
surface is a second renderer over the same data, which is a small job. Doing the
agent surface *first*, over the current menu-string-generating code, means
building it twice.

---

## 5. Shape I would recommend

A single `mux` CLI, roughly twelve verbs, AXI-style output, one SKILL.md, plus a
`SessionStart` hook that puts the inventory in front of the agent so it never
has to discover anything.

```
mux                              # bare: live inventory + who am I + next-step hints
mux self                         # my pane, session, worktree, whether I am managed
mux ls [--busy|--idle] [--worktree W]
                                 # id, label, harness, state, cwd  (4 fields, not 12)
mux open <label> [--worktree BRANCH] [--task "..."] [--harness H] [--window]
                                 # the composite. Wraps what mesh dispatch already does.
mux read <target> [--tail 200] [--since CURSOR] [--full]
mux send <target> <text>         # stages; verifies it landed; NEVER submits
mux submit <target>              # retries Enter only until the composer clears
mux wait <target> [--idle 2] [--text RE] [--timeout 120]
mux restart <target> [--resume]  # the missing capability
mux close <target> [--force]     # refuses on self, refuses busy without --force
mux chat <target> <message>      # mesh send, with the idle ceiling reported honestly
mux doctor                       # deps, versions, limits, self, config problems
```

Deliberately absent: resize, layout, swap, join, break, zoom, buffer operations,
per-key tools, and any exposure of the session/window/pane triple. Labels resolve
internally to one flat namespace.

Two commitments I would defend:

- **`send` never submits by default.** The split, plus proof-of-delivery, is the
  difference between working and silently corrupting a peer agent's prompt.
- **`restart` is the risky verb, not the easy one.** It has to kill or interrupt,
  re-launch, and re-attach identity, and for an idle agent it must type. Every
  guardrail in the table above applies to it at once. Treat it as the hardest
  item, not a convenience.

### Guardrails, ranked by how much evidence stands behind them

1. **Private socket.** One line, eliminates the whole "the agent wrecked my
   session" class. Convention from
   [mitsuhiko's tmux skill](https://raw.githubusercontent.com/mitsuhiko/agent-stuff/main/skills/tmux/SKILL.md).
2. **Cannot kill self.** `tmux-cli` errors explicitly; libtmux-mcp prevents it.
3. **Read before write.** From
   [tmux-bridge-mcp](https://github.com/howardpen9/tmux-bridge-mcp), whose README
   is also honest that it "is not a security boundary".
4. **Proof of delivery, failure over retry.** firstmate.
5. **Liveness classification before sending.** firstmate, but note V3: use a
   `comm` child-walk, not `#{pane_current_command}`.
6. **Access tiers.** libtmux-mcp's `LIBTMUX_SAFETY` = readonly/mutating/destructive.
7. **Launch a shell, then send the command**, because launching the command
   directly means the pane dies on error and the output is lost.
8. **Bounded reads by default.** 200-line tail is the field consensus.
9. **A cap on spawned panes.** Nobody has this. You should.
10. **Give the human a door**: print the `attach` command.

---

## 6. What the field has, so you know what you are competing with

| Project | What it is | Verdict |
|---|---|---|
| [tmux-cli](https://github.com/pchalasani/claude-code-tools) | Python, agent-callable, best-shaped CLI surveyed. `launch/send/capture/list_panes/status/kill/interrupt/wait_idle/execute`. 1.5s delay before Enter with up to 3 verification retries. Refuses to kill your own pane. Local vs remote mode auto-detect. | **Read this first.** Closest thing to the answer. |
| [firstmate](https://github.com/kunchenguid/firstmate) | Agent distro, 90 scripts. Best delivery semantics and guardrails. | Steal the mechanics, not the system. |
| [AXI](https://github.com/kunchenguid/axi) | The interface spec plus benchmark. | Adopt the discipline. |
| [cyber-mux](https://github.com/cyberuni/cyber-mux) | The AXI-shaped tmux tool. `doctor/mode/open/send/submit/read/focus/close/list/exists`. | **2 stars, no license, 12 days old, README says the behaviour spec is not written yet.** The `send`/`submit` split is its one good idea. The space is open. |
| [bnomei/tmux-mcp](https://github.com/bnomei/tmux-mcp) | ~70 tools, Rust. Best policy layer: tool filtering, socket scoping, compile-time capability removal. | Learn from the policy layer, reject the surface size. |
| [libtmux-mcp](https://github.com/tmux-python/libtmux-mcp) | Best primitives: `capture_since` with a cursor, `snapshot_pane`, safety tiers. Pre-alpha. | Copy `capture_since`. |
| [worktrunk](https://worktrunk.dev/claude-code/) | Only project with real agent worktree integration: it **intercepts Claude Code's own `WorktreeCreate`/`WorktreeRemove` hooks** and reroutes them through its own lifecycle. | **Sharpest single pattern found.** Intercept the agent's native primitive instead of teaching it yours. |
| [mitsuhiko tmux SKILL.md](https://raw.githubusercontent.com/mitsuhiko/agent-stuff/main/skills/tmux/SKILL.md) | Conventions, not code. Private socket, `-J` on capture, poll rather than `wait-for`, print the human's attach command. | This is what a good skill looks like. |

Nobody combines all of it. bnomei has the best policy, libtmux-mcp the best
primitives, tmux-bridge-mcp the best single guardrail, tmux-cli the best CLI
shape, firstmate the best delivery semantics, mitsuhiko the best conventions,
cyber-mux the right verbs and no implementation.

---

## 7. Sequencing

The agent surface should come *after* the data layer is separated, not before.
Concretely:

1. **Finish the extraction (D-3 through D-7).** In particular D-4, which makes
   the worktree menus emit TSV instead of tmux menu syntax. The agent surface is
   then a second renderer over that data. Built before D-4, it has to parse
   menu-command strings, and gets rewritten.
2. **Resolve duplication 27**: `mesh dispatch --worktree` should call
   `tmux-worktree`'s worktree creation rather than reimplementing the same path
   convention.
3. **Then build `mux`** as a thin façade: `ls` over `tk_identity_list`, `open`
   over the deduplicated dispatch, `read`/`send`/`submit` over the keys module
   that stays in the resumer, `chat` over mesh.
4. **`restart` last**, because it is the only verb with no prior art in your
   stack and the most ways to go wrong.

One thing worth doing early and cheaply, out of order: **`mux` and the skill
should be a separate repo from tmux-toolkit.** The toolkit is a library that the
mesh vendors, and the mesh's whole thesis is that it contains no `send-keys`,
pinned by a grep over its own tree. An agent-facing tool that types into panes
must not live where that guarantee is enforced.
