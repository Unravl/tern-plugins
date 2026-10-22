--!strict

local agents = require("./agents")
local data = require("./session-data")

export type Node = {
	k: string,
	p: { [string]: any }?,
	c: { Node }?,
}

-- Structural subsets of cx.hosts:list() and cx.sessions:list().
export type ManagedHost = {
	id: number,
	name: string,
	kind: "local" | "remote",
	address: string?,
	state: "connecting" | "connected" | "stalled" | "verify" | "reconnecting" | "failed",
	detail: { error: string? }?,
}

export type ManagedSession = {
	id: number,
	name: string,
	host: number,
	current: boolean,
	locked: boolean,
	note: string?,
	tabs: number,
}

type TargetKind = "switch" | "rename-session" | "change-icon" | "reset-icon" | "rename-host" | "reset-host" | "host-color" | "new-session" | "toggle-host" | "settings" | "toggle-panel" | "move-host" | "move-session" | "place-host" | "place-session" | "cancel-move" | "remove-host" | "boat" | "boats" | "snapshot"

export type Target = {
	kind: TargetKind,
	host: number?,
	session: number?,
	-- The boat sandbox id of a "boat" target.
	boat: string?,
	-- What a "boat", "boats" (Boat section header) or "snapshot" target does (boat-ui.luau).
	op: string?,
	-- The snapshot name of a "snapshot" target.
	snapshot: string?,
}

-- The one item lifted for pick-and-place reordering; `session` is set only for kind "session".
export type Moving = {
	kind: "host" | "session",
	host: number,
	session: number?,
}

-- The Boat section (core.luau's display.boats). `state` is boat-view.luau's Display.
export type BoatDisplay = {
	-- boat-view.luau once it is loaded; until then boat sandbox hosts are not drawn at all.
	view: { section: (ctx: any) -> Node? }?,
	-- Asks for boat-view.luau to be loaded; the next refresh draws the section.
	needView: () -> (),
	-- data.comparableAddress -> sandbox id, for every listed sandbox with an address.
	byAddress: { [string]: string },
	-- Whether the section has anything to show: a listing, a tracked or a new sandbox.
	wanted: boolean,
	-- epoch seconds now, for "stops in 5 h".
	now: number,
	state: any,
}

export type Display = {
	open: boolean,
	holdOpen: boolean,
	moving: Moving?,
	boats: BoatDisplay?,
}

export type BuiltView = {
	view: Node,
	signature: string,
	targets: { [string]: Target },
}

type Group = {
	host: ManagedHost,
	key: string,
	label: string,
	collapsed: boolean,
	-- The rows shown (none while collapsed), and every session on the host.
	rows: { ManagedSession },
	all: { ManagedSession },
}

local ui = require("./tsp")

local function idKey(id: number): string
	-- Remote IDs must not pass through a 32-bit integer format or bit operation.
	return string.format("%.0f", id)
end


local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for key, value in props do
		p[key] = value
	end
	node.p = p
	return node
end

local function addSignature(parts: { string }, value: string)
	-- Length prefixes keep names containing delimiters from aliasing another view.
	table.insert(parts, tostring(#value) .. ":" .. value)
end

local function addTarget(
	targets: { [string]: Target },
	actionName: string,
	nodeId: string,
	kind: TargetKind,
	host: number?,
	session: number?
): string
	targets[actionName .. "\n" .. nodeId] = { kind = kind, host = host, session = session }
	return actionName
end

local function displayPath(path: string): string
	-- Only shorten a leading complete home directory; never change metadata/cwd.
	local suffix = string.match(path, "^/Users/[^/]+(/.*)$") or string.match(path, "^/home/[^/]+(/.*)$")
	if suffix then
		return "~" .. suffix
	end
	if string.match(path, "^/Users/[^/]+$") or string.match(path, "^/home/[^/]+$") then
		return "~/"
	end
	return path
end

-- Overlay drawers have an approximately 259px path column at 11px monospace; use a
-- conservative 35-cell budget. Tern's own truncation measures the floating pane's cells,
-- not that column. Drop whole leading directories so the meaningful end stays visible;
-- docked mode keeps Tern's native truncation.
local OVERLAY_PATH_CELLS = 35
-- Cells each agent glyph takes from the overlay path column (about 6.6px per cell): a 16px
-- glyph slot or the 21.6px spinner window, the 2px gap between glyphs, and its share of the
-- 8px row gap and the marks' 4px right margin. Measured: ?, spinner and ✓ take 69.6px.
local MARK_CELLS = 4

local function fitPath(path: string, cells: number): string
	local length = utf8.len(path) or #path
	if length <= cells then
		return path
	end
	local rest = path
	while true do
		local nextRest = string.match(rest, "^/?[^/]+(/.+)$")
		if not nextRest then
			break
		end
		rest = nextRest
		if (utf8.len(rest) or #rest) + 1 <= cells then
			return "…" .. rest
		end
	end
	-- A single final component longer than the column: keep its end.
	local tail = string.sub(rest, -(cells - 1))
	return "…" .. tail
end

local function plural(count: number, one: string, many: string): string
	return if count == 1 then one else tostring(count) .. " " .. many
end

local function glyph(key: string, text: string, tone: string, title: string): Node
	return ui.el("span", {
		key = key,
		role = "sessions-sidebar-" .. key,
		text = text,
		tone = tone,
		title = title,
		aria = title,
		shrink = 0,
	})
end

-- "?" (asking), spinner (working), "✓" (finished); nil when no agent in the session has one.
local function agentMarks(counts: agents.Counts?): (Node?, number)
	if not counts then
		return nil, 0
	end
	local glyphs: { Node } = {}
	local titles: { string } = {}
	if counts.question > 0 then
		local title = plural(counts.question, "omp is asking a question", "omp agents are asking questions")
		table.insert(titles, title)
		table.insert(glyphs, glyph("question", "?", "warning", title))
	end
	if counts.working > 0 then
		local title = plural(counts.working, "omp is working", "omp agents are working")
		table.insert(titles, title)
		table.insert(glyphs, ui.node("spinner", {
			key = "working",
			role = "sessions-sidebar-working",
			style = "starburst",
			title = title,
			aria = title,
		}))
	end
	if counts.done > 0 then
		local title = plural(counts.done, "omp finished a task", "omp agents finished tasks")
		table.insert(titles, title)
		table.insert(glyphs, glyph("done", "✓", "success", title))
	end
	if #glyphs == 0 then
		return nil, 0
	end
	return ui.el("span", {
		key = "marks",
		role = "sessions-sidebar-marks",
		title = table.concat(titles, " · "),
		shrink = 0,
	}, glyphs), #glyphs
end

local function build(
	hosts: { ManagedHost },
	rows: { ManagedSession },
	snapshot: data.Snapshot,
	display: Display,
	marks: agents.Marks?
): BuiltView
	local groups: { Group } = {}
	local byHost: { [string]: Group } = {}
	for _, host in hosts do
		local key = idKey(host.id)
		local label = snapshot.hostTitles[key]
		local group: Group = {
			host = host,
			key = key,
			label = label,
			collapsed = snapshot.hostCollapsed[key] == true,
			rows = {},
			all = {},
		}
		byHost[key] = group
		table.insert(groups, group)
	end

	-- Group by the actual host slot, never a display name or encoded session bits.
	for _, session in rows do
		local group = byHost[idKey(session.host)]
		if group then
			table.insert(group.all, session)
			if not group.collapsed then
				table.insert(group.rows, session)
			end
		end
	end

	-- Ranks are the final display order: saved order first, then today's default order.
	table.sort(groups, function(a: Group, b: Group): boolean
		return snapshot.hostRank[a.key] < snapshot.hostRank[b.key]
	end)
	for _, group in groups do
		table.sort(group.rows, function(a: ManagedSession, b: ManagedSession): boolean
			return snapshot.sessionRank[idKey(a.id)] < snapshot.sessionRank[idKey(b.id)]
		end)
	end

	local moving = display.moving
	local movingName = ""
	local movingSession: number? = nil
	if moving then
		movingSession = moving.session
		if moving.kind == "session" then
			for _, session in rows do
				if session.id == moving.session and session.host == moving.host then
					movingName = session.name
					break
				end
			end
		else
			movingName = snapshot.hostTitles[idKey(moving.host)] or ""
		end
	end

	local targets: { [string]: Target } = {}
	local rootId = "main.sessions-sidebar"
	local drawerId = rootId .. ".drawer"
	local settingsAction = addTarget(targets, "sidebar-settings", drawerId .. ".toolbar.settings", "settings", nil, nil)
	local children: { Node } = {
		ui.el("div", {
			key = "toolbar",
			role = "sessions-sidebar-toolbar",
			class = "sessions-sidebar-toolbar",
		}, {
			with(ui.text("Sessions"), { key = "title", grow = 1 }),
			ui.el("button", {
				key = "settings",
				role = "sessions-sidebar-settings",
				title = "Sessions sidebar settings",
				aria = "Sessions sidebar settings",
				actions = { click = settingsAction },
			}, {
				ui.node("icon", { key = "icon", name = "gear" }),
			}),
		}),
	}
	if moving then
		table.insert(children, ui.el("div", {
			key = "move",
			role = "sessions-sidebar-move-banner",
			class = "sessions-sidebar-move-banner",
		}, {
			with(ui.text("Moving " .. movingName .. ": click its new place"), {
				key = "text",
				role = "sessions-sidebar-move-text",
				-- Narrow docked sidebars cut one line mid-instruction; wrap instead.
				wrap = "word",
				lines = 3,
				grow = 1,
				shrink = 1,
			}),
			ui.el("button", {
				key = "cancel",
				role = "sessions-sidebar-move-cancel",
				text = "Cancel",
				title = "Cancel move",
				aria = "Cancel move",
				actions = { click = addTarget(targets, "cancel-move", drawerId .. ".move.cancel", "cancel-move", nil, nil) },
				shrink = 0,
			}),
		}))
	end
	local tabActions: { [string]: any } = {}
	if snapshot.sidebarMode ~= "always" then
		tabActions.menu = { addTarget(targets, "sidebar-settings", rootId .. ".tab", "settings", nil, nil) }
	end
	if snapshot.sidebarMode == "click" then
		tabActions.click = addTarget(targets, "toggle-panel", rootId .. ".tab", "toggle-panel", nil, nil)
	end
	local tabTitle = if snapshot.sidebarMode == "click"
		then (if display.open then "Close Sessions sidebar" else "Open Sessions sidebar")
		else "Sessions sidebar"
	local signature: { string } = {}
	addSignature(signature, snapshot.sidebarMode)
	addSignature(signature, tostring(display.open))
	addSignature(signature, tostring(display.holdOpen))
	addSignature(signature, if moving then moving.kind else "")
	addSignature(signature, if moving then idKey(moving.host) else "")
	addSignature(signature, if movingSession then idKey(movingSession) else "")
	addSignature(signature, movingName)
	addSignature(signature, tostring(#groups))

	-- A host group's session rows under `groupId`, in its saved order (snapshot.sessionRank), or
	-- "No sessions".
	local function sessionRows(group: Group, groupId: string): { Node }
		local host = group.host
		local connected = host.state == "connected"
		local section: { Node } = {}
		addSignature(signature, group.key)
		addSignature(signature, group.label)
		addSignature(signature, host.state)
		addSignature(signature, tostring(group.collapsed))
		addSignature(signature, tostring(#group.rows))

		-- Rows follow their host's saved order (snapshot.sessionRank).
		for _, session in group.rows do
			local sessionKey = idKey(session.id)
			local metadata = snapshot.sessions[sessionKey]
			local rowId = groupId .. ".session-" .. sessionKey
			local iconId = rowId .. ".icon"
			local sessionMenu = {
				addTarget(targets, "rename-session", rowId, "rename-session", host.id, session.id),
				addTarget(targets, "move-session", rowId, "move-session", host.id, session.id),
				addTarget(targets, "change-icon", rowId, "change-icon", host.id, session.id),
				addTarget(targets, "reset-icon", rowId, "reset-icon", host.id, session.id),
			}
			local label = session.name
			if session.locked then
				label ..= " · locked"
			end
			local actions: { [string]: any } = { menu = sessionMenu }
			local rowTitle = label
			local rowMark: string? = nil
			local iconActions: { [string]: any }? = nil
			if not moving then
				if connected then
					actions.click = addTarget(targets, "switch-session", rowId, "switch", host.id, session.id)
				end
				addTarget(targets, "rename-session", iconId, "rename-session", host.id, session.id)
				addTarget(targets, "move-session", iconId, "move-session", host.id, session.id)
				addTarget(targets, "reset-icon", iconId, "reset-icon", host.id, session.id)
				iconActions = {
					click = addTarget(targets, "change-icon", iconId, "change-icon", host.id, session.id),
					menu = sessionMenu,
				}
			elseif moving.kind ~= "session" or moving.host ~= host.id then
				rowMark = "drop"
			elseif moving.session == session.id then
				rowMark = "pick"
				rowTitle = "Cancel move"
				actions.click = addTarget(targets, "cancel-move", rowId, "cancel-move", nil, nil)
			else
				rowTitle = "Move here"
				actions.click = addTarget(targets, "place-session", rowId, "place-session", host.id, session.id)
			end
			-- While moving, the icon carries no actions (its right-click reaches the
			-- row's identical menu) so every click lands on the row.
			local iconProps: { [string]: any } = {
				key = "icon",
				role = "sessions-sidebar-icon",
				title = if moving then nil else "Change icon for " .. session.name,
				aria = "Change icon for " .. session.name,
				actions = iconActions,
				shrink = 0,
			}
			local icon: Node
			if metadata.icon.kind == "named" then
				iconProps.name = metadata.icon.value
				icon = ui.node("icon", iconProps)
			else
				iconProps.text = metadata.icon.value
				icon = ui.el("span", iconProps)
			end
			local counts = if marks then marks[sessionKey] else nil
			local markNode, markCount = agentMarks(counts)
			local path = if metadata.path == "" then "Path unavailable" else displayPath(metadata.path)
			if snapshot.sidebarMode ~= "always" then
				path = fitPath(path, OVERLAY_PATH_CELLS - MARK_CELLS * markCount)
			end
			local pathTitle = if metadata.path == "" then "Path unavailable" else metadata.path
			local props: { [string]: any } = {
				key = "session-" .. sessionKey,
				role = if session.current then "sessions-sidebar-current" else "sessions-sidebar-session",
				title = rowTitle,
				mark = rowMark,
				actions = actions,
				align = "center",
				shrink = 0,
			}
			if not connected then
				props.tone = "muted"
			end
			local rowChildren: { Node } = {
				icon,
				with(ui.col({
					with(ui.text(label), {
						key = "name",
						role = "sessions-sidebar-name",
						wrap = "none",
						truncate = "end",
						title = label,
					}),
					with(ui.text(ui.span(path, "path")), {
						key = "path",
						role = "sessions-sidebar-path",
						wrap = "none",
						truncate = "middle",
						title = pathTitle,
					}),
				}), {
					key = "labels",
					role = "sessions-sidebar-labels",
					grow = 1,
					shrink = 1,
				}),
			}
			if markNode then
				-- Flush right after the labels, which shrink to make room.
				table.insert(rowChildren, markNode)
			end
			table.insert(section, with(ui.row(rowChildren), props))

			addSignature(signature, sessionKey)
			addSignature(signature, session.name)
			addSignature(signature, if session.current then "1" else "0")
			addSignature(signature, if session.locked then "1" else "0")
			addSignature(signature, metadata.icon.kind)
			addSignature(signature, metadata.icon.value)
			addSignature(signature, metadata.path)
			addSignature(signature, if counts
				then tostring(counts.question) .. "/" .. tostring(counts.working) .. "/" .. tostring(counts.done)
				else "")
		end

		if not group.collapsed and #group.rows == 0 then
			table.insert(section, with(ui.text("No sessions"), {
				key = "empty",
				role = "sessions-sidebar-empty",
				tone = "muted",
			}))
		end
		return section
	end

	-- One ordinary host's heading and session rows. A remote host's menu adds Remove host….
	local function hostSection(group: Group, parentId: string): Node
		local host = group.host
		local connected = host.state == "connected"
		local groupId = parentId .. ".host-" .. group.key
		local headingId = groupId .. ".heading"
		local hostMenu: { string } = {}
		if connected then
			table.insert(hostMenu, addTarget(targets, "new-session", headingId, "new-session", host.id, nil))
		end
		table.insert(hostMenu, addTarget(targets, "move-host", headingId, "move-host", host.id, nil))
		table.insert(hostMenu, addTarget(targets, "rename-host-title", headingId, "rename-host", host.id, nil))
		table.insert(hostMenu, addTarget(targets, "reset-host-title", headingId, "reset-host", host.id, nil))
		table.insert(hostMenu, addTarget(targets, "change-title-color", headingId, "host-color", host.id, nil))
		if host.kind == "remote" then
			table.insert(hostMenu, addTarget(targets, "remove-host…", headingId, "remove-host", host.id, nil))
		end
		local color = snapshot.hostColors[group.key]
		local heading = group.label
		if not connected then
			heading ..= " · " .. host.state
		end
		local tooltip = heading
		local toggleTitle = (if group.collapsed then "Expand sessions on " else "Collapse sessions on ") .. group.label
		local headingActions: { [string]: any } = { menu = hostMenu }
		local headingProps: { [string]: any } = {
			key = "heading",
			role = "sessions-sidebar-heading",
			title = tooltip,
			align = "center",
			actions = headingActions,
		}
		-- While moving, child buttons carry no actions or titles so every click reaches the heading.
		if moving then
			if moving.kind ~= "host" then
				headingProps.mark = "drop"
			elseif moving.host == host.id then
				headingProps.mark = "pick"
				headingProps.title = "Cancel move"
				headingActions.click = addTarget(targets, "cancel-move", headingId, "cancel-move", nil, nil)
			else
				headingProps.title = "Move here"
				headingActions.click = addTarget(targets, "place-host", headingId, "place-host", host.id, nil)
			end
		end
		local headingChildren: { Node } = {
			ui.el("button", {
				key = "toggle",
				role = "sessions-sidebar-host-toggle",
				text = if group.collapsed then "+" else "-",
				title = if moving then nil else toggleTitle,
				aria = toggleTitle,
				attrs = { ["aria-expanded"] = tostring(not group.collapsed) },
				actions = if moving
					then nil
					else { click = addTarget(targets, "toggle-host", headingId .. ".toggle", "toggle-host", host.id, nil) },
				shrink = 0,
			}),
			-- Text nodes drop `attrs`, so the title color rides on a wrapper element;
			-- window.luau installs one CSS rule per color in use (validated "#rrggbb").
			ui.el("div", {
				key = "label",
				role = "sessions-sidebar-host-label",
				attrs = if color then { ["data-host-color"] = color } else nil,
				grow = 1,
				shrink = 1,
			}, {
				with(ui.text(heading), {
					key = "title",
					role = "sessions-sidebar-host-title",
					title = tooltip,
					wrap = "none",
					truncate = "end",
					grow = 1,
					shrink = 1,
				}),
			}),
		}
		if connected then
			local newTitle = "New session on " .. group.label
			table.insert(headingChildren, ui.el("button", {
				key = "new",
				role = "sessions-sidebar-host-new",
				title = if moving then nil else newTitle,
				aria = newTitle,
				actions = if moving
					then nil
					else { click = addTarget(targets, "new-session", headingId .. ".new", "new-session", host.id, nil) },
				shrink = 0,
			}, {
				ui.node("icon", { key = "icon", name = "plus" }),
			}))
		end
		addSignature(signature, color or "")
		addSignature(signature, table.concat(hostMenu, "|"))
		local section: { Node } = {
			with(ui.row(headingChildren), headingProps),
		}
		for _, row in sessionRows(group, groupId) do
			table.insert(section, row)
		end
		return with(ui.col(section), {
			key = "host-" .. group.key,
			role = "sessions-sidebar-host",
		})
	end

	-- The Boat section comes first (boat-view.luau): every sandbox of the boat.dev account as one
	-- row, never its host's session rows. A boat sandbox host is never drawn as an ordinary host,
	-- even before that module is loaded (window.luau loads it before the first refresh when there
	-- is something to show).
	local boatDisplay = display.boats
	local boatView = if boatDisplay then boatDisplay.view else nil
	local regular: { Group } = {}
	local boatGroups: { { [string]: any } } = {}
	for _, group in groups do
		local record = snapshot.hostBoats[group.key]
		local address = group.host.address
		local id = if record
			then record.id
			elseif boatDisplay and address and group.host.kind == "remote" then boatDisplay.byAddress[data.comparableAddress(address)]
			else nil
		if id then
			table.insert(boatGroups, { host = group.host, key = group.key, label = group.label, id = id, rows = group.all })
		else
			table.insert(regular, group)
		end
	end
	if boatDisplay and not boatView and (boatDisplay.wanted or #boatGroups > 0 or #snapshot.detachedBoats > 0) then
		boatDisplay.needView()
	end
	local boatSection: Node? = nil
	if boatDisplay and boatView then
		boatSection = boatView.section({
			id = drawerId .. ".boats",
			snapshot = snapshot,
			display = boatDisplay.state,
			groups = boatGroups,
			moving = moving ~= nil,
			now = boatDisplay.now,
			target = function(action: string, node: string, target: { [string]: any }): string
				targets[action .. "\n" .. node] = target :: any
				return action
			end,
			sig = function(value: string)
				addSignature(signature, value)
			end,
			-- The agent marks of a sandbox's sessions, summed, as on a session row.
			marks = function(sessions: { ManagedSession }): Node?
				if not marks then
					return nil
				end
				local total = { question = 0, working = 0, done = 0 }
				for _, session in sessions do
					local counts = marks[idKey(session.id)]
					if counts then
						total.question += counts.question
						total.working += counts.working
						total.done += counts.done
					end
				end
				addSignature(signature, tostring(total.question) .. "/" .. tostring(total.working) .. "/" .. tostring(total.done))
				return (agentMarks(total))
			end,
		})
	end
	addSignature(signature, if boatSection then "boats" else "")
	if boatSection then
		table.insert(children, boatSection)
	end
	for _, group in regular do
		table.insert(children, hostSection(group, drawerId))
	end

	if #groups == 0 then
		table.insert(children, with(ui.text("No attached hosts"), {
			key = "empty",
			role = "sessions-sidebar-empty",
			tone = "muted",
		}))
	end

	return {
		view = ui.el("aside", {
			key = "sessions-sidebar",
			role = "sessions-sidebar",
			class = "sessions-sidebar-root",
			attrs = {
				["data-sidebar-mode"] = snapshot.sidebarMode,
				["data-sidebar-open"] = tostring(display.open),
				["data-sidebar-hold"] = tostring(display.holdOpen),
				["data-sidebar-moving"] = if moving then moving.kind else "",
			},
		}, {
			ui.el("button", {
				key = "tab",
				role = "sessions-sidebar-tab",
				class = "sessions-sidebar-tab",
				title = tabTitle,
				aria = tabTitle,
				actions = tabActions,
			}, {
				ui.node("icon", { key = "icon", name = "sidebar" }),
			}),
			ui.el("div", {
				key = "drawer",
				role = "sessions-sidebar-drawer",
				class = "sessions-sidebar-drawer",
			}, children),
		}),
		signature = table.concat(signature),
		targets = targets,
	}
end

return { build = build }
