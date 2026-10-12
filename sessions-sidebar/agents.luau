--!strict
-- Per-window omp agent markers for session rows: "question" while an agent waits for
-- input, "done" after it finishes a turn. In-memory only; window ids are never persisted.
-- Marks change only on observed edges, so visiting the agent's tab clears its mark and
-- leaving again does not bring it back until a new question or finish.

export type Counts = { question: number, done: number }
-- Session id key (string.format("%.0f", id)) -> marked agent counts; sessions without marks are absent.
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
	if active then
		entry.mark = nil
	elseif state == "exited" then
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

local function read(cx: WindowCx, activeTab: number?)
	local agents = cx.agents:list()
	local present: { [string]: boolean } = {}
	if #agents == 0 then
		table.clear(tracked)
		return
	end
	local sessionOfTab: { [string]: string } = {}
	for _, tab in cx.session:tabs() do
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
		local tab = cx.session:tab_of(agent.pane)
		local session = if tab then sessionOfTab[idKey(tab)] else nil
		entry.session = session
		if tab and session then
			local info = cx.session:pane(agent.pane)
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
local function observe(cx: WindowCx, activeTab: number?)
	local ok = pcall(read, cx, activeTab)
	if not ok then
		-- A failed read yields no marks rather than stale ones or a broken sidebar.
		table.clear(tracked)
	end
end

local function marks(): Marks
	local result: Marks = {}
	for _, entry in tracked do
		local session = entry.session
		local mark = entry.mark
		if session and mark then
			local counts = result[session]
			if not counts then
				counts = { question = 0, done = 0 }
				result[session] = counts
			end
			if mark == "question" then
				counts.question += 1
			else
				counts.done += 1
			end
		end
	end
	return result
end

return {
	observe = observe,
	marks = marks,
}
