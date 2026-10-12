--!strict
local agents = require("./agents")
local sessions = require("./sessions")
local data = require("./session-data")
local drawer = require("./drawer")

local ABOUT = "Sessions grouped by machine, with customizable icons, working directories, observed activity, and collapsible host groups. Use sidebar settings for docked, click-tab, or hover display; right-click sessions or host headings for native editing controls; click a grip, then a new place, to reorder sessions or hosts."

type Sidebar = {
	pane: number?,
	contentFocus: number?,
	observed: boolean,
	hidden: boolean,
	place: boolean,
	signature: string?,
}

-- These IDs and preferences belong to this window VM, not the shared KV store.
local sidebars: { [string]: Sidebar } = {}
local paneTabs: { [string]: string } = {}
local closing: { [string]: boolean } = {}
local closed: { [string]: boolean } = {}
local knownTargets: { [string]: sessions.Target } = {}
local failures: { [string]: string } = {}
local unavailableHosts: { [string]: string } = {}
local nativeInputs = 0
-- Pane key -> tern.now() when a canvas without replicated state was first seen.
local unresolvedSince: { [string]: number } = {}
-- Replica lag resolves within moments. Tern 0.7.3's palette "Reload plugins" drops
-- existing local canvases' state for good; past this, stop waiting so the tab gets a sidebar.
local UNRESOLVED_WAIT_MS = 5000
local display: sessions.Display = { open = false, holdOpen = false, moving = nil }
-- The item lifted for pick-and-place reordering; window-local like the rest of the drawer state.
local moving: sessions.Moving? = nil
-- Pane key -> docked split ratio last observed or applied. A visible change is the user's drag.
local widthSeen: { [string]: number } = {}
-- Ratios are 32-bit floats; this is ~0.1px on a 1280px window and far below one cell.
local WIDTH_EPSILON = 1e-4

local function key(id: number): string
	return string.format("%.0f", id)
end

-- A native prompt/picker or a lifted item keeps an overlay drawer open.
local function syncDisplay()
	display.moving = moving
	display.holdOpen = nativeInputs > 0 or moving ~= nil
end

local function findHost(hosts: { ManagedHost }, id: number): ManagedHost?
	for _, host in hosts do
		if host.id == id then
			return host
		end
	end
	return nil
end

local function findSession(rows: { ManagedSession }, hostId: number, id: number?): ManagedSession?
	for _, row in rows do
		if row.id == id and row.host == hostId then
			return row
		end
	end
	return nil
end

local function preferredContent(tab: number): number?
	local state = sidebars[key(tab)]
	return if state then state.contentFocus else nil
end

local function sidebar(tab: number): Sidebar
	local tabKey = key(tab)
	local state = sidebars[tabKey]
	if not state then
		state = { observed = false, hidden = false, place = false }
		sidebars[tabKey] = state
	end
	return state
end

local function report(cx: WindowCx, operation: string, message: string)
	if failures[operation] == message then
		return
	end
	failures[operation] = message
	tern.log.error(operation, message)
	cx:toast("error", "Sessions sidebar: " .. operation, message)
end

-- Catch native lifecycle/operation failures only. View-building errors remain real hook errors.
local function call(cx: WindowCx, operation: string, fn: () -> ...any): (boolean, ...any)
	local ok, first, second = pcall(fn)
	if not ok then
		report(cx, operation, tostring(first))
		return false
	end
	failures[operation] = nil
	return true, first, second
end

local function active(cx: WindowCx): (number?, number?, TabLayout?)
	local ok, pane = call(cx, "reading focus", function()
		return cx.session:focused()
	end)
	if not ok or not pane then
		return nil, nil, nil
	end
	local found, tab = call(cx, "finding active tab", function()
		return cx.session:tab_of(pane)
	end)
	if not found or not tab then
		return nil, nil, nil
	end
	local read, layout = call(cx, "reading active layout", function()
		return cx.session:layout(tab)
	end)
	if not read or not layout then
		return nil, nil, nil
	end
	return pane, tab, layout
end

local function remember(targets: { [string]: sessions.Target })
	-- Keep already-rendered actions recognizable if their target disappears before delivery.
	for action, target in targets do
		knownTargets[action] = target
	end
end

local function closeOwned(cx: WindowCx, pane: number): boolean
	local paneKey = key(pane)
	if closing[paneKey] or closed[paneKey] then
		return true
	end
	closing[paneKey] = true
	local ok = call(cx, "closing sidebar " .. paneKey, function()
		cx.layout:close(pane)
	end)
	if not ok then
		closing[paneKey] = nil
	end
	return ok
end

local function inTree(tree: TabTree, pane: number): boolean
	if tree.pane then
		return tree.pane == pane
	end
	return (tree[1] ~= nil and inTree(tree[1], pane))
		or (tree[2] ~= nil and inTree(tree[2], pane))
end

local function inLayout(layout: TabLayout, pane: number): boolean
	if inTree(layout.root, pane) then
		return true
	end
	for _, float in layout.floats do
		if float.pane == pane then
			return true
		end
	end
	return false
end

-- Whether a tab holds nothing but this plugin's sidebars (its last content pane closed, was
-- parked or moved away). `gone` is a pane whose close is being reported and may still be listed.
local function onlySidebars(layout: TabLayout, owned: { [number]: boolean }, gone: number?): boolean
	local function content(pane: number): boolean
		return pane ~= gone and not owned[pane] and not closed[key(pane)]
	end
	local function any(tree: TabTree): boolean
		if tree.pane then
			return content(tree.pane)
		end
		return (tree[1] ~= nil and any(tree[1])) or (tree[2] ~= nil and any(tree[2]))
	end
	if any(layout.root) then
		return false
	end
	for _, float in layout.floats do
		if content(float.pane) then
			return false
		end
	end
	return true
end

-- Tern closes a tab once its last pane closes, so a sidebar left alone must not keep the tab
-- open (it would show as a tab titled "Sessions Sidebar [ss-…]"). Covers background tabs.
local function closeLoneSidebars(cx: WindowCx, gone: number?)
	local listed, canvasRows = call(cx, "listing canvases", function()
		return cx.canvas:list()
	end)
	if not listed then
		return
	end
	local owned: { [number]: boolean } = {}
	local byTab: { [string]: { tab: number, panes: { number } } } = {}
	for _, canvas in canvasRows do
		if canvas.owner == tern.plugin.id and not closed[key(canvas.pane)] then
			owned[canvas.pane] = true
			local found, tab = call(cx, "locating sidebar panes", function()
				return cx.session:tab_of(canvas.pane)
			end)
			if found and tab then
				local group = byTab[key(tab)] or { tab = tab, panes = {} }
				byTab[key(tab)] = group
				table.insert(group.panes, canvas.pane)
			end
		end
	end
	for _, group in byTab do
		local read, layout = call(cx, "reading sidebar tab layout", function()
			return cx.session:layout(group.tab)
		end)
		if read and layout and onlySidebars(layout, owned, gone) then
			for _, pane in group.panes do
				closeOwned(cx, pane)
			end
		end
	end
end

-- Use the split tree's horizontal order; PaneInfo deliberately has no geometry.
local function leftmost(tree: TabTree, owned: { [number]: boolean }, x: number, width: number): (number?, number)
	if tree.pane then
		if owned[tree.pane] or closed[key(tree.pane)] then
			return nil, math.huge
		end
		return tree.pane, x
	end
	local leftWidth = width
	local rightX = x
	local rightWidth = width
	if tree.split == "right" then
		leftWidth = width * (tree.ratio or 0.5)
		rightX = x + leftWidth
		rightWidth = width - leftWidth
	end
	local first, firstX = nil, math.huge
	local second, secondX = nil, math.huge
	if tree[1] then
		first, firstX = leftmost(tree[1], owned, x, leftWidth)
	end
	if tree[2] then
		second, secondX = leftmost(tree[2], owned, rightX, rightWidth)
	end
	if firstX <= secondX then
		return first, firstX
	end
	return second, secondX
end

local function unresolvedCanvas(cx: WindowCx, tree: TabTree, canvases: { [number]: CanvasInfo }): boolean
	if tree.pane then
		local paneKey = key(tree.pane)
		if closed[paneKey] or canvases[tree.pane] then
			unresolvedSince[paneKey] = nil
			return false
		end
		local ok, info = call(cx, "reading pane metadata", function()
			return cx.session:pane(tree.pane :: number)
		end)
		-- A canvas's pane can precede its replicated owner metadata, especially on reload.
		if ok and info ~= nil and info.block ~= "tern.canvas" then
			unresolvedSince[paneKey] = nil
			return false
		end
		local since = unresolvedSince[paneKey]
		if not since then
			unresolvedSince[paneKey] = tern.now()
			return true
		end
		return tern.now() - since < UNRESOLVED_WAIT_MS
	end
	return (tree[1] ~= nil and unresolvedCanvas(cx, tree[1], canvases))
		or (tree[2] ~= nil and unresolvedCanvas(cx, tree[2], canvases))
end

local function preserveFocus(cx: WindowCx, pane: number, tab: number)
	-- The native prompt/picker owns DOM focus until its fresh-context continuation runs.
	if nativeInputs > 0 then
		return
	end
	local ok, focused = call(cx, "checking preserved focus", function()
		return cx.session:focused()
	end)
	if not ok or focused == pane then
		return
	end
	local found, containing = call(cx, "checking original focus", function()
		return cx.session:tab_of(pane)
	end)
	if found and containing == tab then
		call(cx, "restoring terminal focus", function()
			cx.layout:focus(pane)
		end)
	end
end

local function place(cx: WindowCx, state: Sidebar, pane: number, layout: TabLayout, owned: { [number]: boolean }, focus: number)
	if not state.place or not inLayout(layout, pane) then
		return
	end
	local target = leftmost(layout.root, owned, 0, 1)
	if not target then
		return
	end
	-- Only initialization changes size/position. Never fight a later user drag or resize.
	state.place = false
	local ok, moved = call(cx, "placing sidebar on the left", function()
		return cx.layout:move(pane, target, "left", { focus = false })
	end)
	if ok and moved then
		local shrunk = call(cx, "narrowing sidebar", function()
			return cx.layout:resize(pane, "right", -10000)
		end)
		if shrunk then
			call(cx, "sizing sidebar", function()
				return cx.layout:resize(pane, "right", 34)
			end)
		end
	elseif ok then
		report(cx, "placing sidebar on the left", "The native layout refused the move; the sidebar was left in its original split.")
	end
	preserveFocus(cx, focus, layout.tab)
end

local function syncDrawer(
	cx: WindowCx,
	state: Sidebar,
	pane: number,
	layout: TabLayout,
	owned: { [number]: boolean },
	content: number,
	mode: data.SidebarMode
)
	-- Replica lag and sidebar-only tabs must not turn into a wrong-pane layout mutation.
	if not inLayout(layout, pane) or owned[content] or closed[key(content)] or not inLayout(layout, content) then
		return
	end
	if mode == "always" then
		place(cx, state, pane, layout, owned, content)
	end
	local operation = "updating sidebar display " .. key(pane)
	local ok, synced, message = pcall(drawer.sync, cx, pane, content, mode)
	if not ok then
		report(cx, operation, tostring(synced))
	elseif synced then
		failures[operation] = nil
		if mode ~= "always" then
			state.place = false
		end
	elseif message then
		report(cx, operation, message)
	end
end

-- The left sidebar's split ratio and the share of the tab width its split spans; nil when it
-- does not own a left divider (floating, stacked in a vertical split, or moved to the right).
local function dockedSplit(tree: TabTree, pane: number, outer: number): (number?, number)
	local first, second = tree[1], tree[2]
	if tree.pane or not first or not second then
		return nil, outer
	end
	local ratio = tree.ratio or 0.5
	if tree.split == "down" then
		local found, share = dockedSplit(first, pane, outer)
		if found then
			return found, share
		end
		return dockedSplit(second, pane, outer)
	end
	if first.pane == pane then
		return ratio, outer
	end
	local found, share = dockedSplit(first, pane, outer * ratio)
	if found then
		return found, share
	end
	return dockedSplit(second, pane, outer * (1 - ratio))
end

local function dockedRatio(cx: WindowCx, pane: number, tab: number): (number?, number)
	local layout = cx.session:layout(tab)
	if not layout or layout.zoomed then
		return nil, 1
	end
	return dockedSplit(layout.root, pane, 1)
end

type Probe = { r0: number, r1: number, cols: number }

-- resize scales the split ratio by (cols + cells) / cols, where cols is the pane width in cells from
-- the last layout pass and stays fixed for the whole call (hidden tabs included), so a one-cell probe
-- reveals cols. It leaves the ratio one cell off: `settle` must then set it exactly. Nil when the
-- divider cannot move that way: a pane at Tern's minimum width or the ratio at its 0.1-0.9 bounds.
local function probe(cx: WindowCx, pane: number, tab: number, step: number): Probe?
	local r0 = dockedRatio(cx, pane, tab)
	if not r0 or not cx.layout:resize(pane, "right", step) then
		return nil
	end
	local r1 = dockedRatio(cx, pane, tab)
	if not r1 or r1 == r0 then
		return nil
	end
	return { r0 = r0, r1 = r1, cols = step * r0 / (r1 - r0) }
end

-- Lands a probed split exactly on `target` with one fractional resize.
local function settle(cx: WindowCx, pane: number, tab: number, measured: Probe, target: number): number?
	cx.layout:resize(pane, "right", measured.cols * (target / measured.r1 - 1))
	return dockedRatio(cx, pane, tab)
end

-- A probe toward `step`, else away from it.
local function measure(cx: WindowCx, pane: number, tab: number, step: number): Probe?
	return probe(cx, pane, tab, step) or probe(cx, pane, tab, -step)
end

-- Whether the divider can move both ways. Tern moves a divider that cannot by itself (it holds a
-- pane at its minimum width while the window shrinks), so only a free divider's change is a drag.
local function free(cx: WindowCx, pane: number, tab: number): boolean
	for _, step in { 1, -1 } do
		local measured = probe(cx, pane, tab, step)
		if not measured then
			return false
		end
		settle(cx, pane, tab, measured, measured.r0)
	end
	return true
end

local function setRatio(cx: WindowCx, pane: number, tab: number, target: number): number?
	local r0 = dockedRatio(cx, pane, tab)
	if not r0 or math.abs(r0 - target) <= WIDTH_EPSILON then
		return r0
	end
	local measured = measure(cx, pane, tab, if target > r0 then 1 else -1)
	if not measured then
		return dockedRatio(cx, pane, tab)
	end
	return settle(cx, pane, tab, measured, target)
end

type DockedSidebar = { pane: number, tab: number, ratio: number, share: number }

-- Always expanded: one width in whole cells for every tab's docked sidebar. A ratio this plugin did
-- not set, on a divider free to move, is the user's drag and becomes the width. Resizing the window
-- keeps split ratios and so scales the column; the visible sidebar is measured on every refresh and
-- sized back to the width, which Tern exposes only to the cell. Every other docked sidebar, hidden
-- tabs included, takes the visible one's share of the tab at once, so switching tabs never moves it.
local function lockWidths(cx: WindowCx, tab: number, pane: number, owned: { [number]: boolean })
	call(cx, "keeping sidebar width", function()
		local docked: { DockedSidebar } = {}
		local visible: DockedSidebar? = nil
		-- Check every sidebar, not only the visible one: a drag followed by a tab switch
		-- within one refresh tick leaves the resize on a sidebar that is now hidden.
		local dragged: DockedSidebar? = nil
		for sidebarPane in owned do
			local paneKey = key(sidebarPane)
			local sidebarTab = if closing[paneKey] or closed[paneKey] then nil else cx.session:tab_of(sidebarPane)
			if sidebarTab then
				local ratio, share = dockedRatio(cx, sidebarPane, sidebarTab)
				if ratio then
					local entry = { pane = sidebarPane, tab = sidebarTab, ratio = ratio, share = share }
					table.insert(docked, entry)
					if sidebarPane == pane then
						visible = entry
					end
					local seen = widthSeen[paneKey]
					if seen and math.abs(ratio - seen) > WIDTH_EPSILON and (dragged == nil or sidebarPane == pane) then
						dragged = entry
					end
				end
			end
		end
		if not visible then
			return
		end
		if dragged and not free(cx, dragged.pane, dragged.tab) then
			dragged = nil
		end
		local width = data.getDockedWidth()
		if dragged and dragged ~= visible then
			-- Dragged just before a tab switch: its last layout pass still holds the new width.
			local draggedWidth = measure(cx, dragged.pane, dragged.tab, 1)
			if draggedWidth then
				width = math.floor(draggedWidth.cols + 0.5)
				settle(cx, dragged.pane, dragged.tab, draggedWidth, draggedWidth.r0)
			end
		end
		local measured = measure(cx, pane, tab, 1)
		if not measured then
			widthSeen[key(pane)] = visible.ratio
			return
		end
		if dragged == visible or not width then
			width = math.floor(measured.cols + 0.5)
		end
		data.setDockedWidth(width)
		local ratio = settle(cx, pane, tab, measured, measured.r0 * width / measured.cols) or visible.ratio
		local applied: { [string]: number } = { [key(pane)] = ratio }
		for _, entry in docked do
			if entry ~= visible then
				applied[key(entry.pane)] = setRatio(cx, entry.pane, entry.tab, ratio * visible.share / entry.share)
					or entry.ratio
			end
		end
		widthSeen = applied
	end)
end

-- Text of the "host-colors" sheet this VM installed; nil until the first refresh installs it.
local colorSheet: string? = nil

local function syncColorStyles(snapshot: data.Snapshot)
	local seen: { [string]: boolean } = {}
	local colors: { string } = {}
	for _, color in snapshot.hostColors do
		if not seen[color] then
			seen[color] = true
			table.insert(colors, color)
		end
	end
	table.sort(colors)
	local rules: { string } = {}
	for _, color in colors do
		-- Colors come from data.normalizeColor, so they are always "#" plus six hex digits.
		table.insert(rules, '[data-role="sessions-sidebar"] [data-host-color="' .. color
			.. '"] [data-role="sessions-sidebar-host-title"] { color: ' .. color .. "; }")
	end
	local sheet = table.concat(rules, "\n")
	if sheet ~= colorSheet then
		tern.css("host-colors", sheet)
		colorSheet = sheet
	end
end

local function refresh(cx: WindowCx, explicit: boolean?)
	local focus, tab, layout = active(cx)
	if not focus or not tab or not layout then
		if explicit then
			cx:toast("info", "No active tab for the sessions sidebar", "Open a tab first; the plugin does not create terminals.")
		end
		return
	end
	-- Every refresh (focus, tab, pane events and the 1s timer) samples agent states once.
	agents.observe(cx, tab)
	local state = sidebar(tab)
	local tabKey = key(tab)
	local listed, canvasRows = call(cx, "listing canvases", function()
		return cx.canvas:list()
	end)
	if not listed then
		return
	end
	local canvases: { [number]: CanvasInfo } = {}
	local owned: { [number]: boolean } = {}
	local current: { number } = {}
	local waitingForClose = false
	local waitingForMetadata = false
	for _, canvas in canvasRows do
		if not closed[key(canvas.pane)] then
			canvases[canvas.pane] = canvas
			if canvas.owner == tern.plugin.id then
				owned[canvas.pane] = true
				local found, containing = call(cx, "locating sidebar panes", function()
					return cx.session:tab_of(canvas.pane)
				end)
				if not found then
					return
				end
				if inLayout(layout, canvas.pane) then
					containing = tab
				elseif not containing then
					local read, info = call(cx, "reading sidebar placement", function()
						return cx.session:pane(canvas.pane)
					end)
					if not read then
						return
					end
					-- A parked canvas is deliberately outside every tab; other nil placements
					-- must settle before another owned pane can safely be created.
					if not info or not info.parked then
						waitingForMetadata = true
					end
				end
				if containing then
					paneTabs[key(canvas.pane)] = key(containing)
				end
				if containing == tab then
					if closing[key(canvas.pane)] then
						waitingForClose = true
					else
						table.insert(current, canvas.pane)
					end
				end
			end
		end
	end
	if onlySidebars(layout, owned) then
		-- The tab's last content pane closed, was parked or moved away while it was shown.
		for _, pane in current do
			closeOwned(cx, pane)
		end
		return
	end
	if state.pane and not closed[key(state.pane)] then
		owned[state.pane] = true
		-- A successful open reserves this tab immediately, before its replica arrives.
		if not state.observed and not canvases[state.pane] then
			if state.hidden then
				closeOwned(cx, state.pane)
			end
			return
		end
	end
	if owned[focus] then
		local content = state.contentFocus
		if not content or owned[content] or not inLayout(layout, content) then
			content = leftmost(layout.root, owned, 0, 1)
		end
		if content then
			state.contentFocus = content
			preserveFocus(cx, content, tab)
			focus = content
		end
	else
		state.contentFocus = focus
	end
	if state.hidden then
		for _, pane in current do
			closeOwned(cx, pane)
		end
		return
	end
	if state.pane and state.observed and not inLayout(layout, state.pane) and #current == 0 then
		-- This covers a replicated close or moving the sidebar out of the tab, too.
		state.hidden = true
		state.pane = nil
		state.signature = nil
		return
	end
	local selected: number? = nil
	for _, pane in current do
		if selected == nil or pane < selected then
			selected = pane
		end
	end
	if selected then
		if state.pane ~= selected then
			state.signature = nil
			-- Reused canvases retain their saved placement and user-adjusted size.
			state.place = false
		end
		state.pane = selected
		state.observed = true
		for _, pane in current do
			if pane ~= selected then
				closeOwned(cx, pane)
			end
		end
	elseif waitingForClose or waitingForMetadata then
		return
	elseif state.pane then
		-- Metadata can temporarily lag a pane already observed in this tab.
		selected = state.pane
	end
	local readHosts, hosts = call(cx, "listing machines", function()
		return cx.hosts:list()
	end)
	local readSessions, rows = call(cx, "listing sessions", function()
		return cx.sessions:list()
	end)
	if not readHosts or not readSessions then
		return
	end
	local host: ManagedHost? = nil
	for _, machine in hosts do
		if machine.state ~= "connected" then
			unavailableHosts[key(machine.id)] = nil
		end
		if machine.current then
			host = machine
		end
	end
	local lifted = moving
	if lifted and (not findHost(hosts, lifted.host)
		or (lifted.kind == "session" and not findSession(rows, lifted.host, lifted.session)))
	then
		-- The lifted item disappeared (closed, renamed away or detached elsewhere).
		moving = nil
	end
	local snapshot = data.snapshot(cx, hosts, rows, preferredContent)
	syncColorStyles(snapshot)
	syncDisplay()
	local model = sessions.build(hosts, rows, snapshot, display, agents.marks())
	if selected then
		if state.signature ~= model.signature then
			local updated = call(cx, "updating sidebar " .. key(selected), function()
				cx.canvas:set(selected :: number, {
					title = drawer.title(cx, selected :: number),
					about = ABOUT,
					view = model.view,
				})
			end)
			if updated then
				state.signature = model.signature
				remember(model.targets)
			end
		end
		syncDrawer(cx, state, selected, layout, owned, focus, snapshot.sidebarMode)
		if snapshot.sidebarMode == "always" then
			lockWidths(cx, tab, selected, owned)
		else
			-- Re-docking later resizes on its own; never mistake that for the user's drag.
			table.clear(widthSeen)
		end
		return
	end
	if not host or host.state ~= "connected" or unresolvedCanvas(cx, layout.root, canvases) then
		return
	end
	for _, float in layout.floats do
		if unresolvedCanvas(cx, { pane = float.pane }, canvases) then
			return
		end
	end
	local hostKey = key(host.id)
	if explicit then
		unavailableHosts[hostKey] = nil
	end
	if unavailableHosts[hostKey] then
		return
	end
	local ok, pane, err = call(cx, "opening sidebar on " .. host.name, function()
		return cx.canvas:open({
			title = drawer.newTitle(),
			about = ABOUT,
			view = model.view,
			how = "beside",
			focus = false,
		})
	end)
	if not ok or not pane then
		local message = if ok then tostring(err or "The host did not open a canvas.") else failures["opening sidebar on " .. host.name]
		unavailableHosts[hostKey] = message or "Canvas opening failed."
		if ok then
			report(cx, "opening sidebar on " .. host.name, unavailableHosts[hostKey])
		end
		return
	end
	state.pane = pane
	state.observed = false
	state.place = true
	state.signature = model.signature
	paneTabs[key(pane)] = tabKey
	remember(model.targets)
	preserveFocus(cx, focus, tab)
	-- Use a fresh layout if the new leaf is already visible; otherwise the next callback places it.
	local loaded, updatedLayout = call(cx, "reading new sidebar layout", function()
		return cx.session:layout(tab)
	end)
	if loaded and updatedLayout then
		owned[pane] = true
		syncDrawer(cx, state, pane, updatedLayout, owned, focus, snapshot.sidebarMode)
		if snapshot.sidebarMode == "always" then
			lockWidths(cx, tab, pane, owned)
		end
	end
end

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

local function prompt(cx: WindowCx, operation: string, opts: PromptOptions, apply: (string, WindowCx) -> ())
	-- Anchor input before taking DOM focus, then hold the drawer through the native input.
	refresh(cx)
	nativeInputs += 1
	refresh(cx)
	local opened = call(cx, operation, function()
		cx:prompt(opts):next(function(value: string?, err: string?, fresh: WindowCx?)
			nativeInputs -= 1
			if err then
				inputFailure(operation, err, fresh)
			elseif value ~= nil then
				if fresh then
					apply(value, fresh)
				else
					inputFailure(operation, "The window closed before the input could be applied.", nil)
				end
			end
			if fresh then
				refresh(fresh)
			end
		end)
	end)
	if not opened then
		nativeInputs -= 1
		refresh(cx)
	end
end

local function pick(cx: WindowCx, operation: string, opts: PickOptions, apply: (PickItem, WindowCx) -> ())
	refresh(cx)
	nativeInputs += 1
	refresh(cx)
	local opened = call(cx, operation, function()
		cx:pick(opts):next(function(item: PickItem?, err: string?, fresh: WindowCx?)
			nativeInputs -= 1
			if err then
				inputFailure(operation, err, fresh)
			elseif item ~= nil then
				if fresh then
					apply(item, fresh)
				else
					inputFailure(operation, "The window closed before the choice could be applied.", nil)
				end
			end
			if fresh then
				refresh(fresh)
			end
		end)
	end)
	if not opened then
		nativeInputs -= 1
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
	if nativeInputs > 0 then
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

local function globalAction(cx: WindowCx, target: sessions.Target): boolean
	if target.kind == "settings" then
		sidebarSettings(cx)
	elseif target.kind == "toggle-panel" then
		display.open = not display.open
		refresh(cx)
	elseif target.kind == "cancel-move" then
		moving = nil
		refresh(cx)
	else
		return false
	end
	return true
end

tern.command({
	id = "show",
	title = "Show sessions sidebar",
	run = function(cx: WindowCx)
		local _, tab = active(cx)
		if tab then
			local state = sidebar(tab)
			state.hidden = false
		end
		refresh(cx, true)
	end,
})

tern.command({
	id = "hide",
	title = "Hide sessions sidebar (current tab)",
	run = function(cx: WindowCx)
		local _, tab = active(cx)
		if tab then
			sidebar(tab).hidden = true
			refresh(cx)
		end
	end,
})

tern.command({
	id = "refresh",
	title = "Refresh sessions sidebar",
	run = function(cx: WindowCx)
		refresh(cx, true)
	end,
})

tern.command({
	id = "settings",
	title = "Sessions sidebar settings",
	run = sidebarSettings,
})

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean
	if ev.owner ~= tern.plugin.id then
		return false
	end
	if nativeInputs > 0 then
		return true
	end
	local action = ev.act .. "\n" .. ev.node
	local target: sessions.Target? = knownTargets[action]
	if target and globalAction(cx, target) then
		return true
	end
	local hosts = cx.hosts:list()
	local rows = cx.sessions:list()
	local snapshot = data.snapshot(cx, hosts, rows, preferredContent)
	if not target then
		syncDisplay()
		target = sessions.build(hosts, rows, snapshot, display, agents.marks()).targets[action]
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
		moving = { kind = "session", host = host.id, session = row.id }
		refresh(cx)
	elseif target.kind == "move-host" then
		moving = { kind = "host", host = host.id }
		refresh(cx)
	elseif target.kind == "place-session" and row then
		-- `host`/`row` are the destination, resolved from this callback's fresh lists.
		local lifted = moving
		if not lifted or lifted.kind ~= "session" or lifted.host ~= host.id then
			return true
		end
		local liftedRow = findSession(rows, host.id, lifted.session)
		moving = nil
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
		local lifted = moving
		if not lifted or lifted.kind ~= "host" then
			return true
		end
		local liftedHost = findHost(hosts, lifted.host)
		moving = nil
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
		if not row.current then
			-- Switching failures remain native errors, rather than pretending success.
			cx.sessions:switch(row.id)
		end
		refresh(cx)
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
			data.setHostCollapsed(host, not snapshot.hostCollapsed[key(host.id)])
		end)
		refresh(cx)
	elseif target.kind == "rename-host" then
		prompt(cx, "renaming host title", {
			value = snapshot.hostTitles[key(host.id)] or host.name,
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
		hostColor(cx, target, host, snapshot.hostColors[key(host.id)])
	elseif target.kind == "change-icon" and row then
		local metadata = snapshot.sessions[key(row.id)]
		sessionIcon(cx, target, host, if metadata then metadata.icon else { kind = "named", value = "terminal" })
	elseif target.kind == "reset-icon" and row then
		call(cx, "resetting session icon", function()
			data.setSessionIcon(host, row, rows, nil)
		end)
		refresh(cx)
	elseif target.kind == "new-session" then
		prompt(cx, "creating session", {
			value = "",
			placeholder = "New session on " .. (snapshot.hostTitles[key(host.id)] or host.name),
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
	end
	return true
end)

tern.on("window_start", function(cx: WindowCx)
	closeLoneSidebars(cx)
	refresh(cx)
end)
tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	refresh(cx)
end)
tern.on("pane_created", function(_ev: PaneEvent, cx: WindowCx)
	refresh(cx)
end)
tern.on("tab_created", function(_ev: TabEvent, cx: WindowCx)
	refresh(cx)
end)
tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	local paneKey = key(ev.pane)
	local tabKey = paneTabs[paneKey]
	if tabKey then
		closed[paneKey] = true
		paneTabs[paneKey] = nil
		local state = sidebars[tabKey]
		local wasCurrent = state and state.pane == ev.pane
		if state and state.pane == ev.pane then
			state.pane = nil
			state.observed = false
			state.place = false
			state.signature = nil
		end
		if not closing[paneKey] and (not state or wasCurrent) then
			if not state then
				state = { observed = false, hidden = true, place = false }
				sidebars[tabKey] = state
			end
			state.hidden = true
		end
	else
		-- A content pane closed, possibly the last one of a background tab.
		closeLoneSidebars(cx, ev.pane)
	end
	closing[paneKey] = nil
	refresh(cx)
end)
tern.on("tab_closed", function(ev: TabEvent, cx: WindowCx)
	local tabKey = key(ev.tab)
	sidebars[tabKey] = nil
	for paneKey, containing in paneTabs do
		if containing == tabKey then
			paneTabs[paneKey] = nil
			closing[paneKey] = nil
		end
	end
	refresh(cx)
end)

local function schedule()
	tern.timer(1000, function(cx: WindowCx?)
		-- Schedule first so an ordinary callback failure cannot permanently stop refreshing.
		schedule()
		if cx then
			refresh(cx)
		end
	end)
end
schedule()
-- Existing plugins do not receive window_start again on reload. Never retain the load-time cx.
tern.timer(0, function(cx: WindowCx?)
	if cx then
		-- Also clears tabs left holding only a sidebar before this version.
		closeLoneSidebars(cx)
		refresh(cx)
	end
end)
