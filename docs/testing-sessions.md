# Toolkit Feature: Headless tmux Testing Sessions

## Problem

When developing or debugging tmux extensions (menus, keybindings, pane operations),
every test opens interactive menus on the developer's screen. This makes automated
testing impossible and slows down debugging because:

- `display-menu` blocks waiting for user input
- `send-keys -K` doesn't work with menus (confirmed tmux limitation)
- Every test run interrupts the developer's workflow
- Crewmates can't test their own menu changes without a human pressing keys

## Solution

Add a `tk_test_session` helper that creates a separate, headless tmux session
for automated testing. The test session runs in the background with its own
server socket, isolated from the developer's main session.

```bash
# Start a headless test session
tk_test_session_start [name]     # creates detached session, returns socket path

# Run commands in the test session
tk_test_session_exec <cmd>       # run a tmux command in the test session

# Open a menu in the test session (captures keystrokes programmatically)
tk_test_menu_open <args...>      # opens display-menu in test session
tk_test_menu_send <key>          # sends a keystroke to the active menu
tk_test_menu_close               # dismisses the menu

# Clean up
tk_test_session_stop             # kills the test session
```

## Implementation

Uses `tmux -L test-XXXX -f /dev/null new-session -d` to create a detached
session with a unique socket name. All test commands target this socket via
`-L`. The test session has no real terminal attached — keystrokes are
injected via `send-keys` targeted at the session's active pane (not at
display-menu directly — we work around the menu input limitation by using
non-interactive alternatives or by spawning menus in a pane with a pty).

### Key insight

`display-menu` reads from the CLIENT's TTY, not from a pane. A detached
session with no client has no TTY. Workaround: use `tmux -L test-XXXX
new-session -d` and then `tmux -L test-XXXX display-menu ...`. The detached
session's "client" is the tmux command itself, which provides a pty as
stdin. On some tmux versions, this works; on others, display-menu fails
with "no client."

If the pty approach doesn't work, the fallback is to bypass display-menu
entirely and use `tk_menu_test_*` helpers that validate menu structure
and test item commands directly (see `lib/menu-test.sh`).

## Status

- [ ] Research: does `tmux -L test new -d display-menu` work on tmux 3.7?
- [ ] Implement `tk_test_session_start/stop`
- [ ] Implement `tk_test_session_exec`
- [ ] Implement menu test helpers in isolated session
- [ ] Document in `docs/testing.md`
