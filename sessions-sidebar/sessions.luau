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

type TargetKind = "switch" | "rename-session" | "change-icon" | "reset-icon" | "rename-host" | "reset-host" | "new-session" | "toggle-host" | "settings" | "toggle-panel"

export type Target = {
	kind: TargetKind,
	host: number?,
	session: number?,
}

export type Display = {
	open: boolean,
	holdOpen: boolean,
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
	sortLabel: string,
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

-- Overlay drawers have a fixed 222px path column at 11px monospace (~33 cells), and Tern's
-- own truncation measures the floating pane's cells, not that column. Drop whole leading
-- directories so the meaningful end stays visible; docked mode keeps Tern's native truncation.
local OVERLAY_PATH_CELLS = 32

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
			sortLabel = string.lower(label),
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

	table.sort(groups, function(a: Group, b: Group): boolean
		if a.host.kind ~= b.host.kind then
			return a.host.kind == "local"
		end
		if a.sortLabel ~= b.sortLabel then
			return a.sortLabel < b.sortLabel
		end
		if a.label ~= b.label then
			return a.label < b.label
		end
		return a.host.id < b.host.id
	end)

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
		table.insert(hostMenu, addTarget(targets, "rename-host-title", headingId, "rename-host", host.id, nil))
		table.insert(hostMenu, addTarget(targets, "reset-host-title", headingId, "reset-host", host.id, nil))
		local heading = group.label
		if not connected then
			heading ..= " · " .. host.state
		end
		local toggleTitle = (if group.collapsed then "Expand sessions on " else "Collapse sessions on ") .. group.label
		local section: { Node } = {
			with(ui.row({
				ui.el("button", {
					key = "toggle",
					role = "sessions-sidebar-host-toggle",
					text = if group.collapsed then "+" else "-",
					title = toggleTitle,
					aria = toggleTitle,
					attrs = { ["aria-expanded"] = tostring(not group.collapsed) },
					actions = { click = addTarget(targets, "toggle-host", headingId .. ".toggle", "toggle-host", host.id, nil) },
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
			}), {
				key = "heading",
				role = "sessions-sidebar-heading",
				title = heading,
				align = "center",
				actions = { menu = hostMenu },
			}),
		}

		addSignature(signature, group.key)
		addSignature(signature, group.label)
		addSignature(signature, host.state)
		addSignature(signature, tostring(group.collapsed))
		addSignature(signature, tostring(#group.rows))

		-- Rows retain the session API's order within their own host.
		for _, session in group.rows do
			local sessionKey = idKey(session.id)
			local metadata = snapshot.sessions[sessionKey]
			local rowId = groupId .. ".session-" .. sessionKey
			local iconId = rowId .. ".icon"
			local sessionMenu = {
				addTarget(targets, "rename-session", rowId, "rename-session", host.id, session.id),
				addTarget(targets, "change-icon", rowId, "change-icon", host.id, session.id),
				addTarget(targets, "reset-icon", rowId, "reset-icon", host.id, session.id),
			}
			addTarget(targets, "rename-session", iconId, "rename-session", host.id, session.id)
			local changeIcon = addTarget(targets, "change-icon", iconId, "change-icon", host.id, session.id)
			addTarget(targets, "reset-icon", iconId, "reset-icon", host.id, session.id)
			local label = session.name
			if session.locked then
				label ..= " · locked"
			end
			local actions: { [string]: any } = { menu = sessionMenu }
			if connected then
				actions.click = addTarget(targets, "switch-session", rowId, "switch", host.id, session.id)
			end
			local iconProps: { [string]: any } = {
				key = "icon",
				role = "sessions-sidebar-icon",
				title = "Change icon for " .. session.name,
				aria = "Change icon for " .. session.name,
				actions = { click = changeIcon, menu = sessionMenu },
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
				title = label,
				actions = actions,
				align = "center",
				shrink = 0,
			}
			if not connected then
				props.tone = "muted"
			end
			table.insert(section, with(ui.row({
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
