--!strict

export type Icon = { kind: "named" | "glyph", value: string }
export type SidebarMode = "always" | "click" | "hover"
export type SessionMetadata = {
	path: string,
	icon: Icon,
}
-- A boat.dev sandbox the sidebar tracks: one it (or the boat-sandbox script's add-host request)
-- created or connected. Keyed by its sandbox id; `title` is its sidebar title, `address` the Tern
-- host address it was last attached at, `error` the last failed operation's message and `savedAt`
-- (epoch seconds) when the record was last saved, so an account listing older than that cannot
-- call it gone.
export type Boat = {
	id: string,
	name: string,
	title: string,
	address: string?,
	state: "running" | "stopped",
	error: string?,
	savedAt: number?,
}
-- A tracked boat sandbox that no host of this window is attached to, with its display title.
export type DetachedBoat = { boat: Boat, title: string }
export type Snapshot = {
	hostTitles: { [string]: string },
	-- idKey(host.id) -> lowercase "#rrggbb" title color; absent uses the theme color.
	hostColors: { [string]: string },
	-- idKey(host.id) -> true when hostTitles is a saved title alias, not Tern's own host name.
	hostAliased: { [string]: boolean },
	hostCollapsed: { [string]: boolean },
	sidebarMode: SidebarMode,
	sessions: { [string]: SessionMetadata },
	-- idKey(host.id) -> 1..n final display order of every attached host.
	hostRank: { [string]: number },
	-- idKey(session.id) -> 1..n final display order within its host.
	sessionRank: { [string]: number },
	-- idKey(host.id) -> the boat sandbox an attached remote host is.
	hostBoats: { [string]: Boat },
	detachedBoats: { DetachedBoat },
}
-- The docked sidebar's width in Always expanded mode: `cols` whole cells at terminal font size
-- `font`, which is what a window resize keeps, and `fraction`, its share of the tab width when
-- saved, which a new window starts from.
export type DockedWidth = { cols: number, font: number?, fraction: number? }
-- What a refresh read of the window already: snapshot uses it instead of reading it again.
export type Window = {
	canvases: { CanvasInfo },
	tabs: { TabInfo },
	panes: { PaneInfo },
	focused: number?,
}

type Values = { [string]: any }
type NameCounts = { [string]: number }
type RememberedIcon = { host: string, name: string, icon: Icon?, unique: boolean }
type Observed = { path: string, priority: number }
type ObservedTab = {
	info: TabInfo,
	session: Observed?,
}

local HOST_TITLES = "sidebar.host-titles.v1"
-- { [stableHostKey]: lowercase "#rrggbb" }
local HOST_COLORS = "sidebar.host-title-colors.v1"
local SESSION_ICONS = "sidebar.session-icons.v1"
local HOST_COLLAPSED = "sidebar.host-collapsed.v1"
local SIDEBAR_MODE = "sidebar.display-mode.v1"
local DOCKED_WIDTH = "sidebar.docked-width.v3"
-- 1.7 saved the width in whole cells only.
local DOCKED_CELLS = "sidebar.docked-width.v2"
-- Array of stable host keys, first displayed first.
local HOST_ORDER = "sidebar.host-order.v1"
-- { [stableHostKey]: array of unique session names }, first displayed first.
local SESSION_ORDER = "sidebar.session-order.v1"
-- { [boat sandbox id]: Boat }
local BOATS = "sidebar.boats.v1"
-- true while the Boat section's Snapshots list is folded.
local SNAPSHOTS_COLLAPSED = "sidebar.boat-snapshots-collapsed.v1"
-- true while the Boat section shows each sandbox's second line (Show details).
local BOAT_DETAILS = "sidebar.boat-details.v1"
-- Tests only: { script = argv, env = { NAME = value }, copies = path }: the command run instead of
-- ~/bin/boat-sandbox, variables added to its environment (for example BOAT_SANDBOX_DEFAULTS), and
-- a file that receives the sidebar's copies (one JSON string per line) instead of the clipboard.
local BOAT_COMMANDS = "sidebar.boat-commands.v1"
-- Saved per stable host key; a boat sandbox's preferences follow it to a new address.
local HOST_MAPS = { HOST_TITLES, HOST_COLORS, HOST_COLLAPSED, SESSION_ICONS, SESSION_ORDER }
local DEFAULT_ICON: Icon = { kind = "named", value = "terminal" }

-- Received session ids belong only to this VM. In particular, ambiguous names
-- must never cause one session to acquire another session's saved icon.
local rememberedIcons: { [string]: RememberedIcon } = {}
-- Stable host key -> this VM's session order keys ("n:" .. unique name or
-- "i:" .. idKey(id)). Only "n:" keys are durable; exact ids place duplicates.
local sessionOrders: { [string]: { string } } = {}

local function idKey(id: number): string
	return string.format("%.0f", id)
end

-- JSON tuples distinguish addresses from fallback names without delimiter
-- ambiguity. These are display preferences, not remote trust identities.
local function addressKey(address: string): string
	return tern.json.encode({ "remote-address", address })
end

local function hostKey(host: ManagedHost): string
	if host.kind == "local" then
		return "local"
	end
	local address = host.address
	if address and address ~= "" then
		return addressKey(address)
	end
	return tern.json.encode({ "remote-name", host.name })
end

local function hostTitle(host: ManagedHost): string
	if host.kind == "local" then
		return "This PC"
	end
	if string.find(host.name, "%S") then
		return host.name
	end
	local address = host.address
	if address and string.find(address, "%S") then
		return address
	end
	return "Host " .. idKey(host.id)
end

local function readValues(key: string): Values
	local value = tern.kv.get(key)
	return if type(value) == "table" then table.clone(value) else {}
end

-- Accepts "#rgb", "#rrggbb" or either without "#"; returns lowercase "#rrggbb".
local function normalizeColor(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	local digits = string.match(value, "^%s*#?(%x+)%s*$")
	if digits and #digits == 3 then
		digits = string.gsub(digits, "%x", "%0%0")
	end
	return if digits and #digits == 6 then "#" .. string.lower(digits) else nil
end

local function validIcon(value: any): Icon?
	if type(value) ~= "table" or type(value.value) ~= "string" then
		return nil
	end
	if value.kind ~= "named" and value.kind ~= "glyph" then
		return nil
	end
	if not string.find(value.value, "%S") or string.find(value.value, "%c") then
		return nil
	end
	if value.kind == "glyph" and #value.value > 64 then
		return nil
	end
	return value :: Icon
end

local function savedIcon(saved: Values, host: string, name: string): Icon?
	local icons = saved[host]
	return if type(icons) == "table" then validIcon(icons[name]) else nil
end

local function chosenIcon(saved: Values, host: string, row: ManagedSession, unique: boolean): Icon?
	local remembered = rememberedIcons[idKey(row.id)]
	if remembered and remembered.host == host and remembered.name == row.name then
		if not unique or not remembered.unique then
			return remembered.icon
		end
	end
	-- Stable unique names read fresh preferences; a duplicate survivor instead
	-- keeps its exact-id choice, including an explicitly remembered default.
	return if unique then savedIcon(saved, host, row.name) else nil
end

local function rememberIcon(host: string, row: ManagedSession, icon: Icon?, unique: boolean)
	local key = idKey(row.id)
	local remembered = rememberedIcons[key]
	if remembered then
		remembered.host = host
		remembered.name = row.name
		remembered.icon = icon
		remembered.unique = unique
	else
		rememberedIcons[key] = { host = host, name = row.name, icon = icon, unique = unique }
	end
end

local function namesOnHost(rows: { ManagedSession }, host: number): NameCounts
	local counts: NameCounts = {}
	for _, row in rows do
		if row.host == host then
			counts[row.name] = (counts[row.name] or 0) + 1
		end
	end
	return counts
end

local function findRow(rows: { ManagedSession }, host: ManagedHost, row: ManagedSession): ManagedSession
	for _, candidate in rows do
		if candidate.id == row.id and candidate.host == host.id and row.host == host.id then
			return candidate
		end
	end
	error("The session is no longer present on the selected host.")
end

local function iconsOnHost(saved: Values, host: string): Values
	local icons = saved[host]
	if type(icons) == "table" then
		return table.clone(icons)
	end
	return {}
end

local function updateSavedIcon(saved: Values, host: string, name: string, icon: Icon?): boolean
	local icons = iconsOnHost(saved, host)
	local current = validIcon(icons[name])
	if icon then
		if current and current.kind == icon.kind and current.value == icon.value then
			return false
		end
	elseif icons[name] == nil then
		return false
	end
	icons[name] = icon
	saved[host] = if next(icons) then icons else nil
	return true
end

local function stringList(value: any): { string }
	local list: { string } = {}
	if type(value) ~= "table" then
		return list
	end
	local seen: { [string]: boolean } = {}
	for _, item in ipairs(value) do
		if type(item) == "string" and not seen[item] then
			seen[item] = true
			table.insert(list, item)
		end
	end
	return list
end

local function sameList(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return false
	end
	for index, value in a do
		if b[index] ~= value then
			return false
		end
	end
	return true
end

-- Places `moving` in `target`'s slot: right after it when `moving` was above,
-- otherwise right before it.
local function moveKey(keys: { string }, moving: string, target: string): { string }
	local from = table.find(keys, moving)
	local to = table.find(keys, target)
	if not from or not to or from == to then
		error("The item to move or its new place is no longer listed.")
	end
	local order = table.clone(keys)
	table.remove(order, from)
	-- Index `to` is right after the shifted target when moving down, and
	-- right before the unshifted target when moving up.
	table.insert(order, to, moving)
	return order
end

local function displayTitle(titles: Values, host: ManagedHost): string
	local title = titles[hostKey(host)]
	return if type(title) == "string" and string.find(title, "%S") then title else hostTitle(host)
end

-- Saved hosts first in saved order, then the rest local first and by title.
local function orderHosts(hosts: { ManagedHost }, titles: Values, saved: { string }): { ManagedHost }
	local position: { [string]: number } = {}
	for index, key in saved do
		position[key] = index
	end
	local ranks: { [string]: number } = {}
	local labels: { [string]: string } = {}
	local sortLabels: { [string]: string } = {}
	for _, host in hosts do
		local key = idKey(host.id)
		local label = displayTitle(titles, host)
		ranks[key] = position[hostKey(host)]
		labels[key] = label
		sortLabels[key] = string.lower(label)
	end
	-- SDK lists carry a protected metatable that table.clone rejects.
	local ordered: { ManagedHost } = {}
	for _, host in hosts do
		table.insert(ordered, host)
	end
	table.sort(ordered, function(a: ManagedHost, b: ManagedHost): boolean
		local aKey = idKey(a.id)
		local bKey = idKey(b.id)
		local aRank = ranks[aKey]
		local bRank = ranks[bKey]
		if aRank ~= bRank then
			if aRank and bRank then
				return aRank < bRank
			end
			return aRank ~= nil
		end
		if a.kind ~= b.kind then
			return a.kind == "local"
		end
		if sortLabels[aKey] ~= sortLabels[bKey] then
			return sortLabels[aKey] < sortLabels[bKey]
		end
		if labels[aKey] ~= labels[bKey] then
			return labels[aKey] < labels[bKey]
		end
		return a.id < b.id
	end)
	return ordered
end

local function sessionKey(row: ManagedSession, counts: NameCounts): string
	return if counts[row.name] == 1 then "n:" .. row.name else "i:" .. idKey(row.id)
end

local function namesOf(keys: { string }): { string }
	local names: { string } = {}
	for _, key in keys do
		if string.sub(key, 1, 2) == "n:" then
			table.insert(names, string.sub(key, 3))
		end
	end
	return names
end

local function sessionOrderKeys(stable: string, saved: Values): { string }
	local names = stringList(saved[stable])
	local remembered = sessionOrders[stable]
	-- Another window may have saved a newer order; its names then win.
	if remembered and sameList(namesOf(remembered), names) then
		return remembered
	end
	local keys: { string } = {}
	for _, name in names do
		table.insert(keys, "n:" .. name)
	end
	return keys
end

-- Listed sessions first in list order, then the rest in native order.
local function orderSessions(host: ManagedHost, rows: { ManagedSession }, saved: Values): { ManagedSession }
	local counts = namesOnHost(rows, host.id)
	local byKey: { [string]: ManagedSession } = {}
	local onHost: { ManagedSession } = {}
	for _, row in rows do
		if row.host == host.id then
			table.insert(onHost, row)
			byKey[sessionKey(row, counts)] = row
		end
	end
	local ordered: { ManagedSession } = {}
	local placed: { [string]: boolean } = {}
	for _, key in sessionOrderKeys(hostKey(host), saved) do
		local row = byKey[key]
		if row and not placed[idKey(row.id)] then
			placed[idKey(row.id)] = true
			table.insert(ordered, row)
		end
	end
	for _, row in onHost do
		if not placed[idKey(row.id)] then
			table.insert(ordered, row)
		end
	end
	return ordered
end

-- Replaces `old` in place with `replacement`, dropping stale `replacement`s.
local function renameKey(keys: { string }, old: string, replacement: string): ({ string }, boolean)
	local index = table.find(keys, old)
	if not index then
		return keys, false
	end
	local renamed: { string } = {}
	for position, key in keys do
		if position == index then
			table.insert(renamed, replacement)
		elseif key ~= replacement then
			table.insert(renamed, key)
		end
	end
	return renamed, true
end

local function getSidebarMode(): SidebarMode
	local mode = tern.kv.get(SIDEBAR_MODE)
	return if mode == "always" or mode == "click" or mode == "hover" then mode else "hover"
end

local function setSidebarMode(mode: SidebarMode): ()
	if mode ~= "always" and mode ~= "click" and mode ~= "hover" then
		error("Choose Always expanded, Click tab, or Hover left edge.")
	end
	if getSidebarMode() ~= mode then
		tern.kv.set(SIDEBAR_MODE, mode)
	end
end

local function wholeCells(value: any): number?
	return if type(value) == "number" and value >= 1 and value == math.floor(value) then value else nil
end

local function getDockedWidth(): DockedWidth?
	local saved = tern.kv.get(DOCKED_WIDTH)
	if type(saved) == "table" and wholeCells(saved.cols) then
		local font, fraction = saved.font, saved.fraction
		return {
			cols = saved.cols,
			font = if type(font) == "number" and font > 0 then font else nil,
			fraction = if type(fraction) == "number" and fraction > 0 and fraction < 1 then fraction else nil,
		}
	end
	local cols = wholeCells(tern.kv.get(DOCKED_CELLS))
	return if cols then { cols = cols } else nil
end

local function setDockedWidth(width: DockedWidth): ()
	if not wholeCells(width.cols) then
		return
	end
	tern.kv.set(DOCKED_WIDTH, { cols = width.cols, font = width.font, fraction = width.fraction })
end

local function setHostCollapsed(host: ManagedHost, collapsed: boolean): ()
	local saved = readValues(HOST_COLLAPSED)
	local key = hostKey(host)
	if (saved[key] == true) == collapsed then
		return
	end
	saved[key] = if collapsed then true else nil
	tern.kv.set(HOST_COLLAPSED, saved)
end

-- Tern stores IPv6 hosts without brackets; requests may carry them. Case never matters.
local function comparableAddress(address: string): string
	return string.lower((string.gsub(address, "[%[%]]", "")))
end

local function validBoat(id: any, value: any): Boat?
	if type(id) ~= "string" or not string.match(id, "^bx_%w+$") or type(value) ~= "table" then
		return nil
	end
	local name, title, address = value.name, value.title, value.address
	if type(name) ~= "string" or not string.find(name, "%S") or type(title) ~= "string" or not string.find(title, "%S") then
		return nil
	end
	if address ~= nil and (type(address) ~= "string" or not string.find(address, "^%S+$")) then
		return nil
	end
	local message, savedAt = value.error, value.savedAt
	return {
		id = id,
		name = name,
		title = title,
		address = address,
		state = if value.state == "stopped" then "stopped" else "running",
		error = if type(message) == "string" and string.find(message, "%S") then message else nil,
		savedAt = if type(savedAt) == "number" and savedAt > 0 then savedAt else nil,
	}
end

local function getBoats(): { [string]: Boat }
	local boats: { [string]: Boat } = {}
	for id, value in readValues(BOATS) do
		local boat = validBoat(id, value)
		if boat then
			boats[id] = boat
		end
	end
	return boats
end

local function getBoat(id: string): Boat?
	return getBoats()[id]
end

-- The boat sandbox last attached at `address`; the lowest id wins should two claim it.
local function boatAt(boats: { [string]: Boat }, address: string): Boat?
	local wanted = comparableAddress(address)
	local found: Boat? = nil
	for _, boat in boats do
		local at = boat.address
		if at and comparableAddress(at) == wanted and (found == nil or boat.id < found.id) then
			found = boat
		end
	end
	return found
end

-- The title alias of the boat's address (Rename host title), else the title it was created with.
local function titleOfBoat(titles: Values, boat: Boat): string
	local address = boat.address
	local title = if address then titles[addressKey(address)] else nil
	return if type(title) == "string" and string.find(title, "%S") then title else boat.title
end

-- `window`: the canvas, tab and pane lists and the focused pane the caller read already (a
-- refresh reads them once for everything it does); without it they are read here.
local function snapshot(
	cx: WindowCx,
	hosts: { ManagedHost },
	rows: { ManagedSession },
	preferredContent: ((tab: number) -> number?)?,
	window: Window?
): Snapshot
	local titles = readValues(HOST_TITLES)
	local colors = readValues(HOST_COLORS)
	local icons = readValues(SESSION_ICONS)
	local collapsed = readValues(HOST_COLLAPSED)
	local result: Snapshot = {
		hostTitles = {},
		hostColors = {},
		hostAliased = {},
		hostCollapsed = {},
		sidebarMode = getSidebarMode(),
		sessions = {},
		hostRank = {},
		sessionRank = {},
		hostBoats = {},
		detachedBoats = {},
	}
	local stableHosts: { [string]: string } = {}
	local names: { [string]: NameCounts } = {}
	for _, host in hosts do
		local key = idKey(host.id)
		local stable = hostKey(host)
		stableHosts[key] = stable
		names[key] = {}
		result.hostTitles[key] = displayTitle(titles, host)
		local alias = titles[stable]
		result.hostAliased[key] = type(alias) == "string" and string.find(alias, "%S") ~= nil
		result.hostColors[key] = normalizeColor(colors[stable])
		result.hostCollapsed[key] = collapsed[stable] == true
	end
	for index, host in orderHosts(hosts, titles, stringList(tern.kv.get(HOST_ORDER))) do
		result.hostRank[idKey(host.id)] = index
	end
	local boats = getBoats()
	local attached: { [string]: boolean } = {}
	for _, host in hosts do
		local address = host.address
		if host.kind == "remote" and address and address ~= "" then
			local boat = boatAt(boats, address)
			if boat then
				result.hostBoats[idKey(host.id)] = boat
				attached[boat.id] = true
			end
		end
	end
	for id, boat in boats do
		if not attached[id] then
			table.insert(result.detachedBoats, { boat = boat, title = titleOfBoat(titles, boat) })
		end
	end
	local sessionOrder = readValues(SESSION_ORDER)
	for _, host in hosts do
		for index, row in orderSessions(host, rows, sessionOrder) do
			result.sessionRank[idKey(row.id)] = index
		end
	end
	-- Rows of unattached hosts still get a native-order rank within that host.
	local unattached: { [string]: number } = {}
	for _, row in rows do
		local key = idKey(row.id)
		if not result.sessionRank[key] then
			local hostId = idKey(row.host)
			local rank = (unattached[hostId] or 0) + 1
			unattached[hostId] = rank
			result.sessionRank[key] = rank
		end
	end

	local observed: { [string]: Observed } = {}
	local present: { [string]: boolean } = {}
	for _, row in rows do
		local key = idKey(row.id)
		present[key] = true
		observed[key] = { path = "", priority = 0 }
		local counts = names[idKey(row.host)]
		if counts then
			counts[row.name] = (counts[row.name] or 0) + 1
		end
	end

	local seen: Window = window or {
		canvases = cx.canvas:list(),
		tabs = cx.session:tabs(),
		panes = cx.session:panes(),
		focused = cx.session:focused(),
	}
	local canvasOwners: { [string]: string } = {}
	for _, canvas in seen.canvases do
		canvasOwners[idKey(canvas.pane)] = canvas.owner
	end
	local tabs = seen.tabs
	local panes = seen.panes
	local focused = seen.focused
	local selected: TabInfo? = nil
	local byTab: { [string]: ObservedTab } = {}
	for _, tab in tabs do
		byTab[idKey(tab.id)] = {
			info = tab,
			session = observed[idKey(tab.session)],
		}
		if tab.pane == focused then
			selected = tab
		end
	end
	local preferred = if selected and preferredContent then preferredContent(selected.id) else nil

	for _, pane in panes do
		local tab = if pane.tab then byTab[idKey(pane.tab)] else nil
		if not tab or not tab.session or pane.parked then
			continue
		end
		local owner = canvasOwners[idKey(pane.pane)]
		-- An owner-tagged canvas can appear before its owner replica. Do not use
		-- that unresolved canvas's cwd as content until its owner is known.
		if owner == tern.plugin.id or (pane.block == "tern.canvas" and not owner) then
			continue
		end
		local session = tab.session
		local path = pane.cwd or ""
		if path == "" and tab.info.pane == pane.pane then
			path = tab.info.cwd or ""
		end
		if path == "" then
			-- Native file/root paths are real metadata too, not inferred homes.
			path = pane.path or ""
		end
		if path ~= "" then
			local priority = 1
			if pane.focused or tab.info.pane == pane.pane then
				priority = 2
				if selected and selected.id == tab.info.id then
					priority = 3
				end
			end
			if selected and selected.id == tab.info.id and preferred == pane.pane then
				priority = 4
			end
			if priority > session.priority then
				session.path = path
				session.priority = priority
			end
		end
	end

	local iconsChanged = false
	for _, row in rows do
		local key = idKey(row.id)
		local hostId = idKey(row.host)
		local stable = stableHosts[hostId]
		local info = observed[key]
		local icon: Icon? = nil
		if stable then
			local unique = names[hostId][row.name] == 1
			local remembered = rememberedIcons[key]
			icon = chosenIcon(icons, stable, row, unique)
			if unique and remembered and remembered.host == stable and remembered.name == row.name and not remembered.unique then
				-- Ambiguity ended: publish this survivor's actual choice/default
				-- once, removing any durable preference belonging to its sibling.
				if updateSavedIcon(icons, stable, row.name, icon) then
					iconsChanged = true
				end
			end
			-- Even default is a record: absence must not revive a sibling's icon.
			rememberIcon(stable, row, icon, unique)
		else
			rememberedIcons[key] = nil
		end

		result.sessions[key] = { path = info.path, icon = icon or DEFAULT_ICON }
	end
	for key in rememberedIcons do
		if not present[key] then
			rememberedIcons[key] = nil
		end
	end
	if iconsChanged then
		tern.kv.set(SESSION_ICONS, icons)
	end
	return result
end

local function saveTitle(stable: string, title: string?): ()
	if title and not string.find(title, "%S") then
		error("A host title must not be blank.")
	end
	local titles = readValues(HOST_TITLES)
	if titles[stable] == title then
		return
	end
	titles[stable] = title
	tern.kv.set(HOST_TITLES, titles)
end

local function setHostTitle(host: ManagedHost, title: string?): ()
	saveTitle(hostKey(host), title)
end

-- Titles a remote address before its host exists, so it shows that way from first contact.
local function setAddressTitle(address: string, title: string?): ()
	saveTitle(addressKey(address), title)
end

-- Moves every preference saved under stable host key `from` (title, color, folding, place, session
-- order and icons) to `to`, keeping any that `to` already has; without `to`, forgets them.
local function moveStable(from: string, to: string?): ()
	if from == to then
		return
	end
	for _, name in HOST_MAPS do
		local saved = readValues(name)
		if saved[from] ~= nil then
			if to and saved[to] == nil then
				saved[to] = saved[from]
			end
			saved[from] = nil
			tern.kv.set(name, saved)
		end
	end
	local order = stringList(tern.kv.get(HOST_ORDER))
	local index = table.find(order, from)
	if index then
		if to and not table.find(order, to) then
			order[index] = to
		else
			table.remove(order, index)
		end
		tern.kv.set(HOST_ORDER, if #order > 0 then order else nil)
	end
	local remembered = sessionOrders[from]
	sessionOrders[from] = nil
	if to and remembered and not sessionOrders[to] then
		sessionOrders[to] = remembered
	end
end

-- Moves the preferences of the host at address `old` to `new`, or forgets them without `new`. A
-- boat sandbox can come back from Stop at another address.
local function moveAddress(old: string, new: string?): ()
	moveStable(addressKey(old), if new then addressKey(new) else nil)
end

-- Forgets every preference saved for a host (Remove host…). This PC keeps its own.
local function forgetHost(host: ManagedHost): ()
	if host.kind ~= "local" then
		moveStable(hostKey(host), nil)
	end
end

local function epochNow(): number?
	local ok, now = pcall(os.time)
	return if ok and type(now) == "number" then now else nil
end

-- Saves a boat sandbox record, stamped with the time; when its address changed, the old
-- address's preferences move along.
local function saveBoat(boat: Boat): ()
	local clean = validBoat(boat.id, boat)
	if not clean then
		error("A boat sandbox record needs a bx_ id, a name and a title.")
	end
	clean.savedAt = epochNow()
	local saved = readValues(BOATS)
	local previous = validBoat(clean.id, saved[clean.id])
	local before = if previous then previous.address else nil
	local after = clean.address
	if before and after and comparableAddress(before) ~= comparableAddress(after) then
		moveAddress(before, after)
	end
	saved[clean.id] = clean
	tern.kv.set(BOATS, saved)
end

-- Forgets a deleted boat sandbox together with every preference saved for its address.
local function forgetBoat(id: string): ()
	local saved = readValues(BOATS)
	if saved[id] == nil then
		return
	end
	local boat = validBoat(id, saved[id])
	saved[id] = nil
	tern.kv.set(BOATS, saved)
	local address = if boat then boat.address else nil
	if address then
		moveAddress(address, nil)
	end
end

local function boatTitle(boat: Boat): string
	return titleOfBoat(readValues(HOST_TITLES), boat)
end

local function argvList(value: any): { string }?
	if type(value) ~= "table" then
		return nil
	end
	local argv: { string } = {}
	for _, part in ipairs(value) do
		if type(part) ~= "string" or part == "" then
			return nil
		end
		table.insert(argv, part)
	end
	return if #argv > 0 then argv else nil
end

-- Tests only: the argv that replaces the boat-sandbox script.
local function getBoatCommand(): { string }?
	local saved = tern.kv.get(BOAT_COMMANDS)
	return if type(saved) == "table" then argvList(saved.script) else nil
end

-- Tests only: variables added to the boat-sandbox script's environment.
local function getBoatEnv(): { [string]: string }
	local saved = tern.kv.get(BOAT_COMMANDS)
	local env: { [string]: string } = {}
	local values = if type(saved) == "table" then saved.env else nil
	if type(values) == "table" then
		for name, value in values do
			if type(name) == "string" and string.match(name, "^[%a_][%w_]*$") and type(value) == "string" then
				env[name] = value
			end
		end
	end
	return env
end

-- Tests only: the file the sidebar's copies go to instead of the clipboard.
local function getCopyFile(): string?
	local saved = tern.kv.get(BOAT_COMMANDS)
	local path = if type(saved) == "table" then saved.copies else nil
	return if type(path) == "string" and string.sub(path, 1, 1) == "/" then path else nil
end

local function getSnapshotsCollapsed(): boolean
	return tern.kv.get(SNAPSHOTS_COLLAPSED) == true
end

local function setSnapshotsCollapsed(collapsed: boolean): ()
	if getSnapshotsCollapsed() ~= collapsed then
		tern.kv.set(SNAPSHOTS_COLLAPSED, if collapsed then true else nil)
	end
end

local function getBoatDetails(): boolean
	return tern.kv.get(BOAT_DETAILS) == true
end

local function setBoatDetails(shown: boolean): ()
	if getBoatDetails() ~= shown then
		tern.kv.set(BOAT_DETAILS, if shown then true else nil)
	end
end

local function setHostColor(host: ManagedHost, color: string?): ()
	local value: string? = nil
	if color then
		value = normalizeColor(color)
		if not value then
			error("A title color must be a hex color such as #3b82f6.")
		end
	end
	local colors = readValues(HOST_COLORS)
	local stable = hostKey(host)
	if colors[stable] == value then
		return
	end
	colors[stable] = value
	tern.kv.set(HOST_COLORS, colors)
end

local function setSessionIcon(host: ManagedHost, row: ManagedSession, rows: { ManagedSession }, icon: Icon?): ()
	if icon and not validIcon(icon) then
		error("Choose a native icon or a nonblank symbol of at most 64 bytes without control characters.")
	end
	local target = findRow(rows, host, row)
	local stable = hostKey(host)
	local choice: Icon? = if icon then { kind = icon.kind, value = icon.value } else nil
	local unique = namesOnHost(rows, host.id)[target.name] == 1
	if unique then
		local saved = readValues(SESSION_ICONS)
		if updateSavedIcon(saved, stable, target.name, choice) then
			tern.kv.set(SESSION_ICONS, saved)
		end
	end
	rememberIcon(stable, target, choice, unique)
end

local function renameSession(cx: WindowCx, host: ManagedHost, row: ManagedSession, name: string): ()
	if not string.find(name, "%S") then
		error("A session name must not be blank.")
	end
	local before = cx.sessions:list()
	local target = findRow(before, host, row)
	local stable = hostKey(host)
	local oldName = target.name
	local counts = namesOnHost(before, host.id)
	local saved = readValues(SESSION_ICONS)
	local icon = chosenIcon(saved, stable, target, counts[oldName] == 1)
	local destination: ManagedSession? = nil
	local destinationIcon: Icon? = nil
	if name ~= oldName and counts[name] == 1 then
		for _, candidate in before do
			if candidate.host == host.id and candidate.name == name then
				destination = candidate
				destinationIcon = chosenIcon(saved, stable, candidate, true)
				break
			end
		end
	end

	-- Exact received id: renaming never switches sessions or hosts.
	cx.sessions:rename(target.id, name)
	local after = cx.sessions:list()
	local renamed = findRow(after, host, target)
	if renamed.name == oldName then
		return
	end
	local remaining = namesOnHost(after, host.id)
	rememberIcon(stable, renamed, icon, remaining[renamed.name] == 1)
	if destination then
		for _, candidate in after do
			if candidate.id == destination.id and candidate.host == host.id and candidate.name == destination.name then
				rememberIcon(stable, candidate, destinationIcon, remaining[candidate.name] == 1)
				break
			end
		end
	end

	-- Re-read after the native operation; do not overwrite another window's
	-- unrelated changes with the map captured before the rename.
	local fresh = readValues(SESSION_ICONS)
	local changed = false
	if counts[oldName] == 1 and not remaining[oldName] then
		changed = updateSavedIcon(fresh, stable, oldName, nil)
	elseif counts[oldName] > 1 and remaining[oldName] == 1 then
		for _, candidate in after do
			if candidate.host == host.id and candidate.name == oldName then
				-- The remaining exact session owns this name now, not the
				-- renamed sibling whose old durable preference may still exist.
				local survivorIcon = chosenIcon(fresh, stable, candidate, false)
				if updateSavedIcon(fresh, stable, oldName, survivorIcon) then
					changed = true
				end
				rememberIcon(stable, candidate, survivorIcon, true)
				break
			end
		end
	end
	if remaining[renamed.name] == 1 then
		-- Preserve source default as well as custom icons at the destination.
		if updateSavedIcon(fresh, stable, renamed.name, icon) then
			changed = true
		end
	end
	if changed then
		tern.kv.set(SESSION_ICONS, fresh)
	end

	if counts[oldName] == 1 and remaining[renamed.name] == 1 then
		-- Both names are unique: the session keeps its place under the new name.
		local remembered = sessionOrders[stable]
		if remembered then
			sessionOrders[stable] = (renameKey(remembered, "n:" .. oldName, "n:" .. renamed.name))
		end
		local orders = readValues(SESSION_ORDER)
		local order, moved = renameKey(stringList(orders[stable]), oldName, renamed.name)
		if moved then
			orders[stable] = order
			tern.kv.set(SESSION_ORDER, orders)
		end
	end
end

local function findHost(hosts: { ManagedHost }, host: ManagedHost): ManagedHost
	for _, candidate in hosts do
		if candidate.id == host.id then
			return candidate
		end
	end
	error("The host is no longer attached to this window.")
end

local function moveHost(hosts: { ManagedHost }, moving: ManagedHost, target: ManagedHost): ()
	if moving.id == target.id then
		error("Choose a different host as the new place.")
	end
	local movingKey = hostKey(findHost(hosts, moving))
	local targetKey = hostKey(findHost(hosts, target))
	if movingKey == targetKey then
		error("These hosts share one saved identity, so their order cannot be saved.")
	end
	local saved = stringList(tern.kv.get(HOST_ORDER))
	-- Saved but detached hosts keep their slots; attached unsaved hosts join
	-- in their current display order.
	local full = table.clone(saved)
	local listed: { [string]: boolean } = {}
	for _, key in saved do
		listed[key] = true
	end
	for _, host in orderHosts(hosts, readValues(HOST_TITLES), saved) do
		local key = hostKey(host)
		if not listed[key] then
			listed[key] = true
			table.insert(full, key)
		end
	end
	local order = moveKey(full, movingKey, targetKey)
	if not sameList(order, saved) then
		tern.kv.set(HOST_ORDER, order)
	end
end

local function moveSession(host: ManagedHost, rows: { ManagedSession }, moving: ManagedSession, target: ManagedSession): ()
	if moving.id == target.id then
		error("Choose a different session as the new place.")
	end
	local lifted = findRow(rows, host, moving)
	local destination = findRow(rows, host, target)
	local stable = hostKey(host)
	local counts = namesOnHost(rows, host.id)
	local saved = readValues(SESSION_ORDER)
	local keys: { string } = {}
	for _, row in orderSessions(host, rows, saved) do
		table.insert(keys, sessionKey(row, counts))
	end
	local order = moveKey(keys, sessionKey(lifted, counts), sessionKey(destination, counts))
	sessionOrders[stable] = order
	-- Only unique names are durable; present sessions only.
	local names = namesOf(order)
	if not sameList(names, stringList(saved[stable])) then
		saved[stable] = if #names > 0 then names else nil
		tern.kv.set(SESSION_ORDER, saved)
	end
end

return {
	snapshot = snapshot,
	setHostTitle = setHostTitle,
	setAddressTitle = setAddressTitle,
	setHostColor = setHostColor,
	normalizeColor = normalizeColor,
	getSidebarMode = getSidebarMode,
	setSidebarMode = setSidebarMode,
	getDockedWidth = getDockedWidth,
	setDockedWidth = setDockedWidth,
	setHostCollapsed = setHostCollapsed,
	setSessionIcon = setSessionIcon,
	renameSession = renameSession,
	moveHost = moveHost,
	moveSession = moveSession,
	comparableAddress = comparableAddress,
	forgetHost = forgetHost,
	getBoats = getBoats,
	getBoat = getBoat,
	saveBoat = saveBoat,
	forgetBoat = forgetBoat,
	boatTitle = boatTitle,
	getBoatCommand = getBoatCommand,
	getBoatEnv = getBoatEnv,
	getCopyFile = getCopyFile,
	getSnapshotsCollapsed = getSnapshotsCollapsed,
	setSnapshotsCollapsed = setSnapshotsCollapsed,
	getBoatDetails = getBoatDetails,
	setBoatDetails = setBoatDetails,
}
