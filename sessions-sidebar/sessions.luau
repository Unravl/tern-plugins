--!strict

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

type TargetKind = "switch" | "rename-session" | "change-icon" | "reset-icon" | "rename-host" | "reset-host" | "new-session" | "toggle-host" | "settings" | "toggle-panel" | "move-host" | "move-session" | "place-host" | "place-session" | "cancel-move"

export type Target = {
	kind: TargetKind,
	host: number?,
	session: number?,
}

-- The one item lifted for pick-and-place reordering; `session` is set only for kind "session".
export type Moving = {
	kind: "host" | "session",
	host: number,
	session: number?,
}

export type Display = {
	open: boolean,
	holdOpen: boolean,
	moving: Moving?,
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
	rows: { ManagedSession },
}

local ui = tern.ui

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

-- Overlay drawers have a fixed 210px path column at 11px monospace (~31 cells; the reorder
-- grip takes 12px), and Tern's own truncation measures the floating pane's cells, not that
-- column. Drop whole leading directories so the meaningful end stays visible; docked mode
-- keeps Tern's native truncation.
local OVERLAY_PATH_CELLS = 30

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

local statusLabels: { [string]: string } = {
	active = "Active",
	working = "Working",
	loaded = "Loaded",
	unloaded = "Not loaded",
	unavailable = "Unavailable",
}

local statusTones: { [string]: string } = {
	active = "accent",
	working = "pending",
	loaded = "success",
	unloaded = "muted",
	unavailable = "error",
}

local function build(hosts: { ManagedHost }, rows: { ManagedSession }, snapshot: data.Snapshot, display: Display): BuiltView
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
		}
		byHost[key] = group
		table.insert(groups, group)
	end

	-- Group by the actual host slot, never a display name or encoded session bits.
	for _, session in rows do
		local group = byHost[idKey(session.host)]
		if group and not group.collapsed then
			table.insert(group.rows, session)
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

	for _, group in groups do
		local host = group.host
		local connected = host.state == "connected"
		local groupId = drawerId .. ".host-" .. group.key
		local headingId = groupId .. ".heading"
		local hostMenu: { string } = {}
		if connected then
			table.insert(hostMenu, addTarget(targets, "new-session", headingId, "new-session", host.id, nil))
		end
		table.insert(hostMenu, addTarget(targets, "move-host", headingId, "move-host", host.id, nil))
		table.insert(hostMenu, addTarget(targets, "rename-host-title", headingId, "rename-host", host.id, nil))
		table.insert(hostMenu, addTarget(targets, "reset-host-title", headingId, "reset-host", host.id, nil))
		local heading = group.label
		if not connected then
			heading ..= " · " .. host.state
		end
		local toggleTitle = (if group.collapsed then "Expand sessions on " else "Collapse sessions on ") .. group.label
		local hostMoveTitle = "Move " .. group.label
		local headingActions: { [string]: any } = { menu = hostMenu }
		local headingProps: { [string]: any } = {
			key = "heading",
			role = "sessions-sidebar-heading",
			title = heading,
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
				key = "grip",
				role = "sessions-sidebar-host-grip",
				title = if moving then nil else hostMoveTitle,
				aria = hostMoveTitle,
				actions = if moving
					then nil
					else { click = addTarget(targets, "move-host", headingId .. ".grip", "move-host", host.id, nil) },
				shrink = 0,
			}, {
				ui.node("icon", { key = "icon", name = "grip" }),
			}),
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
			with(ui.text(heading), {
				key = "title",
				role = "sessions-sidebar-host-title",
				title = heading,
				wrap = "none",
				truncate = "end",
				grow = 1,
				shrink = 1,
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
		local section: { Node } = {
			with(ui.row(headingChildren), headingProps),
		}

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
			local sessionMoveTitle = "Move " .. session.name
			local actions: { [string]: any } = { menu = sessionMenu }
			local rowTitle = label
			local rowMark: string? = nil
			local gripActions: { [string]: any }? = nil
			local iconActions: { [string]: any }? = nil
			if not moving then
				if connected then
					actions.click = addTarget(targets, "switch-session", rowId, "switch", host.id, session.id)
				end
				gripActions = { click = addTarget(targets, "move-session", rowId .. ".grip", "move-session", host.id, session.id) }
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
			-- While moving, the grip and icon carry no actions (their right-click reaches the
			-- row's identical menu) so every click lands on the row.
			local grip = ui.el("button", {
				key = "grip",
				role = "sessions-sidebar-grip",
				title = if moving then nil else sessionMoveTitle,
				aria = sessionMoveTitle,
				actions = gripActions,
				shrink = 0,
			}, {
				ui.node("icon", { key = "icon", name = "grip" }),
			})
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
			local path = if metadata.path == "" then "Path unavailable" else displayPath(metadata.path)
			if snapshot.sidebarMode ~= "always" then
				path = fitPath(path, OVERLAY_PATH_CELLS)
			end
			local pathTitle = if metadata.path == "" then "Path unavailable" else metadata.path
			local status = statusLabels[metadata.status]
			local statusTitle = status .. " · " .. metadata.statusDetail
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
			table.insert(section, with(ui.row({
				grip,
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
				ui.el("span", {
					key = "status",
					role = "sessions-sidebar-status",
					tone = statusTones[metadata.status],
					title = statusTitle,
					aria = statusTitle,
					shrink = 0,
				}),
			}), props))

			addSignature(signature, sessionKey)
			addSignature(signature, session.name)
			addSignature(signature, if session.current then "1" else "0")
			addSignature(signature, if session.locked then "1" else "0")
			addSignature(signature, metadata.icon.kind)
			addSignature(signature, metadata.icon.value)
			addSignature(signature, metadata.path)
			addSignature(signature, metadata.status)
			addSignature(signature, metadata.statusDetail)
		end

		if not group.collapsed and #group.rows == 0 then
			table.insert(section, with(ui.text("No sessions"), {
				key = "empty",
				role = "sessions-sidebar-empty",
				tone = "muted",
			}))
		end
		table.insert(children, with(ui.col(section), {
			key = "host-" .. group.key,
			role = "sessions-sidebar-host",
		}))
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
