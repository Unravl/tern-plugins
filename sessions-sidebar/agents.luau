--!strict
-- Per-window omp agent status for session rows: "question" while an agent waits for
-- input, "working" while it works, "done" after it finishes a turn. In-memory only;
-- window ids are never persisted. Question and done marks change only on observed edges,
-- so visiting the agent's tab clears its mark and leaving again does not bring it back
-- until a new question or finish. Working is live: it shows even in the active tab, and
-- new work replaces an earlier done mark.

export type Counts = { question: number, working: number, done: number }
-- Session id key (string.format("%.0f", id)) -> agent counts per display state; sessions
-- whose counts are all zero are absent.
export type Marks = { [string]: Counts }

type State = "idle" | "working" | "waiting_input" | "exited"
type Mark = "question" | "done"

type Tracked = {
	-- Last observation; nil until the agent has been observed in a resolvable tab.
	seen: { state: State, alert: boolean }?,
	mark: Mark?,
	-- Session id key of the last resolved placement; nil while unresolved (e.g. parked).
	session: string?,
}

-- Pane id key -> tracked agent.
local tracked: { [string]: Tracked } = {}

local function idKey(id: number): string
	-- Remote IDs must not pass through a 32-bit integer format or bit operation.
	return string.format("%.0f", id)
end

local function apply(entry: Tracked, state: State, alert: boolean, active: boolean)
	local seen = entry.seen
	if active or state == "exited" or state == "working" then
		-- Working supersedes an earlier finish; the turn now running brings its own tick.
		entry.mark = nil
	else
		if entry.mark == "question" and state ~= "waiting_input" then
			-- Answered or cancelled elsewhere; it may also have finished since.
			entry.mark = nil
		end
		if state == "waiting_input" and (not seen or seen.state ~= "waiting_input") then
			entry.mark = "question"
		elseif state == "idle"
			and ((seen and seen.state == "working") or (alert and (not seen or not seen.alert)))
		then
			-- Tern's unseen alert rises when a turn completes; it also covers turns shorter
			-- than the refresh interval and the first observation after a plugin reload.
			entry.mark = "done"
		end
	end
	entry.seen = { state = state, alert = alert }
end

-- What a refresh read of the window already (core.luau's Seen): its tabs, and pane key -> listing.
export type Window = { tabs: { TabInfo }, byPane: { [string]: PaneInfo } }

local function read(cx: WindowCx, activeTab: number?, window: Window?)
	local agents = cx.agents:list()
	local present: { [string]: boolean } = {}
	if #agents == 0 then
		table.clear(tracked)
		return
	end
	local sessionOfTab: { [string]: string } = {}
	for _, tab in if window then window.tabs else cx.session:tabs() do
		sessionOfTab[idKey(tab.id)] = idKey(tab.session)
	end
	for _, agent in agents do
		local paneKey = idKey(agent.pane)
		present[paneKey] = true
		local entry = tracked[paneKey]
		if not entry then
			entry = {}
			tracked[paneKey] = entry
		end
		-- The window's pane listing has the tab and alert of every agent it lists.
		local listed = if window then window.byPane[paneKey] else nil
		local tab = if listed then listed.tab else cx.session:tab_of(agent.pane)
		local session = if tab then sessionOfTab[idKey(tab)] else nil
		entry.session = session
		if tab and session then
			local info = listed or cx.session:pane(agent.pane)
			apply(entry, agent.state, info ~= nil and info.alert == true, tab == activeTab)
		end
	end
	for paneKey in tracked do
		if not present[paneKey] then
			tracked[paneKey] = nil
		end
	end
end

-- Observes every agent in the window; call once per refresh with the active tab.
local function observe(cx: WindowCx, activeTab: number?, window: Window?)
	local ok = pcall(read, cx, activeTab, window)
	if not ok then
		-- A failed read yields no marks rather than stale ones or a broken sidebar.
		table.clear(tracked)
	end
end

-- Each agent counts once, by precedence: question > working > done.
local function marks(): Marks
	local result: Marks = {}
	for _, entry in tracked do
		local session = entry.session
		local seen = entry.seen
		if not session or not seen then
			continue
		end
		local mark = entry.mark
		local working = seen.state == "working"
		if not mark and not working then
			continue
		end
		local counts = result[session]
		if not counts then
			counts = { question = 0, working = 0, done = 0 }
			result[session] = counts
		end
		if mark == "question" then
			counts.question += 1
		elseif working then
			counts.working += 1
		else
			counts.done += 1
		end
	end
	return result
end

return {
	observe = observe,
	marks = marks,
}
