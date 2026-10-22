--!strict
-- The window entry. Tern gives the load hook, like every other hook call, 50 ms, and a reload that
-- runs past it leaves the plugin unloaded ("load exceeded 50 ms"); compiling the sidebar's modules
-- takes most of that on a busy machine. So loading only registers the commands and hooks, and the
-- modules compile afterwards, one per callback of its own: core.luau (canvases, refresh, docked
-- width, lifecycle) and actions.luau (clicks, menus, inputs, add-host requests) after what they
-- require, and boat-view.luau too when the Boat section has something to show (boat-ui.luau
-- follows the first refresh, see core.luau). Until then the hooks do nothing, a click on a sidebar
-- drawn before a reload is taken without effect, commands wait, and the first refresh comes right
-- after the last module.
local core: any = nil
local actions: any = nil
local ready = false
-- Commands run before the modules were in, replayed in order once they are.
local waiting: { (WindowCx) -> () } = {}

-- Dependency order, so that each step compiles one module and finds the others it needs compiled.
local STEPS: { () -> () } = {
	function()
		require("./tsp")
	end,
	function()
		require("./agents")
	end,
	function()
		require("./session-data")
	end,
	function()
		require("./docked")
	end,
	function()
		require("./drawer")
	end,
	function()
		require("./sessions")
	end,
	function()
		require("./boats")
	end,
	function()
		core = require("./core")
	end,
	function()
		actions = require("./actions")
	end,
	function()
		core.preloadBoatView()
	end,
}

local function replay()
	local run = table.remove(waiting, 1)
	if not run then
		return
	end
	tern.sleep(0):next(function(_, _, fresh: WindowCx?)
		if fresh then
			run(fresh)
		end
		replay()
	end)
end

local function step(index: number)
	tern.sleep(0):next(function(_, _, fresh: WindowCx?)
		local ok, err = pcall(STEPS[index])
		if not ok then
			-- Reported as Tern reports a window entry that fails to load; the sidebar stays off
			-- until the next reload.
			local message = tostring(err)
			tern.log.error("sessions sidebar", "cannot load: " .. message)
			if fresh then
				fresh:toast("error", "Plugin " .. tern.plugin.name .. " failed to load", string.match(message, "^[^\n]*"))
			end
			return
		end
		if index < #STEPS then
			step(index + 1)
			return
		end
		ready = true
		if fresh then
			core.start(fresh)
		end
		replay()
	end)
end
step(1)

local function command(id: string, title: string, run: (WindowCx) -> ())
	tern.command({
		id = id,
		title = title,
		run = function(cx: WindowCx)
			if ready then
				run(cx)
			else
				table.insert(waiting, run)
			end
		end,
	})
end

command("show", "Show sessions sidebar", function(cx: WindowCx)
	core.show(cx)
end)
command("hide", "Hide sessions sidebar (current tab)", function(cx: WindowCx)
	core.hide(cx)
end)
command("refresh", "Refresh sessions sidebar", function(cx: WindowCx)
	core.refresh(cx, true)
end)
command("settings", "Sessions sidebar settings", function(cx: WindowCx)
	actions.sidebarSettings(cx)
end)
-- Script requests (the boat-sandbox script behind the omp `/boat` command); see actions.luau.
command("add-host", "Add remote host from request file (scripts)", function(cx: WindowCx)
	actions.addHost(cx)
end)

-- Overrides take built-in ids only; a Tern without this command keeps the rest of the plugin.
pcall(tern.override, "equalize", function(cx: WindowCx): boolean
	return ready and core.keepWidthOnEqualize(cx)
end)

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean
	if ev.owner ~= tern.plugin.id then
		return false
	end
	if not ready then
		return true
	end
	return actions.canvasAction(ev, cx)
end)
tern.on("window_start", function(cx: WindowCx)
	if ready then
		core.windowStart(cx)
	end
end)
tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	if ready then
		core.refresh(cx)
	end
end)
tern.on("pane_created", function(_ev: PaneEvent, cx: WindowCx)
	if ready then
		core.refresh(cx)
	end
end)
tern.on("tab_created", function(_ev: TabEvent, cx: WindowCx)
	if ready then
		core.refresh(cx)
	end
end)
tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if ready then
		core.paneClosed(ev, cx)
	end
end)
tern.on("tab_closed", function(ev: TabEvent, cx: WindowCx)
	if ready then
		core.tabClosed(ev, cx)
	end
end)
