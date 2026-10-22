--!strict
-- The Boat section of the sidebar: its header (+ and menu), plan usage, one row per sandbox in the
-- boat.dev account (tracked ones under their sidebar name, the rest under their boat name; a row
-- stands for its host when it is attached here, which never shows as a host group of its own),
-- sandboxes being created, and the Snapshots list. Plain view tables (tsp.luau); every action's
-- target is registered through the caller. Compiled before the first refresh or on first use (see
-- core.luau), never inside the load hook.
local boats = require("./boats")
local data = require("./session-data")
local ui = require("./tsp")

type Node = ui.Node

-- An attached host that is a boat sandbox, with every session on it.
export type BoatGroup = {
	host: ManagedHost,
	key: string,
	label: string,
	id: string,
	rows: { ManagedSession },
}
-- A sandbox being created (New sandbox, Duplicate): its title and second line.
export type Creating = { title: string, detail: string }
-- A snapshot being saved from sandbox `source` (`title`).
export type Saving = { name: string, source: string, title: string }

-- Window-local Boat section state (core.luau's display.boats).
export type Display = {
	-- Operation in progress by sandbox id: "starting", "stopping", "saving", "deleting", …
	ops: { [string]: string },
	creating: { Creating },
	saving: { Saving },
	-- Operation in progress by snapshot name ("deleting").
	snapshotOps: { [string]: string },
	inventory: boats.Inventory?,
	failed: string?,
	busy: boolean,
	usage: boats.UsageView?,
	snapshotsCollapsed: boolean,
	-- Show details: each sandbox's second line (size · auto-stop or disk · cost).
	details: boolean,
	desktop: boolean,
}

export type Context = {
	-- This section's node id (the drawer's id .. ".boats").
	id: string,
	snapshot: data.Snapshot,
	display: Display,
	groups: { BoatGroup },
	moving: boolean,
	now: number,
	-- Registers `target` for action `action` on node `node`; returns the action name.
	target: (action: string, node: string, target: { [string]: any }) -> string,
	sig: (value: string) -> (),
	-- The omp agent marks of these sessions together, drawn like a session row's; nil for none.
	marks: (rows: { ManagedSession }) -> Node?,
}

type Entry = {
	id: string,
	-- The row's name: a tracked sandbox's sidebar name, else its boat name.
	title: string,
	name: string,
	record: data.Boat?,
	sandbox: boats.Sandbox?,
	group: BoatGroup?,
	-- Tracked, but an account listing newer than the record no longer has it.
	gone: boolean,
}

type Look = {
	state: string,
	tone: string,
	why: string?,
	busy: boolean,
	running: boolean,
	stopped: boolean,
	connected: boolean,
	icon: string,
}

local DAY = 86400
-- A stopped sandbox's disk is deleted after 14 days; within this the line turns amber.
local DISK_WARNING = 3 * DAY
-- U+2011 keeps the hyphen: Tern shows "-" in action names as a space.
local AUTO_STOP = "Auto\u{2011}stop…"

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for key, value in props do
		p[key] = value
	end
	node.p = p
	return node
end

local function plainText(spans: { any }): string
	local parts: { string } = {}
	for _, span in spans do
		table.insert(parts, if type(span) == "string" then span else span.t)
	end
	return table.concat(parts)
end

-- A key safe inside a dotted node id (snapshot names may hold ".").
local function keyOf(name: string): string
	return (string.gsub(name, "[^%w_%-]", function(c: string): string
		return string.format("~%02x", string.byte(c))
	end))
end

-- ---------- sandboxes ----------

local function collect(ctx: Context): { Entry }
	local snapshot = ctx.snapshot
	local inventory = ctx.display.inventory
	local byId: { [string]: Entry } = {}
	local list: { Entry } = {}
	local function entry(id: string): Entry
		local found = byId[id]
		if not found then
			found = { id = id, title = id, name = id, gone = false }
			byId[id] = found
			table.insert(list, found)
		end
		return found :: Entry
	end
	local recordTitles: { [string]: string } = {}
	for _, record in snapshot.hostBoats do
		entry(record.id).record = record
	end
	for _, detached in snapshot.detachedBoats do
		entry(detached.boat.id).record = detached.boat
		recordTitles[detached.boat.id] = detached.title
	end
	for _, attached in ctx.groups do
		entry(attached.id).group = attached
	end
	if inventory then
		for _, sandbox in inventory.sandboxes do
			entry(sandbox.id).sandbox = sandbox
		end
	end
	local fetchedAt = if inventory then inventory.fetchedAt else nil
	for _, item in list do
		local record, sandbox, group = item.record, item.sandbox, item.group
		item.name = if record then record.name elseif sandbox then sandbox.name else item.id
		if group and snapshot.hostAliased[group.key] then
			item.title = group.label
		elseif record then
			item.title = recordTitles[item.id] or record.title
		elseif sandbox then
			item.title = sandbox.name
		elseif group then
			item.title = group.label
		end
		-- "Boat Sandbox (demo)" shows as "demo".
		item.title = boats.nameOfTitle(item.title)
		item.gone = record ~= nil and sandbox == nil and fetchedAt ~= nil and (record.savedAt or 0) < fetchedAt
	end
	-- Untracked sandboxes made from one snapshot share its name: tell them apart by id.
	local seen: { [string]: number } = {}
	for _, item in list do
		seen[string.lower(item.title)] = (seen[string.lower(item.title)] or 0) + 1
	end
	for _, item in list do
		if seen[string.lower(item.title)] > 1 and not item.record then
			item.title ..= " · " .. item.id
		end
	end
	table.sort(list, function(a: Entry, b: Entry): boolean
		local left, right = string.lower(a.title), string.lower(b.title)
		if left ~= right then
			return left < right
		end
		return a.id < b.id
	end)
	return list
end

local function lookOf(ctx: Context, item: Entry): Look
	local op = ctx.display.ops[item.id]
	local sandbox, record, group = item.sandbox, item.record, item.group
	local host = if group then group.host else nil
	local remote = if sandbox then sandbox.state else nil
	local running = if remote then remote == "running" else (record ~= nil and record.state ~= "stopped" and not item.gone)
	local stopped = if remote then remote == "stopped" else (record ~= nil and record.state == "stopped")
	local connected = host ~= nil and host.state == "connected"
	local look: Look = {
		state = "running",
		tone = "success",
		why = nil,
		busy = false,
		running = running,
		stopped = stopped,
		connected = connected,
		icon = "plug",
	}
	if op then
		look.state, look.tone, look.busy = op, "pending", true
		return look
	end
	if item.gone then
		look.state, look.tone, look.icon = "gone", "muted", "slash-circle"
		look.why = "boat.dev no longer lists this sandbox; it was deleted elsewhere"
		return look
	end
	if remote == "starting" or remote == "stopping" or remote == "deleting" then
		look.state, look.tone, look.busy = remote :: string, "pending", true
		return look
	end
	if host and not stopped and remote ~= "error" then
		if host.state == "connected" then
			look.why = nil
		elseif host.state == "failed" then
			local detail = host.detail
			look.state, look.tone, look.icon = "error", "error", "warn"
			look.why = (if detail then detail.error else nil) or "Tern could not connect"
		else
			look.state, look.tone = "connecting", "pending"
			look.why = "Tern is " .. host.state
		end
		return look
	end
	if remote == "error" then
		look.state, look.tone, look.icon = "error", "error", "warn"
		look.why = (if sandbox then sandbox.error else nil) or "boat.dev reports an error"
		return look
	end
	if record and record.error then
		look.state, look.tone, look.icon = "error", "error", "warn"
		look.why = record.error
		return look
	end
	if stopped then
		look.state, look.tone, look.icon = "stopped", "muted", "power"
		return look
	end
	look.why = "Running, but not connected in this window"
	return look
end

-- The second line: size · auto-stop or stopped time and disk · cost.
local function detailSpans(ctx: Context, item: Entry, look: Look): { any }
	local now = ctx.now
	local sandbox = item.sandbox
	local parts: { any } = {}
	local function add(span: any)
		if #parts > 0 then
			table.insert(parts, " · ")
		end
		table.insert(parts, span)
	end
	if sandbox and sandbox.type then
		add(sandbox.type)
	end
	if sandbox then
		if look.stopped then
			local stoppedAt = sandbox.stoppedAt
			add(if stoppedAt and now > 0 then "stopped " .. boats.span(math.max(0, now - stoppedAt)) .. " ago" else "stopped")
			local expires = sandbox.dataExpiresAt
			if expires and now > 0 then
				if expires <= now then
					add(ui.span("disk deleted", "error"))
				else
					local kept = "disk kept until " .. (boats.shortDate(expires) or "?")
					add(if expires - now <= DISK_WARNING then ui.span(kept, "warning") else kept)
				end
			end
		elseif sandbox.state == "running" then
			if sandbox.noAutoStop then
				add("no auto-stop")
			elseif sandbox.autoStopAt and now > 0 then
				local remaining = sandbox.autoStopAt - now
				add(if remaining > 0 then "stops in " .. boats.left(remaining) else "stopping soon")
			end
		end
		local usage = sandbox.usage
		if usage then
			add(boats.money(usage.dollars))
		end
	elseif item.record then
		add(if look.stopped then "stopped" else (if item.gone then "not in your account" else "status unavailable"))
	end
	return parts
end

-- What a click on the row does: "switch" into the sandbox's session (attached here), "connect" it
-- here and then switch (running, not attached), else nothing (stopped, busy, gone, boat's error).
local function clickOf(item: Entry, look: Look): string?
	if look.busy or item.gone then
		return nil
	elseif look.connected then
		return "switch"
	elseif look.running and not look.stopped and look.state ~= "connecting" then
		return "connect"
	end
	return nil
end

-- The row's tooltip: state, the details line (Show details also puts it under the name), the rest
-- of what is known, and what a click does.
local function tooltipOf(ctx: Context, item: Entry, look: Look, detail: string, click: string?): string
	local now = ctx.now
	local sandbox = item.sandbox
	local lines = { item.title .. " · " .. look.state .. (if look.why then ": " .. look.why else "") }
	if detail ~= "" then
		table.insert(lines, detail)
	end
	local size = boats.sizeOf(if sandbox then sandbox.type else nil)
	table.insert(
		lines,
		item.id .. (if size then " · " .. size.id .. ": " .. boats.sizeDetail(size) elseif sandbox and sandbox.type then " · " .. sandbox.type else "")
	)
	if item.record == nil then
		table.insert(lines, "Boat name " .. item.name .. "; not tracked by the sidebar until you connect it")
	end
	if sandbox then
		if look.stopped then
			local stoppedAt = boats.dateTime(sandbox.stoppedAt)
			local expires = boats.dateTime(sandbox.dataExpiresAt)
			table.insert(
				lines,
				(if stoppedAt then "Stopped " .. stoppedAt else "Stopped")
					.. (if expires
						then (if (sandbox.dataExpiresAt :: number) > now then "; its disk is kept until " else "; its disk was deleted ") .. expires
						else "; its disk is kept for 14 days")
			)
		elseif sandbox.state == "running" then
			if sandbox.noAutoStop then
				table.insert(lines, "No auto-stop: it runs until you stop it")
			elseif sandbox.autoStopAt then
				table.insert(lines, "Stops by itself " .. (boats.dateTime(sandbox.autoStopAt) or "?"))
			end
		end
		if sandbox.environment then
			table.insert(lines, "Environment " .. sandbox.environment)
		end
		if sandbox.createdAt then
			table.insert(lines, "Created " .. (boats.dateTime(sandbox.createdAt) or "?"))
		end
		if sandbox.usage then
			table.insert(
				lines,
				"Compute since created: " .. boats.hours(sandbox.usage.seconds) .. " · " .. boats.money(sandbox.usage.dollars)
			)
		end
		if sandbox.address then
			table.insert(lines, "Address " .. sandbox.address)
		end
	end
	local group = item.group
	if group then
		table.insert(lines, if look.connected then "Connected in this window" else "Tern host here: " .. group.host.state)
	end
	if click == "switch" then
		table.insert(lines, "Click to switch to it; right-click for more")
	elseif click == "connect" then
		table.insert(lines, "Click to connect it here and switch to it; right-click for more")
	elseif item.gone then
		table.insert(lines, "Right-click to forget it")
	elseif look.busy then
		table.insert(lines, "Busy " .. look.state .. "; right-click for more")
	elseif look.stopped then
		table.insert(lines, "Right-click to start it")
	else
		table.insert(lines, "Right-click for more")
	end
	return table.concat(lines, "\n")
end

-- The entry's right-click menu, by state.
local function menuOf(ctx: Context, item: Entry, look: Look, node: string): { string }
	local menu: { string } = {}
	local id = item.id
	local group = item.group
	local function op(label: string, name: string)
		table.insert(menu, ctx.target(label, node, { kind = "boat", boat = id, op = name }))
	end
	local function hostAction(label: string, kind: string)
		if group then
			table.insert(menu, ctx.target(label, node, { kind = kind, host = group.host.id }))
		end
	end
	if look.busy then
		op("Copy sandbox ID", "copy-id")
		op("Rename…", "rename")
		return menu
	end
	if item.gone then
		op("Forget", "forget")
		op("Copy sandbox ID", "copy-id")
		return menu
	end
	if look.stopped then
		op("Start", "start")
		op("Start as size…", "start-as")
		op("Save snapshot…", "snapshot")
		op("Duplicate…", "duplicate")
		op("Copy sandbox ID", "copy-id")
		op("Rename…", "rename")
		if group then
			op("Remove from Tern", "remove")
		end
		op("Delete…", "delete")
		return menu
	end
	if look.running and not look.connected then
		op("Connect", "connect")
	end
	if look.running then
		op("Save snapshot…", "snapshot")
		op("Duplicate…", "duplicate")
		op(AUTO_STOP, "auto-stop")
		op("Resize…", "resize")
		op("Open SSH terminal", "ssh")
		op("Copy SSH details…", "ssh-details")
		if ctx.display.desktop then
			op("Open desktop", "desktop")
		end
	end
	op("Copy sandbox ID", "copy-id")
	op("Rename…", "rename")
	if look.connected then
		hostAction("change-title-color", "host-color")
	end
	if group then
		op("Remove from Tern", "remove")
	end
	op("Stop…", "stop")
	op("Delete…", "delete")
	return menu
end

-- The name (and with Show details the second line) of a sandbox row; muted unless attached here.
local function label(title: string, detail: { any }?, tooltip: string, attached: boolean, color: string?): Node
	local attrs: { [string]: string } = { ["data-boat"] = if attached then "attached" else "detached" }
	if color then
		attrs["data-host-color"] = color
	end
	local children: { Node } = {
		with(ui.text(title), {
			key = "name",
			role = "sessions-sidebar-boat-name",
			title = tooltip,
			wrap = "none",
			truncate = "end",
		}),
	}
	if detail and #detail > 0 then
		table.insert(children, with(ui.text(detail), {
			key = "detail",
			role = "sessions-sidebar-boat-detail",
			title = tooltip,
			wrap = "none",
			truncate = "end",
		}))
	end
	return ui.el("div", {
		key = "label",
		role = "sessions-sidebar-boat-label",
		attrs = attrs,
		grow = 1,
		shrink = 1,
	}, children)
end

local function spinner(key: string, role: string, aria: string): Node
	return ui.node("spinner", { key = key, role = role, style = "orbit", aria = aria })
end

-- One sandbox: a single row with its name, a badge unless it runs, and the agent marks of its
-- host's sessions; highlighted while the current session is on that host, like a session row.
local function entryNode(ctx: Context, item: Entry): Node
	local look = lookOf(ctx, item)
	local detail = detailSpans(ctx, item, look)
	local detailText = plainText(detail)
	local click = if ctx.moving then nil else clickOf(item, look)
	local tooltip = tooltipOf(ctx, item, look, detailText, click)
	local group = item.group
	local key = "boat-" .. item.id
	local rowId = ctx.id .. "." .. key
	local menu = menuOf(ctx, item, look, rowId)
	local color = if group then ctx.snapshot.hostColors[group.key] else nil
	local current = false
	if group then
		for _, row in group.rows do
			if row.current then
				current = true
				break
			end
		end
	end
	local shown = ctx.display.details
	local children: { Node } = {
		if look.busy
			then spinner("status", "sessions-sidebar-boat-status", look.state)
			else ui.node("icon", {
				key = "status",
				role = "sessions-sidebar-boat-status",
				name = look.icon,
				aria = look.state,
			}),
		label(item.title, if shown then detail else nil, tooltip, look.connected, color),
	}
	if look.state ~= "running" then
		table.insert(children, with(ui.badge(look.state, look.tone), {
			key = "state",
			role = "sessions-sidebar-boat-state",
			title = tooltip,
		}))
	end
	local marks = if group then ctx.marks(group.rows) else nil
	if marks then
		table.insert(children, marks)
	end
	local actions: { [string]: any } = {}
	if click then
		actions.click = ctx.target("open-sandbox", rowId, { kind = "boat", boat = item.id, op = "open" })
	end
	if #menu > 0 then
		actions.menu = menu
	end
	ctx.sig(key)
	ctx.sig(item.title)
	ctx.sig(if shown then detailText else "")
	ctx.sig(tooltip)
	ctx.sig(look.state .. "/" .. look.tone .. "/" .. look.icon .. "/" .. tostring(look.busy) .. "/" .. tostring(look.connected))
	ctx.sig(table.concat(menu, "|"))
	ctx.sig(color or "")
	ctx.sig(if current then "current" else "")
	ctx.sig(click or "")
	return with(ui.row(children), {
		key = key,
		role = if current then "sessions-sidebar-boat-current" else "sessions-sidebar-boat",
		title = tooltip,
		align = "center",
		mark = if ctx.moving then "drop" else nil,
		actions = if next(actions) then actions else nil,
	})
end

local function creatingNode(ctx: Context, entry: Creating, index: number): Node
	local name = boats.nameOfTitle(entry.title)
	local hint = "Creating " .. name .. " (" .. entry.detail .. "): a paid boat.dev sandbox, ready in a minute or two"
	ctx.sig("creating")
	ctx.sig(entry.title)
	ctx.sig(entry.detail)
	return with(ui.row({
		spinner("status", "sessions-sidebar-boat-status", "creating"),
		label(name, if ctx.display.details then { entry.detail } else nil, hint, false, nil),
		with(ui.badge("creating", "pending"), {
			key = "state",
			role = "sessions-sidebar-boat-state",
			title = hint,
		}),
	}), {
		key = "creating-" .. tostring(index),
		role = "sessions-sidebar-boat",
		title = hint,
		align = "center",
	})
end

-- ---------- header and usage ----------

local function header(ctx: Context): Node
	local headerId = ctx.id .. ".header"
	-- Right-click menus (the header, ⋯ and +); ⋯'s click opens the same as a picker (boat-ui.luau).
	local function menuFor(node: string): { string }
		return {
			ctx.target("New sandbox…", node, { kind = "boats", op = "new" }),
			ctx.target("Defaults…", node, { kind = "boats", op = "defaults" }),
			ctx.target("Refresh", node, { kind = "boats", op = "refresh" }),
			ctx.target(if ctx.display.details then "Hide details" else "Show details", node, { kind = "boats", op = "details" }),
		}
	end
	local addId = headerId .. ".add"
	local menuId = headerId .. ".menu"
	local headerMenu = menuFor(headerId)
	ctx.sig(table.concat(headerMenu, "|"))
	return ui.el("div", {
		key = "header",
		role = "sessions-sidebar-boats-header",
		actions = { menu = headerMenu },
	}, {
		with(ui.text("Boat sandboxes"), {
			key = "title",
			role = "sessions-sidebar-boats-title",
			wrap = "none",
			truncate = "end",
			grow = 1,
			shrink = 1,
		}),
		ui.el("button", {
			key = "menu",
			role = "sessions-sidebar-boats-menu",
			title = "Boat sandboxes menu",
			aria = "Boat sandboxes menu",
			actions = {
				click = ctx.target("boats-menu", menuId, { kind = "boats", op = "menu" }),
				menu = menuFor(menuId),
			},
			shrink = 0,
		}, {
			ui.node("icon", { key = "icon", name = "more" }),
		}),
		ui.el("button", {
			key = "add",
			role = "sessions-sidebar-boats-add",
			title = "New sandbox…",
			aria = "New sandbox",
			actions = {
				click = ctx.target("boats-new", addId, { kind = "boats", op = "new" }),
				menu = menuFor(addId),
			},
			shrink = 0,
		}, {
			ui.node("icon", { key = "icon", name = "plus" }),
		}),
	})
end

local function usageNode(ctx: Context, view: boats.UsageView): Node
	ctx.sig(view.label)
	ctx.sig(view.detail)
	ctx.sig(view.tone)
	local fraction = view.fraction
	if fraction == nil then
		return with(ui.text(view.label), {
			key = "usage",
			role = "sessions-sidebar-usage-unavailable",
			tone = "muted",
			title = view.detail,
			wrap = "none",
			truncate = "end",
		})
	end
	ctx.sig(string.format("%.4f", fraction))
	return ui.el("div", {
		key = "usage",
		role = "sessions-sidebar-usage",
		title = view.detail,
	}, {
		ui.node("progress", {
			key = "bar",
			role = "sessions-sidebar-usage-bar",
			value = fraction,
			tone = view.tone,
			label = "",
			title = view.detail,
			aria = "Plan compute used: " .. view.label,
		}),
		with(ui.text(view.label), {
			key = "label",
			role = "sessions-sidebar-usage-label",
			title = view.detail,
			wrap = "none",
			truncate = "end",
		}),
	})
end

local function notice(ctx: Context, text: string, why: string): Node
	ctx.sig(text)
	ctx.sig(why)
	return with(ui.text(text), {
		key = "notice",
		role = "sessions-sidebar-boats-notice",
		tone = "muted",
		title = why,
		wrap = "none",
		truncate = "end",
	})
end

-- ---------- snapshots ----------

local function snapshotsNode(ctx: Context, entries: { Entry }): Node?
	local display = ctx.display
	local inventory = display.inventory
	if not inventory then
		return nil
	end
	local snaps = inventory.snapshots
	local snapshotsId = ctx.id .. ".snapshots"
	local headingId = snapshotsId .. ".heading"
	local collapsed = display.snapshotsCollapsed
	local default = inventory.defaults.snapshot
	local titles: { [string]: string } = {}
	for _, item in entries do
		titles[item.id] = item.title
	end
	local allowance = inventory.allowance
	local figure: string
	local tip: string
	if not snaps then
		figure = "unavailable"
		tip = "boat snapshots: " .. (inventory.errors.snapshots or "no listing")
	elseif allowance then
		local over = math.max(0, allowance.used - allowance.free)
		figure = string.format("%d of %d free", allowance.used, allowance.free)
		tip = string.format("Named snapshots: %d saved, %d free.", allowance.used, allowance.free)
		local price = allowance.price
		if price then
			if over > 0 then
				figure ..= string.format(" · $%.2f/mo", over * price)
				tip ..= string.format(" Each one over that costs $%.2f a month: $%.2f a month now.", price, over * price)
			else
				tip ..= string.format(" Each one over that costs $%.2f a month.", price)
			end
		end
	else
		figure = tostring(#snaps)
		tip = "Named snapshots: " .. tostring(#snaps)
	end
	tip ..= " Click a snapshot to make a sandbox from it; right-click for more."
	local toggleTitle = if collapsed then "Show snapshots" else "Hide snapshots"
	local children: { Node } = {
		with(ui.row({
			ui.el("button", {
				key = "toggle",
				role = "sessions-sidebar-snapshots-toggle",
				text = if collapsed then "+" else "-",
				title = if ctx.moving then nil else toggleTitle,
				aria = toggleTitle,
				attrs = { ["aria-expanded"] = tostring(not collapsed) },
				actions = if ctx.moving
					then nil
					else { click = ctx.target("snapshots-toggle", headingId .. ".toggle", { kind = "boats", op = "toggle-snapshots" }) },
				shrink = 0,
			}),
			with(ui.text("Snapshots"), {
				key = "title",
				role = "sessions-sidebar-snapshots-title",
				title = tip,
				wrap = "none",
				truncate = "end",
				grow = 1,
				shrink = 1,
			}),
			with(ui.text(figure), {
				key = "allowance",
				role = "sessions-sidebar-snapshots-allowance",
				title = tip,
				wrap = "none",
				truncate = "end",
				shrink = 0,
			}),
		}), {
			key = "heading",
			role = "sessions-sidebar-snapshots-heading",
			title = tip,
			align = "center",
			mark = if ctx.moving then "drop" else nil,
		}),
	}
	ctx.sig("snapshots")
	ctx.sig(figure)
	ctx.sig(tip)
	ctx.sig(tostring(collapsed))
	if not collapsed then
		local shown = 0
		for _, snap in snaps or {} do
			shown += 1
			local key = "snap-" .. keyOf(snap.name)
			local rowId = snapshotsId .. "." .. key
			local op = display.snapshotOps[snap.name]
			local ready = snap.status == nil or snap.status == "ready"
			local isDefault = snap.name == default
			local source = if snap.source then titles[snap.source] or snap.source else nil
			local parts: { string } = {}
			local size = boats.bytes(snap.sizeBytes)
			if size then
				table.insert(parts, size)
			end
			local date = boats.shortDate(snap.createdAt)
			if date then
				table.insert(parts, date)
			end
			if not ready and snap.status then
				table.insert(parts, snap.status)
			end
			local hint = snap.name
				.. (if size then " · " .. size else "")
				.. (if snap.createdAt then " · saved " .. (boats.dateTime(snap.createdAt) or "?") else "")
				.. (if source then " from " .. source else "")
				.. (if snap.type then " · " .. snap.type .. " machine" else "")
				.. (if isDefault then "\nThe default for new sandboxes and omp /boat" else "")
				.. (if op then "\n" .. op .. "…" else (if ready then "\nClick to make a sandbox from it" else ""))
			local menu: { string } = {}
			local click: string? = nil
			if not op and not ctx.moving then
				local function item(label: string, name: string)
					table.insert(menu, ctx.target(label, rowId, { kind = "snapshot", snapshot = snap.name, op = name }))
				end
				if ready then
					item("New sandbox from this…", "new")
				end
				if not isDefault and ready then
					item("Set as default", "default")
				end
				item("Copy name", "copy")
				item("Delete snapshot…", "delete")
				if ready then
					click = ctx.target("New sandbox from this…", rowId, { kind = "snapshot", snapshot = snap.name, op = "new" })
				end
			end
			local rowChildren: { Node } = {
				if op
					then spinner("status", "sessions-sidebar-boat-status", op)
					else ui.node("icon", { key = "status", role = "sessions-sidebar-boat-status", name = "layers", aria = "snapshot" }),
				ui.el("div", {
					key = "label",
					role = "sessions-sidebar-host-label",
					attrs = { ["data-boat"] = "snapshot" },
					grow = 1,
					shrink = 1,
				}, {
					with(ui.text(snap.name), {
						key = "name",
						role = "sessions-sidebar-snapshot-name",
						title = hint,
						wrap = "none",
						truncate = "end",
					}),
					with(ui.text(table.concat(parts, " · ")), {
						key = "detail",
						role = "sessions-sidebar-snapshot-detail",
						title = hint,
						wrap = "none",
						truncate = "end",
					}),
				}),
			}
			if op then
				table.insert(rowChildren, with(ui.badge(op, "pending"), { key = "state", role = "sessions-sidebar-boat-state", title = hint }))
			elseif isDefault then
				table.insert(rowChildren, with(ui.badge("default", "accent"), {
					key = "default",
					role = "sessions-sidebar-snapshot-default",
					title = "The default for new sandboxes and omp /boat",
				}))
			end
			local actions: { [string]: any } = {}
			if #menu > 0 then
				actions.menu = menu
			end
			if click then
				actions.click = click
			end
			table.insert(children, with(ui.row(rowChildren), {
				key = key,
				role = "sessions-sidebar-snapshot",
				title = hint,
				align = "center",
				mark = if ctx.moving then "drop" else nil,
				actions = if next(actions) then actions else nil,
			}))
			ctx.sig(key)
			ctx.sig(hint)
			ctx.sig(table.concat(parts, " · "))
			ctx.sig(op or "")
			ctx.sig(table.concat(menu, "|"))
		end
		for index, saving in display.saving do
			shown += 1
			local hint = "Saving snapshot " .. saving.name .. " from " .. saving.title
			table.insert(children, with(ui.row({
				spinner("status", "sessions-sidebar-boat-status", "saving"),
				ui.el("div", {
					key = "label",
					role = "sessions-sidebar-host-label",
					attrs = { ["data-boat"] = "snapshot" },
					grow = 1,
					shrink = 1,
				}, {
					with(ui.text(saving.name), {
						key = "name",
						role = "sessions-sidebar-snapshot-name",
						title = hint,
						wrap = "none",
						truncate = "end",
					}),
					with(ui.text("from " .. saving.title), {
						key = "detail",
						role = "sessions-sidebar-snapshot-detail",
						title = hint,
						wrap = "none",
						truncate = "end",
					}),
				}),
				with(ui.badge("saving", "pending"), { key = "state", role = "sessions-sidebar-boat-state", title = hint }),
			}), {
				key = "saving-" .. tostring(index),
				role = "sessions-sidebar-snapshot",
				title = hint,
				align = "center",
			}))
			ctx.sig("saving")
			ctx.sig(hint)
		end
		if shown == 0 and snaps then
			table.insert(children, with(ui.text("No snapshots yet"), {
				key = "empty",
				role = "sessions-sidebar-empty",
				tone = "muted",
			}))
		end
	end
	return with(ui.col(children), { key = "snapshots", role = "sessions-sidebar-snapshots" })
end

-- The Boat section, or nil while there is nothing to show (no listing yet, nothing tracked).
local function section(ctx: Context): Node?
	local display = ctx.display
	local inventory = display.inventory
	local entries = collect(ctx)
	if not inventory and #entries == 0 and #display.creating == 0 then
		return nil
	end
	local children: { Node } = { header(ctx) }
	local usage = display.usage
	if usage then
		table.insert(children, usageNode(ctx, usage))
	end
	local failed = display.failed
	if failed then
		local at = if inventory then boats.dateTime(inventory.fetchedAt) else nil
		table.insert(
			children,
			notice(ctx, if inventory then "Not refreshed" .. (if at then " since " .. at else "") else "Sandboxes unavailable", failed)
		)
	elseif not inventory and display.busy then
		table.insert(children, notice(ctx, "Loading sandboxes…", "Reading your boat.dev account"))
	end
	for _, item in entries do
		table.insert(children, entryNode(ctx, item))
	end
	for index, entry in display.creating do
		table.insert(children, creatingNode(ctx, entry, index))
	end
	if #entries == 0 and #display.creating == 0 then
		table.insert(children, with(ui.text("No sandboxes yet"), {
			key = "empty",
			role = "sessions-sidebar-empty",
			tone = "muted",
		}))
	end
	local snapshots = snapshotsNode(ctx, entries)
	if snapshots then
		table.insert(children, snapshots)
	end
	return ui.el("div", { key = "boats", role = "sessions-sidebar-boats" }, children)
end

return { section = section }
