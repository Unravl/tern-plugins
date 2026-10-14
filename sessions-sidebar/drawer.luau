--!strict

type SidebarMode = "always" | "click" | "hover"

local TITLE_PREFIX = "Sessions Sidebar [ss-"
local assignedTitles: { [number]: string } = {}
local pendingTitles: { [number]: string } = {}
local styledTitles: { [number]: string } = {}
local styledWidth = 0

-- The drawer's 320px root is canvas px, and Tern scales a canvas by font_size over its
-- default (15 against 13 makes it 369px). This frame is window px, so it must scale too,
-- or it clips the gear, + buttons and activity strips.
local FRAME_WIDTH = 320

local function frameWidth(cx: WindowCx): number
	local ok, size, default = pcall(function()
		return cx.settings:get("font_size"), cx.settings:describe("font_size").default
	end)
	if not ok or type(size) ~= "number" or type(default) ~= "number" or default <= 0 then
		return FRAME_WIDTH
	end
	return math.ceil(FRAME_WIDTH * size / default)
end

-- Tern 0.7.3 exposes the outer PiP's title through this aria-label prefix,
-- not a pane/owner attribute. A random owned title scopes every native override.
-- The actual hover/click states stay inside the canvas; its frame changes only with font_size.
local FRAME_CSS = [[
@ {
 top: 0 !important;
 left: 0 !important;
 width: min(WIDTHpx, 100%) !important;
 height: 100% !important;
 transform: none !important;
 scale: 1 !important;
 rotate: none !important;
 z-index: 100 !important;
 overflow: visible !important;
 background: transparent !important;
 border-radius: 0 !important;
 box-shadow: none !important;
 pointer-events: none !important;
 animation: none !important;
 transition: none !important;
}
@::after { display: none !important; }
@ > .tn-head,
@ > .tn-pip-grip { display: none !important; }
@ .tn-body,
@ .tv,
@ .tv-cover {
 height: 100% !important;
 width: 100% !important;
 overflow: visible !important;
 background: transparent !important;
 pointer-events: none !important;
}
@ .tv-cover {
 position: absolute !important;
 inset: 0 !important;
 padding: 0 !important;
}
@ .sf-main {
 display: block !important;
 position: absolute !important;
 inset: 0 !important;
 height: 100% !important;
 width: 100% !important;
 padding: 0 !important;
 margin: 0 !important;
 overflow: visible !important;
 pointer-events: none !important;
}
]]

local function marked(title: string): boolean
	local nonce = title:match("^Sessions Sidebar %[ss%-([0-9a-f]+)%]$")
	return nonce ~= nil and #nonce == 32
end

local function newTitle(): string
	-- Eight independent 16-bit draws: ASCII only, no host/pane identity on disk.
	return TITLE_PREFIX .. string.format(
		"%04x%04x%04x%04x%04x%04x%04x%04x",
		math.random(0, 65535), math.random(0, 65535),
		math.random(0, 65535), math.random(0, 65535),
		math.random(0, 65535), math.random(0, 65535),
		math.random(0, 65535), math.random(0, 65535)
	) .. "]"
end

local function chooseTitle(canvas: CanvasInfo): string
	if marked(canvas.title) then
		assignedTitles[canvas.pane] = canvas.title
		pendingTitles[canvas.pane] = nil
		return canvas.title
	end
	local title = assignedTitles[canvas.pane]
	if not title then
		title = newTitle()
		assignedTitles[canvas.pane] = title
	end
	return title
end

local function title(cx: WindowCx, pane: number): string
	-- list() omits views; adopting a title does not copy the whole session tree.
	for _, canvas in cx.canvas:list() do
		if canvas.pane == pane then
			if canvas.owner ~= tern.plugin.id then
				error("The sidebar canvas is not owned by this plugin")
			end
			return chooseTitle(canvas)
		end
	end
	error("The sidebar canvas is not available in this window")
end

local function syncStyles(canvases: { CanvasInfo }, width: number)
	local current: { [number]: string } = {}
	local present: { [number]: boolean } = {}
	local changed = width ~= styledWidth
	for _, canvas in canvases do
		if canvas.owner == tern.plugin.id then
			present[canvas.pane] = true
			if marked(canvas.title) then
				current[canvas.pane] = canvas.title
				if styledTitles[canvas.pane] ~= canvas.title then
					changed = true
				end
			end
		end
	end
	for pane, oldTitle in styledTitles do
		if current[pane] ~= oldTitle then
			changed = true
		end
	end
	for pane in assignedTitles do
		if not present[pane] then
			assignedTitles[pane] = nil
			pendingTitles[pane] = nil
		end
	end
	if not changed then
		return
	end

	local titles: { string } = {}
	for _, value in current do
		table.insert(titles, value)
	end
	table.sort(titles)
	local sheets: { string } = {}
	for _, value in titles do
		local selector = '.tn-stage > .tn-pane.pip[aria-label^="' .. value .. ', "]'
		local sheet = FRAME_CSS:gsub("WIDTH", tostring(width)):gsub("@", selector)
		table.insert(sheets, sheet)
	end
	tern.css("drawer-panels", table.concat(sheets, "\n"))
	styledTitles = current
	styledWidth = width
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

-- Match the window controller's horizontal tree order; down-splits share x.
local function leftmost(tree: TabTree, owned: { [number]: boolean }, x: number, width: number): (number?, number)
	if tree.pane then
		return if owned[tree.pane] then nil else tree.pane, if owned[tree.pane] then math.huge else x
	end
	local leftWidth, rightX, rightWidth = width, x, width
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

local function sync(cx: WindowCx, pane: number, content: number, mode: SidebarMode): (boolean, string?)
	local tab = cx.session:tab_of(pane)
	local contentTab = cx.session:tab_of(content)
	local focus = cx.session:focused()
	if not tab or contentTab ~= tab or not focus or cx.session:tab_of(focus) ~= tab then
		return false, nil
	end
	local layout = cx.session:layout(tab)
	if not layout or pane == content or not inLayout(layout, pane) or not inLayout(layout, content) then
		return false, nil
	end

	local canvases = cx.canvas:list()
	local sidebar: CanvasInfo? = nil
	local owned: { [number]: boolean } = {}
	for _, canvas in canvases do
		if canvas.owner == tern.plugin.id then
			owned[canvas.pane] = true
		end
		if canvas.pane == pane then
			sidebar = canvas
		end
	end
	if not sidebar then
		return false, nil
	end
	if sidebar.owner ~= tern.plugin.id or owned[content] then
		return false, "Sidebar transport requires its owned canvas and a non-sidebar content pane"
	end

	local desiredTitle = chooseTitle(sidebar)
	if sidebar.title ~= desiredTitle then
		if pendingTitles[pane] ~= desiredTitle then
			cx.canvas:set(pane, { title = desiredTitle })
			pendingTitles[pane] = desiredTitle
		end
		-- Let the replica mount the scoped title before creating a native PiP.
		return false, nil
	end
	syncStyles(canvases, frameWidth(cx))

	local floating = false
	for _, float in layout.floats do
		if float.pane == pane then
			floating = true
			break
		end
	end
	if (mode == "always" and not floating) or (mode ~= "always" and floating) then
		return true, nil
	end

	local target = leftmost(layout.root, owned, 0, 1)
	if not target then
		return false, "Sidebar transport needs a non-sidebar tiled pane in the active tab"
	end
	if mode == "always" then
		-- Docking restores Tern's default split; the window controller sizes it in the same call.
		return cx.layout:dock(pane, target, "left", { focus = false })
	end
	return cx.layout:float(pane, target, "tl", { focus = false })
end

return {
	newTitle = newTitle,
	title = title,
	sync = sync,
}
