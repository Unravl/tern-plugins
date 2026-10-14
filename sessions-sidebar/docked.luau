--!strict
-- Always expanded: every docked sidebar, in every tab, session and host of this window, keeps one
-- exact width that only the user's drag changes. Tern stores a split as a ratio of its tab's width
-- and every tab of a window has the same width, so the ratio itself is the width: a drag's ratio is
-- copied to every other sidebar unchanged. Tern exposes pane widths only as whole cells, through
-- `cx.layout:resize`, and those come from a tab's last layout pass, which lags any ratio set since.
-- Cells are therefore read only to notice the window (or its tab area) changing width, and only
-- once the same reading holds at an unchanged ratio and font size.
local data = require("./session-data")

export type Sidebar = { pane: number, tab: number }

type Entry = { pane: number, tab: number, key: string, ratio: number, share: number }
type Seen = { ratio: number, tab: number, share: number }
type Reading = { key: string, ratio: number, cols: number, font: number?, at: number }
type Probe = { r1: number, cols: number }

-- Ratios are 32-bit floats; this is ~0.1px on a 1280px window and far below one cell.
local EPSILON = 1e-4
-- Tern keeps every split ratio within these bounds.
local MIN_RATIO, MAX_RATIO = 0.1, 0.9
-- A cells reading counts once it is read again this much later at the same ratio and font.
local SETTLE_MS = 250
-- Width of the first sidebar when nothing is docked or saved: a quarter of the tab.
local DEFAULT_FRACTION = 0.25
-- A canvas counts cells inside its inset (about 16px, two cells), so its cells are not
-- proportional to its width; scaling with the inset added lands a window resize's correction in
-- one step. A wrong guess only costs another step.
local INSET_CELLS = 2

-- The sidebar's share of its tab's width. Nil until adopted from a docked sidebar or restored.
local width: number? = nil
-- The width in whole cells at `font` (the terminal font size): what a window resize must keep.
local cells: data.DockedWidth? = nil
local reading: Reading? = nil
-- Pane key -> placement as last seen or set. A ratio this plugin did not set is the user's drag.
local seen: { [string]: Seen } = {}
-- Panes this plugin just placed or docked: their ratio is Tern's default, never a width to keep.
local fresh: { [string]: boolean } = {}
-- The sidebar in view at the previous refresh: a drag just before a tab switch is left there.
local lastVisible: string? = nil

local function key(id: number): string
	return string.format("%.0f", id)
end

local function clampRatio(ratio: number): number
	return math.clamp(ratio, MIN_RATIO, MAX_RATIO)
end

-- The ratio of the split whose first side is `pane`, and the share of the tab width that split
-- spans; nil when the pane owns no left divider (floating, stacked in a vertical split, moved right).
local function split(tree: TabTree, pane: number, outer: number): (number?, number)
	local first, second = tree[1], tree[2]
	if tree.pane or not first or not second then
		return nil, outer
	end
	local ratio = tree.ratio or 0.5
	if tree.split == "down" then
		local found, share = split(first, pane, outer)
		if found then
			return found, share
		end
		return split(second, pane, outer)
	end
	if first.pane == pane then
		return ratio, outer
	end
	local found, share = split(first, pane, outer * ratio)
	if found then
		return found, share
	end
	return split(second, pane, outer * (1 - ratio))
end

local function ratioOf(cx: WindowCx, pane: number, tab: number): (number?, number)
	local layout = cx.session:layout(tab)
	if not layout or layout.zoomed then
		return nil, 1
	end
	return split(layout.root, pane, 1)
end

-- `resize` scales the ratio by (cols + cells) / cols, where cols is the pane's width in whole cells
-- from its tab's last layout pass and stays fixed for the whole call (hidden tabs and just-opened
-- panes included), so a one-cell step reveals cols and a fractional step lands any ratio exactly.
-- A step Tern clamped (the ratio bounds, a pane's minimum width) yields a fractional cols: rejected.
local function probe(cx: WindowCx, pane: number, tab: number, step: number): Probe?
	local r0 = ratioOf(cx, pane, tab)
	if not r0 or not cx.layout:resize(pane, "right", step) then
		return nil
	end
	local r1 = ratioOf(cx, pane, tab)
	if not r1 or r1 == r0 then
		return nil
	end
	local cols = step * r0 / (r1 - r0)
	local whole = math.floor(cols + 0.5)
	if whole < 1 or math.abs(cols - whole) > 0.01 then
		return nil
	end
	return { r1 = r1, cols = whole }
end

local function settle(cx: WindowCx, pane: number, tab: number, measured: Probe, target: number): number?
	cx.layout:resize(pane, "right", measured.cols * (target / measured.r1 - 1))
	return (ratioOf(cx, pane, tab))
end

local function setRatio(cx: WindowCx, pane: number, tab: number, target: number): number?
	local current = ratioOf(cx, pane, tab)
	if not current or math.abs(current - target) <= EPSILON then
		return current
	end
	local step = if target > current then 1 else -1
	for _, direction in { step, -step } do
		local measured = probe(cx, pane, tab, direction)
		if measured then
			local landed = settle(cx, pane, tab, measured, target)
			if landed and math.abs(landed - target) <= EPSILON then
				return landed
			end
		end
	end
	return (ratioOf(cx, pane, tab))
end

-- The pane's width in cells from its tab's last layout pass; the ratio is left exactly as it was.
local function measureCols(cx: WindowCx, pane: number, tab: number): number?
	local r0 = ratioOf(cx, pane, tab)
	if not r0 then
		return nil
	end
	for _, step in { 1, -1 } do
		local measured = probe(cx, pane, tab, step)
		if measured then
			settle(cx, pane, tab, measured, r0)
			return measured.cols
		end
	end
	setRatio(cx, pane, tab, r0)
	return nil
end

local function fontSize(cx: WindowCx): number?
	local ok, size = pcall(function()
		return cx.settings:get("font_size")
	end)
	return if ok and type(size) == "number" then size else nil
end

local function sameFont(saved: number?, font: number?): boolean
	-- Widths saved before 1.8 carry no font size.
	return saved == nil or saved == font
end

local function save(cols: number, font: number?)
	local fraction = width
	if cells and cells.cols == cols and cells.font == font and cells.fraction ~= nil and fraction ~= nil
		and math.abs(cells.fraction - fraction) <= EPSILON
	then
		return
	end
	cells = { cols = cols, font = font, fraction = fraction }
	data.setDockedWidth(cells)
end

-- Watches the visible sidebar's width in cells. Once a reading holds, it is saved as the width in
-- cells (after a drag or a font size change, which keeps the ratio and so the column), or, when the
-- tab area changed width, the ratio is scaled to keep those cells.
local function watchCells(cx: WindowCx, visible: Entry)
	local current = width
	if not current then
		return
	end
	local cols = measureCols(cx, visible.pane, visible.tab)
	visible.ratio = ratioOf(cx, visible.pane, visible.tab) or visible.ratio
	if not cols then
		reading = nil
		return
	end
	local font = fontSize(cx)
	local last = reading
	if not last or last.key ~= visible.key or last.cols ~= cols or last.font ~= font
		or math.abs(last.ratio - visible.ratio) > EPSILON
	then
		reading = { key = visible.key, ratio = visible.ratio, cols = cols, font = font, at = tern.now() }
		return
	end
	if tern.now() - last.at < SETTLE_MS then
		return
	end
	local target = cells
	if not target or not sameFont(target.font, font) or cols == target.cols then
		save(if target and sameFont(target.font, font) then target.cols else cols, font)
		return
	end
	-- Aim at the middle of the saved cell.
	width = clampRatio(current * (target.cols + 0.5 + INSET_CELLS) / (cols + 0.5 + INSET_CELLS))
	reading = nil
end

-- Gives every docked sidebar the one width. `sidebars` lists this plugin's sidebar panes in any
-- tab, session or host of the window; `visiblePane` is the one in the tab being shown.
local function lock(cx: WindowCx, sidebars: { Sidebar }, visiblePane: number?)
	local entries: { Entry } = {}
	local visible: Entry? = nil
	for _, sidebar in sidebars do
		local ratio, share = ratioOf(cx, sidebar.pane, sidebar.tab)
		if ratio then
			local entry = { pane = sidebar.pane, tab = sidebar.tab, key = key(sidebar.pane), ratio = ratio, share = share }
			table.insert(entries, entry)
			if sidebar.pane == visiblePane then
				visible = entry
			end
		end
	end

	-- Only a divider the user can reach moves by hand: the one in view, or the one in view at the
	-- last refresh. Its split must be unchanged; a new tab or share is a layout change, not a drag.
	local dragged: Entry? = nil
	for _, entry in entries do
		local before = seen[entry.key]
		if before and not fresh[entry.key] and before.tab == entry.tab
			and math.abs(before.share - entry.share) <= EPSILON
			and math.abs(before.ratio - entry.ratio) > EPSILON
			and (entry == visible or entry.key == lastVisible)
			and (dragged == nil or entry == visible)
		then
			dragged = entry
		end
	end

	if dragged then
		width = dragged.ratio * dragged.share
		cells = nil
		reading = nil
	elseif not width then
		-- A docked sidebar this plugin did not just place already shows the window's width (it
		-- survives reloads and restarts); the visible one wins.
		local source: Entry? = if visible and not fresh[visible.key] then visible else nil
		if not source then
			for _, entry in entries do
				if not fresh[entry.key] then
					source = entry
					break
				end
			end
		end
		local saved = data.getDockedWidth()
		if source then
			width = source.ratio * source.share
		elseif #entries > 0 then
			width = clampRatio(if saved and saved.fraction then saved.fraction else DEFAULT_FRACTION)
		else
			return
		end
		cells = if saved and sameFont(saved.font, fontSize(cx)) then saved else nil
	end

	if visible and visible.key == lastVisible and width
		and math.abs(visible.ratio - clampRatio(width / visible.share)) <= EPSILON
	then
		watchCells(cx, visible)
	elseif not visible or (reading and reading.key ~= visible.key) then
		reading = nil
	end

	local placements: { [string]: Seen } = {}
	for _, entry in entries do
		if width then
			local target = clampRatio(width / entry.share)
			if math.abs(entry.ratio - target) > EPSILON then
				entry.ratio = setRatio(cx, entry.pane, entry.tab, target) or entry.ratio
			end
		end
		fresh[entry.key] = nil
		placements[entry.key] = { ratio = entry.ratio, tab = entry.tab, share = entry.share }
	end
	seen = placements
	lastVisible = if visible then visible.key else nil
end

-- A sidebar this plugin is placing or docking now: its ratio is Tern's default until `lock` sizes it.
local function placed(pane: number)
	fresh[key(pane)] = true
end

-- Its next ratio change is not a drag (closed pane, or the sidebar about to be evened out).
local function forget(pane: number)
	local paneKey = key(pane)
	seen[paneKey] = nil
	fresh[paneKey] = nil
	if lastVisible == paneKey then
		lastVisible = nil
	end
end

-- Leaving Always expanded: sidebars float, and docking them again starts from Tern's default split.
-- The width itself stays; it applies again when they dock.
local function release()
	table.clear(seen)
	table.clear(fresh)
	lastVisible = nil
	reading = nil
end

local function locked(): boolean
	return width ~= nil
end

return {
	lock = lock,
	placed = placed,
	forget = forget,
	release = release,
	locked = locked,
}
