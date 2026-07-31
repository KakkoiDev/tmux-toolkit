# shellcheck shell=bash
# toolkit-ui.sh - entry point for interactive and install-time work.
#
# The hot set plus the modules a harness hook must never pay for. Source this
# from a key binding, a menu handler, an installer or a CLI; source
# lib/toolkit.sh from a hook.
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/toolkit-ui.sh"
#   tk_init agent-mesh "$MESH_DIR"
#
# Carries the full interactive set: every module not on the hot path.

if [[ -z "${TK_UI_LOADED:-}" ]]; then
    TK_UI_LOADED=1

    _tk_ui_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -n "${TMUX_TOOLKIT_DEV:-}" && -r "${TMUX_TOOLKIT_DEV%/}/lib/core.sh" ]]; then
        _tk_ui_src="${TMUX_TOOLKIT_DEV%/}/lib"
    fi

    # shellcheck source=toolkit.sh
    source "$_tk_ui_src/toolkit.sh"

    # shellcheck source=lock.sh
    source "$_tk_ui_src/lock.sh"
    # shellcheck source=menu.sh
    source "$_tk_ui_src/menu.sh"
    # shellcheck source=notify.sh
    source "$_tk_ui_src/notify.sh"
    # shellcheck source=target.sh
    source "$_tk_ui_src/target.sh"
    # shellcheck source=fmt.sh
    source "$_tk_ui_src/fmt.sh"
    # shellcheck source=toolkit-pane.sh
    # Pane I/O (send/run/read/wait, agent-aware typing) is opt-in and lives in
    # its own file: it is the only module that may reach keystroke injection,
    # and the hot set (toolkit.sh) must stay free of that.
    source "$_tk_ui_src/toolkit-pane.sh"
    # shellcheck source=pane-ops.sh
    source "$_tk_ui_src/pane-ops.sh"
    # shellcheck source=hook.sh
    source "$_tk_ui_src/hook.sh"
    # shellcheck source=status.sh
    source "$_tk_ui_src/status.sh"
    # shellcheck source=identity.sh
    source "$_tk_ui_src/identity.sh"

    unset _tk_ui_src
fi
