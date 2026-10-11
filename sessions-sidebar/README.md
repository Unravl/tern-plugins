# Sessions Sidebar for Tern

A native **Sessions** list on the left of each tab: every session grouped by host (**This PC** first, then attached remote hosts), with icons, names, working directories and activity lights. Click a row to switch. Files: `plugin.toml`, `window.luau`, `sessions.luau`, `session-data.luau`, `drawer.luau`, `sidebar.css`, `drawer.css`.

## Install

Requires a Tern desktop app; built and verified on **Tern 0.7.3**. The `tern` command is the app's executable (`/Applications/Tern.app/Contents/MacOS/tern` on macOS) if it is not on your PATH.

From a copy of this folder (for example an unzipped download):

```sh
tern plugin install ~/Downloads/sessions-sidebar
```

From the [tern-plugins](https://github.com/Unravl/tern-plugins) repository, where this plugin is the `sessions-sidebar` folder. The repository is private, so this needs a GitHub account with access to it and git credentials on that machine:

```sh
tern plugin install github.com/Unravl/tern-plugins/sessions-sidebar
```

`install` copies the plugin into Tern's plugins folder (`tern plugin dir`) and reloads plugins; the sidebar appears in each tab you open or visit. `tern plugin list` should show `sessions-sidebar 1.4.1 … ready`. To update, run the same command with `--force`; to uninstall, `tern plugin remove sessions-sidebar`.

To develop, use the folder in place instead: `tern plugin link ~/Documents/tern-plugins/sessions-sidebar`. After editing, reload with **`tern plugin reload`** from a terminal (see [Known limits](#known-limits) for why not the palette's *Reload plugins*).

## Display modes

Open **Sessions sidebar settings** from the gear in the sidebar header or the command palette:

| Mode | Behavior |
| --- | --- |
| **Hover left edge** (default) | A thin strip on the window's left edge. Moving the pointer onto it slides the drawer out **over** the content; it stays while the pointer is inside and closes when it leaves. |
| **Click tab** | A small tab on the left edge. Click it to open the drawer over the content; click it again to close. |
| **Always expanded** | The sidebar is docked as a normal left split and takes its own space. Drag its divider to the width you want: every tab and session uses that same width, so switching never moves the column. The width is remembered as a share of the window, so it scales if you resize the window. |

The two overlay modes never resize the terminal or other panes: the drawer floats above them and leaves no gap when closed. While a rename, icon or new-session prompt is open, the drawer stays open. The chosen mode is saved and applies to every tab.

## Using the list

- **Switch:** click a session row. Switching uses the exact numeric session ID, so duplicate names (also across hosts) are safe. The current session is highlighted; clicking it only returns focus to the terminal and never changes tabs. Clicking a session on another host switches host too.
- **Collapse a host:** click the **-** / **+** button left of a host title. Collapsed hosts are remembered.
- **New session on a host:** click the **+** icon at the far right of a connected host's header. It asks for a name, creates the session on that host and switches to it; blank or cancelled does nothing.
- **Reorder sessions and hosts:** Tern 0.7.3 plugin panels cannot be dragged with the mouse, so moving is pick and place. Click the grip (dotted handle that appears on hover) at the left of a session or host header, or right-click it and choose **Move session** / **Move host**. The item lifts (accent bar) and a banner appears; click the session or host header whose place it should take. Moving down lands just after that item, moving up just before it. Click the lifted item again or **Cancel** to stop. Sessions move within their own host; hosts (including **This PC**) move among hosts. While an item is lifted the drawer stays open in the overlay modes.
- **Right-click a session:** **Rename session**, **Move session**, **Change icon**, **Reset icon**. Renaming does not switch to the session and keeps its icon and position.
- **Right-click a host title:** **New session** (same as the **+** icon; hidden while the host is not connected), **Move host**, **Rename host title**, **Reset host title**. The host title is a display alias in the sidebar only; the host's connection, address and Tern's own name are unchanged.
- **Change an icon:** click a session's icon (or use its menu). Pick a native icon (Terminal, Folder, Code, Branch, Server, Database, Globe, Rocket, Moon, omp, Python, Rust), **Custom glyph or emoji** (up to 64 UTF-8 bytes), or **Reset icon**. Choosing an icon does not switch sessions.
- **Paths:** the line under each name is the session's working directory. Paths in your home directory show as `~/…` (`/Users/<you>/…` locally, `/home/<you>/…` on Linux hosts). Long paths drop leading folders (`…/project/src`); hover a path for the full text.

Other palette commands: **Show sessions sidebar**, **Hide sessions sidebar (current tab)**, **Refresh sessions sidebar**. There are no default shortcuts; bind `plugin.sessions-sidebar.show`, `.hide`, `.refresh` or `.settings` in your Tern keybindings if you want them. Hide (or closing the sidebar pane) keeps that tab's sidebar hidden until Show, a plugin reload or a new window.

## Activity lights

Tern's plugin SDK exposes no per-session sleep or daemon-suspend state, so the light reports what this window can actually observe. Colors come from your Tern theme; hover the light for its explanation.

| Light | Meaning |
| --- | --- |
| **Active** (accent dot) | The session selected in this window. |
| **Working** (orange dot) | A content pane of the session reports a running command. |
| **Loaded** (green dot) | The session's content panes are observable in this window. |
| **Not loaded** (hollow ring) | No content panes of the session are observable in this window. This is **not** a daemon sleep state. |
| **Unavailable** (red dot) | The host is not connected (connecting, stalled, reconnecting, failed, waiting for key verification) or no longer attached. |

Session renames, creation and closing appear within about a second; **Refresh sessions sidebar** forces an immediate update.

## Remote hosts

Only hosts already attached to this window are listed: **This PC** first and remote hosts alphabetically until you reorder them. Nothing is installed on the remote, and the plugin runs no shell, SSH or network commands of its own; the remote Tern service must support native canvas panes. Disconnecting and forgetting a host removes its group.

## What is saved

Saved in Tern's plugin storage and kept across reloads and restarts: display mode, docked sidebar width, collapsed hosts, host order, session order, host title aliases and session icons. Hosts are identified by `This PC` or the remote's address (else its name), never by window-local IDs; a host that is detached keeps its saved place for when it returns.

Session icons and positions are saved by host plus session name, so they follow a session when you rename it through the sidebar. A session renamed elsewhere, or created later, appears after the ordered ones until you move it. If two sessions on the same host share a name, their icons and positions are kept only for the current window and are not saved; a session never inherits another session's icon (for example after the original of a duplicate name closes).

## Known limits

- **Use `tern plugin reload`, not the palette's *Reload plugins*.** In Tern 0.7.3 the palette action loses the window state of existing plugin canvases; each affected sidebar becomes a blank floating **Canvas** card. The plugin replaces it with a working sidebar within about five seconds, but close the leftover blank cards yourself. The CLI reload, source-file reloads and session switches do not have this problem.
- The overlay modes style the floating panel through the accessible label Tern 0.7.3 gives plugin canvases (`Sessions Sidebar [ss-…]`). That is not a documented, stable SDK hook; if a future Tern changes it, use **Always expanded**, which needs no such styling.
- In **Always expanded** mode in a tab with vertically stacked splits, the sidebar fills the height of the leftmost column only; existing splits are never flattened.
- Desktop windows only: Tern's web client has no window Lua runtime.

To remove the plugin, hide or close the sidebars, then run `tern plugin remove sessions-sidebar` (or `tern plugin unlink sessions-sidebar` for a linked development copy). Removing it does not close sidebar panes that are still open.

## Verification and development

Verified in native **Tern 0.7.3** windows with an isolated config, using local sessions and loopback remote hosts: hover, click-tab and always-expanded modes (terminal size unchanged in overlay modes, drawer full height and opaque, clipped drawer not clickable when closed), mode switching, session switching on both hosts, right-click menus, rename of an inactive session without switching, prompt focus across refreshes, cancel and blank-name handling, host title alias, host collapse/expand, New session on the remote host from the menu and the header **+**, native and custom-emoji icons, duplicate-name icon isolation across close and reload, `~/` paths, long-name and long-path truncation, Working / Active / Loaded / Unavailable lights and recovery after reconnect, the shared docked width (a real divider drag is kept exactly, also when you switch tabs within half a second of releasing it; hidden tabs, new tabs and other sessions follow it, pane geometry is pixel-identical immediately after every tab switch, and it survives mode switches, window resizing and plugin reloads), pick-and-place reordering (sessions moved up and down within a host from the grip and the menu, hosts including This PC reordered, Cancel, clicking the lifted item, inert dimmed rows of other hosts, clicks on a destination's icon placing instead of opening the icon picker, position kept through a sidebar rename and a plugin reload, drawer held open while moving in hover mode), and the lifecycle scenario below (also right after a plugin reload). Real SSH hosts were **not** tested; loopback is not an SSH test.

The native lifecycle regression scenario is `tests/sidebar-lifecycle.txt` (row click keeps terminal focus, parked replacement, Hide, manual close, Show, tab switching). It is verified in **Hover left edge** and **Always expanded** modes; Click tab mode is not supported by the script because its row click needs the drawer open. Run it in a **fresh isolated window**, never your normal sessions:

```sh
test_dir="$(mktemp -d /tmp/tern-sidebar-test.XXXXXX)"
export TERN_CONFIG_DIR="$test_dir/config" TERN_DAEMON_SOCKET="$test_dir/daemon.sock" STENCIL_LOG_DIR="$test_dir/logs"
tern plugin link "$PWD"
tern --control "$test_dir/control.sock" /tmp &
# once the window shows a prompt:
tern ctl --control "$test_dir/control.sock" --file tests/sidebar-lifecycle.txt
```

The scenario creates one extra tab and never closes content panes or sessions. Tern's [script reference](https://docs.stencil.so/tern/scripts/) documents `ctl`.

Optional SDK types and static analysis, with `luau-lsp` installed separately:

```sh
tern plugin types .
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau *.luau
```

Generated types are development-only; static typechecking is not part of the native verification above.
