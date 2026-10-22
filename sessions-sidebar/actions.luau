--!strict
-- What the sidebar's clicks, menus and inputs do: switching, renaming, icons, title colors, moving,
-- the settings picker, Remove host…, the Boat section (through boat-ui.luau, compiled on first
-- use) and add-host requests from scripts. window.luau compiles this module in a callback of its
-- own, after core.luau (see there).
local agents = require("./agents")
local boats = require("./boats")
local core = require("./core")
local data = require("./session-data")
local sessions = require("./sessions")

local shared = core.shared
local display = core.display
local knownTargets = core.knownTargets
local key = core.key
local call = core.call
local report = core.report
local refresh = core.refresh
local requestRefresh = core.requestRefresh
local askInventory = core.askInventory
local findHost = core.findHost
local findSession = core.findSession
local preferredContent = core.preferredContent
local syncDisplay = core.syncDisplay
local disconnectHost = core.disconnectHost
local disconnectAddress = core.disconnectAddress
local boatUiModule: any = nil

local function resolveTarget(
	cx: WindowCx,
	target: sessions.Target,
	hosts: { ManagedHost },
	rows: { ManagedSession },
	originalHost: ManagedHost?
): (ManagedHost?, ManagedSession?)
	local host: ManagedHost? = nil
	for _, candidate in hosts do
		if candidate.id == target.host then
			host = candidate
			break
		end
	end
	if not host
		or (originalHost and (host.kind ~= originalHost.kind
			or (host.kind == "remote" and (host.address ~= originalHost.address
				or (host.address == nil and host.name ~= originalHost.name)))))
	then
		cx:toast("error", "Machine no longer attached", "The original sidebar target is no longer available; no other machine was changed.")
		refresh(cx)
		return nil, nil
	end
	if (target.kind == "switch" or target.kind == "rename-session" or target.kind == "new-session")
		and host.state ~= "connected"
	then
		cx:toast("error", "Machine is not connected", host.name .. ": " .. host.state)
		refresh(cx)
		return nil, nil
	end
	local row: ManagedSession? = nil
	if target.session then
		for _, candidate in rows do
			if candidate.id == target.session and candidate.host == host.id then
				row = candidate
				break
			end
		end
		if not row then
			cx:toast("error", "Session no longer exists", "The sidebar has been refreshed; no other session was changed.")
			refresh(cx)
			return nil, nil
		end
	end
	return host, row
end

local function liveTarget(cx: WindowCx, target: sessions.Target, originalHost: ManagedHost): (ManagedHost?, ManagedSession?, { ManagedSession })
	local hosts = cx.hosts:list()
	local rows = cx.sessions:list()
	local host, row = resolveTarget(cx, target, hosts, rows, originalHost)
	return host, row, rows
end

local function inputFailure(operation: string, message: string, cx: WindowCx?)
	if cx then
		report(cx, operation, message)
	else
		tern.log.error("Sessions sidebar: " .. operation, message)
	end
end

-- `dismissed` runs when the user backs out (Esc), so a form can return to its summary.
local function prompt(
	cx: WindowCx,
	operation: string,
	opts: PromptOptions,
	apply: (string, WindowCx) -> (),
	dismissed: ((WindowCx) -> ())?
)
	-- Anchor input before taking DOM focus, then hold the drawer through the native input.
	refresh(cx)
	shared.nativeInputs += 1
	refresh(cx)
	local opened = call(cx, operation, function()
		cx:prompt(opts):next(function(value: string?, err: string?, fresh: WindowCx?)
			shared.nativeInputs -= 1
			if err then
				inputFailure(operation, err, fresh)
			elseif value ~= nil then
				if fresh then
					apply(value, fresh)
				else
					inputFailure(operation, "The window closed before the input could be applied.", nil)
				end
			elseif fresh and dismissed then
				dismissed(fresh)
			end
			if fresh then
				refresh(fresh)
			end
		end)
	end)
	if not opened then
		shared.nativeInputs -= 1
		refresh(cx)
	end
end

local function pick(
	cx: WindowCx,
	operation: string,
	opts: PickOptions,
	apply: (PickItem, WindowCx) -> (),
	dismissed: ((WindowCx) -> ())?
)
	refresh(cx)
	shared.nativeInputs += 1
	refresh(cx)
	local opened = call(cx, operation, function()
		cx:pick(opts):next(function(item: PickItem?, err: string?, fresh: WindowCx?)
			shared.nativeInputs -= 1
			if err then
				inputFailure(operation, err, fresh)
			elseif item ~= nil then
				if fresh then
					apply(item, fresh)
				else
					inputFailure(operation, "The window closed before the choice could be applied.", nil)
				end
			elseif fresh and dismissed then
				dismissed(fresh)
			end
			if fresh then
				refresh(fresh)
			end
		end)
	end)
	if not opened then
		shared.nativeInputs -= 1
		refresh(cx)
	end
end

local function nonblank(cx: WindowCx, value: string, label: string): boolean
	if not string.find(value, "%S") then
		cx:toast("error", "Enter a " .. label, "Blank values do not change the sidebar or create a session.")
		return false
	end
	return true
end

local function validGlyph(cx: WindowCx, value: string): boolean
	if not nonblank(cx, value, "custom glyph or emoji") then
		return false
	end
	local valid = #value <= 64
	for _, codepoint in utf8.codes(value) do
		if codepoint < 32 or (codepoint >= 127 and codepoint <= 159)
			or codepoint == 0x2028 or codepoint == 0x2029
		then
			valid = false
			break
		end
	end
	if not valid then
		cx:toast("error", "Use one short glyph or emoji", "Custom icons must be at most 64 UTF-8 bytes and contain no newlines or control characters.")
	end
	return valid
end

local NATIVE_ICONS: { { label: string, name: string } } = {
	{ label = "Terminal", name = "terminal" },
	{ label = "Folder", name = "folder" },
	{ label = "Code", name = "code" },
	{ label = "Branch", name = "branch" },
	{ label = "Server", name = "server" },
	{ label = "Database", name = "database" },
	{ label = "Globe", name = "globe" },
	{ label = "Rocket", name = "rocket" },
	{ label = "Moon", name = "moon" },
	{ label = "omp", name = "app-omp" },
	{ label = "Python", name = "app-python" },
	{ label = "Rust", name = "app-rust" },
}

local function customGlyph(cx: WindowCx, target: sessions.Target, originalHost: ManagedHost, current: data.Icon)
	prompt(cx, "changing session icon", {
		value = if current.kind == "glyph" then current.value else "",
		placeholder = "Custom session glyph or emoji",
		icon = "type",
		action = "save",
	}, function(value, fresh)
		local host, row, rows = liveTarget(fresh, target, originalHost)
		if not host or not row or not validGlyph(fresh, value) then
			return
		end
		call(fresh, "changing session icon", function()
			data.setSessionIcon(host, row, rows, { kind = "glyph", value = value })
		end)
	end)
end

local function sessionIcon(cx: WindowCx, target: sessions.Target, originalHost: ManagedHost, current: data.Icon)
	local items: { PickItem } = {}
	for _, icon in NATIVE_ICONS do
		table.insert(items, {
			label = icon.label,
			icon = icon.name,
			group = "Native icons",
			current = current.kind == "named" and current.value == icon.name,
			mode = "named",
			value = icon.name,
		})
	end
	table.insert(items, {
		label = "Custom glyph or emoji",
		detail = "Enter a short symbol, up to 64 UTF-8 bytes",
		icon = "type",
		group = "Customization",
		current = current.kind == "glyph",
		mode = "glyph",
	})
	table.insert(items, {
		label = "Reset icon",
		detail = "Use the default terminal icon",
		icon = "undo",
		group = "Customization",
		mode = "reset",
	})
	pick(cx, "choosing session icon", {
		items = items,
		placeholder = "Choose a session icon",
		icon = "terminal",
		action = "choose",
	}, function(item, fresh)
		local host, row, rows = liveTarget(fresh, target, originalHost)
		if not host or not row then
			return
		end
		if item.mode == "glyph" then
			customGlyph(fresh, target, host, current)
			return
		end
		local icon: data.Icon? = if item.mode == "named" then { kind = "named", value = item.value } else nil
		call(fresh, "changing session icon", function()
			data.setSessionIcon(host, row, rows, icon)
		end)
	end)
end

local TITLE_COLORS: { { label: string, value: string } } = {
	{ label = "Red", value = "#f87171" },
	{ label = "Orange", value = "#fb923c" },
	{ label = "Yellow", value = "#facc15" },
	{ label = "Green", value = "#4ade80" },
	{ label = "Teal", value = "#2dd4bf" },
	{ label = "Blue", value = "#60a5fa" },
	{ label = "Purple", value = "#c084fc" },
	{ label = "Pink", value = "#f472b6" },
}

local function customColor(cx: WindowCx, target: sessions.Target, originalHost: ManagedHost, current: string?)
	prompt(cx, "changing host title color", {
		value = current or "",
		placeholder = "Hex title color, e.g. #3b82f6",
		icon = "pen",
		action = "save",
	}, function(value, fresh)
		local host = liveTarget(fresh, target, originalHost)
		if not host or not nonblank(fresh, value, "hex color") then
			return
		end
		local color = data.normalizeColor(value)
		if not color then
			fresh:toast("error", "Use a hex color", "Enter #rgb or #rrggbb, for example #3b82f6.")
			return
		end
		call(fresh, "changing host title color", function()
			data.setHostColor(host, color)
		end)
	end)
end

local function hostColor(cx: WindowCx, target: sessions.Target, originalHost: ManagedHost, current: string?)
	local items: { PickItem } = {}
	local preset = false
	for _, color in TITLE_COLORS do
		preset = preset or current == color.value
		table.insert(items, {
			label = color.label,
			detail = color.value,
			group = "Colors",
			current = current == color.value,
			mode = "preset",
			value = color.value,
		})
	end
	table.insert(items, {
		label = "Custom hex color",
		detail = if current and not preset then current else "Enter #rgb or #rrggbb",
		icon = "pen",
		group = "Customization",
		current = current ~= nil and not preset,
		mode = "custom",
	})
	table.insert(items, {
		label = "Default color",
		detail = "Use the theme's heading color",
		icon = "undo",
		group = "Customization",
		current = current == nil,
		mode = "reset",
	})
	pick(cx, "choosing host title color", {
		items = items,
		placeholder = "Choose a host title color",
		icon = "pen",
		action = "choose",
	}, function(item, fresh)
		local host = liveTarget(fresh, target, originalHost)
		if not host then
			return
		end
		if item.mode == "custom" then
			customColor(fresh, target, host, current)
			return
		end
		call(fresh, "changing host title color", function()
			data.setHostColor(host, if item.mode == "preset" then item.value else nil)
		end)
	end)
end

local function sidebarSettings(cx: WindowCx)
	if shared.nativeInputs > 0 then
		return
	end
	local mode = data.getSidebarMode()
	pick(cx, "choosing sidebar display", {
		items = {
			{
				label = "Always expanded",
				detail = "Dock on the left and reserve space for the session list",
				mode = "always",
				current = mode == "always",
			},
			{
				label = "Click tab",
				detail = "Click the small left tab to toggle an overlay without resizing content",
				mode = "click",
				current = mode == "click",
			},
			{
				label = "Hover left edge",
				detail = "Overlay while the pointer is over the left edge or drawer; close on leave",
				mode = "hover",
				current = mode == "hover",
			},
		},
		placeholder = "Sessions sidebar settings",
		icon = "gear",
		action = "choose",
	}, function(item, fresh)
		call(fresh, "changing sidebar display", function()
			data.setSidebarMode(item.mode)
		end)
	end)
end

type Confirm = {
	question: string,
	yes: string,
	detail: string,
	icon: string,
	cancelFirst: boolean?,
	-- The Cancel row's detail.
	keep: string?,
}

-- A two-choice picker. Destructive questions list Cancel first, so a reflexive ↵ changes nothing.
local function confirm(cx: WindowCx, operation: string, ask: Confirm, apply: (WindowCx) -> ())
	local yes: PickItem = { label = ask.yes, detail = ask.detail, icon = ask.icon, mode = "yes" }
	local no: PickItem = { label = "Cancel", detail = ask.keep or "Leave the sandbox as it is", icon = "x", mode = "no" }
	pick(cx, operation, {
		items = if ask.cancelFirst then { no, yes } else { yes, no },
		placeholder = ask.question,
		icon = ask.icon,
		action = "choose",
	}, function(item, fresh)
		if item.mode == "yes" then
			apply(fresh)
		end
	end)
end

-- After an operation: a fresh inventory, and the sidebar drawn again.
local function boatSettled(cx: WindowCx?)
	if cx then
		askInventory(true)
	end
	requestRefresh()
end

-- What boat-ui.luau borrows from the window (its Env).
local boatEnv = {
	pick = pick,
	prompt = prompt,
	confirm = confirm,
	-- Holds the drawer open between two chained inputs (each in a callback of its own).
	hold = function()
		shared.nativeInputs += 1
	end,
	release = function()
		shared.nativeInputs = math.max(0, shared.nativeInputs - 1)
		if shared.nativeInputs == 0 then
			requestRefresh()
		end
	end,
	refresh = function(cx: WindowCx)
		refresh(cx)
	end,
	requestRefresh = function()
		requestRefresh()
	end,
	settled = boatSettled,
	disconnect = disconnectAddress,
	ops = core.boatOps,
	creating = core.creatingBoats,
	saving = core.savingSnapshots,
	snapshotOps = core.snapshotOps,
}

-- boat-ui.luau with the window's helpers. core.luau compiles it in a callback of its own right
-- after boat-view.luau; a click before that compiles it here.
local function loadBoatUi(): any
	if not boatUiModule then
		local module: any = require("./boat-ui")
		module.init(boatEnv)
		boatUiModule = module
	end
	return boatUiModule
end
core.hooks.loadBoatUi = function()
	loadBoatUi()
end

-- Remove host…: disconnects a remote host, so Tern forgets it, and forgets its saved sidebar
-- preferences (title, color, folding, place, session order and icons).
local function removeHost(cx: WindowCx, host: ManagedHost, title: string)
	confirm(cx, "removing host", {
		question = "Remove " .. title .. "?",
		yes = "Remove " .. title,
		detail = "Disconnects it, Tern forgets it and the sidebar forgets its title, color, place and icons; programs keep running there",
		icon = "trash",
		cancelFirst = true,
		keep = "Keep the host",
	}, function(fresh)
		local live = findHost(fresh.hosts:list(), host.id)
		if not live or live.kind ~= "remote" or live.address ~= host.address or live.name ~= host.name then
			fresh:toast("error", "Machine no longer attached", "Nothing was removed.")
			return
		end
		if disconnectHost(fresh, live) then
			call(fresh, "forgetting host preferences", function()
				data.forgetHost(live)
			end)
			fresh:toast("success", "Removed " .. title, "Add it again with Tern's Add remote host.")
		end
	end)
end

local function globalAction(cx: WindowCx, target: sessions.Target): boolean
	if target.kind == "settings" then
		sidebarSettings(cx)
	elseif target.kind == "toggle-panel" then
		display.open = not display.open
		if display.open then
			askInventory(true)
		end
		refresh(cx)
	elseif target.kind == "cancel-move" then
		shared.moving = nil
		refresh(cx)
	elseif target.kind == "boat" or target.kind == "boats" or target.kind == "snapshot" then
		-- Normally loaded in the background right after the section was first drawn.
		loadBoatUi().action(cx, target)
	else
		return false
	end
	return true
end

-- Script requests (the boat-sandbox script behind the omp `/boat` command) to add a remote host
-- under a sidebar title, through the same attach path as New Boat Sandbox and Start. Request and
-- result files sit in the plugin data dir; README.md documents both formats.
local ADD_HOST_REQUEST = tern.plugin.data .. "/add-host.json"
local ADD_HOST_RESULT = tern.plugin.data .. "/add-host.result.json"
local ADD_HOST_MAX_BYTES = 16384

type AddHostRequest = {
	id: string,
	address: string,
	title: string,
	fingerprint: string,
	boat: { id: string, name: string }?,
}

local function writeAddHostResult(id: string?, ok: boolean, state: string, message: string?)
	local wrote, err = pcall(function()
		tern.fs.mkdir(tern.plugin.data)
		tern.fs.write(
			ADD_HOST_RESULT,
			tern.json.encode({ id = id or tern.json.null, ok = ok, state = state, error = message })
		)
	end)
	if not wrote then
		tern.log.error("add host", "cannot write result: " .. tostring(err))
	end
end

local function failAddHost(cx: WindowCx?, title: string, message: string)
	tern.log.warn("add host", message)
	if cx then
		cx:toast("error", "Sessions sidebar: add host", title .. ": " .. message)
	end
end

local function textField(value: any): string?
	return if type(value) == "string" and string.find(value, "%S") then value else nil
end

-- Returns the request, else the request id when one was readable and the problem.
local function parseAddHostRequest(text: string): (AddHostRequest?, string?, string?)
	local decoded, value = pcall(tern.json.decode, text)
	if not decoded or type(value) ~= "table" then
		return nil, nil, "the request is not a JSON object"
	end
	local id = textField(value.id)
	if not id then
		return nil, nil, "the request needs a non-blank string id"
	end
	local address = textField(value.address)
	if not address or string.find(address, "%s") then
		return nil, id, "address must be a host address ([user@]host[:port]) without spaces"
	end
	local title = textField(value.title)
	if not title then
		return nil, id, "the request needs a non-blank title"
	end
	local fingerprint = textField(value.fingerprint)
	if not fingerprint or string.sub(fingerprint, 1, 7) ~= "SHA256:" then
		return nil, id, "fingerprint must be the host key's SHA256:… fingerprint"
	end
	local boat: { id: string, name: string }? = nil
	if value.boat ~= nil then
		local sandbox = value.boat
		local boatId = if type(sandbox) == "table" then textField(sandbox.id) else nil
		local name = if type(sandbox) == "table" and type(sandbox.name) == "string" then boats.validName(sandbox.name) else nil
		if not boatId or not string.match(boatId, "^bx_%w+$") or not name then
			return nil, id, 'boat must be {"id": "bx_…", "name": "<1–40 letters, digits, spaces, . _ ->"}'
		end
		boat = { id = boatId, name = name }
	end
	return { id = id, address = address, title = title, fingerprint = fingerprint, boat = boat }, id, nil
end

local function addHost(cx: WindowCx)
	if not tern.fs.exists(ADD_HOST_REQUEST) then
		return
	end
	local read, text = pcall(tern.fs.read, ADD_HOST_REQUEST, ADD_HOST_MAX_BYTES)
	pcall(tern.fs.remove, ADD_HOST_REQUEST)
	local request, id, problem
	if read then
		request, id, problem = parseAddHostRequest(text)
	else
		problem = "cannot read the request: " .. tostring(text)
	end
	if not request then
		local message = problem or "invalid request"
		writeAddHostResult(id, false, "invalid", message)
		failAddHost(cx, "invalid request", message)
		return
	end
	local accepted = request :: AddHostRequest
	boats.attach(cx, {
		address = accepted.address,
		title = accepted.title,
		fingerprint = accepted.fingerprint,
		boat = accepted.boat,
	}, function(ok: boolean, state: string, message: string?, fresh: WindowCx?)
		writeAddHostResult(accepted.id, ok, state, message)
		if not ok then
			failAddHost(fresh, accepted.title, message or "failed")
		end
		if fresh and accepted.boat then
			askInventory(true)
		end
		-- Deferred to the sidebar's usual timer hook: a slow refresh here would count against the
		-- await hook that the attach polling depends on.
		requestRefresh()
	end)
	refresh(cx)
end

-- A click or menu choice on this plugin's canvas (window.luau's canvas_action hook).
local function canvasAction(ev: CanvasAction, cx: WindowCx): boolean
	if shared.nativeInputs > 0 then
		return true
	end
	local action = ev.act .. "\n" .. ev.node
	local target: sessions.Target? = knownTargets[action]
	if target and globalAction(cx, target) then
		return true
	end
	local hosts = cx.hosts:list()
	local rows = cx.sessions:list()
	-- A snapshot reads every session's metadata (3-6 ms with six hosts). Only branches that use it
	-- take one, at most once, so switching and moving stay far inside the 50 ms hook budget.
	local taken: data.Snapshot? = nil
	local function snapshot(): data.Snapshot
		if not taken then
			taken = data.snapshot(cx, hosts, rows, preferredContent)
		end
		return taken :: data.Snapshot
	end
	if not target then
		syncDisplay()
		target = sessions.build(hosts, rows, snapshot(), display, agents.marks()).targets[action]
		if not target then
			return false
		end
		if globalAction(cx, target) then
			return true
		end
	end
	local host, row = resolveTarget(cx, target, hosts, rows, nil)
	if not host then
		return true
	end
	if target.kind == "move-session" and row then
		shared.moving = { kind = "session", host = host.id, session = row.id }
		refresh(cx)
	elseif target.kind == "move-host" then
		shared.moving = { kind = "host", host = host.id }
		refresh(cx)
	elseif target.kind == "place-session" and row then
		-- `host`/`row` are the destination, resolved from this callback's fresh lists.
		local lifted = shared.moving
		if not lifted or lifted.kind ~= "session" or lifted.host ~= host.id then
			return true
		end
		local liftedRow = findSession(rows, host.id, lifted.session)
		shared.moving = nil
		if not liftedRow then
			cx:toast("error", "Session no longer exists", "The move was cancelled; no session was reordered.")
		elseif liftedRow.id ~= row.id then
			call(cx, "moving session", function()
				data.moveSession(host, rows, liftedRow, row)
			end)
		end
		refresh(cx)
	elseif target.kind == "place-host" then
		-- `host` is the destination, resolved from this callback's fresh list.
		local lifted = shared.moving
		if not lifted or lifted.kind ~= "host" then
			return true
		end
		local liftedHost = findHost(hosts, lifted.host)
		shared.moving = nil
		if not liftedHost then
			cx:toast("error", "Machine no longer attached", "The move was cancelled; no host was reordered.")
		elseif liftedHost.id ~= host.id then
			call(cx, "moving host", function()
				data.moveHost(hosts, liftedHost, host)
			end)
		end
		refresh(cx)
	elseif target.kind == "switch" and row then
		-- Switching to the shown session jumps to the tab Tern last remembered for it, not the
		-- visible one; clicking the current row only hands focus back to the content pane.
		if row.current then
			refresh(cx)
		else
			-- The switch applies after this callback returns, so a refresh here would only redraw
			-- the old session. Queue one first; the switch stays last.
			requestRefresh()
			-- Switching failures remain native errors, rather than pretending success.
			cx.sessions:switch(row.id)
		end
	elseif target.kind == "rename-session" and row then
		prompt(cx, "renaming session", {
			value = row.name,
			placeholder = "Rename session",
			icon = "pen",
			action = "rename",
		}, function(name, fresh)
			local liveHost, liveRow = liveTarget(fresh, target, host)
			if not liveHost or not liveRow or not nonblank(fresh, name, "session name") then
				return
			end
			call(fresh, "renaming session", function()
				data.renameSession(fresh, liveHost, liveRow, name)
			end)
		end)
	elseif target.kind == "toggle-host" then
		call(cx, "toggling host sessions", function()
			data.setHostCollapsed(host, not snapshot().hostCollapsed[key(host.id)])
		end)
		refresh(cx)
	elseif target.kind == "rename-host" then
		prompt(cx, "renaming host title", {
			value = snapshot().hostTitles[key(host.id)] or host.name,
			placeholder = "Host display title (connection address stays unchanged)",
			icon = "pen",
			action = "rename",
		}, function(title, fresh)
			local liveHost = liveTarget(fresh, target, host)
			if not liveHost or not nonblank(fresh, title, "host display title") then
				return
			end
			call(fresh, "renaming host title", function()
				data.setHostTitle(liveHost, title)
			end)
		end)
	elseif target.kind == "reset-host" then
		call(cx, "resetting host title", function()
			data.setHostTitle(host, nil)
		end)
		refresh(cx)
	elseif target.kind == "host-color" then
		hostColor(cx, target, host, snapshot().hostColors[key(host.id)])
	elseif target.kind == "change-icon" and row then
		local metadata = snapshot().sessions[key(row.id)]
		sessionIcon(cx, target, host, if metadata then metadata.icon else { kind = "named", value = "terminal" })
	elseif target.kind == "reset-icon" and row then
		call(cx, "resetting session icon", function()
			data.setSessionIcon(host, row, rows, nil)
		end)
		refresh(cx)
	elseif target.kind == "new-session" then
		prompt(cx, "creating session", {
			value = "",
			placeholder = "New session on " .. (snapshot().hostTitles[key(host.id)] or host.name),
			icon = "terminal",
			action = "create",
		}, function(name, fresh)
			local liveHost = liveTarget(fresh, target, host)
			if not liveHost or not nonblank(fresh, name, "session name") then
				return
			end
			local created = call(fresh, "creating session", function()
				-- Create is current-host scoped. Do not switch until confirmed and revalidated.
				fresh.hosts:switch(liveHost.id)
				fresh.sessions:create({ name = name })
			end)
			if created then
				call(fresh, "expanding host sessions", function()
					data.setHostCollapsed(liveHost, false)
				end)
			end
		end)
	elseif target.kind == "remove-host" and host.kind == "remote" then
		removeHost(cx, host, snapshot().hostTitles[key(host.id)] or host.name)
	end
	return true
end

return {
	canvasAction = canvasAction,
	sidebarSettings = sidebarSettings,
	addHost = addHost,
}
