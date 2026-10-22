--!strict
-- boat.dev sandboxes, window half: runs of ~/bin/boat-sandbox (the only boat command the plugin
-- runs), the account inventory it reports (cached in kv, read again in the background), the one
-- path that attaches a host under its title (add-host requests, New sandbox, Connect, Start), and the
-- figures and wording the Boat section shows. Every run is asynchronous. Loaded on first use, never
-- inside the load hook (see window.luau).
local data = require("./session-data")

-- A script run's last stdout line (see README.md): `value` is the whole JSON object ({} when the
-- run printed none), the other fields are its common ones.
export type Result = {
	ok: boolean,
	error: string?,
	value: { [string]: any },
	id: string?,
	address: string?,
	fingerprint: string?,
	state: string?,
}

export type AttachRequest = {
	address: string,
	title: string,
	fingerprint: string,
	-- Records the host as this boat sandbox once it is connected.
	boat: { id: string, name: string }?,
}

-- Called once: whether the host connected, its last state, the problem, and a fresh cx if any.
export type AttachDone = (ok: boolean, state: string, message: string?, cx: WindowCx?) -> ()

-- A machine size: vCPUs, RAM and disk in GB, dollars per hour, and the plan it needs.
export type Size = { id: string, vcpu: number, memory: number, disk: number, hourly: number, plan: number? }

-- One sandbox of the account. Times are epoch seconds.
export type Sandbox = {
	id: string,
	name: string,
	-- "running" | "starting" | "stopping" | "stopped" | "deleting" | "error"
	state: string,
	rawState: string?,
	type: string?,
	vcpu: number?,
	memoryGB: number?,
	ip: string?,
	address: string?,
	autoStopAt: number?,
	noAutoStop: boolean,
	environment: string?,
	createdAt: number?,
	stoppedAt: number?,
	dataExpiresAt: number?,
	error: string?,
	usage: { seconds: number, dollars: number }?,
}

-- A named snapshot.
export type Snap = {
	name: string,
	sizeBytes: number?,
	createdAt: number?,
	source: string?,
	status: string?,
	type: string?,
}

-- What New sandbox and `/boat` start from: `hours` nil is no auto-stop, `environment` nil the
-- account's default environment, `secrets` false is --no-env.
export type Defaults = { snapshot: string, type: string, hours: number?, environment: string?, secrets: boolean }

export type Starts = { limit: number?, remaining: number?, used: number? }
export type Limits = {
	quota: number?,
	remaining: number?,
	periodEnd: number?,
	live: number?,
	pack: number?,
	plan: number?,
	active: number?,
	canStart: boolean?,
	blocked: string?,
	day: Starts?,
	hour: Starts?,
	-- Machine size -> whether this plan may start it (`limits.machineTypes`).
	types: { [string]: { available: boolean, reason: string? } },
}

export type Inventory = {
	fetchedAt: number?,
	sandboxes: { Sandbox },
	byId: { [string]: Sandbox },
	-- nil when that part of the listing failed (errors says why).
	snapshots: { Snap }?,
	allowance: { used: number, free: number, price: number? }?,
	limits: Limits?,
	environments: { { name: string, isDefault: boolean } }?,
	defaults: Defaults,
	errors: { [string]: string },
}

-- The usage bar: `fraction` of the plan's included compute used this period; nil when usage is
-- unavailable, which `label` and `detail` then say.
export type UsageView = { fraction: number?, label: string, tone: string, detail: string }

type Ran = { status: number, stdout: string, stderr: string, timed_out: boolean }
type Pending = {
	request: AttachRequest,
	started: number,
	added: boolean,
	trusted: boolean,
	state: string,
	done: boolean,
	finish: AttachDone,
}

local ATTACH_TIMEOUT_MS = 60000
local ATTACH_POLL_MS = 250
-- The inventory runs every listing call in parallel; a slow account still answers within this.
local INVENTORY_TIMEOUT_MS = 120000
-- The inventory is read at most once a minute while a sidebar shows; an explicit refresh or a
-- finished operation may read it sooner, never twice within INVENTORY_FORCED_MS. After failures it
-- waits 1, 2, 4… minutes, at most INVENTORY_BACKOFF_MAX_MS.
local INVENTORY_INTERVAL_MS = 60000
local INVENTORY_FORCED_MS = 5000
local INVENTORY_BACKOFF_MAX_MS = 15 * 60000
-- { savedAt = epoch seconds, value = the script's --inventory JSON }, shared by every window.
local INVENTORY_KEY = "sidebar.boat-inventory.v1"
local DAY = 86400
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- boat.dev's sizes and prices (`boat new --type`).
local SIZES: { Size } = {
	{ id = "small", vcpu = 2, memory = 4, disk = 12, hourly = 0.018 },
	{ id = "default", vcpu = 4, memory = 8, disk = 50, hourly = 0.036 },
	{ id = "large", vcpu = 8, memory = 16, disk = 125, hourly = 0.072 },
	{ id = "xlarge", vcpu = 16, memory = 32, disk = 251, hourly = 0.20, plan = 100 },
}

-- The script's own defaults when it has no defaults file.
local BUILTIN_DEFAULTS: Defaults = {
	snapshot = "tern-omp-inferhub-v2",
	type = "default",
	hours = 24,
	environment = nil,
	secrets = true,
}

local function text(value: any): string?
	return if type(value) == "string" and string.find(value, "%S") then value else nil
end

local function amount(value: any): number?
	return if type(value) == "number" and value == value and value >= 0 and value < math.huge then value else nil
end

local function bool(value: any): boolean?
	return if type(value) == "boolean" then value else nil
end

-- ---------- running the script ----------

-- A Tern started from the Dock gets launchd's PATH, which has no boat, Bun or ~/bin.
local function searchPath(home: string): string
	return table.concat({
		home .. "/.ascii/bin",
		home .. "/.bun/bin",
		home .. "/bin",
		"/opt/homebrew/bin",
		"/usr/local/bin",
		"/usr/bin",
		"/bin",
		"/usr/sbin",
		"/sbin",
	}, ":")
end

-- Runs ~/bin/boat-sandbox (under Bun) with `args`. `done` may run before this returns.
local function spawn(cx: WindowCx, args: { string }, timeoutMs: number, done: (Ran?, string?, WindowCx?) -> ())
	local home = tern.getenv("HOME")
	local argv = data.getBoatCommand()
	if not argv then
		if not home or home == "" then
			done(nil, "HOME is not set", cx)
			return
		end
		argv = { "/usr/bin/env", "bun", home .. "/bin/boat-sandbox" }
	end
	local command = argv :: { string }
	for _, arg in args do
		table.insert(command, arg)
	end
	local dir = if home and home ~= "" then home else "/"
	local env = data.getBoatEnv()
	env.PATH = searchPath(dir)
	local started, err = pcall(tern.process.run, command, {
		cwd = dir,
		env = env,
		timeout_ms = timeoutMs,
	}, function(result: ProcessResult, fresh: WindowCx?)
		done(result, nil, fresh)
	end)
	if not started then
		done(nil, tostring(err), cx)
	end
end

-- One JSON document, else its last line that is one.
local function decodeJson(output: string): { [string]: any }?
	local whole, value = pcall(tern.json.decode, output)
	if whole and type(value) == "table" then
		return value
	end
	local last: string? = nil
	for line in string.gmatch(output, "[^\r\n]+") do
		if string.find(line, "^%s*{") then
			last = line
		end
	end
	if not last then
		return nil
	end
	local parsed, lineValue = pcall(tern.json.decode, last)
	return if parsed and type(lineValue) == "table" then lineValue else nil
end

local function lastLine(output: string): string?
	local last: string? = nil
	for line in string.gmatch(output, "[^\r\n]+") do
		if string.find(line, "%S") then
			last = line
		end
	end
	return last
end

local function minutes(ms: number): string
	local count = ms // 60000
	return tostring(count) .. (if count == 1 then " minute" else " minutes")
end

-- Runs `boat-sandbox <args>`; `done` gets its summary, or a failed one saying what went wrong.
local function script(cx: WindowCx, args: { string }, timeoutMs: number, done: (Result, WindowCx?) -> ())
	spawn(cx, args, timeoutMs, function(ran: Ran?, problem: string?, fresh: WindowCx?)
		if not ran then
			done({ ok = false, error = "cannot run ~/bin/boat-sandbox: " .. tostring(problem), value = {} }, fresh)
			return
		end
		local value = decodeJson(ran.stdout) or {}
		local id = text(value.id)
		local result: Result = {
			ok = value.ok == true and ran.status == 0,
			error = text(value.error),
			value = value,
			id = if id and string.match(id, "^bx_%w+$") then id else nil,
			address = text(value.address),
			fingerprint = text(value.fingerprint),
			state = text(value.state),
		}
		if not result.ok and not result.error then
			local last = lastLine(ran.stderr)
			result.error = if ran.timed_out
				then "boat-sandbox did not finish within " .. minutes(timeoutMs)
				else "boat-sandbox exited with status " .. tostring(ran.status) .. (if last then ": " .. last else "")
		end
		done(result, fresh)
	end)
end

-- ---------- names ----------

-- A sandbox name: 1–40 letters, digits, spaces, ".", "_" or "-" once trimmed, not starting with
-- "-", as the script requires.
local function validName(value: string): string?
	local name = string.match(value, "^%s*(.-)%s*$") or ""
	if #name < 1 or #name > 40 or string.find(name, "[^%w ._%-]") or string.sub(name, 1, 1) == "-" then
		return nil
	end
	return name
end

-- A snapshot name: 1–64 letters, digits, ".", "_" or "-".
local function validSnapshotName(value: string): string?
	local name = string.match(value, "^%s*(.-)%s*$") or ""
	if #name < 1 or #name > 64 or string.find(name, "[^%w._%-]") then
		return nil
	end
	return name
end

-- `value` made into a valid name of at most `limit` characters: runs of whitespace become one
-- space (`spaces`) or "-", other characters "-".
local function cleanName(value: string, spaces: boolean, limit: number): string
	local name = string.gsub(value, "%s+", if spaces then " " else "-")
	name = string.gsub(name, if spaces then "[^%w ._%-]" else "[^%w._%-]", "-")
	name = string.gsub(name, "%-%-+", "-")
	name = string.gsub(name, "^[%s%-]+", "")
	name = string.gsub(string.sub(name, 1, limit), "[%s%-]+$", "")
	return name
end

local function titleFor(name: string): string
	return "Boat Sandbox (" .. name .. ")"
end

-- The name a sidebar title shows the sandbox under: titleFor's "Boat Sandbox (demo)" is "demo"; a
-- title given with Rename… stays as it is.
local function nameOfTitle(title: string): string
	return string.match(title, "^Boat Sandbox %((.+)%)$") or title
end

-- ---------- attaching a host ----------

local function hostAt(hosts: { ManagedHost }, address: string): ManagedHost?
	local wanted = data.comparableAddress(address)
	for _, host in hosts do
		local candidate = host.address
		if host.kind == "remote" and candidate and data.comparableAddress(candidate) == wanted then
			return host
		end
	end
	return nil
end

local function finishAttach(cx: WindowCx?, pending: Pending, ok: boolean, message: string?)
	if pending.done then
		return
	end
	pending.done = true
	if not ok and pending.added and cx then
		-- A host this request added is not left behind failed or awaiting an unmatched key.
		local listed, hosts = pcall(function()
			return cx.hosts:list()
		end)
		local host = if listed then hostAt(hosts, pending.request.address) else nil
		if host then
			local id = host.id
			pcall(function()
				cx.hosts:disconnect(id)
			end)
		end
	end
	pending.finish(ok, pending.state, message, cx)
end

local function connected(cx: WindowCx?, pending: Pending, host: ManagedHost)
	local request = pending.request
	-- Also title the host's own key, in case Tern reports the address in another form.
	pcall(data.setHostTitle, host, request.title)
	local boat = request.boat
	if boat then
		local saved, err = pcall(data.saveBoat, {
			id = boat.id,
			name = boat.name,
			title = request.title,
			address = request.address,
			state = "running",
		})
		if not saved then
			tern.log.error("boat sandbox", "cannot save " .. boat.id .. ": " .. tostring(err))
		end
	end
	finishAttach(cx, pending, true)
end

-- Polls the host list: trusts a first-contact key only when it is the expected fingerprint.
-- Polls with tern.sleep, not tern.timer: Tern disables a plugin's whole timer hook once one
-- refresh tick overruns its budget, which would strand a pending attach.
local function check(cx: WindowCx, pending: Pending)
	if pending.done then
		return
	end
	local listed, hosts = pcall(function()
		return cx.hosts:list()
	end)
	local host = if listed then hostAt(hosts, pending.request.address) else nil
	if host then
		pending.state = host.state
		local detail = host.detail
		local fingerprint = if detail then detail.fingerprint else nil
		if host.state == "connected" then
			connected(cx, pending, host)
			return
		elseif host.state == "failed" then
			finishAttach(cx, pending, false, (if detail then detail.error else nil) or "connection failed")
			return
		elseif host.state == "verify" and fingerprint and not pending.trusted then
			if fingerprint ~= pending.request.fingerprint then
				finishAttach(
					cx,
					pending,
					false,
					"host key " .. fingerprint .. " does not match the expected " .. pending.request.fingerprint
				)
				return
			end
			pending.trusted = true
			local id = host.id
			local key = fingerprint :: string
			local trusted, err = pcall(function()
				cx.hosts:trust(id, key)
			end)
			if not trusted then
				finishAttach(cx, pending, false, "trusting the host key failed: " .. tostring(err))
				return
			end
		end
	end
	if tern.now() - pending.started >= ATTACH_TIMEOUT_MS then
		finishAttach(cx, pending, false, "timed out after 60 s while " .. pending.state)
		return
	end
	tern.sleep(ATTACH_POLL_MS):next(function(_, _, fresh: WindowCx?)
		if fresh then
			check(fresh, pending)
		end
	end)
end

-- Adds the host at `request.address` (unless it is attached already), trusts only the expected
-- first-contact key, saves the title alias and, once connected, the boat record. `done` runs once;
-- a host this added is disconnected again when it fails.
local function attach(cx: WindowCx, request: AttachRequest, done: AttachDone)
	local pending: Pending = {
		request = request,
		started = tern.now(),
		added = false,
		trusted = false,
		state = "connecting",
		done = false,
		finish = done,
	}
	local titled, err = pcall(data.setAddressTitle, request.address, request.title)
	if not titled then
		finishAttach(cx, pending, false, "cannot save the title: " .. tostring(err))
		return
	end
	local listed, hosts = pcall(function()
		return cx.hosts:list()
	end)
	local existing = if listed then hostAt(hosts, request.address) else nil
	if existing then
		pending.state = existing.state
	end
	if not existing or existing.state == "failed" then
		local started, awaitable = pcall(function()
			return cx.hosts:add(request.address)
		end)
		if not started then
			pending.state = "failed"
			finishAttach(cx, pending, false, tostring(awaitable))
			return
		end
		pending.added = true
		awaitable:next(function(host: ManagedHost?, failure: string?, fresh: WindowCx?)
			if pending.done then
				return
			end
			if host then
				pending.state = host.state
				if host.state == "connected" then
					connected(fresh, pending, host)
				end
			else
				pending.state = "failed"
				finishAttach(fresh, pending, false, failure or "connection failed")
			end
		end)
	end
	check(cx, pending)
end

-- ---------- time ----------

local function epochNow(): number
	local ok, now = pcall(os.time)
	return if ok and type(now) == "number" then now else 0
end

-- Days since 1970-01-01 of a proleptic Gregorian date.
local function daysFromCivil(y: number, m: number, d: number): number
	local year = if m <= 2 then y - 1 else y
	local era = (if year >= 0 then year else year - 399) // 400
	local yoe = year - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- "2026-11-14T18:16:09.000Z" (or with a ±hh:mm offset) -> epoch seconds.
local function parseIso(value: any): number?
	if type(value) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s, rest = string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
	if not y then
		return nil
	end
	local zone = string.match(rest :: string, "^%.?%d*(.*)$") or ""
	local offset = 0
	if zone ~= "Z" and zone ~= "z" and zone ~= "" then
		local sign, oh, om = string.match(zone, "^([%+%-])(%d%d):?(%d%d)$")
		if not sign then
			return nil
		end
		offset = ((tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60) * (if sign == "+" then 1 else -1)
	end
	return daysFromCivil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number) * DAY
		+ (tonumber(h) :: number) * 3600
		+ (tonumber(mi) :: number) * 60
		+ (tonumber(s) :: number)
		- offset
end

type Clock = { year: number, month: number, day: number, hour: number, min: number }

-- Local calendar fields of an epoch time.
local function clock(epoch: number): Clock?
	local ok, t = pcall(os.date, "*t", math.floor(epoch))
	if ok and type(t) == "table" then
		return t :: any
	end
	return nil
end

-- "Nov 14" (local date).
local function shortDate(epoch: number?): string?
	local t = if epoch then clock(epoch) else nil
	if not t then
		return nil
	end
	return MONTHS[t.month] .. " " .. tostring(t.day)
end

-- "Nov 14, 18:16" (local).
local function dateTime(epoch: number?): string?
	local t = if epoch then clock(epoch) else nil
	if not t then
		return nil
	end
	return string.format("%s %d, %02d:%02d", MONTHS[t.month], t.day, t.hour, t.min)
end

-- "yyyymmdd-hhmm" (local), for snapshot names.
local function stamp(epoch: number): string
	local t = clock(epoch)
	if not t then
		return tostring(math.floor(epoch))
	end
	return string.format("%04d%02d%02d-%02d%02d", t.year, t.month, t.day, t.hour, t.min)
end

-- Time elapsed in whole units, rounded down: "<1 min", "25 min", "5 h", "3 d" ("stopped 5 h ago").
local function span(seconds: number): string
	if seconds < 60 then
		return "<1 min"
	elseif seconds < 3600 then
		return tostring(seconds // 60) .. " min"
	elseif seconds < 2 * DAY then
		return tostring(seconds // 3600) .. " h"
	end
	return tostring(seconds // DAY) .. " d"
end

-- Time left, to the nearest unit: just after choosing 4 hours it reads "4 h", not "3 h", and
-- 1 hour reads "1 h", not "59 min". "<1 min", "25 min", "5 h", "3 d".
local function left(seconds: number): string
	if seconds < 30 then
		return "<1 min"
	elseif seconds < 3570 then
		return tostring(math.floor(seconds / 60 + 0.5)) .. " min"
	elseif seconds < 47.5 * 3600 then
		return tostring(math.floor(seconds / 3600 + 0.5)) .. " h"
	end
	return tostring(math.floor(seconds / DAY + 0.5)) .. " d"
end

-- ---------- figures ----------

local function hours(seconds: number): string
	return string.format("%.1f h", seconds / 3600)
end

local function count(value: number): string
	return tostring(math.floor(value + 0.5))
end

local function money(dollars: number): string
	return string.format("$%.2f", dollars)
end

-- "$0.018/h" or "$0.20/h".
local function hourly(dollars: number): string
	local cents = dollars * 100
	return if math.abs(cents - math.floor(cents + 0.5)) < 1e-9
		then string.format("$%.2f/h", dollars)
		else string.format("$%.3f/h", dollars)
end

-- "2.4 GB" (decimal units, as boat.dev shows sizes).
local function bytes(value: number?): string?
	if not value then
		return nil
	end
	if value >= 1e9 then
		return string.format("%.1f GB", value / 1e9)
	elseif value >= 1e6 then
		return string.format("%d MB", math.floor(value / 1e6 + 0.5))
	end
	return string.format("%d KB", math.max(1, math.floor(value / 1e3 + 0.5)))
end

local function sizeOf(id: string?): Size?
	for _, size in SIZES do
		if size.id == id then
			return size
		end
	end
	return nil
end

-- "2 vCPU · 4 GB RAM · 12 GB disk · $0.018/h".
local function sizeDetail(size: Size): string
	return string.format("%d vCPU · %d GB RAM · %d GB disk · ", size.vcpu, size.memory, size.disk) .. hourly(size.hourly)
end

-- An auto-stop choice: "1 h", "3 days", "No auto-stop".
local function autoStopLabel(value: number?): string
	if not value then
		return "No auto-stop"
	elseif value % 24 == 0 and value >= 48 then
		return tostring(value // 24) .. " days"
	end
	return tostring(value) .. " h"
end

-- ---------- the account inventory ----------

local function parseSandbox(value: any): Sandbox?
	if type(value) ~= "table" then
		return nil
	end
	local id = text(value.id)
	if not id or not string.match(id, "^bx_%w+$") then
		return nil
	end
	local state = text(value.state) or "error"
	if state ~= "running" and state ~= "starting" and state ~= "stopping" and state ~= "stopped" and state ~= "deleting" then
		state = "error"
	end
	local usage = value.usage
	local seconds = if type(usage) == "table" then amount(usage.seconds) else nil
	local dollars = if type(usage) == "table" then amount(usage.dollars) else nil
	return {
		id = id,
		name = text(value.name) or id,
		state = state,
		rawState = text(value.rawState),
		type = text(value.type),
		vcpu = amount(value.vcpu),
		memoryGB = amount(value.memoryGB),
		ip = text(value.ip),
		address = text(value.address),
		autoStopAt = parseIso(value.autoStopAt),
		noAutoStop = value.noAutoStop == true,
		environment = text(value.environment),
		createdAt = parseIso(value.createdAt),
		stoppedAt = parseIso(value.stoppedAt),
		dataExpiresAt = parseIso(value.dataExpiresAt),
		error = text(value.error),
		usage = if seconds and dollars then { seconds = seconds, dollars = dollars } else nil,
	}
end

local function parseSnap(value: any): Snap?
	if type(value) ~= "table" then
		return nil
	end
	local name = text(value.name)
	if not name then
		return nil
	end
	return {
		name = name,
		sizeBytes = amount(value.sizeBytes),
		createdAt = parseIso(value.createdAt),
		source = text(value.sourceSandboxId),
		status = text(value.status),
		type = text(value.type),
	}
end

local function parseStarts(value: any): Starts?
	if type(value) ~= "table" then
		return nil
	end
	return { limit = amount(value.limit), remaining = amount(value.remaining), used = amount(value.used) }
end

local function parseLimits(value: any): Limits?
	if type(value) ~= "table" then
		return nil
	end
	local starts = if type(value.starts) == "table" then value.starts else {}
	local types: { [string]: { available: boolean, reason: string? } } = {}
	if type(value.machineTypes) == "table" then
		for _, item in ipairs(value.machineTypes) do
			local id = if type(item) == "table" then text(item.type) else nil
			if id and type(item.available) == "boolean" then
				types[id] = { available = item.available, reason = text(item.reason) }
			end
		end
	end
	return {
		quota = amount(value.quotaSeconds),
		remaining = amount(value.remainingSeconds),
		periodEnd = parseIso(value.periodEnd),
		live = amount(value.liveUsageSeconds),
		pack = amount(value.packSeconds),
		plan = amount(value.planDollars),
		active = amount(value.activeSandboxes),
		canStart = bool(value.canStart),
		blocked = text(value.startBlockedReason),
		day = parseStarts(starts.day),
		hour = parseStarts(starts.hour),
		types = types,
	}
end

local function parseHours(value: any): (boolean, number?)
	if value == nil then
		return true, nil
	end
	local n = amount(value)
	if n and n >= 1 and n <= 720 and n == math.floor(n) then
		return true, n
	end
	return false, nil
end

-- The script's resolved defaults. JSON null decodes to an absent key, so a missing `hours` is
-- no auto-stop.
local function parseDefaults(value: any): Defaults
	local defaults = table.clone(BUILTIN_DEFAULTS)
	if type(value) ~= "table" then
		return defaults
	end
	defaults.snapshot = text(value.snapshot) or defaults.snapshot
	defaults.type = if sizeOf(value.type) then value.type else defaults.type
	local okHours, parsedHours = parseHours(value.hours)
	if okHours then
		defaults.hours = parsedHours
	end
	defaults.environment = text(value.environment)
	local secrets = bool(value.secrets)
	if secrets ~= nil then
		defaults.secrets = secrets
	end
	return defaults
end

local function parseInventory(value: { [string]: any }): Inventory?
	if type(value.sandboxes) ~= "table" then
		return nil
	end
	local inventory: Inventory = {
		fetchedAt = parseIso(value.fetchedAt),
		sandboxes = {},
		byId = {},
		snapshots = nil,
		allowance = nil,
		limits = parseLimits(value.limits),
		environments = nil,
		defaults = parseDefaults(value.defaults),
		errors = {},
	}
	for _, item in ipairs(value.sandboxes) do
		local sandbox = parseSandbox(item)
		if sandbox and not inventory.byId[sandbox.id] then
			inventory.byId[sandbox.id] = sandbox
			table.insert(inventory.sandboxes, sandbox)
		end
	end
	if type(value.snapshots) == "table" then
		local snaps: { Snap } = {}
		for _, item in ipairs(value.snapshots) do
			local snap = parseSnap(item)
			if snap then
				table.insert(snaps, snap)
			end
		end
		table.sort(snaps, function(a: Snap, b: Snap): boolean
			return string.lower(a.name) < string.lower(b.name)
		end)
		inventory.snapshots = snaps
	end
	local allowance = value.allowance
	if type(allowance) == "table" and amount(allowance.used) and amount(allowance.free) then
		inventory.allowance = {
			used = allowance.used,
			free = allowance.free,
			price = amount(allowance.pricePerExtraMonthlyDollars),
		}
	end
	if type(value.environments) == "table" then
		local environments: { { name: string, isDefault: boolean } } = {}
		for _, item in ipairs(value.environments) do
			local name = if type(item) == "table" then text(item.name) else nil
			if name then
				table.insert(environments, { name = name, isDefault = item.isDefault == true })
			end
		end
		inventory.environments = environments
	end
	if type(value.errors) == "table" then
		for part, message in value.errors do
			if type(part) == "string" and text(message) then
				inventory.errors[part] = message
			end
		end
	end
	return inventory
end

-- Window-local: the inventory this window shows (its own last read, or a fresher one another
-- window cached), and the state of reading it.
local inventoryState: {
	inventory: Inventory?,
	-- tern.now() when this window last finished (or adopted) a read.
	at: number?,
	busy: boolean,
	again: boolean,
	-- A forced read that came too soon after the last one waits for INVENTORY_FORCED_MS.
	deferred: boolean,
	failed: string?,
	failures: number,
	-- savedAt of the kv cache entry the shown inventory came from.
	cachedAt: number?,
	loaded: boolean,
} = { busy = false, again = false, deferred = false, failures = 0, loaded = false }

local function backoffMs(): number
	return math.min(INVENTORY_BACKOFF_MAX_MS, INVENTORY_INTERVAL_MS * 2 ^ math.max(0, inventoryState.failures - 1))
end

-- What this window changed that a listing started before the change cannot show yet: sandboxes it
-- created or duplicated (shown from the run's own summary) and sandboxes and snapshots it deleted
-- (kept out of sight). Each holds until a listing started after it (`at`, epoch seconds) arrives;
-- that listing is then believed, even when it still has a deleted item or lacks a new one.
local pending: {
	created: { [string]: { sandbox: Sandbox, at: number } },
	deletedSandboxes: { [string]: number },
	deletedSnapshots: { [string]: number },
} = { created = {}, deletedSandboxes = {}, deletedSnapshots = {} }

local function addSandbox(shown: Inventory, sandbox: Sandbox)
	if not shown.byId[sandbox.id] then
		shown.byId[sandbox.id] = sandbox
		table.insert(shown.sandboxes, sandbox)
	end
end

local function removeSandbox(shown: Inventory, id: string)
	local listed = shown.byId[id]
	if listed then
		shown.byId[id] = nil
		local index = table.find(shown.sandboxes, listed)
		if index then
			table.remove(shown.sandboxes, index)
		end
	end
end

local function removeSnapshot(shown: Inventory, name: string)
	for index, snap in shown.snapshots or {} do
		if snap.name == name then
			table.remove(shown.snapshots :: { Snap }, index)
			local allowance = shown.allowance
			if allowance then
				allowance.used = math.max(0, allowance.used - 1)
			end
			return
		end
	end
end

-- Applies the pending changes to a listing just read, taken at `asOf` (epoch seconds), and drops
-- those it has caught up with.
local function overlay(shown: Inventory, asOf: number)
	for id, entry in pending.created do
		if shown.byId[id] or asOf > entry.at then
			pending.created[id] = nil
		else
			addSandbox(shown, entry.sandbox)
		end
	end
	for id, at in pending.deletedSandboxes do
		if not shown.byId[id] or asOf > at then
			pending.deletedSandboxes[id] = nil
		else
			removeSandbox(shown, id)
		end
	end
	local snaps = shown.snapshots
	if snaps then
		for name, at in pending.deletedSnapshots do
			local listed = false
			for _, snap in snaps do
				listed = listed or snap.name == name
			end
			if not listed or asOf > at then
				pending.deletedSnapshots[name] = nil
			else
				removeSnapshot(shown, name)
			end
		end
	end
end

-- Adopts the kv cache when it is newer than what this window shows; true when it did.
local function adoptCache(): boolean
	local ok, cached = pcall(tern.kv.get, INVENTORY_KEY)
	if not ok or type(cached) ~= "table" or type(cached.value) ~= "table" then
		return false
	end
	local savedAt = amount(cached.savedAt)
	if not savedAt or (inventoryState.cachedAt and savedAt <= inventoryState.cachedAt) then
		return false
	end
	local parsed = parseInventory(cached.value)
	if not parsed then
		return false
	end
	overlay(parsed, parsed.fetchedAt or savedAt)
	inventoryState.inventory = parsed
	inventoryState.cachedAt = savedAt
	return true
end

-- The shown inventory; the first call reads the kv cache, so a new window draws at once.
local function inventory(): Inventory?
	if not inventoryState.loaded then
		inventoryState.loaded = true
		adoptCache()
	end
	return inventoryState.inventory
end

-- A sandbox this window just created or duplicated, as the run reported it, shown until a listing
-- has it (instead of "status unavailable" for the seconds that takes).
local function expectSandbox(sandbox: Sandbox)
	pending.created[sandbox.id] = { sandbox = sandbox, at = epochNow() }
	pending.deletedSandboxes[sandbox.id] = nil
	local shown = inventoryState.inventory
	if shown then
		addSandbox(shown, sandbox)
	end
end

-- A sandbox this window deleted: out of sight until a listing confirms it is gone.
local function sandboxDeleted(id: string)
	pending.created[id] = nil
	pending.deletedSandboxes[id] = epochNow()
	local shown = inventoryState.inventory
	if shown then
		removeSandbox(shown, id)
	end
end

-- A named snapshot this window deleted: out of sight until a listing confirms it is gone.
local function snapshotDeleted(name: string)
	pending.deletedSnapshots[name] = epochNow()
	local shown = inventoryState.inventory
	if shown then
		removeSnapshot(shown, name)
	end
end

-- Whether requestInventory would read now: at most once a minute (backing off after failures),
-- or within INVENTORY_FORCED_MS when `force`d. Cheap, so callers can skip queueing work.
local function inventoryDue(force: boolean): boolean
	if inventoryState.busy then
		return force
	end
	local last = inventoryState.at
	if not last then
		return true
	end
	local wait = if force
		then INVENTORY_FORCED_MS
		elseif inventoryState.failures > 0 then backoffMs()
		else INVENTORY_INTERVAL_MS
	return tern.now() - last >= wait
end

-- Reads the inventory in the background when inventoryDue says so, unless the cache (this
-- window's from before a reload, or another window's) is under a minute old; `notify` runs when
-- the result is in.
local function requestInventory(cx: WindowCx, force: boolean, notify: () -> ())
	inventory()
	if inventoryState.busy then
		inventoryState.again = inventoryState.again or force
		return
	end
	if not inventoryDue(force) then
		local last = inventoryState.at
		if force and last and not inventoryState.deferred then
			-- An operation finished right after a read: read again once the minimum gap is over.
			inventoryState.deferred = true
			tern.sleep(math.max(0, INVENTORY_FORCED_MS - (tern.now() - last)) + 50):next(function(_, _, fresh: WindowCx?)
				inventoryState.deferred = false
				if fresh then
					requestInventory(fresh, true, notify)
				end
			end)
		end
		return
	end
	if not force then
		local adopted = adoptCache()
		local cachedAt = inventoryState.cachedAt
		local age = if cachedAt and inventoryState.inventory then epochNow() - cachedAt else nil
		if age and age >= 0 and age * 1000 < INVENTORY_INTERVAL_MS then
			inventoryState.at = tern.now() - age * 1000
			if adopted then
				inventoryState.failed = nil
				inventoryState.failures = 0
			end
			notify()
			return
		end
	end
	inventoryState.busy = true
	inventoryState.again = false
	local started = epochNow()
	script(cx, { "--inventory" }, INVENTORY_TIMEOUT_MS, function(result: Result, fresh: WindowCx?)
		inventoryState.busy = false
		inventoryState.at = tern.now()
		local parsed = if result.ok then parseInventory(result.value) else nil
		if parsed then
			overlay(parsed, parsed.fetchedAt or started)
			inventoryState.inventory = parsed
			inventoryState.failed = nil
			inventoryState.failures = 0
			local savedAt = epochNow()
			inventoryState.cachedAt = savedAt
			local saved, err = pcall(tern.kv.set, INVENTORY_KEY, { savedAt = savedAt, value = result.value })
			if not saved then
				tern.log.warn("boat sandbox", "cannot cache the inventory: " .. tostring(err))
			end
		else
			inventoryState.failed = result.error or "unexpected boat-sandbox --inventory output"
			inventoryState.failures += 1
		end
		notify()
		if fresh and inventoryState.again then
			inventoryState.again = false
			inventoryState.at = nil
			requestInventory(fresh, true, notify)
		end
	end)
end

-- The last read's problem while it failed (the shown inventory, if any, is older).
local function inventoryFailed(): string?
	return inventoryState.failed
end

-- Whether a read is running.
local function inventoryBusy(): boolean
	return inventoryState.busy
end

-- comparableAddress -> sandbox id, for every sandbox the inventory gives an address.
local function addressIndex(): { [string]: string }
	local index: { [string]: string } = {}
	local shown = inventoryState.inventory
	if shown then
		for _, sandbox in shown.sandboxes do
			local address = sandbox.address
			if address then
				index[data.comparableAddress(address)] = sandbox.id
			end
		end
	end
	return index
end

-- ---------- the usage bar ----------

local function startsText(starts: Starts?, period: string): string?
	if not starts or not starts.remaining or not starts.limit then
		return nil
	end
	return count(starts.remaining) .. " of " .. count(starts.limit) .. " " .. period
end

-- The usage bar's content; nil until this window has an inventory.
local function usageView(): UsageView?
	local shown = inventoryState.inventory
	if not shown then
		local failed = inventoryState.failed
		return if failed
			then { fraction = nil, label = "Usage unavailable", tone = "muted", detail = "boat-sandbox --inventory: " .. failed }
			else nil
	end
	local limits = shown.limits
	local quota = if limits then limits.quota else nil
	local remaining = if limits then limits.remaining else nil
	if not limits or not quota or quota <= 0 or not remaining then
		return {
			fraction = nil,
			label = "Usage unavailable",
			tone = "muted",
			detail = "boat limits: " .. (shown.errors.limits or "no plan figures"),
		}
	end
	local used = math.max(0, quota - remaining)
	local fraction = math.min(1, used / quota)
	local reset = shortDate(limits.periodEnd)
	local parts = { hours(used) .. " of " .. hours(quota) }
	local details = {
		"Plan compute this period: "
			.. hours(used)
			.. " used of "
			.. hours(quota)
			.. " ("
			.. count(fraction * 100)
			.. "%), "
			.. hours(remaining)
			.. " left.",
	}
	local pack = limits.pack
	if pack and pack > 0 then
		table.insert(parts, "+" .. hours(pack) .. " extra")
		table.insert(details, "Extra credit: " .. hours(pack) .. ".")
	end
	if reset then
		table.insert(parts, "resets " .. reset)
		table.insert(details, "Resets " .. reset .. ".")
	end
	local active = limits.active
	if active then
		local live = limits.live
		table.insert(
			details,
			"Running now: "
				.. count(active)
				.. (if active == 1 then " sandbox" else " sandboxes")
				.. (if live then ", " .. hours(live) .. " live" else "")
				.. "."
		)
	end
	local day = startsText(limits.day, "today")
	local hour = startsText(limits.hour, "this hour")
	if day or hour then
		local starts = {}
		if day then
			table.insert(starts, day)
		end
		if hour then
			table.insert(starts, hour)
		end
		table.insert(details, "Starts left: " .. table.concat(starts, ", ") .. ".")
	end
	if limits.plan then
		table.insert(details, "Plan: $" .. count(limits.plan) .. " a month.")
	end
	local tone = if fraction >= 0.95 then "error" elseif fraction >= 0.8 then "warning" else "accent"
	if limits.canStart == false then
		tone = "error"
		table.insert(details, "New starts are blocked" .. (if limits.blocked then ": " .. limits.blocked else "") .. ".")
	end
	return {
		fraction = fraction,
		label = table.concat(parts, " · "),
		tone = tone,
		detail = table.concat(details, " "),
	}
end

return {
	SIZES = SIZES,
	BUILTIN_DEFAULTS = BUILTIN_DEFAULTS,
	script = script,
	validName = validName,
	validSnapshotName = validSnapshotName,
	cleanName = cleanName,
	titleFor = titleFor,
	nameOfTitle = nameOfTitle,
	hostAt = hostAt,
	attach = attach,
	epochNow = epochNow,
	parseIso = parseIso,
	shortDate = shortDate,
	dateTime = dateTime,
	stamp = stamp,
	span = span,
	left = left,
	hours = hours,
	money = money,
	hourly = hourly,
	bytes = bytes,
	sizeOf = sizeOf,
	sizeDetail = sizeDetail,
	autoStopLabel = autoStopLabel,
	inventory = inventory,
	expectSandbox = expectSandbox,
	sandboxDeleted = sandboxDeleted,
	snapshotDeleted = snapshotDeleted,
	inventoryDue = inventoryDue,
	requestInventory = requestInventory,
	inventoryFailed = inventoryFailed,
	inventoryBusy = inventoryBusy,
	addressIndex = addressIndex,
	usageView = usageView,
}
