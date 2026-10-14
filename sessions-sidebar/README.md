# Sessions Sidebar for Tern

A native **Sessions** list on the left of each tab: every session grouped by host (**This PC** first, then attached remote hosts), with icons, names, working directories and what each session's omp agents are doing. Click a row to switch. Files: `plugin.toml`, `window.luau`, `sessions.luau`, `session-data.luau`, `agents.luau`, `drawer.luau`, `docked.luau`, `sidebar.css`, `drawer.css`.

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

`install` copies the plugin into Tern's plugins folder (`tern plugin dir`) and reloads plugins; the sidebar appears in each tab you open or visit. `tern plugin list` should show `sessions-sidebar 1.8.0 … ready`. To update, run the same command with `--force`; to uninstall, `tern plugin remove sessions-sidebar`.

To develop, use the folder in place instead: `tern plugin link ~/Documents/tern-plugins/sessions-sidebar`. After editing, reload with **`tern plugin reload`** from a terminal (see [Known limits](#known-limits) for why not the palette's *Reload plugins*).

## Display modes

Open **Sessions sidebar settings** from the gear in the sidebar header or the command palette:

| Mode | Behavior |
| --- | --- |
| **Hover left edge** (default) | A thin strip on the window's left edge. Moving the pointer onto it slides the drawer out **over** the content; it stays while the pointer is inside and closes when it leaves. |
| **Click tab** | A small tab on the left edge. Click it to open the drawer over the content; click it again to close. |
| **Always expanded** | The sidebar is docked as a normal left split and takes its own space. Drag its divider to the width you want: it stays exactly where you let go, and every tab, session and remote host gets that same width, so switching never moves the column and new tabs and sessions open with it. Only a drag changes the width. **Even out splits** (⌃⌘=) evens the other panes and leaves the sidebar alone, and a font size change keeps its width in pixels. When the window (or its tab area) changes width, the column keeps its width in terminal cells: it settles back within a second or two, to the nearest cell, because Tern exposes pane widths only in whole cells. Tern never lets a split be narrower than 10% of the window, so in a window more than ten times the sidebar's width the column grows to that 10%. |

The two overlay modes never resize the terminal or other panes: the drawer floats above them and leaves no gap when closed. While a rename, icon or new-session prompt is open, the drawer stays open. The chosen mode is saved and applies to every tab.

Row icons sit **5 px from the drawer content's left edge**, with no grips on session rows or host headers. Tern's native **10 px docked canvas inset** remains in Always expanded mode; the 5 px spacing is relative to sidebar content, not the visible window edge.

## Using the list

- **Switch:** click a session row. Switching uses the exact numeric session ID, so duplicate names (also across hosts) are safe. The current session is highlighted; clicking it only returns focus to the terminal and never changes tabs. Clicking a session on another host switches host too.
- **Collapse a host:** click the **-** / **+** button left of a host title. Collapsed hosts are remembered.
- **New session on a host:** click the **+** icon at the far right of a connected host's header. It asks for a name, creates the session on that host and switches to it; blank or cancelled does nothing.
- **Reorder sessions and hosts:** Tern 0.7.3 plugin panels cannot be dragged with the mouse, so moving is pick and place. Right-click a session row or host title and choose **Move session** / **Move host**. The item lifts (accent bar) and a banner appears; click the session or host header whose place it should take. Moving down lands just after that item, moving up just before it. Click the lifted item again or **Cancel** to stop. Sessions move within their own host; hosts (including **This PC**) move among hosts. While an item is lifted the drawer stays open in the overlay modes.
- **Right-click a session:** **Rename session**, **Move session**, **Change icon**, **Reset icon**. Renaming does not switch to the session and keeps its icon and position.
- **Right-click a host title:** **New session** (same as the **+** icon; hidden while the host is not connected), **Move host**, **Rename host title**, **Reset host title**, **Change title color**. The host title is a display alias in the sidebar only; the host's connection, address and Tern's own name are unchanged.
- **Change a host title's color:** right-click the host title and choose **Change title color**. Pick Red, Orange, Yellow, Green, Teal, Blue, Purple or Pink, **Custom hex color** (`#rgb` or `#rrggbb`, with or without `#`), or **Default color** to return to the theme's heading color. Only the title text changes; the toggle and **+** keep theme colors.
- **Change an icon:** click a session's icon (or use its menu). Pick a native icon (Terminal, Folder, Code, Branch, Server, Database, Globe, Rocket, Moon, omp, Python, Rust), **Custom glyph or emoji** (up to 64 UTF-8 bytes), or **Reset icon**. Choosing an icon does not switch sessions.
- **Paths:** the line under each name is the session's working directory. Paths in your home directory show as `~/…` (`/Users/<you>/…` locally, `/home/<you>/…` on Linux hosts). Long paths drop leading folders (`…/project/src`); hover a path for the full text.

Other palette commands: **Show sessions sidebar**, **Hide sessions sidebar (current tab)**, **Refresh sessions sidebar**. There are no default shortcuts; bind `plugin.sessions-sidebar.show`, `.hide`, `.refresh` or `.settings` in your Tern keybindings if you want them. Hide (or closing the sidebar pane) keeps that tab's sidebar hidden until Show, a plugin reload or a new window.

The sidebar never keeps a tab open on its own. When a tab's last other pane closes (for example its shell exits), is parked or moves away, the sidebar closes too and Tern closes the tab, so no tab is left titled **Sessions Sidebar [ss-…]**. Loading the plugin also closes any such leftover tabs.

Session renames, creation and closing appear within about a second; **Refresh sessions sidebar** forces an immediate update.

## Agent status

The right end of a session row shows what the omp agents in that session's tabs are doing, in large bold marks:

| Mark | Meaning |
| --- | --- |
| **?** (amber) | An agent is asking a question and waits for your answer (for example omp's ask prompt). |
| Spinner | An agent is working. |
| **✓** (green) | An agent finished a task (its turn ended) and you have not visited its tab since. |

Nothing shows when the session's agents are idle and you have seen how they ended, and nothing marks the session you are on: its row highlight does that. Plain shell commands show nothing.

The spinner is live: it shows whenever an agent in the session is working, also in the tab you are looking at. **?** and **✓** wait for you. Visiting the agent's tab clears them: switching to that tab, or to its session when that tab is the one the session shows. They come back only when that agent asks again or finishes another task, and an agent in the tab you are looking at never gets one. When an agent with a **✓** starts working again, the spinner replaces the tick. A **?** also goes away when the question is answered elsewhere. A session with several agents can show more than one mark (in the order **?**, spinner, **✓**); hover a mark for how many agents it stands for.

Agents are Tern agent blocks and shells where `omp` was typed at the prompt, on This PC and on attached remote hosts. Marks follow each agent's progress and Tern's unseen-alert flag as this window sees them, within about a second. They belong to the window and are not saved; after a plugin reload, a finished turn Tern still holds as unseen (its pane has not been focused) shows its tick again.

## Remote hosts

Only hosts already attached to this window are listed: **This PC** first and remote hosts alphabetically until you reorder them. Nothing is installed on the remote, and the plugin runs no shell, SSH or network commands of its own; the remote Tern service must support native canvas panes. Disconnecting and forgetting a host removes its group.

## What is saved

Saved in Tern's plugin storage and kept across reloads and restarts: display mode, docked sidebar width (in terminal cells at the font size it was set at, plus its share of the window, which a new window starts from), collapsed hosts, host order, session order, host title aliases, host title colors and session icons. Agent status is not saved. Hosts are identified by `This PC` or the remote's address (else its name), never by window-local IDs; a host that is detached keeps its saved place for when it returns.

Session icons and positions are saved by host plus session name, so they follow a session when you rename it through the sidebar. A session renamed elsewhere, or created later, appears after the ordered ones until you move it. If two sessions on the same host share a name, their icons and positions are kept only for the current window and are not saved; a session never inherits another session's icon (for example after the original of a duplicate name closes).

## Known limits

- **Prefer `tern plugin reload` to the palette's *Reload plugins*.** The palette action (and sometimes restarting Tern) makes Tern drop the state of existing plugin canvases: each sidebar becomes a blank pane titled **Canvas**, and a tab whose focused pane is one shows as **Canvas** in the tab bar. The plugin closes every such blank canvas, in any tab or session of the window, once it has had no state for five seconds, and the tab you are in gets a working sidebar again; other tabs get theirs when you visit them. Blank canvases left by older versions are closed the same way. The CLI reload, source-file reloads and session switches do not drop canvas state.
- The overlay modes style the floating panel through the accessible label Tern 0.7.3 gives plugin canvases (`Sessions Sidebar [ss-…]`). That is not a documented, stable SDK hook; if a future Tern changes it, use **Always expanded**, which needs no such styling.
- In **Always expanded** mode in a tab with vertically stacked splits, the sidebar fills the height of the leftmost column only; existing splits are never flattened. Likewise, a sidebar opened or docked in a tab that already has several columns (by Show, a mode switch or Reload plugins) sits inside the leftmost column, which Tern does not let it fill; if that column is too narrow for the docked width, drag its divider wider and the sidebar takes the docked width again.
- In **Always expanded** mode Tern's own **Even out splits** is kept from resizing the sidebar through its command (key binding, palette or action). Tern scripts and other plugins that even out a tab directly do resize it, and the sidebar then takes that width as if dragged.
- Agent status needs Tern's agent support (`cx.agents`, verified on **Tern 0.8.2**); without it rows show no marks. A turn too short for the one-second refresh to see it working shows no spinner; its tick comes from Tern's unseen alert, so if omp sends no completion alert such a turn shows no tick either. Tern's `agent_finished` event does not fire for these agents in 0.8.2 and is not used.
- Desktop windows only: Tern's web client has no window Lua runtime.

To remove the plugin, hide or close the sidebars, then run `tern plugin remove sessions-sidebar` (or `tern plugin unlink sessions-sidebar` for a linked development copy). Removing it does not close sidebar panes that are still open.

## Verification and development

Verified in native **Tern 0.7.3** windows with an isolated config, using local sessions and loopback remote hosts: hover, click-tab and always-expanded modes (terminal size unchanged in overlay modes, drawer full height and opaque, clipped drawer not clickable when closed), mode switching, session switching on both hosts, right-click menus, rename of an inactive session without switching, prompt focus across refreshes, cancel and blank-name handling, host title alias, host collapse/expand, New session on the remote host from the menu and the header **+**, native and custom-emoji icons, duplicate-name icon isolation across close and reload, `~/` paths, long-name and long-path truncation, Working / Active / Loaded / Unavailable strips and recovery after reconnect, the shared docked width (a real divider drag is kept exactly, also when you switch tabs within half a second of releasing it; hidden tabs, new tabs and other sessions follow it, pane geometry is pixel-identical immediately after every tab switch, and it survives mode switches, window resizing and plugin reloads), pick-and-place reordering (sessions moved up and down within a host from the menu, hosts including This PC reordered, Cancel, clicking the lifted item, inert dimmed rows of other hosts, clicks on a destination's icon placing instead of opening the icon picker, position kept through a sidebar rename and a plugin reload, drawer held open while moving in hover mode), and the lifecycle scenario below (also right after a plugin reload). Real SSH hosts were **not** tested; loopback is not an SSH test.

For **1.4.2**, isolated native **Tern 0.8.0** checks exercised the 5 px icon content inset, absence of grips, 4 × 24 px strips centered in 48 px rows and flush right, and right-click **Move session** / **Move host** with cancellation by clicking the picked row or host heading.

For **1.5.0**, isolated native **Tern 0.8.2** checks exercised **Change title color** on the local host and a loopback remote host: preset colors, a custom `#A5F` normalized to `#aa55ff`, rejection of an invalid hex with a toast and no change, **Default color** removing the color, colors kept across `tern plugin reload`, and long colored titles still truncating in hover and Always expanded modes. `tests/sidebar-lifecycle.txt` passed afterwards.

For **1.5.1**, isolated native **Tern 0.8.2** checks resized the window between 700 and 1600 px wide in Always expanded mode: the column stayed within one cell (193–202 px; it went 162–276 px before), a divider drag was adopted as the new width, shrinking to 700 px and growing back did not change the saved width, switching tabs kept it identical, idle refreshes left terminal sizes unchanged, and at 2400 px Tern's 10% minimum set it to 213 px. `tests/sidebar-lifecycle.txt` passed afterwards.

For **1.5.2**, isolated native **Tern 0.8.2** checks on Windows covered a non-default `font_size`. Tern scales the drawer canvas by `font_size` over its default (15 against 13 makes the 320 px drawer 369 px), while the floating frame stayed 320 px and clipped the settings gear, the per-host **+** and the activity strips in hover and click-tab modes. The frame now scales by the same factor: 370 px at `font_size` 15 with all three visible, and still 320 px at the default size. `tests/sidebar-lifecycle.txt` passed at `font_size` 15.

For **1.6.0**, isolated native **Tern 0.8.2** checks exercised agent markers with stand-in omp agents (TSP recordings played with `surface-play`) across tabs and sessions, and with one real `omp` turn of about a second, whose **✓** came from Tern's unseen alert. `tests/agent-markers.txt` passed in Hover left edge and Always expanded modes, the markers sat left of the strip without moving it from the right edge, long names still truncated, and `tests/sidebar-lifecycle.txt` passed afterwards.

For **1.6.1**, isolated native **Tern 0.8.2** checks reproduced the leftover tab (after `exit` in a tab's only shell, 1.6.0 kept the tab open titled **Sessions Sidebar [ss-…]**) and confirmed that the tab now closes. The same holds when the last pane of a background tab closes and when the last pane is parked, and a leftover tab from 1.6.0 closed when the plugin reloaded. The new exit step in `tests/sidebar-lifecycle.txt` fails on 1.6.0 and passes on 1.6.1; `tests/agent-markers.txt` passed too.

For **1.7.0**, isolated native **Tern 0.8.2** checks replaced the activity strips with agent status marks. Stand-in omp agents showed the spinner while working in a background tab and in the tab being looked at, a **✓** after a background finish but none after a finish in view, and the spinner replacing a **✓** when that agent worked again. With **?**, spinner and **✓** on one row, the marks drew at 18 px, weight 900, centered in the 48 px row and ending at the drawer's right edge in Hover left edge and Always expanded modes, and long names and paths still truncated. `tests/agent-markers.txt` (both modes) and `tests/sidebar-lifecycle.txt` passed.

For **1.7.1**, isolated native **Tern 0.8.2** checks reproduced the **Canvas** tab: the palette's *Reload plugins* turned every docked sidebar into a blank pane titled **Canvas**, and 1.7.0 left them next to the new sidebars. 1.7.1 closed every blank canvas within one refresh after five seconds, across tabs, sessions and a loopback remote host. Live sidebars in all of those stayed untouched through repeated refreshes. The new Reload plugins step in `tests/sidebar-lifecycle.txt` fails on 1.7.0 and passes on 1.7.1 in Always expanded and Hover left edge modes; `tests/agent-markers.txt` passed too.

For **1.8.0**, isolated native **Tern 0.8.3** checks reproduced the moving column in Always expanded mode. 1.7.1 rounded a drag to whole cells (323 px became 331.5 px in every tab), then measured another tab from cells left over from before the drag and moved every sidebar back. A new tab on a loopback remote host with 200 ms latency swung every sidebar in every session through 1146, 398 and 423 px before it settled at 415 px, and new tabs and sessions opened at 372 px before jumping to the locked width. 1.8.0 kept a drag exactly (422.00 px, the same split ratio on all eight sidebars across two local sessions and the remote host). Over 30 samples each, new tabs, sessions and remote tabs (200 ms latency) showed no width but the docked one, and a drag followed by a tab switch before any refresh still became the width. **Even out splits** run as an action left the sidebar at 392 px, and raising and resetting the font size left it at 404.53 px. Window resizes between 1100 and 1920 px settled within one cell of the dragged 402 px (398.9–405.6 px) in at most two steps, a plugin reload and a switch to Hover left edge and back kept the width, a new window opened at the saved width (404.53 px) without a correction, and a 1.7 width of 40 cells was taken over once. The new `tests/docked-width.txt` fails on 1.7.1 (the column moved by itself before any drag) and passes on 1.8.0; `tests/sidebar-lifecycle.txt` and `tests/agent-markers.txt` passed in Hover left edge and Always expanded modes.

The native regression scenarios are `tests/sidebar-lifecycle.txt` (row click keeps terminal focus, parked replacement, Hide, manual close, Show, tab switching, a tab whose shell exits closes, Reload plugins leaves no blank **Canvas** panes), `tests/agent-markers.txt` (spinner while an agent works, also in the tab in view; **?** and **✓** for agents in tabs you are not looking at, none in the active tab, cleared by visiting the tab and not brought back by leaving; the spinner replacing a **✓** when work resumes; marks on another session's row; several marks on one row; no activity strips) and `tests/docked-width.txt` (in Always expanded mode, a drag is kept exactly and every sidebar takes it across a new tab, a tab switch, a drag followed at once by a tab switch, a new session, a slow loopback remote host and its new tab, Even out splits and a font size change). The lifecycle scenario is verified in **Hover left edge** and **Always expanded** modes; Click tab mode is not supported because its row click needs the drawer open. The agent scenario works in any mode; the width scenario switches the window to Always expanded itself. Run them from this folder in a **fresh isolated window**, never your normal sessions. The window below starts hidden in the background, so it does not take focus:

```sh
test_dir="$(mktemp -d /tmp/tern-sidebar-test.XXXXXX)"
export TERN_CONFIG_DIR="$test_dir/config" TERN_DAEMON_SOCKET="$test_dir/daemon.sock" STENCIL_LOG_DIR="$test_dir/logs"
mkdir -p "$TERN_CONFIG_DIR/omp" && printf '{"managed":false,"checked":0,"no_build":false,"offered":true}' > "$TERN_CONFIG_DIR/omp/state.json"
rsync -a --exclude tests ./ "$test_dir/sessions-sidebar/"
tern plugin link "$test_dir/sessions-sidebar"
open -g -j -n --env TERN_CONFIG_DIR="$TERN_CONFIG_DIR" --env TERN_DAEMON_SOCKET="$TERN_DAEMON_SOCKET" --env STENCIL_LOG_DIR="$STENCIL_LOG_DIR" \
  -a /Applications/Tern.app --args --control "$test_dir/control.sock" /tmp
until [ -S "$test_dir/control.sock" ]; do sleep 0.5; done
tern ctl --control "$test_dir/control.sock" --file tests/sidebar-lifecycle.txt
tern ctl --control "$test_dir/control.sock" --file tests/agent-markers.txt
tern ctl --control "$test_dir/control.sock" --file tests/docked-width.txt
```

The `state.json` line stops a fresh config from offering to install omp (and linking it into `~/bin`). The window runs a copy of the plugin: a linked folder reloads on every save, which would reset the plugin's window state in the middle of a scenario. The lifecycle scenario creates two extra tabs, exits the last one's shell and ends with the palette's Reload plugins; the agent scenario writes three recordings to `/tmp/sessions-sidebar-agent-*.jsonl` and opens three tabs and one extra session without closing any pane; the width scenario switches to Always expanded and opens two tabs, a session named `WidthTwo`, a loopback remote host `widthbox` and a tab there, so run it last. None closes sessions. Afterwards run `tern ctl --control "$test_dir/control.sock" quit`, then `pkill -f "$test_dir/control.sock"` and `pkill -f "tern daemon --socket $test_dir/daemon.sock"`, and delete `$test_dir`. Tern's [script reference](https://docs.stencil.so/tern/scripts/) documents `ctl`.

Optional SDK types and static analysis, with `luau-lsp` installed separately:

```sh
tern plugin types .
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau *.luau
```

Generated types are development-only; static typechecking is not part of the native verification above.
