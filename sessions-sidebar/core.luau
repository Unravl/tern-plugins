--!strict
-- The window half's lifecycle: which tab shows which sidebar canvas, drawing them (refresh), the
-- docked width, the Boat section's background reads and module loads, and the lifecycle hooks and
-- commands window.luau registers. window.luau compiles this module in a callback of its own, after
-- every module it requires (see there).
local agents = require("./agents")
local docked = require("./docked")
local sessions = require("./sessions")
local data = require("./session-data")
local drawer = require("./drawer")
local boats = require("./boats")
-- The Boat section's view (boat-view.luau): compiled before the first refresh when there is a
-- section to draw, else on first use, each time in a callback of its own.
local boatViewModule: any = nil

local ABOUT = "Sessions grouped by machine, with customizable icons, working directories, observed activity, and collapsible host groups, plus a Boat sandboxes section for the boat.dev account (create, start, stop, resize, duplicate, snapshot and delete sandboxes through ~/bin/boat-sandbox). Use sidebar settings for docked, click-tab, or hover display; right-click sessions, host headings, sandboxes and snapshots for native controls; click a grip, then a new place, to reorder sessions or hosts."

type Sidebar = {
	pane: number?,
	contentFocus: number?,
	observed: boolean,
	hidden: boolean,
	place: boolean,
	signature: string?,
	-- A changed view waiting for its own callback (queueDraw).
	drawing: { pane: number, model: sessions.BuiltView }?,
}

-- These IDs and preferences belong to this window VM, not the shared KV store.
local sidebars: { [string]: Sidebar } = {}
-- Pane key -> tab key of every sidebar this window opened or has seen drawn.
local paneTabs: { [string]: string } = {}
-- Pane key -> tern.now() when this window asked Tern to close it.
local closing: { [string]: number } = {}
local closed: { [string]: boolean } = {}
local knownTargets: { [string]: sessions.Target } = {}
local failures: { [string]: string } = {}
local unavailableHosts: { [string]: string } = {}
-- Pane key -> tern.now() when a canvas without replicated state was first seen.
local unresolvedSince: { [string]: number } = {}
-- Replica lag resolves within moments. Tern's palette "Reload plugins" (and an app restart)
-- drops existing canvases' state for good; past this, such a canvas is dead and gets closed.
local UNRESOLVED_WAIT_MS = 5000
-- A sidebar this window opened or has seen drawn is not one of those, yet a new one on a remote
-- host can drop out of the replica for over five seconds (Tern 0.9.5) before it shows for good.
local KNOWN_WAIT_MS = 30000
-- A close that has not landed by then (one asked before the canvas reached the replica, or while
-- its host was going away) is asked again.
local CLOSE_WAIT_MS = 10000
local display: sessions.Display = { open = false, holdOpen = false, moving = nil }
-- Shared with actions.luau: the item lifted for pick-and-place reordering and how many native
-- inputs (prompts, pickers) of the sidebar are open, window-local like the rest of the drawer state.
export type Shared = { moving: sessions.Moving?, nativeInputs: number }
local shared: Shared = { moving = nil, nativeInputs = 0 }
-- Boat sandbox work this window started: the operation running per sandbox id ("starting",
-- "stopping", "saving", "deleting", "connecting", …), sandboxes being created, snapshots being
-- saved and snapshot operations by name. kv holds only the records and the inventory cache.
local boatOps: { [string]: string } = {}
local creatingBoats: { { title: string, detail: string } } = {}
local savingSnapshots: { { name: string, source: string, title: string } } = {}
local snapshotOps: { [string]: string } = {}

local function key(id: number): string
	return string.format("%.0f", id)
end

-- Loads boat-view.luau in a callback of its own (defined after requestRefresh).
local loadBoatView: () -> ()

-- A native prompt/picker or a lifted item keeps an overlay drawer open.
local function syncDisplay()
	local moving = shared.moving
	display.moving = moving
	display.holdOpen = shared.nativeInputs > 0 or moving ~= nil
	local inventory = boats.inventory()
	display.boats = {
		view = boatViewModule,
		needView = loadBoatView,
		byAddress = boats.addressIndex(),
		wanted = inventory ~= nil or #creatingBoats > 0,
		now = boats.epochNow(),
		state = {
			ops = boatOps,
			creating = creatingBoats,
			saving = savingSnapshots,
			snapshotOps = snapshotOps,
			inventory = inventory,
			failed = boats.inventoryFailed(),
			busy = boats.inventoryBusy(),
			usage = boats.usageView(),
			snapshotsCollapsed = data.getSnapshotsCollapsed(),
			details = data.getBoatDetails(),
			desktop = true,
		},
	}
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

-- Asks Tern to close `pane` once; a close that has not landed after CLOSE_WAIT_MS is asked again.
local function closeCanvas(cx: WindowCx, pane: number): boolean
	local paneKey = key(pane)
	local asked = closing[paneKey]
	if closed[paneKey] or (asked and tern.now() - asked < CLOSE_WAIT_MS) then
		return true
	end
	closing[paneKey] = tern.now()
	local ok = call(cx, "closing sidebar " .. paneKey, function()
		cx.layout:close(pane)
	end)
	if not ok then
		closing[paneKey] = asked
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

-- One reading of the window, shared by everything one hook call does: these lists are the costly
-- native reads (with 50 sidebars a refresh spent half of its 15-40 ms reading them again in each
-- step), and the tab of every listed pane comes with them.
type Seen = {
	canvases: { CanvasInfo },
	panes: { PaneInfo },
	tabs: { TabInfo },
	-- Pane key -> its listing.
	byPane: { [string]: PaneInfo },
}

local function look(cx: WindowCx): Seen?
	local listed, canvasRows = call(cx, "listing canvases", function()
		return cx.canvas:list()
	end)
	local read, paneRows = call(cx, "listing panes", function()
		return cx.session:panes()
	end)
	local found, tabRows = call(cx, "listing tabs", function()
		return cx.session:tabs()
	end)
	if not listed or not read or not found then
		return nil
	end
	local byPane: { [string]: PaneInfo } = {}
	for _, info in paneRows do
		byPane[key(info.pane)] = info
	end
	return { canvases = canvasRows, panes = paneRows, tabs = tabRows, byPane = byPane }
end

-- The pane's listing, else (a pane newer than the reading) Tern's answer now.
local function paneInfo(cx: WindowCx, seen: Seen, pane: number): (boolean, PaneInfo?)
	local info = seen.byPane[key(pane)]
	if info then
		return true, info
	end
	return call(cx, "reading pane metadata", function()
		return cx.session:pane(pane)
	end)
end

-- The pane's tab (nil while parked or unplaced); false when it cannot be read.
local function tabOf(cx: WindowCx, seen: Seen, pane: number): (boolean, number?)
	local info = seen.byPane[key(pane)]
	if info then
		return true, info.tab
	end
	return call(cx, "locating sidebar panes", function()
		return cx.session:tab_of(pane)
	end)
end

-- Whether the window still lists the tab.
local function tabExists(seen: Seen, tabKey: string): boolean
	for _, tab in seen.tabs do
		if key(tab.id) == tabKey then
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
local function closeLoneSidebars(cx: WindowCx, seen: Seen, gone: number?)
	local owned: { [number]: boolean } = {}
	local byTab: { [string]: { tab: number, panes: { number } } } = {}
	for _, canvas in seen.canvases do
		if canvas.owner == tern.plugin.id and not closed[key(canvas.pane)] then
			owned[canvas.pane] = true
			local found, tab = tabOf(cx, seen, canvas.pane)
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
				closeCanvas(cx, pane)
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

-- How long a canvas pane may show no replicated state before it counts as dead.
local function unresolvedWait(paneKey: string): number
	return if paneTabs[paneKey] then KNOWN_WAIT_MS else UNRESOLVED_WAIT_MS
end

local function unresolvedCanvas(cx: WindowCx, seen: Seen, tree: TabTree, canvases: { [number]: CanvasInfo }): boolean
	if tree.pane then
		local paneKey = key(tree.pane)
		if closed[paneKey] or canvases[tree.pane] then
			unresolvedSince[paneKey] = nil
			return false
		end
		local ok, info = paneInfo(cx, seen, tree.pane :: number)
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
		return tern.now() - since < unresolvedWait(paneKey)
	end
	return (tree[1] ~= nil and unresolvedCanvas(cx, seen, tree[1], canvases))
		or (tree[2] ~= nil and unresolvedCanvas(cx, seen, tree[2], canvases))
end

-- A canvas whose state Tern dropped stays as a blank pane titled "Canvas" that no plugin draws or
-- removes, and when focused it names its tab "Canvas". Close every canvas pane, in any tab or
-- session of this window, that has had no replicated state for UNRESOLVED_WAIT_MS (KNOWN_WAIT_MS
-- for this window's own sidebars). Live canvases of any owner (this plugin, other plugins, Carly)
-- are listed and never touched.
--
-- Tern 0.9.5 reports no pane_closed or tab_closed for the panes and tabs of a remote host that
-- detaches (Stop, Resize, Delete, Remove from Tern), and a host that attaches again brings back the
-- same tab and pane ids, its restored sidebar's too. This window's state for them would then act
-- on the returning panes (a canvas closed as long dead before its replica arrives, a close waited
-- for forever, a sidebar taken for hidden), so it goes once a pane is listed nowhere and its tab
-- is gone. Ordinary closes still arrive as pane_closed and tab_closed first.
local function closeDeadCanvases(cx: WindowCx, seen: Seen)
	local live: { [string]: boolean } = {}
	for _, canvas in seen.canvases do
		live[key(canvas.pane)] = true
	end
	-- Every pane of the window, and every tab holding one: a tab without panes is gone.
	local present: { [string]: boolean } = {}
	local tabs: { [string]: boolean } = {}
	local now = tern.now()
	for _, info in seen.panes do
		local paneKey = key(info.pane)
		present[paneKey] = true
		if info.tab then
			tabs[key(info.tab)] = true
		end
		if info.block == "tern.canvas" and not live[paneKey] then
			local since = unresolvedSince[paneKey]
			if not since then
				unresolvedSince[paneKey] = now
			elseif now - since >= unresolvedWait(paneKey) then
				closeCanvas(cx, info.pane)
			end
		end
	end
	for paneKey in unresolvedSince do
		if live[paneKey] or not present[paneKey] then
			unresolvedSince[paneKey] = nil
		end
	end
	for paneKey in closed do
		if not live[paneKey] and not present[paneKey] then
			closed[paneKey] = nil
		end
	end
	for paneKey, tabKey in paneTabs do
		if not live[paneKey] and not present[paneKey] and not tabs[tabKey] then
			paneTabs[paneKey] = nil
			docked.forget(tonumber(paneKey) :: number)
		end
	end
	for paneKey in closing do
		if not live[paneKey] and not present[paneKey] and not paneTabs[paneKey] then
			closing[paneKey] = nil
		end
	end
	for tabKey in sidebars do
		if not tabs[tabKey] then
			sidebars[tabKey] = nil
		end
	end
end

local function preserveFocus(cx: WindowCx, pane: number, tab: number)
	-- The native prompt/picker owns DOM focus until its fresh-context continuation runs.
	if shared.nativeInputs > 0 then
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
	-- Only initialization moves the sidebar. Its width is the docked width, set in the same refresh.
	state.place = false
	local ok, moved = call(cx, "placing sidebar on the left", function()
		return cx.layout:move(pane, target, "left", { focus = false })
	end)
	if ok and moved then
		docked.placed(pane)
	elseif ok then
		report(cx, "placing sidebar on the left", "The native layout refused the move; the sidebar was left in its original split.")
	end
	preserveFocus(cx, focus, layout.tab)
end

-- `canvases` is this refresh's canvas list; nil (right after opening a sidebar) reads it again.
local function syncDrawer(
	cx: WindowCx,
	state: Sidebar,
	pane: number,
	layout: TabLayout,
	owned: { [number]: boolean },
	content: number,
	mode: data.SidebarMode,
	canvases: { CanvasInfo }?
)
	-- Replica lag and sidebar-only tabs must not turn into a wrong-pane layout mutation.
	if not inLayout(layout, pane) or owned[content] or closed[key(content)] or not inLayout(layout, content) then
		return
	end
	if mode == "always" then
		place(cx, state, pane, layout, owned, content)
		for _, float in layout.floats do
			if float.pane == pane then
				-- drawer.sync docks it below, into Tern's default split.
				docked.placed(pane)
			end
		end
	end
	local operation = "updating sidebar display " .. key(pane)
	local ok, synced, message = pcall(drawer.sync, cx, pane, content, mode, canvases)
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

-- Always expanded: every docked sidebar this plugin owns, in any tab, session or host of the
-- window, gets the one docked width (see docked.luau). `pane` is the sidebar in the active tab.
local function lockWidths(cx: WindowCx, seen: Seen, pane: number, owned: { [number]: boolean })
	call(cx, "keeping sidebar width", function()
		local list: { docked.Sidebar } = {}
		for sidebarPane in owned do
			local paneKey = key(sidebarPane)
			if not closing[paneKey] and not closed[paneKey] then
				local _, sidebarTab = tabOf(cx, seen, sidebarPane)
				if sidebarTab then
					table.insert(list, { pane = sidebarPane, tab = sidebarTab })
				end
			end
		end
		docked.lock(cx, list, pane)
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
		-- Colors come from data.normalizeColor, so they are always "#" plus six hex digits. A
		-- sandbox row's name takes its host's color too.
		local scope = '[data-role="sessions-sidebar"] [data-host-color="' .. color .. '"] '
		table.insert(rules, scope .. '[data-role="sessions-sidebar-host-title"], ' .. scope
			.. '[data-role="sessions-sidebar-boat-name"] { color: ' .. color .. "; }")
	end
	local sheet = table.concat(rules, "\n")
	if sheet ~= colorSheet then
		tern.css("host-colors", sheet)
		colorSheet = sheet
	end
end

-- Process and network callbacks ask for a refresh through this (defined after refresh).
local requestRefresh: () -> ()

-- tern.now() when an inventory read was queued, and whether one was forced since.
local inventoryAsked: number? = nil
local inventoryForced = false

-- The boat.dev inventory (sandboxes, snapshots, usage) is read in a callback of its own, never
-- inside the hook that asks: the process spawn must not count against a refresh's 50 ms budget. A
-- refresh queues nothing unless a read is due: at most once a minute while a sidebar shows
-- (backing off after failures), sooner when `force`d by an explicit refresh, a shown sidebar or a
-- finished operation.
local function askInventory(force: boolean)
	inventoryForced = inventoryForced or force
	local asked = inventoryAsked
	if asked and tern.now() - asked < 2000 then
		return
	end
	if not inventoryForced and not boats.inventoryDue(false) then
		return
	end
	inventoryAsked = tern.now()
	tern.sleep(0):next(function(_, _, fresh: WindowCx?)
		inventoryAsked = nil
		local forced = inventoryForced
		inventoryForced = false
		if fresh then
			boats.requestInventory(fresh, forced, requestRefresh)
		end
	end)
end

-- Copying a whole view to Tern costs about as much as building it (7-13 ms with 36 sessions), so a
-- changed view is drawn in a callback of its own, never in the hook call of the refresh that built
-- it. A newer view replaces one still waiting; one whose sidebar moved on or left the replica is
-- dropped, and a later refresh draws again.
local function queueDraw(state: Sidebar, pane: number, model: sessions.BuiltView)
	local queued = state.drawing ~= nil
	state.drawing = { pane = pane, model = model }
	if queued then
		return
	end
	tern.sleep(0):next(function(_, _, fresh: WindowCx?)
		local job = state.drawing
		state.drawing = nil
		if not fresh or not job or state.pane ~= job.pane or closed[key(job.pane)] or closing[key(job.pane)] then
			return
		end
		local drawn = job.model
		call(fresh, "updating sidebar " .. key(job.pane), function()
			local title = drawer.title(fresh, job.pane)
			if title then
				fresh.canvas:set(job.pane, { title = title, about = ABOUT, view = drawn.view })
				state.signature = drawn.signature
				remember(drawn.targets)
			end
		end)
	end)
end

-- `given`: a reading this hook call already took.
local function refresh(cx: WindowCx, explicit: boolean?, given: Seen?)
	local seen = given or look(cx)
	if not seen then
		return
	end
	closeDeadCanvases(cx, seen)
	if explicit then
		askInventory(true)
	end
	local focus, tab, layout = active(cx)
	if not focus or not tab or not layout then
		if explicit then
			cx:toast("info", "No active tab for the sessions sidebar", "Open a tab first; the plugin does not create terminals.")
		end
		return
	end
	local focused = focus
	-- Every refresh (focus, tab, pane events and the 1s timer) samples agent states once.
	agents.observe(cx, tab, seen)
	local state = sidebar(tab)
	local tabKey = key(tab)
	local canvases: { [number]: CanvasInfo } = {}
	local owned: { [number]: boolean } = {}
	local current: { number } = {}
	local waitingForClose = false
	local waitingForMetadata = false
	for _, canvas in seen.canvases do
		if not closed[key(canvas.pane)] then
			canvases[canvas.pane] = canvas
			if canvas.owner == tern.plugin.id then
				owned[canvas.pane] = true
				local found, containing = tabOf(cx, seen, canvas.pane)
				if not found then
					return
				end
				if inLayout(layout, canvas.pane) then
					containing = tab
				elseif not containing then
					local read, info = paneInfo(cx, seen, canvas.pane)
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
						-- Never drawn again; a close that has not landed is asked again.
						closeCanvas(cx, canvas.pane)
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
			closeCanvas(cx, pane)
		end
		return
	end
	if state.pane and not closed[key(state.pane)] then
		owned[state.pane] = true
		-- A successful open reserves this tab immediately, before its replica arrives.
		if not state.observed and not canvases[state.pane] then
			if state.hidden then
				closeCanvas(cx, state.pane)
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
			closeCanvas(cx, pane)
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
				closeCanvas(cx, pane)
			end
		end
	elseif waitingForClose or waitingForMetadata then
		-- Settles within moments; the Boat section's schedule keeps running meanwhile.
		askInventory(false)
		return
	elseif state.pane and canvases[state.pane] then
		-- Metadata can temporarily lag a pane already observed in this tab.
		selected = state.pane
	elseif state.pane then
		-- Its canvas is not in this window's replica: a new one on a remote host drops out for a
		-- few seconds, and a host that attaches again restores its panes before their canvases.
		-- Drawing it now would fail; a later refresh draws it.
		askInventory(false)
		return
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
	local attached: { [string]: boolean } = {}
	for _, machine in hosts do
		attached[key(machine.id)] = true
		if machine.state ~= "connected" then
			unavailableHosts[key(machine.id)] = nil
		end
		if machine.current then
			host = machine
		end
	end
	-- A host id that left the window can come back, as the same machine or another one.
	for hostKey in unavailableHosts do
		if not attached[hostKey] then
			unavailableHosts[hostKey] = nil
		end
	end
	local lifted = shared.moving
	if lifted and (not findHost(hosts, lifted.host)
		or (lifted.kind == "session" and not findSession(rows, lifted.host, lifted.session)))
	then
		-- The lifted item disappeared (closed, renamed away or detached elsewhere).
		shared.moving = nil
	end
	local snapshot = data.snapshot(cx, hosts, rows, preferredContent, {
		canvases = seen.canvases,
		tabs = seen.tabs,
		panes = seen.panes,
		focused = focused,
	})
	syncColorStyles(snapshot)
	syncDisplay()
	local model = sessions.build(hosts, rows, snapshot, display, agents.marks())
	if selected then
		if state.signature ~= model.signature then
			queueDraw(state, selected, model)
		else
			-- A view still waiting is older than what is drawn.
			state.drawing = nil
		end
		syncDrawer(cx, state, selected, layout, owned, focus, snapshot.sidebarMode, seen.canvases)
		if snapshot.sidebarMode == "always" then
			lockWidths(cx, seen, selected, owned)
		else
			docked.release()
		end
		-- A shown sidebar keeps the Boat section current (at most once a minute).
		askInventory(false)
		return
	end
	if not host or host.state ~= "connected" or unresolvedCanvas(cx, seen, layout.root, canvases) then
		return
	end
	for _, float in layout.floats do
		if unresolvedCanvas(cx, seen, { pane = float.pane }, canvases) then
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
			lockWidths(cx, seen, pane, owned)
		end
	end
	askInventory(false)
end

-- tern.now() when a deferred refresh was queued. A queue older than two seconds is assumed lost
-- (Tern can disable a plugin's timer hook) and queued again.
local refreshQueued: number? = nil

-- Coalesces the refreshes that process, host and timer callbacks ask for into one timer tick, so a
-- slow refresh never counts against the callback that asked.
requestRefresh = function()
	local queued = refreshQueued
	if queued and tern.now() - queued < 2000 then
		return
	end
	refreshQueued = tern.now()
	tern.timer(0, function(fresh: WindowCx?)
		refreshQueued = nil
		if fresh then
			refresh(fresh)
		end
	end)
end

-- What actions.luau plugs in: compiling boat-ui.luau (its menus and forms) with the window's input
-- helpers, right after boat-view.luau, so the first click there does not compile it either.
local hooks: { loadBoatUi: (() -> ())? } = {}
local viewQueued = false

local function loadBoatUiLater()
	tern.sleep(0):next(function()
		local load = hooks.loadBoatUi
		if load then
			local ok, err = pcall(load)
			if not ok then
				tern.log.error("boat sandbox", "cannot load boat-ui.luau: " .. tostring(err))
			end
		end
	end)
end

-- Whether the Boat section has anything to show: a listing (also one cached by another window or
-- before a reload), a tracked sandbox or one being created.
local function boatsWanted(): boolean
	return boats.inventory() ~= nil or #creatingBoats > 0 or next(data.getBoats()) ~= nil
end

-- boat-view.luau compiles in a callback of its own and the next refresh draws the Boat section.
loadBoatView = function()
	if boatViewModule or viewQueued then
		return
	end
	viewQueued = true
	tern.sleep(0):next(function()
		local ok, loaded = pcall(function()
			return require("./boat-view")
		end)
		if not ok then
			tern.log.error("boat sandbox", "cannot load boat-view.luau: " .. tostring(loaded))
			return
		end
		boatViewModule = loaded
		requestRefresh()
		loadBoatUiLater()
	end)
end

-- A step of window.luau's loading: compiles boat-view.luau before the first refresh when the
-- section has something to show, so that refresh draws it (sessions.build leaves boat sandbox
-- hosts out until the module is loaded).
-- If it fails to load, only the Boat section goes missing (as on first use, loadBoatView); the
-- rest of the sidebar still loads.
local function preloadBoatView()
	if boatViewModule or not boatsWanted() then
		return
	end
	local ok, loaded = pcall(function()
		return require("./boat-view")
	end)
	if ok then
		boatViewModule = loaded
	else
		viewQueued = true
		tern.log.error("boat sandbox", "cannot load boat-view.luau: " .. tostring(loaded))
	end
end

-- Disconnects a remote host, which also makes Tern forget it. Its tabs go with it, and so do their
-- sidebars: those are marked as closing, so a close reported for them does not count as hidden by
-- the user (Tern 0.9.5 reports none; closeDeadCanvases forgets them).
local function disconnectHost(cx: WindowCx, host: ManagedHost): boolean
	local marked: { string } = {}
	for _, pane in host.panes do
		local paneKey = key(pane)
		if paneTabs[paneKey] and not closing[paneKey] then
			closing[paneKey] = tern.now()
			table.insert(marked, paneKey)
		end
	end
	local id = host.id
	local disconnected = call(cx, "disconnecting host", function()
		cx.hosts:disconnect(id)
	end)
	if not disconnected then
		for _, paneKey in marked do
			closing[paneKey] = nil
		end
	end
	return disconnected
end

-- Disconnects the host attached at `address`, if any (Stop, Delete, Resize, Remove from Tern).
local function disconnectAddress(cx: WindowCx, address: string?)
	if not address then
		return
	end
	local listed, hosts = pcall(function()
		return cx.hosts:list()
	end)
	local host = if listed then boats.hostAt(hosts, address) else nil
	if host then
		disconnectHost(cx, host)
	end
end

-- ---------- commands and lifecycle hooks (window.luau registers them) ----------

local function show(cx: WindowCx)
	local _, tab = active(cx)
	if tab then
		sidebar(tab).hidden = false
	end
	refresh(cx, true)
end

local function hide(cx: WindowCx)
	local _, tab = active(cx)
	if tab then
		sidebar(tab).hidden = true
		refresh(cx)
	end
end

-- Even out splits (⌃⌘=) gives the docked sidebar an equal share too. Tern evens the tab as usual;
-- the sidebar goes straight back to the docked width instead of that counting as a drag.
local function keepWidthOnEqualize(cx: WindowCx): boolean
	if data.getSidebarMode() ~= "always" or not docked.locked() then
		return false
	end
	local _, tab = active(cx)
	local state = if tab then sidebars[key(tab)] else nil
	if state and state.pane then
		docked.forget(state.pane)
		tern.timer(0, function(fresh: WindowCx?)
			if fresh then
				refresh(fresh)
			end
		end)
	end
	return false
end

local function windowStart(cx: WindowCx)
	local seen = look(cx)
	if seen then
		closeLoneSidebars(cx, seen)
	end
	refresh(cx, nil, seen)
end

local function paneClosed(ev: PaneEvent, cx: WindowCx)
	local seen = look(cx)
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
			-- An unreadable window counts as still listing the tab.
			if not seen or tabExists(seen, tabKey) then
				if not state then
					state = { observed = false, hidden = true, place = false }
					sidebars[tabKey] = state
				end
				state.hidden = true
			else
				-- Its tab went with it (for example its host was disconnected, as Stop and Delete
				-- do): not a close by the user. The tab id may come back for another host.
				sidebars[tabKey] = nil
			end
		end
	elseif seen then
		-- A content pane closed, possibly the last one of a background tab.
		closeLoneSidebars(cx, seen, ev.pane)
	end
	closing[paneKey] = nil
	unresolvedSince[paneKey] = nil
	docked.forget(ev.pane)
	refresh(cx, nil, seen)
end

local function tabClosed(ev: TabEvent, cx: WindowCx)
	local tabKey = key(ev.tab)
	sidebars[tabKey] = nil
	for paneKey, containing in paneTabs do
		if containing == tabKey then
			paneTabs[paneKey] = nil
			closing[paneKey] = nil
		end
	end
	refresh(cx)
end

local function schedule()
	tern.timer(1000, function(cx: WindowCx?)
		-- Schedule first so an ordinary callback failure cannot permanently stop refreshing.
		schedule()
		if cx then
			refresh(cx)
		end
	end)
end

-- The first refresh, once window.luau has every module: existing plugins do not receive
-- window_start again on reload. Also clears tabs left holding only a sidebar before this version.
local function start(cx: WindowCx)
	schedule()
	windowStart(cx)
	if boatViewModule then
		loadBoatUiLater()
	end
end

return {
	shared = shared,
	display = display,
	knownTargets = knownTargets,
	hooks = hooks,
	boatOps = boatOps,
	creatingBoats = creatingBoats,
	savingSnapshots = savingSnapshots,
	snapshotOps = snapshotOps,
	key = key,
	call = call,
	report = report,
	active = active,
	sidebar = sidebar,
	findHost = findHost,
	findSession = findSession,
	preferredContent = preferredContent,
	syncDisplay = syncDisplay,
	refresh = refresh,
	requestRefresh = requestRefresh,
	askInventory = askInventory,
	disconnectHost = disconnectHost,
	disconnectAddress = disconnectAddress,
	preloadBoatView = preloadBoatView,
	start = start,
	show = show,
	hide = hide,
	keepWidthOnEqualize = keepWidthOnEqualize,
	windowStart = windowStart,
	paneClosed = paneClosed,
	tabClosed = tabClosed,
}
