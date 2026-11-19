--!strict
-- The panel's link to the chargelimit daemon, which owns the limit and the plan. The panel sends
-- requests through noctalia.state; the service answers them with the chargelimit CLI, and every
-- minute it republishes the daemon's status file. This plugin's settings own the daemon's schedule.

type Kind = "read" | "set" | "target" | "cancel" | "schedule" | "config"
type Request = { id: string?, kind: Kind, limit: number?, deadline: number? } -- id nil: the service's own
type Controller = {
	status: "reading" | "ready" | "applying" | "failed",
	limit: number?,
	drains: boolean?,
	target: number?, -- the limit being applied
	message: string?,
	ack: string?, -- the id of the last panel request handled
}
type Plan = {
	note: string?,
	scheduling: boolean,
	overridden: boolean,
	target: { limit: number, deadline: number }?,
}
-- The daemon's status, from its status file or from the CLI's answer.
type Status =
	{ kind: "ready", limit: number, drains: boolean, plan: Plan, settings: { [string]: string } }
	| { kind: "failed", message: string }

local cli = "/usr/local/bin/chargelimit"
local statusPath = "/run/chargelimit/status.json"
local staleSeconds = 3 * 60 -- the daemon rewrites its status every minute
local notRunning: Status = { kind = "failed", message = "The chargelimit service is not running." }
local invalid: Status = { kind = "failed", message = "The chargelimit status is invalid." }
-- The CLI's names for this plugin's settings, in the order `config` receives them.
local settingKeys = {
	"work-hours",
	"work-days",
	"work-start",
	"work-end",
	"work-limit",
	"after-work-limit",
	"tolerance",
	"learn-rates",
}
local workDays = { weekdays = "weekdays", mon_sat = "mon-sat", every_day = "every-day" }
local presets = { [50] = true, [60] = true, [70] = true, [80] = true, [90] = true, [100] = true }

-- noctalia.state outlives a service restart, so the last acknowledgement carries over.
local controller: Controller = noctalia.state.get("controller") or { status = "reading" }
local queue: { Request } = {}
local busy = false
local lastNotified: string? = nil
local settingsChecked = false -- compared with the daemon's once, at the first status read

-- The CLI checks every value, so an unknown one is passed on for it to reject.
local function settings(): { [string]: string }
	local function switch(key: string): string
		return if noctalia.getConfig(key) == true then "on" else "off"
	end
	local days = noctalia.getConfig("work_days")
	return {
		["work-hours"] = switch("work_hours"),
		["work-days"] = workDays[days] or tostring(days),
		["work-start"] = tostring(noctalia.getConfig("work_start")),
		["work-end"] = tostring(noctalia.getConfig("work_end")),
		["work-limit"] = tostring(noctalia.getConfig("work_limit")),
		["after-work-limit"] = tostring(noctalia.getConfig("after_work_limit")),
		["tolerance"] = tostring(noctalia.getConfig("tolerance")),
		["learn-rates"] = switch("learn_rates"),
	}
end

local function parse(text: string): Status
	local value = noctalia.json.decode(text)
	if typeof(value) ~= "table" or typeof(value.at) ~= "number" then
		return invalid
	elseif os.time() - value.at > staleSeconds then
		return notRunning
	elseif typeof(value.error) == "string" then
		return { kind = "failed", message = value.error }
	end
	local plan = value.plan
	local target = if typeof(plan) == "table" then plan.target else nil
	if
		typeof(value.limit) ~= "number"
		or typeof(value.drains) ~= "boolean"
		or typeof(value.settings) ~= "table"
		or typeof(plan) ~= "table"
		or typeof(plan.scheduling) ~= "boolean"
		or typeof(plan.overridden) ~= "boolean"
		or (plan.note ~= nil and typeof(plan.note) ~= "string")
		or (
			target ~= nil
			and (typeof(target) ~= "table" or typeof(target.limit) ~= "number" or typeof(target.deadline) ~= "number")
		)
	then
		return invalid
	end
	return {
		kind = "ready",
		limit = value.limit,
		drains = value.drains,
		plan = {
			note = plan.note,
			scheduling = plan.scheduling,
			overridden = plan.overridden,
			target = target and { limit = target.limit, deadline = target.deadline },
		},
		settings = value.settings,
	}
end

local function readStatus(): Status
	local text = noctalia.readFile(statusPath)
	return if text then parse(text) else notRunning
end

local function publish(changes: { [string]: any })
	local next = table.clone(controller) :: any
	for key, value in changes do
		next[key] = value
	end
	-- A cleared field arrives as nil, which table.clone keeps; drop what the new status does not use.
	if next.status ~= "applying" then
		next.target = nil
	end
	if next.status ~= "failed" then
		next.message = nil
	end
	controller = next
	noctalia.state.set("controller", controller)
end

local function failed(message: string, ack: string?)
	publish({ status = "failed", message = message, ack = ack or controller.ack })
	if message ~= lastNotified then
		lastNotified = message
		noctalia.notifyError("Charge limit", message)
	end
end

local function show(status: Status, ack: string?)
	if status.kind == "failed" then
		noctalia.state.set("plan", {})
		failed(status.message, ack)
	else
		lastNotified = nil
		noctalia.state.set("plan", status.plan)
		publish({ status = "ready", limit = status.limit, drains = status.drains, ack = ack or controller.ack })
	end
end

local pump: () -> ()

-- Runs the CLI, shows its answer, then hands the next queued request on.
local function run(arguments: { string }, ack: string?)
	busy = true
	local function finish(result)
		busy = false
		local stderr = noctalia.string.trim(result.stderr)
		local status: Status = if result.timedOut
			then { kind = "failed", message = "The chargelimit command timed out." }
			elseif result.exitCode ~= 0 and stderr ~= "" then { kind = "failed", message = stderr }
			elseif result.exitCode ~= 0 then
				{ kind = "failed", message = `The chargelimit command failed with exit code {result.exitCode}.` }
			else parse(result.stdout)
		if status.kind == "failed" then
			-- Reported once; the panel then shows what the daemon holds.
			failed(status.message, ack)
			show(readStatus())
		else
			show(status, ack)
		end
		pump()
	end
	if not noctalia.fileExists(cli) then
		finish({ exitCode = 1, timedOut = false, stdout = "", stderr = "The chargelimit command is not installed." })
	elseif not noctalia.runAsync({ cli, table.unpack(arguments) }, finish) then
		finish({ exitCode = 1, timedOut = false, stdout = "", stderr = "The chargelimit command could not be started." })
	end
end

local function handle(request: Request)
	local kind = request.kind
	if kind == "read" then
		show(readStatus(), request.id)
	elseif kind == "set" then
		local limit = request.limit :: number
		publish({ status = "applying", target = limit })
		run({ "set", tostring(limit) }, request.id)
	elseif kind == "target" then
		run({ "charge-by", tostring(request.limit), string.format("@%d", request.deadline :: number) }, request.id)
	elseif kind == "cancel" then
		run({ "charge-by", "off" }, request.id)
	elseif kind == "schedule" then
		run({ "resume" }, request.id)
	elseif kind == "config" then
		local wanted, arguments = settings(), { "config" }
		for _, key in settingKeys do
			table.insert(arguments, `{key}={wanted[key]}`)
		end
		run(arguments, nil)
	else
		error(`a request of kind {kind} cannot reach the queue`)
	end
end

pump = function()
	if busy or #queue == 0 then
		return
	end
	handle(table.remove(queue, 1) :: Request)
	pump()
end

local function enqueue(request: Request)
	table.insert(queue, request)
	pump()
end

-- One waiting config is enough: it reads the settings when it runs.
local function pushSettings()
	for _, request in queue do
		if request.kind == "config" then
			return
		end
	end
	enqueue({ kind = "config" })
end

local function refresh()
	if busy or #queue > 0 then
		return -- the queued commands answer with a newer status
	end
	local status = readStatus()
	show(status)
	if status.kind == "ready" and not settingsChecked then
		settingsChecked = true
		local wanted = settings()
		for _, key in settingKeys do
			if status.settings[key] ~= wanted[key] then
				pushSettings()
				return
			end
		end
	end
end

-- The panel is this service's input, so its requests are checked before anything acts on them.
local function valid(request: Request): boolean
	local kind = request.kind
	if kind == "read" or kind == "cancel" or kind == "schedule" then
		return true
	elseif kind == "set" then
		return presets[request.limit :: any] == true
	elseif kind == "target" then
		return presets[request.limit :: any] == true
			and typeof(request.deadline) == "number"
			and request.deadline % 1 == 0
			and request.deadline > os.time()
	end
	return false
end

-- The panel sends one request at a time and waits for its acknowledgement.
local function receive(request: Request?)
	if request == nil or request.id == nil or request.id == controller.ack then
		return
	elseif valid(request) then
		enqueue(request)
	else
		failed("The charge-limit request is invalid.", request.id)
	end
end

noctalia.setUpdateInterval(60 * 1000)
noctalia.state.watch("request", receive)
receive(noctalia.state.get("request"))
refresh()

function update()
	refresh()
end

function onConfigChanged()
	pushSettings()
end
