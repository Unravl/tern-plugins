--!strict
-- What the Boat section's buttons, menus and forms do. New sandbox, Duplicate and Defaults are a
-- summary picker acting as a form: choosing a field opens its own picker or prompt and comes back
-- to the summary with the value updated. Every boat.dev change runs through ~/bin/boat-sandbox
-- (boats.luau) in the background: the section shows it in progress and a toast says how it ended,
-- with the script's own error text. Loaded on first use (see core.luau).
local boats = require("./boats")
local data = require("./session-data")

export type Confirm = {
	question: string,
	yes: string,
	detail: string,
	icon: string,
	cancelFirst: boolean?,
	-- The Cancel row's detail (default: leave the sandbox as it is).
	keep: string?,
}
export type Creating = { title: string, detail: string }
export type Saving = { name: string, source: string, title: string }

-- What actions.luau lends this module (see its boatEnv).
export type Env = {
	-- Native inputs that hold the drawer open; `dismissed` runs when the user backs out.
	pick: (cx: WindowCx, operation: string, opts: PickOptions, apply: (PickItem, WindowCx) -> (), dismissed: ((WindowCx) -> ())?) -> (),
	prompt: (cx: WindowCx, operation: string, opts: PromptOptions, apply: (string, WindowCx) -> (), dismissed: ((WindowCx) -> ())?) -> (),
	confirm: (cx: WindowCx, operation: string, ask: Confirm, apply: (WindowCx) -> ()) -> (),
	-- Keeps the drawer held open between two inputs; every hold is released once.
	hold: () -> (),
	release: () -> (),
	refresh: (cx: WindowCx) -> (),
	requestRefresh: () -> (),
	-- After an operation: the inventory read again soon and the sidebar drawn again.
	settled: (cx: WindowCx?) -> (),
	-- Disconnects the host attached at `address`, closing its tabs' sidebars quietly.
	disconnect: (cx: WindowCx, address: string?) -> (),
	ops: { [string]: string },
	creating: { Creating },
	saving: { Saving },
	snapshotOps: { [string]: string },
}

type Form = {
	name: string?,
	snapshot: string,
	type: string,
	hours: number?,
	environment: string?,
	secrets: boolean,
}
type ForkForm = { source: string, sourceTitle: string, name: string?, type: string, hours: number? }
type Info = {
	id: string,
	title: string,
	-- The sidebar's name for it (the tracked record's), else boat's own label.
	name: string,
	record: data.Boat?,
	sandbox: boats.Sandbox?,
	host: ManagedHost?,
	stopped: boolean,
	running: boolean,
}

-- A run is killed after this long: above the script's own worst case for each mode.
local CREATE_TIMEOUT_MS = 25 * 60000
local RESUME_TIMEOUT_MS = 30 * 60000
local RESIZE_TIMEOUT_MS = 45 * 60000
local STOP_TIMEOUT_MS = 20 * 60000
local DELETE_TIMEOUT_MS = 6 * 60000
local EXTEND_TIMEOUT_MS = 3 * 60000
local SNAPSHOT_TIMEOUT_MS = 30 * 60000
local SNAPSHOT_RM_TIMEOUT_MS = 5 * 60000
local DEFAULTS_TIMEOUT_MS = 60000
local DESKTOP_TIMEOUT_MS = 2 * 60000
local SSH_TIMEOUT_MS = 2 * 60000

local AUTO_STOPS: { { hours: number, label: string, detail: string? } } = {
	{ hours = 1, label = "1 hour", detail = "Boat's default" },
	{ hours = 4, label = "4 hours" },
	{ hours = 8, label = "8 hours" },
	{ hours = 24, label = "24 hours" },
	{ hours = 72, label = "3 days" },
	{ hours = 168, label = "7 days" },
	{ hours = 720, label = "30 days", detail = "The longest boat.dev allows" },
}

local env: Env = nil :: any

local function init(lent: Env)
	env = lent
end

-- Runs `fn` in a callback of its own, so one picker's answer and the next picker never share a
-- hook's 50 ms budget; the drawer stays held open in between.
local function after(fn: (WindowCx) -> ())
	env.hold()
	tern.sleep(0):next(function(_, _, fresh: WindowCx?)
		if fresh then
			local ok, err = pcall(fn, fresh)
			if not ok then
				tern.log.error("boat sandbox", tostring(err))
				fresh:toast("error", "Sessions sidebar: boat sandboxes", tostring(err))
			end
		end
		env.release()
	end)
end

local function recordState(state: string?): ("running" | "stopped")?
	if state == "archived" or state == "stopped" then
		return "stopped"
	elseif state == nil or state == "deleted" then
		return nil
	end
	return "running"
end

-- Re-reads a record (another window may have changed it) and saves `change`'s edit to it.
local function updateBoat(id: string, change: (data.Boat) -> ()): data.Boat?
	local boat = data.getBoat(id)
	if not boat then
		return nil
	end
	change(boat)
	local saved, err = pcall(data.saveBoat, boat)
	if not saved then
		tern.log.error("boat sandbox", "cannot save " .. id .. ": " .. tostring(err))
	end
	return boat
end

local function hostsOf(cx: WindowCx): { ManagedHost }
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	return if ok then hosts else {}
end

-- Everything known about sandbox `id` now: its record, its listing and its host here.
local function infoOf(cx: WindowCx, id: string): Info?
	local record = data.getBoat(id)
	local inventory = boats.inventory()
	local sandbox = if inventory then inventory.byId[id] else nil
	if not record and not sandbox then
		return nil
	end
	local hosts = hostsOf(cx)
	local host: ManagedHost? = nil
	if record and record.address then
		host = boats.hostAt(hosts, record.address)
	end
	if not host and sandbox and sandbox.address then
		host = boats.hostAt(hosts, sandbox.address)
	end
	local name = if record then record.name else (sandbox :: boats.Sandbox).name
	local title: string
	if record then
		title = data.boatTitle(record)
	else
		local listed = sandbox :: boats.Sandbox
		title = data.boatTitle({
			id = id,
			name = listed.name,
			title = listed.name,
			address = if host then host.address else listed.address,
			state = "running",
		})
	end
	local stopped = if sandbox then sandbox.state == "stopped" else (record ~= nil and record.state == "stopped")
	return {
		id = id,
		title = title,
		name = name,
		record = record,
		sandbox = sandbox,
		host = host,
		stopped = stopped,
		running = if sandbox then sandbox.state == "running" else not stopped,
	}
end

local function busy(cx: WindowCx, info: Info): boolean
	local op = env.ops[info.id]
	if op then
		cx:toast("info", info.title .. " is " .. op, "Wait until it finishes.")
		return true
	end
	return false
end

local function defaultsOr(inventory: boats.Inventory?): boats.Defaults
	return if inventory then inventory.defaults else table.clone(boats.BUILTIN_DEFAULTS)
end

-- `fn` gets the script's resolved defaults: from the inventory, else from `--defaults`.
local function withDefaults(cx: WindowCx, fn: (WindowCx, boats.Defaults) -> ())
	local inventory = boats.inventory()
	if inventory then
		fn(cx, table.clone(inventory.defaults))
		return
	end
	boats.script(cx, { "--defaults" }, DEFAULTS_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
		if not fresh then
			return
		end
		local value = result.value.defaults
		local defaults = table.clone(boats.BUILTIN_DEFAULTS)
		if type(value) == "table" then
			defaults.snapshot = if type(value.snapshot) == "string" then value.snapshot else defaults.snapshot
			defaults.type = if boats.sizeOf(value.type) then value.type else defaults.type
			defaults.hours = if type(value.hours) == "number" then value.hours else nil
			defaults.environment = if type(value.environment) == "string" then value.environment else nil
			defaults.secrets = value.secrets ~= false
		end
		fn(fresh, defaults)
	end)
end

-- ---------- field pickers ----------

-- Why boat.dev would refuse size `id` on this plan, if it would.
local function sizeRefusal(id: string): string?
	local size = boats.sizeOf(id)
	local inventory = boats.inventory()
	local limits = if inventory then inventory.limits else nil
	if not size or not limits then
		return nil
	end
	local listed = limits.types[id]
	if listed and listed.available == false then
		return id .. " " .. (listed.reason or "is not available on your plan")
	end
	local plan = limits.plan
	if size.plan and plan and plan < size.plan then
		return string.format("%s needs the $%d+ plan; yours is $%d a month", id, size.plan, plan)
	end
	return nil
end

local function sizeItems(current: string?): { PickItem }
	local items: { PickItem } = {}
	for _, size in boats.SIZES do
		local detail = boats.sizeDetail(size)
		if size.plan then
			local refusal = sizeRefusal(size.id)
			detail ..= " · needs the $" .. tostring(size.plan) .. "+ plan" .. (if refusal then " (not yours)" else "")
		end
		table.insert(items, {
			label = size.id,
			detail = detail,
			icon = "cpu",
			current = size.id == current,
			size = size.id,
		})
	end
	return items
end

-- A size picker; `chosen` gets an allowed size (refused ones toast and change nothing).
local function pickSize(
	cx: WindowCx,
	placeholder: string,
	current: string?,
	chosen: (string, WindowCx) -> (),
	dismissed: ((WindowCx) -> ())?
)
	env.pick(cx, "choosing a sandbox size", {
		items = sizeItems(current),
		placeholder = placeholder,
		icon = "cpu",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		local size = item.size :: string
		local refusal = sizeRefusal(size)
		if refusal then
			fresh:toast("error", "Cannot use " .. size, refusal .. ".")
			if dismissed then
				after(dismissed)
			end
			return
		end
		chosen(size, fresh)
	end, dismissed)
end

local function hoursLabel(hours: number?): string
	if not hours then
		return "Never"
	end
	for _, choice in AUTO_STOPS do
		if choice.hours == hours then
			return choice.label
		end
	end
	return boats.autoStopLabel(hours)
end

-- 1–720 whole hours from a prompt; `chosen` gets them.
local function customHours(cx: WindowCx, current: number?, chosen: (number, WindowCx) -> (), dismissed: ((WindowCx) -> ())?)
	env.prompt(cx, "choosing auto-stop hours", {
		value = if current then tostring(current) else "",
		placeholder = "Auto-stop after how many hours? (1–720)",
		icon = "timer",
		action = "set",
	}, function(value: string, fresh: WindowCx)
		local hours = tonumber((string.match(value, "^%s*(.-)%s*$")))
		if not hours or hours < 1 or hours > 720 or hours ~= math.floor(hours) then
			fresh:toast("error", "Enter whole hours from 1 to 720", "30 days is the longest boat.dev allows; choose Never for no auto-stop.")
			if dismissed then
				after(dismissed)
			end
			return
		end
		chosen(hours, fresh)
	end, dismissed)
end

-- An auto-stop picker for a new sandbox: 1 h … 30 days, Never, Custom…; `chosen` gets hours or nil.
local function pickAutoStop(
	cx: WindowCx,
	placeholder: string,
	current: number?,
	chosen: (number?, WindowCx) -> (),
	dismissed: ((WindowCx) -> ())?
)
	local items: { PickItem } = {}
	local listed = current == nil
	for _, choice in AUTO_STOPS do
		listed = listed or choice.hours == current
		table.insert(items, {
			label = choice.label,
			detail = choice.detail,
			icon = "timer",
			current = current == choice.hours,
			hours = choice.hours,
		})
	end
	table.insert(items, {
		label = "Never",
		detail = "No auto-stop: it runs (and bills) until you stop it",
		icon = "timer",
		current = current == nil,
		never = true,
	})
	table.insert(items, {
		label = "Custom…",
		detail = if listed then "Any whole number of hours from 1 to 720" else tostring(current) .. " hours",
		icon = "pen",
		current = not listed,
		custom = true,
	})
	env.pick(cx, "choosing auto-stop", {
		items = items,
		placeholder = placeholder,
		icon = "timer",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		if item.custom then
			after(function(next: WindowCx)
				customHours(next, current, chosen, dismissed)
			end)
		elseif item.never then
			chosen(nil, fresh)
		else
			chosen(item.hours :: number, fresh)
		end
	end, dismissed)
end

local function pickSnapshot(cx: WindowCx, current: string, chosen: (string, WindowCx) -> (), dismissed: ((WindowCx) -> ())?)
	local inventory = boats.inventory()
	local snaps = if inventory then inventory.snapshots else nil
	local items: { PickItem } = {}
	local titles: { [string]: string } = {}
	if inventory then
		for _, sandbox in inventory.sandboxes do
			titles[sandbox.id] = sandbox.name
		end
		for id, record in data.getBoats() do
			titles[id] = record.title
		end
	end
	local listed = false
	for _, snap in snaps or {} do
		listed = listed or snap.name == current
		local parts: { string } = {}
		local size = boats.bytes(snap.sizeBytes)
		if size then
			table.insert(parts, size)
		end
		local date = boats.shortDate(snap.createdAt)
		if date then
			table.insert(parts, date)
		end
		if snap.source then
			table.insert(parts, "from " .. (titles[snap.source] or snap.source))
		end
		if snap.status and snap.status ~= "ready" then
			table.insert(parts, snap.status)
		end
		table.insert(items, {
			label = snap.name,
			detail = table.concat(parts, " · "),
			icon = "layers",
			current = snap.name == current,
			snapshot = snap.name,
		})
	end
	if not listed then
		table.insert(items, 1, {
			label = current,
			detail = if snaps then "Not in your named snapshots" else "Your snapshots could not be listed",
			icon = "layers",
			current = true,
			snapshot = current,
		})
	end
	env.pick(cx, "choosing a snapshot", {
		items = items,
		placeholder = "Snapshot to start from",
		icon = "layers",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		chosen(item.snapshot :: string, fresh)
	end, dismissed)
end

local function environmentLabel(name: string?): string
	if name then
		return name
	end
	local inventory = boats.inventory()
	for _, environment in (if inventory then inventory.environments else nil) or {} do
		if environment.isDefault then
			return "Account default (" .. environment.name .. ")"
		end
	end
	return "Account default"
end

local function pickEnvironment(cx: WindowCx, current: string?, chosen: (string?, WindowCx) -> (), dismissed: ((WindowCx) -> ())?)
	local inventory = boats.inventory()
	local items: { PickItem } = {
		{
			label = environmentLabel(nil),
			detail = "Whichever environment is your default when the sandbox starts",
			icon = "box",
			current = current == nil,
			account = true,
		},
	}
	for _, environment in (if inventory then inventory.environments else nil) or {} do
		table.insert(items, {
			label = environment.name,
			detail = if environment.isDefault then "Your default environment" else "Named environment",
			icon = "box",
			current = current == environment.name,
			environment = environment.name,
		})
	end
	env.pick(cx, "choosing an environment", {
		items = items,
		placeholder = "Environment (repos, secrets, credentials)",
		icon = "box",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		chosen(if item.account then nil else item.environment, fresh)
	end, dismissed)
end

local function pickSecrets(cx: WindowCx, current: boolean, chosen: (boolean, WindowCx) -> (), dismissed: ((WindowCx) -> ())?)
	env.pick(cx, "choosing secrets", {
		items = {
			{
				label = "Pass my secrets",
				detail = "Your account's stored secrets and logins, as usual",
				icon = "key",
				current = current,
				secrets = true,
			},
			{
				label = "No secrets",
				detail = "--no-env: none of your stored secrets; SSH, desktop and snapshots still work",
				icon = "lock",
				current = not current,
				secrets = false,
			},
		},
		placeholder = "Secrets for the new sandbox",
		icon = "key",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		chosen(item.secrets == true, fresh)
	end, dismissed)
end

local function sizeSummary(id: string): string
	local size = boats.sizeOf(id)
	return if size then id .. " · " .. boats.sizeDetail(size) else id
end

local function autoStopSummary(hours: number?): string
	return if hours then hoursLabel(hours) .. " auto-stop" else "no auto-stop"
end

local function formSummary(form: Form): string
	local parts = { form.type, form.snapshot, autoStopSummary(form.hours), environmentLabel(form.environment) }
	if not form.secrets then
		table.insert(parts, "no secrets")
	end
	return table.concat(parts, " · ")
end

local function defaultsJson(form: Form): string
	return tern.json.encode({
		snapshot = form.snapshot,
		type = form.type,
		hours = if form.hours then form.hours else tern.json.null,
		environment = if form.environment then form.environment else tern.json.null,
		secrets = form.secrets,
	})
end

-- ---------- connecting ----------

-- Attaches a sandbox the script got ready under `title` (the shared add-host path, which records
-- it once connected); a failure stays on the record for the section to show.
local function connect(
	cx: WindowCx,
	id: string,
	name: string,
	title: string,
	address: string,
	fingerprint: string,
	verb: string,
	entered: ((WindowCx) -> ())?
)
	env.ops[id] = "connecting"
	boats.attach(cx, {
		address = address,
		title = title,
		fingerprint = fingerprint,
		boat = { id = id, name = name },
	}, function(ok: boolean, state: string, message: string?, fresh: WindowCx?)
		env.ops[id] = nil
		if ok then
			if fresh then
				fresh:toast("success", title .. " is " .. verb, "Connected at " .. address)
				if entered then
					entered(fresh)
				end
			end
		else
			local problem = message or ("Tern could not connect (" .. state .. ")")
			updateBoat(id, function(boat)
				boat.error = problem
			end)
			if fresh then
				fresh:toast("error", "Could not connect " .. title, problem .. ". Right-click it under Boat sandboxes to connect again or delete it.")
			end
		end
		env.settled(fresh)
	end)
	env.requestRefresh()
end

-- What a create or duplicate asked for, and when its run started (epoch seconds): boat counts the
-- auto-stop from when the run makes the sandbox, a second or two later.
type Asked = { type: string, hours: number?, environment: string?, startedAt: number }

-- The new sandbox as its run made it, shown until a listing has it.
local function provisional(id: string, name: string, result: boats.Result, asked: Asked): boats.Sandbox
	local size = boats.sizeOf(result.value.type) or boats.sizeOf(asked.type)
	local hours = asked.hours
	return {
		id = id,
		name = name,
		state = "running",
		type = if size then size.id else asked.type,
		vcpu = if size then size.vcpu else nil,
		memoryGB = if size then size.memory else nil,
		ip = if type(result.value.ip) == "string" then result.value.ip else nil,
		address = result.address,
		autoStopAt = if hours then asked.startedAt + hours * 3600 else nil,
		noAutoStop = hours == nil,
		environment = asked.environment,
		createdAt = asked.startedAt,
		usage = { seconds = 0, dollars = 0 },
	}
end

-- The end of a create or duplicate: record the sandbox (a paid one stays listed even when Tern
-- cannot reach it) and show it as asked for until a listing has it, then attach it.
local function created(fresh: WindowCx?, result: boats.Result, name: string, title: string, asked: Asked)
	local id = result.id
	local address, fingerprint = result.address, result.fingerprint
	local ready = result.ok and id ~= nil and address ~= nil and fingerprint ~= nil
	if id and result.state ~= "deleted" then
		local saved, err = pcall(data.saveBoat, {
			id = id,
			name = name,
			title = title,
			address = address,
			state = if ready then "running" else recordState(result.state) or "running",
			error = if ready then nil else result.error or "boat-sandbox did not report the address and host key",
		})
		if not saved then
			tern.log.error("boat sandbox", "cannot save " .. id .. ": " .. tostring(err))
		end
		if ready or recordState(result.state) == "running" then
			boats.expectSandbox(provisional(id, name, result, asked))
		end
	end
	if not fresh then
		env.settled(nil)
		return
	end
	if not ready then
		fresh:toast("error", "Could not create " .. title, result.error or "boat-sandbox did not report the sandbox id, address and host key.")
		env.settled(fresh)
		return
	end
	connect(fresh, id :: string, name, title, address :: string, fingerprint :: string, "ready")
end

local function removeCreating(entry: Creating)
	local index = table.find(env.creating, entry)
	if index then
		table.remove(env.creating, index)
	end
end

-- ---------- New sandbox ----------

local newForm: (cx: WindowCx, form: Form) -> ()

local function createSandbox(cx: WindowCx, form: Form)
	local name = form.name :: string
	local refusal = sizeRefusal(form.type)
	if refusal then
		cx:toast("error", "Cannot create a " .. form.type .. " sandbox", refusal .. ".")
		after(function(next: WindowCx)
			newForm(next, form)
		end)
		return
	end
	local args = { "--no-tern", "--from", form.snapshot, "--type", form.type }
	if form.hours then
		table.insert(args, "--hours")
		table.insert(args, tostring(form.hours))
	else
		table.insert(args, "--no-auto-stop")
	end
	if form.environment then
		table.insert(args, "--environment")
		table.insert(args, form.environment)
	end
	if not form.secrets then
		table.insert(args, "--no-env")
	end
	table.insert(args, name)
	local title = boats.titleFor(name)
	local entry: Creating = { title = title, detail = form.type .. " · " .. form.snapshot }
	table.insert(env.creating, entry)
	cx:toast("info", "Creating " .. title .. "…", formSummary(form) .. ". A paid boat.dev sandbox; it takes a minute or two.")
	env.requestRefresh()
	local asked: Asked = { type = form.type, hours = form.hours, environment = form.environment, startedAt = boats.epochNow() }
	boats.script(cx, args, CREATE_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
		removeCreating(entry)
		created(fresh, result, name, title, asked)
	end)
end

local function askName(cx: WindowCx, current: string?, placeholder: string, chosen: (string, WindowCx) -> (), dismissed: (WindowCx) -> ())
	env.prompt(cx, "naming the sandbox", {
		value = current or "",
		placeholder = placeholder,
		icon = "pen",
		action = "set",
	}, function(value: string, fresh: WindowCx)
		local name = boats.validName(value)
		if not name then
			fresh:toast("error", "Use 1–40 letters, digits, spaces, '.', '_' or '-'", "Not starting with '-'. Nothing was created.")
			after(dismissed)
			return
		end
		chosen(name, fresh)
	end, dismissed)
end

local function saveDefaults(cx: WindowCx, form: Form, done: (boolean, WindowCx?) -> ())
	boats.script(cx, { "--set-defaults", defaultsJson(form) }, DEFAULTS_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
		if fresh then
			if result.ok then
				fresh:toast("success", "Saved the defaults", formSummary(form) .. ". New sandboxes and omp /boat use them.")
			else
				fresh:toast("error", "Could not save the defaults", result.error)
			end
		end
		env.settled(fresh)
		done(result.ok, fresh)
	end)
end

newForm = function(cx: WindowCx, form: Form)
	local function back(next: WindowCx)
		newForm(next, form)
	end
	local function backAfter(_: WindowCx)
		after(back)
	end
	local name = form.name
	env.pick(cx, "creating a boat sandbox", {
		items = {
			{
				label = if name then "Create " .. boats.titleFor(name) else "Create Boat Sandbox…",
				detail = formSummary(form) .. (if name then "" else " · name it first"),
				icon = "plus",
				group = "New boat sandbox",
				field = "create",
			},
			{ label = "Name", detail = name or "Required", icon = "pen", group = "Settings", field = "name" },
			{ label = "Snapshot", detail = form.snapshot, icon = "layers", group = "Settings", field = "snapshot" },
			{ label = "Size", detail = sizeSummary(form.type), icon = "cpu", group = "Settings", field = "size" },
			{ label = "Auto-stop", detail = hoursLabel(form.hours), icon = "timer", group = "Settings", field = "hours" },
			{ label = "Environment", detail = environmentLabel(form.environment), icon = "box", group = "Settings", field = "environment" },
			{
				label = "Secrets",
				detail = if form.secrets then "Pass my secrets" else "No secrets (--no-env)",
				icon = "key",
				group = "Settings",
				field = "secrets",
			},
			{
				label = "Save as defaults",
				detail = "Use these settings (not the name) for new sandboxes and omp /boat",
				icon = "save",
				group = "Defaults",
				field = "save",
			},
		},
		placeholder = "New boat sandbox: create it, or choose a setting to change",
		icon = "server",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		local field = item.field
		if field == "create" then
			if form.name then
				createSandbox(fresh, form)
			else
				after(function(next: WindowCx)
					askName(next, nil, "Name the new sandbox (letters, digits, spaces, . _ -)", function(value: string, named: WindowCx)
						form.name = value
						createSandbox(named, form)
					end, backAfter)
				end)
			end
		elseif field == "name" then
			after(function(next: WindowCx)
				askName(next, form.name, "Sandbox name (letters, digits, spaces, . _ -)", function(value: string)
					form.name = value
					after(back)
				end, backAfter)
			end)
		elseif field == "snapshot" then
			after(function(next: WindowCx)
				pickSnapshot(next, form.snapshot, function(value: string)
					form.snapshot = value
					after(back)
				end, backAfter)
			end)
		elseif field == "size" then
			after(function(next: WindowCx)
				pickSize(next, "Size of the new sandbox", form.type, function(value: string)
					form.type = value
					after(back)
				end, backAfter)
			end)
		elseif field == "hours" then
			after(function(next: WindowCx)
				pickAutoStop(next, "Stop the new sandbox by itself after", form.hours, function(value: number?)
					form.hours = value
					after(back)
				end, backAfter)
			end)
		elseif field == "environment" then
			after(function(next: WindowCx)
				pickEnvironment(next, form.environment, function(value: string?)
					form.environment = value
					after(back)
				end, backAfter)
			end)
		elseif field == "secrets" then
			after(function(next: WindowCx)
				pickSecrets(next, form.secrets, function(value: boolean)
					form.secrets = value
					after(back)
				end, backAfter)
			end)
		elseif field == "save" then
			env.hold()
			saveDefaults(fresh, form, function(_: boolean, done: WindowCx?)
				if done then
					newForm(done, form)
				end
				env.release()
			end)
		end
	end)
end

-- New sandbox…, pre-filled from the defaults (and `snapshot` when it starts from one).
local function newSandbox(cx: WindowCx, snapshot: string?)
	withDefaults(cx, function(fresh: WindowCx, defaults: boats.Defaults)
		newForm(fresh, {
			name = nil,
			snapshot = snapshot or defaults.snapshot,
			type = defaults.type,
			hours = defaults.hours,
			environment = defaults.environment,
			secrets = defaults.secrets,
		})
	end)
end

-- ---------- Defaults ----------

local defaultsForm: (cx: WindowCx, form: Form, saved: Form) -> ()

defaultsForm = function(cx: WindowCx, form: Form, saved: Form)
	local function back(next: WindowCx)
		defaultsForm(next, form, saved)
	end
	local function backAfter(_: WindowCx)
		after(back)
	end
	env.pick(cx, "editing boat sandbox defaults", {
		items = {
			{ label = "Snapshot", detail = form.snapshot, icon = "layers", group = "Defaults for new sandboxes and omp /boat", field = "snapshot" },
			{ label = "Size", detail = sizeSummary(form.type), icon = "cpu", group = "Defaults for new sandboxes and omp /boat", field = "size" },
			{ label = "Auto-stop", detail = hoursLabel(form.hours), icon = "timer", group = "Defaults for new sandboxes and omp /boat", field = "hours" },
			{
				label = "Environment",
				detail = environmentLabel(form.environment),
				icon = "box",
				group = "Defaults for new sandboxes and omp /boat",
				field = "environment",
			},
			{
				label = "Secrets",
				detail = if form.secrets then "Pass my secrets" else "No secrets (--no-env)",
				icon = "key",
				group = "Defaults for new sandboxes and omp /boat",
				field = "secrets",
			},
			{ label = "Done", detail = "Save these defaults", icon = "check", group = "Save", field = "done" },
		},
		placeholder = "Boat sandbox defaults: choose one to change, then Done",
		icon = "sliders",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		local field = item.field
		if field == "done" then
			if defaultsJson(form) == defaultsJson(saved) then
				fresh:toast("info", "The defaults are unchanged", formSummary(form))
				return
			end
			saveDefaults(fresh, form, function() end)
		elseif field == "snapshot" then
			after(function(next: WindowCx)
				pickSnapshot(next, form.snapshot, function(value: string)
					form.snapshot = value
					after(back)
				end, backAfter)
			end)
		elseif field == "size" then
			after(function(next: WindowCx)
				pickSize(next, "Default size", form.type, function(value: string)
					form.type = value
					after(back)
				end, backAfter)
			end)
		elseif field == "hours" then
			after(function(next: WindowCx)
				pickAutoStop(next, "Stop new sandboxes by themselves after", form.hours, function(value: number?)
					form.hours = value
					after(back)
				end, backAfter)
			end)
		elseif field == "environment" then
			after(function(next: WindowCx)
				pickEnvironment(next, form.environment, function(value: string?)
					form.environment = value
					after(back)
				end, backAfter)
			end)
		elseif field == "secrets" then
			after(function(next: WindowCx)
				pickSecrets(next, form.secrets, function(value: boolean)
					form.secrets = value
					after(back)
				end, backAfter)
			end)
		end
	end)
end

local function editDefaults(cx: WindowCx)
	withDefaults(cx, function(fresh: WindowCx, defaults: boats.Defaults)
		local saved: Form = {
			snapshot = defaults.snapshot,
			type = defaults.type,
			hours = defaults.hours,
			environment = defaults.environment,
			secrets = defaults.secrets,
		}
		defaultsForm(fresh, table.clone(saved), saved)
	end)
end

-- ---------- Duplicate ----------

local forkForm: (cx: WindowCx, form: ForkForm) -> ()

local function forkSandbox(cx: WindowCx, form: ForkForm)
	local refusal = sizeRefusal(form.type)
	if refusal then
		cx:toast("error", "Cannot duplicate as " .. form.type, refusal .. ".")
		after(function(next: WindowCx)
			forkForm(next, form)
		end)
		return
	end
	local name = form.name :: string
	local args = { "--fork", form.source, "--type", form.type }
	if form.hours then
		table.insert(args, "--hours")
		table.insert(args, tostring(form.hours))
	else
		table.insert(args, "--no-auto-stop")
	end
	table.insert(args, name)
	local title = boats.titleFor(name)
	local entry: Creating = { title = title, detail = form.type .. " · copy of " .. form.sourceTitle }
	table.insert(env.creating, entry)
	cx:toast("info", "Duplicating " .. form.sourceTitle .. " as " .. title .. "…", "A paid boat.dev sandbox from its latest snapshot; it takes a minute or two.")
	env.requestRefresh()
	local asked: Asked = { type = form.type, hours = form.hours, environment = nil, startedAt = boats.epochNow() }
	boats.script(cx, args, CREATE_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
		removeCreating(entry)
		created(fresh, result, name, title, asked)
	end)
end

forkForm = function(cx: WindowCx, form: ForkForm)
	local function back(next: WindowCx)
		forkForm(next, form)
	end
	local function backAfter(_: WindowCx)
		after(back)
	end
	local name = form.name
	env.pick(cx, "duplicating a boat sandbox", {
		items = {
			{
				label = if name then "Duplicate as " .. boats.titleFor(name) else "Duplicate…",
				detail = form.type .. " · " .. autoStopSummary(form.hours) .. " · from the latest snapshot of " .. form.sourceTitle,
				icon = "copy",
				group = "Duplicate " .. form.sourceTitle,
				field = "create",
			},
			{ label = "Name", detail = name or "Required", icon = "pen", group = "Settings", field = "name" },
			{ label = "Size", detail = sizeSummary(form.type), icon = "cpu", group = "Settings", field = "size" },
			{ label = "Auto-stop", detail = hoursLabel(form.hours), icon = "timer", group = "Settings", field = "hours" },
		},
		placeholder = "Duplicate " .. form.sourceTitle .. ": create it, or choose a setting to change",
		icon = "copy",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		local field = item.field
		if field == "create" then
			if form.name then
				forkSandbox(fresh, form)
			else
				after(function(next: WindowCx)
					askName(next, nil, "Name the duplicate (letters, digits, spaces, . _ -)", function(value: string, named: WindowCx)
						form.name = value
						forkSandbox(named, form)
					end, backAfter)
				end)
			end
		elseif field == "name" then
			after(function(next: WindowCx)
				askName(next, form.name, "Name of the duplicate (letters, digits, spaces, . _ -)", function(value: string)
					form.name = value
					after(back)
				end, backAfter)
			end)
		elseif field == "size" then
			after(function(next: WindowCx)
				pickSize(next, "Size of the duplicate", form.type, function(value: string)
					form.type = value
					after(back)
				end, backAfter)
			end)
		elseif field == "hours" then
			after(function(next: WindowCx)
				pickAutoStop(next, "Stop the duplicate by itself after", form.hours, function(value: number?)
					form.hours = value
					after(back)
				end, backAfter)
			end)
		end
	end)
end

local function duplicate(cx: WindowCx, info: Info)
	withDefaults(cx, function(fresh: WindowCx, defaults: boats.Defaults)
		local sandbox = info.sandbox
		local suggested = boats.validName(boats.cleanName(info.name .. " copy", true, 40))
		forkForm(fresh, {
			source = info.id,
			sourceTitle = info.title,
			name = suggested,
			type = if sandbox and boats.sizeOf(sandbox.type) then sandbox.type :: string else defaults.type,
			hours = defaults.hours,
		})
	end)
end

-- ---------- sandbox operations ----------

-- The address of the host attached for sandbox `id` in this window, if any.
local function attachedAddress(cx: WindowCx, id: string): string?
	local info = infoOf(cx, id)
	local host = if info then info.host else nil
	return if host then host.address else nil
end

-- Connect (a running sandbox no host here is attached to), Start (a stopped one) and Start as size:
-- the script resumes it when needed, keeps its host key and reopens Tern's port; the shared path
-- attaches it, at a new address if it has one. An untracked sandbox becomes tracked.
-- `entered` runs once it is connected (a click on a running sandbox switches into it).
local function resume(cx: WindowCx, info: Info, size: string?, entered: ((WindowCx) -> ())?)
	local id = info.id
	local starting = info.stopped
	local title = if info.record then info.title else boats.titleFor(info.name)
	env.ops[id] = if starting then "starting" else "connecting"
	cx:toast("info", (if starting then "Starting " else "Connecting ") .. title .. (if size then " as " .. size else "") .. "…", "It takes a minute or two.")
	local args = { "--resume", id }
	if size then
		table.insert(args, "--type")
		table.insert(args, size)
	end
	boats.script(cx, args, RESUME_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
		local address, fingerprint = result.address, result.fingerprint
		if not result.ok or not address or not fingerprint then
			env.ops[id] = nil
			local problem = result.error or "boat-sandbox did not report the address and host key"
			updateBoat(id, function(record)
				record.state = recordState(result.state) or record.state
				record.error = problem
			end)
			if fresh then
				fresh:toast("error", "Could not " .. (if starting then "start " else "connect ") .. title, problem)
			end
			env.settled(fresh)
			return
		end
		local current = updateBoat(id, function(record)
			record.state = "running"
			record.error = nil
		end)
		if not fresh then
			env.ops[id] = nil
			env.settled(nil)
			return
		end
		-- A host still attached at an old address never reaches the sandbox there again.
		local old = if current then current.address else nil
		if old and data.comparableAddress(old) ~= data.comparableAddress(address) then
			env.disconnect(fresh, old)
		end
		connect(fresh, id, if current then current.name else info.name, if current then data.boatTitle(current) else title, address, fingerprint, if size then "running as " .. size else "running", entered)
	end)
	env.requestRefresh()
end

local function stop(cx: WindowCx, info: Info)
	local id, title = info.id, info.title
	env.confirm(cx, "stopping boat sandbox", {
		question = "Stop " .. title .. "?",
		yes = "Stop " .. title,
		detail = "Ends its programs and disconnects it; its disk is kept for 14 days",
		icon = "stop",
	}, function(fresh: WindowCx)
		if env.ops[id] then
			return
		end
		env.ops[id] = "stopping"
		env.requestRefresh()
		boats.script(fresh, { "--stop", id }, STOP_TIMEOUT_MS, function(result: boats.Result, done: WindowCx?)
			env.ops[id] = nil
			if result.ok then
				if done then
					env.disconnect(done, attachedAddress(done, id))
				end
				updateBoat(id, function(record)
					record.state = "stopped"
					record.error = nil
				end)
				if done then
					done:toast("success", "Stopped " .. title, "Its disk is kept for 14 days. Right-click it to start it again.")
				end
			else
				updateBoat(id, function(record)
					record.state = recordState(result.state) or record.state
					record.error = result.error
				end)
				if done then
					done:toast("error", "Could not stop " .. title, result.error)
				end
			end
			env.settled(done)
		end)
	end)
end

local function delete(cx: WindowCx, info: Info)
	local id, title = info.id, info.title
	env.confirm(cx, "deleting boat sandbox", {
		question = "Delete " .. title .. " and all of its data?",
		yes = "Delete " .. title,
		detail = "Disconnects it and deletes the sandbox with its disk; this cannot be undone",
		icon = "trash",
		cancelFirst = true,
	}, function(fresh: WindowCx)
		if env.ops[id] then
			return
		end
		env.ops[id] = "deleting"
		env.disconnect(fresh, attachedAddress(fresh, id))
		env.requestRefresh()
		boats.script(fresh, { "--delete", id }, DELETE_TIMEOUT_MS, function(result: boats.Result, done: WindowCx?)
			env.ops[id] = nil
			if result.ok then
				boats.sandboxDeleted(id)
				local forgot, err = pcall(data.forgetBoat, id)
				if not forgot then
					tern.log.error("boat sandbox", "cannot forget " .. id .. ": " .. tostring(err))
				end
				if done then
					done:toast("success", "Deleted " .. title)
				end
			else
				updateBoat(id, function(record)
					record.error = result.error
				end)
				if done then
					done:toast("error", "Could not delete " .. title, result.error)
				end
			end
			env.settled(done)
		end)
	end)
end

local function resize(cx: WindowCx, info: Info)
	local id, title = info.id, info.title
	local current = if info.sandbox then info.sandbox.type else nil
	pickSize(cx, "Resize " .. title .. (if current then " (now " .. current .. ")" else ""), current, function(size: string, fresh: WindowCx)
		if size == current then
			fresh:toast("info", title .. " is already " .. size, "Nothing was changed.")
			return
		end
		local now = infoOf(fresh, id)
		if not now or busy(fresh, now) then
			return
		end
		if now.stopped then
			resume(fresh, now, size)
			return
		end
		local target = boats.sizeOf(size) :: boats.Size
		after(function(next: WindowCx)
			env.confirm(next, "resizing boat sandbox", {
				question = "Restart " .. title .. " as " .. size .. "?",
				yes = "Restart as " .. size,
				detail = "Its programs end: it stops, then starts again as " .. size .. " · " .. boats.sizeDetail(target),
				icon = "cpu",
				cancelFirst = true,
			}, function(confirmed: WindowCx)
				if env.ops[id] then
					return
				end
				env.ops[id] = "resizing"
				env.disconnect(confirmed, attachedAddress(confirmed, id))
				confirmed:toast("info", "Resizing " .. title .. " to " .. size .. "…", "It stops and starts again; that takes a minute or two.")
				env.requestRefresh()
				boats.script(confirmed, { "--resize", id, "--type", size }, RESIZE_TIMEOUT_MS, function(result: boats.Result, done: WindowCx?)
					local address, fingerprint = result.address, result.fingerprint
					if not result.ok or not address or not fingerprint then
						env.ops[id] = nil
						local problem = result.error or "boat-sandbox did not report the address and host key"
						updateBoat(id, function(record)
							record.state = recordState(result.state) or record.state
							record.error = problem
						end)
						if done then
							done:toast("error", "Could not resize " .. title, problem)
						end
						env.settled(done)
						return
					end
					local record = updateBoat(id, function(saved)
						saved.state = "running"
						saved.error = nil
					end)
					if not done then
						env.ops[id] = nil
						env.settled(nil)
						return
					end
					local name = if record then record.name else now.name
					local newTitle = if record then data.boatTitle(record) else boats.titleFor(now.name)
					connect(done, id, name, newTitle, address, fingerprint, "running as " .. size)
				end)
			end)
		end)
	end)
end

local function autoStop(cx: WindowCx, info: Info)
	local id, title = info.id, info.title
	local sandbox = info.sandbox
	local now = boats.epochNow()
	local current = "now: unknown"
	if sandbox then
		if sandbox.noAutoStop then
			current = "now: no auto-stop"
		elseif sandbox.autoStopAt then
			local remaining = sandbox.autoStopAt - now
			current = "now: " .. (if remaining > 0 then "stops in " .. boats.left(remaining) else "stopping soon") .. " (" .. (boats.dateTime(sandbox.autoStopAt) or "?") .. ")"
		end
	end
	local items: { PickItem } = {}
	for _, choice in AUTO_STOPS do
		table.insert(items, {
			label = "Stop in " .. choice.label,
			detail = "At " .. (boats.dateTime(now + choice.hours * 3600) or "?"),
			icon = "timer",
			hours = choice.hours,
		})
	end
	table.insert(items, {
		label = "Never",
		detail = "No auto-stop: it runs (and bills) until you stop it",
		icon = "timer",
		current = sandbox ~= nil and sandbox.noAutoStop,
		never = true,
	})
	table.insert(items, { label = "Custom…", detail = "Stop in 1 to 720 hours", icon = "pen", custom = true })
	local function apply(hours: number?, fresh: WindowCx)
		local live = infoOf(fresh, id)
		if not live or busy(fresh, live) then
			return
		end
		local args = { "--extend", id }
		if hours then
			table.insert(args, "--hours")
			table.insert(args, tostring(hours))
		else
			table.insert(args, "--no-auto-stop")
		end
		env.ops[id] = "updating"
		env.requestRefresh()
		boats.script(fresh, args, EXTEND_TIMEOUT_MS, function(result: boats.Result, done: WindowCx?)
			env.ops[id] = nil
			if done then
				if result.ok then
					local at = boats.parseIso(result.value.autoStopAt)
					if result.value.noAutoStop == true or not at then
						done:toast("success", title .. " has no auto-stop", "It runs until you stop it.")
					else
						done:toast("success", title .. " stops " .. (boats.dateTime(at) or "later"), "In " .. boats.left(math.max(0, at - boats.epochNow())) .. ".")
					end
				else
					done:toast("error", "Could not change the auto-stop of " .. title, result.error)
				end
			end
			env.settled(done)
		end)
	end
	env.pick(cx, "changing auto-stop", {
		items = items,
		placeholder = "Auto-stop for " .. title .. " (" .. current .. ")",
		icon = "timer",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		if item.custom then
			after(function(next: WindowCx)
				customHours(next, nil, apply, nil)
			end)
		elseif item.never then
			apply(nil, fresh)
		else
			apply(item.hours :: number, fresh)
		end
	end)
end

local function saveSnapshot(cx: WindowCx, info: Info, name: string, replace: boolean)
	local id, title = info.id, info.title
	if env.ops[id] then
		return
	end
	local entry: Saving = { name = name, source = id, title = title }
	env.ops[id] = "saving"
	table.insert(env.saving, entry)
	cx:toast("info", "Saving snapshot " .. name .. "…", "From " .. title .. "; it takes a minute or so.")
	env.requestRefresh()
	local args = { "--snapshot", id, name }
	if replace then
		table.insert(args, "--replace")
	end
	boats.script(cx, args, SNAPSHOT_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
		env.ops[id] = nil
		local index = table.find(env.saving, entry)
		if index then
			table.remove(env.saving, index)
		end
		if fresh then
			if result.ok then
				local saved = result.value.snapshot
				local size = if type(saved) == "table" then boats.bytes(saved.sizeBytes) else nil
				fresh:toast("success", "Saved snapshot " .. name, (if size then size .. " · " else "") .. "from " .. title .. ". New sandboxes can start from it.")
			elseif not replace and string.sub(result.error or "", 1, 16) == "snapshot exists:" then
				local live = infoOf(fresh, id)
				if live then
					after(function(next: WindowCx)
						env.confirm(next, "replacing snapshot", {
							question = "Replace snapshot " .. name .. "?",
							yes = "Replace " .. name,
							detail = "Saves " .. title .. " over it; the snapshot it holds now is lost",
							icon = "layers",
							cancelFirst = true,
							keep = "Keep the snapshot as it is",
						}, function(confirmed: WindowCx)
							saveSnapshot(confirmed, live, name, true)
						end)
					end)
				end
			else
				fresh:toast("error", "Could not save snapshot " .. name, result.error)
			end
		end
		env.settled(fresh)
	end)
end

local function snapshotFrom(cx: WindowCx, info: Info)
	local base = boats.cleanName(info.name, false, 49)
	local suggested = (if base ~= "" then base .. "-" else "") .. boats.stamp(boats.epochNow())
	env.prompt(cx, "naming the snapshot", {
		value = suggested,
		placeholder = "Snapshot name for " .. info.title .. " (lowercase letters, digits, -)",
		icon = "layers",
		action = "save",
	}, function(value: string, fresh: WindowCx)
		local name = boats.validSnapshotName(value)
		if not name then
			fresh:toast("error", "Use 1–63 lowercase letters, digits or '-'", "Not starting with '-'. No snapshot was saved.")
			return
		end
		local live = infoOf(fresh, info.id)
		if not live or busy(fresh, live) then
			return
		end
		local inventory = boats.inventory()
		local exists = false
		for _, snap in (if inventory then inventory.snapshots else nil) or {} do
			exists = exists or snap.name == name
		end
		if not exists then
			saveSnapshot(fresh, live, name, false)
			return
		end
		after(function(next: WindowCx)
			env.confirm(next, "replacing snapshot", {
				question = "Replace snapshot " .. name .. "?",
				yes = "Replace " .. name,
				detail = "Saves " .. live.title .. " over it; the snapshot it holds now is lost",
				icon = "layers",
				cancelFirst = true,
				keep = "Keep the snapshot as it is",
			}, function(confirmed: WindowCx)
				saveSnapshot(confirmed, live, name, true)
			end)
		end)
	end)
end

-- Rename… edits the name the row shows ("Boat Sandbox (demo)" shows as "demo"); blank goes back to
-- Boat Sandbox (<its name>), and the name left as it was changes nothing.
local function rename(cx: WindowCx, info: Info)
	env.prompt(cx, "renaming boat sandbox", {
		value = boats.nameOfTitle(info.title),
		placeholder = "Name in the sidebar (blank: " .. info.name .. ")",
		icon = "pen",
		action = "rename",
	}, function(value: string, fresh: WindowCx)
		local live = infoOf(fresh, info.id)
		if not live then
			return
		end
		local trimmed = string.match(value, "^%s*(.-)%s*$") or ""
		if trimmed == boats.nameOfTitle(live.title) then
			return
		end
		local title = if trimmed == "" then boats.titleFor(live.name) else trimmed
		local host = live.host
		local address = (if host then host.address else nil)
			or (if live.record then live.record.address else nil)
			or (if live.sandbox then live.sandbox.address else nil)
		local ok, err = pcall(function()
			if address then
				data.setAddressTitle(address, title)
			end
			if host then
				data.setHostTitle(host, title)
			end
			local record = live.record
			data.saveBoat({
				id = live.id,
				name = live.name,
				title = title,
				address = if record then record.address else address,
				state = if live.stopped then "stopped" else "running",
				error = if record then record.error else nil,
			})
		end)
		if not ok then
			fresh:toast("error", "Could not rename " .. info.title, tostring(err))
		end
	end)
end

-- A click on an attached sandbox's row: into its only session, the one Tern last showed on its
-- host when there are several, or a new one named after the sandbox when it has none.
local function enter(cx: WindowCx, id: string)
	local info = infoOf(cx, id)
	local host = if info then info.host else nil
	if not info or not host or host.state ~= "connected" then
		env.settled(cx)
		return
	end
	local on: { ManagedSession } = {}
	for _, row in cx.sessions:list() do
		if row.host == host.id then
			if row.current then
				env.refresh(cx)
				return
			end
			table.insert(on, row)
		end
	end
	-- The switch applies after this callback returns: queue the refresh first.
	env.requestRefresh()
	if #on == 1 then
		cx.sessions:switch(on[1].id)
		return
	end
	-- Tern shows the session it last showed there; on a host without sessions it makes one with a
	-- generated name and shows it, which then takes the sandbox's name.
	cx.hosts:switch(host.id)
	if #on == 0 then
		local made = cx.sessions:current()
		if made.host == host.id then
			cx.sessions:rename(made.id, boats.nameOfTitle(info.title))
		end
	end
end

-- The clipboard, or for tests the copies file of the script hook (data.getCopyFile): one JSON
-- string per line, written before this returns.
local function copy(cx: WindowCx, text: string)
	local file = data.getCopyFile()
	if not file then
		cx:copy(text)
		return
	end
	local wrote, err = pcall(function()
		local before = if tern.fs.exists(file) then tern.fs.read(file) else ""
		tern.fs.write(file, before .. tern.json.encode(text) .. "\n")
	end)
	if not wrote then
		tern.log.error("boat sandbox", "cannot write the copies file: " .. tostring(err))
	end
end

-- Copy SSH details…: the script authorizes boat's key on the running sandbox, saves its host key
-- to ~/.ssh/boat/<id>.known_hosts and reports ready-made texts; the chosen one is copied.
local function sshDetails(cx: WindowCx, info: Info)
	local id = info.id
	local name = boats.nameOfTitle(info.title)
	cx:toast("info", "Getting SSH details…", name .. ": it takes a few seconds.")
	boats.script(cx, { "--ssh", id, "--name", name }, SSH_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
		if not fresh then
			return
		end
		local value = result.value
		if not result.ok or type(value.command) ~= "string" then
			fresh:toast("error", "Could not get SSH details for " .. name, result.error or "boat-sandbox reported no SSH command")
			return
		end
		local host = tostring(value.host)
		local where = (if string.find(host, ":", 1, true) then "[" .. host .. "]" else host) .. ":" .. tostring(value.port)
		local key = string.gsub(tostring(value.identityFile), "^/Users/[^/]+/", "~/")
		env.pick(fresh, "copying SSH details", {
			items = {
				{ label = "SSH command", detail = value.command, icon = "terminal", text = value.command },
				{ label = "SSH config entry", detail = "Host " .. tostring(value.alias) .. " · for ~/.ssh/config, VS Code, Cursor", icon = "sliders", text = value.config },
				{ label = "Connection details", detail = where .. " · " .. tostring(value.user) .. " · " .. key, icon = "server", text = value.details },
				{ label = "boat ssh command", detail = value.boatCommand, icon = "terminal", text = value.boatCommand },
			},
			placeholder = "Copy SSH details for " .. name,
			icon = "terminal",
			action = "copy",
		}, function(item: PickItem, chosen: WindowCx)
			copy(chosen, tostring(item.text))
			chosen:toast("success", "Copied " .. tostring(item.label) .. " for " .. name)
		end)
	end)
end

local function boatAction(cx: WindowCx, op: string, id: string)
	local info = infoOf(cx, id)
	if not info then
		cx:toast("error", "Boat sandbox no longer listed", "The sidebar has been refreshed; nothing was changed.")
		env.settled(cx)
		return
	end
	if op == "copy-id" then
		copy(cx, id)
		cx:toast("success", "Copied " .. id, info.title)
		return
	elseif op == "rename" then
		rename(cx, info)
		return
	elseif op == "forget" then
		pcall(data.forgetBoat, id)
		cx:toast("success", "Forgot " .. info.title, "It is no longer in your boat.dev account.")
		env.refresh(cx)
		return
	end
	if busy(cx, info) then
		return
	end
	if op == "open" then
		if info.host and info.host.state == "connected" then
			enter(cx, id)
		elseif info.running and not info.stopped then
			resume(cx, info, nil, function(fresh: WindowCx)
				enter(fresh, id)
			end)
		else
			env.refresh(cx)
		end
	elseif op == "ssh-details" then
		sshDetails(cx, info)
	elseif op == "connect" or op == "start" then
		resume(cx, info, nil)
	elseif op == "start-as" then
		pickSize(cx, "Start " .. info.title .. " as", if info.sandbox then info.sandbox.type else nil, function(size: string, fresh: WindowCx)
			local live = infoOf(fresh, id)
			if live and not busy(fresh, live) then
				resume(fresh, live, size)
			end
		end)
	elseif op == "stop" then
		stop(cx, info)
	elseif op == "delete" then
		delete(cx, info)
	elseif op == "resize" then
		resize(cx, info)
	elseif op == "auto-stop" then
		autoStop(cx, info)
	elseif op == "snapshot" then
		snapshotFrom(cx, info)
	elseif op == "duplicate" then
		duplicate(cx, info)
	elseif op == "remove" then
		local host = info.host
		if host then
			env.disconnect(cx, host.address)
			cx:toast("success", "Removed " .. info.title .. " from Tern", "The sandbox keeps running; Connect attaches it again.")
		end
		env.settled(cx)
	elseif op == "ssh" then
		local ok, err = pcall(function()
			cx.hosts:terminal("local", { command = "boat ssh " .. id })
		end)
		if not ok then
			cx:toast("error", "Could not open an SSH terminal", tostring(err))
		end
	elseif op == "desktop" then
		cx:toast("info", "Opening the desktop of " .. info.title .. "…")
		boats.script(cx, { "--desktop", id }, DESKTOP_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
			local url = result.value.url
			if not fresh then
				return
			end
			if result.ok and type(url) == "string" and string.match(url, "^https://") then
				fresh:open(url)
			else
				fresh:toast("error", "Could not open the desktop of " .. info.title, result.error or "boat-sandbox reported no URL")
			end
		end)
	end
end

-- ---------- snapshots ----------

local function snapshotAction(cx: WindowCx, op: string, name: string)
	local inventory = boats.inventory()
	local isDefault = inventory ~= nil and inventory.defaults.snapshot == name
	if op == "new" then
		newSandbox(cx, name)
	elseif op == "copy" then
		copy(cx, name)
		cx:toast("success", "Copied " .. name)
	elseif op == "default" then
		local form = defaultsOr(inventory)
		boats.script(cx, { "--set-defaults", tern.json.encode({ snapshot = name }) }, DEFAULTS_TIMEOUT_MS, function(result: boats.Result, fresh: WindowCx?)
			if fresh then
				if result.ok then
					fresh:toast("success", "New sandboxes start from " .. name, "omp /boat follows it too (was " .. form.snapshot .. ").")
				else
					fresh:toast("error", "Could not make " .. name .. " the default", result.error)
				end
			end
			env.settled(fresh)
		end)
	elseif op == "delete" then
		if env.snapshotOps[name] then
			return
		end
		env.confirm(cx, "deleting snapshot", {
			question = "Delete snapshot " .. name .. "?" .. (if isDefault then " It is your default." else ""),
			yes = "Delete snapshot " .. name,
			detail = "Deletes the saved disk image; sandboxes made from it keep running"
				.. (if isDefault then ". New sandboxes and omp /boat start from it, so choose another default" else ""),
			icon = "trash",
			cancelFirst = true,
			keep = "Keep the snapshot",
		}, function(fresh: WindowCx)
			if env.snapshotOps[name] then
				return
			end
			env.snapshotOps[name] = "deleting"
			env.requestRefresh()
			boats.script(fresh, { "--snapshot-rm", name }, SNAPSHOT_RM_TIMEOUT_MS, function(result: boats.Result, done: WindowCx?)
				env.snapshotOps[name] = nil
				if result.ok then
					boats.snapshotDeleted(name)
				end
				if done then
					if result.ok then
						done:toast("success", "Deleted snapshot " .. name, if isDefault then "It was your default; choose another under Defaults…." else nil)
					else
						done:toast("error", "Could not delete snapshot " .. name, result.error)
					end
				end
				env.settled(done)
			end)
		end)
	end
end

-- ---------- the section header ----------

local function headerMenu(cx: WindowCx)
	env.pick(cx, "choosing a boat sandboxes action", {
		items = {
			{ label = "New sandbox…", detail = "A paid boat.dev sandbox, connected here", icon = "plus", op = "new" },
			{ label = "Defaults…", detail = "What new sandboxes and omp /boat start from", icon = "sliders", op = "defaults" },
			{ label = "Refresh", detail = "Read your sandboxes, snapshots and usage again", icon = "redo", op = "refresh" },
			{
				label = "Show details",
				detail = "Size · auto-stop or disk · cost under each sandbox's name",
				icon = "sliders",
				current = data.getBoatDetails(),
				op = "details",
			},
		},
		placeholder = "Boat sandboxes",
		icon = "server",
		action = "choose",
	}, function(item: PickItem, fresh: WindowCx)
		if item.op == "new" then
			after(function(next: WindowCx)
				newSandbox(next, nil)
			end)
		elseif item.op == "defaults" then
			after(editDefaults)
		elseif item.op == "details" then
			data.setBoatDetails(not data.getBoatDetails())
			env.refresh(fresh)
		else
			env.settled(fresh)
		end
	end)
end

-- A click or menu choice in the Boat section (a sessions.Target of kind "boats", "boat" or
-- "snapshot").
local function action(cx: WindowCx, target: { [string]: any })
	local op = target.op
	if type(op) ~= "string" then
		return
	end
	if target.kind == "boats" then
		if op == "new" then
			newSandbox(cx, nil)
		elseif op == "defaults" then
			editDefaults(cx)
		elseif op == "refresh" then
			env.settled(cx)
		elseif op == "menu" then
			headerMenu(cx)
		elseif op == "toggle-snapshots" then
			data.setSnapshotsCollapsed(not data.getSnapshotsCollapsed())
			env.refresh(cx)
		elseif op == "details" then
			data.setBoatDetails(not data.getBoatDetails())
			env.refresh(cx)
		end
	elseif target.kind == "boat" and type(target.boat) == "string" then
		boatAction(cx, op, target.boat)
	elseif target.kind == "snapshot" and type(target.snapshot) == "string" then
		snapshotAction(cx, op, target.snapshot)
	end
end

return { init = init, action = action }
