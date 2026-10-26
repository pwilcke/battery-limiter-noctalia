--!strict
-- The only part of the plugin that reads or sets the controller. The panel sends requests through
-- noctalia.state; every minute the service asks the planner which limit should apply and sets it
-- when that changes. With working hours off and no target, it never runs the helper on its own.
local planner = require("./planner.luau")
local power = require("./power.luau")

-- "set" is a manual choice from the panel; "apply" is the service carrying out the plan.
type Kind = "read" | "set" | "apply" | "target" | "cancel" | "schedule"
type Request = { id: string?, kind: Kind, limit: number?, deadline: number? } -- id nil: the service's own
type Controller = {
	status: "reading" | "ready" | "applying" | "failed",
	limit: number?,
	drains: boolean?,
	target: number?, -- the limit being applied
	message: string?,
	ack: string?, -- the id of the last panel request handled
}

local helper = "/usr/local/libexec/framework-charge-limit"
local verifySeconds = 15 * 60 -- how often an active plan rereads the controller
local gapSeconds = 3 * 60 -- a longer pause between ticks means sleep or a stopped shell
local retrySeconds = 5 * 60 -- a limit that failed to apply waits this long before another try
local daySets = {
	weekdays = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true },
	mon_sat = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true },
	every_day = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true },
}

local intentsPath = assert(noctalia.pluginDataDir(), "the plugin data directory is unavailable") .. "/intents.json"
-- noctalia.state outlives a service restart, so the last acknowledgement carries over.
local controller: Controller = noctalia.state.get("controller") or { status = "reading" }
local queue: { Request } = {}
local busy = false
local verifiedAt = 0
local lastTick = os.time()
local rates, ratesAt = planner.defaultRates, -math.huge
local lastNotified: string? = nil
local failedLimit: number?, failedAt = nil, 0
local presets = { [50] = true, [60] = true, [70] = true, [80] = true, [100] = true }

local function loadIntents(): planner.Intents
	local text = noctalia.readFile(intentsPath)
	local saved = text and noctalia.json.decode(text)
	if typeof(saved) ~= "table" then
		return {}
	end
	local intents: planner.Intents = {}
	local override, target = saved.override, saved.target
	if typeof(override) == "table" and typeof(override.limit) == "number" and typeof(override.date) == "string" then
		intents.override = { limit = override.limit, date = override.date }
	end
	if
		typeof(target) == "table"
		and typeof(target.limit) == "number"
		and typeof(target.deadline) == "number"
		and typeof(target.waitLimit) == "number"
	then
		intents.target = {
			limit = target.limit,
			deadline = target.deadline,
			waitLimit = target.waitLimit,
			started = target.started == true,
		}
	end
	if typeof(saved.workCharging) == "string" then
		intents.workCharging = saved.workCharging
	end
	if presets[saved.restore] then
		intents.restore = saved.restore
	end
	return intents
end

local intents = loadIntents()

local function sameIntents(a: planner.Intents, b: planner.Intents): boolean
	local ao, bo, at, bt = a.override, b.override, a.target, b.target
	return a.workCharging == b.workCharging
		and a.restore == b.restore
		and (ao == nil) == (bo == nil)
		and (ao == nil or (ao.limit == bo.limit and ao.date == bo.date))
		and (at == nil) == (bt == nil)
		and (
			at == nil
			or (
				at.limit == bt.limit
				and at.deadline == bt.deadline
				and at.waitLimit == bt.waitLimit
				and at.started == bt.started
			)
		)
end

-- Written beside the old file and renamed over it, so a failed write keeps the previous intents.
local function saveIntents(next: planner.Intents): boolean
	local pending = intentsPath .. ".new"
	if noctalia.writeFile(pending, noctalia.json.encode(next)) and noctalia.renameFile(pending, intentsPath) then
		intents = next
		return true
	end
	noctalia.notifyError("Charge limit", "The charge plan could not be saved.")
	return false
end

local function readRules(): planner.Rules
	local tolerance = noctalia.getConfig("tolerance")
	if noctalia.getConfig("work_hours") ~= true then
		return { tolerance = tolerance }
	end
	local startMinute = planner.parseClock(noctalia.getConfig("work_start"))
	local endMinute = planner.parseClock(noctalia.getConfig("work_end"))
	local during = tonumber(noctalia.getConfig("work_limit"))
	local after = tonumber(noctalia.getConfig("after_work_limit"))
	local days = daySets[noctalia.getConfig("work_days")]
	if not (startMinute and endMinute and during and after and days) or startMinute >= endMinute or after < during then
		return { tolerance = tolerance, workProblem = "Working hours: check Settings" }
	end
	return {
		work = { days = days, startMinute = startMinute, endMinute = endMinute, during = during, after = after },
		tolerance = tolerance,
	}
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

local pump: () -> ()
local reconcile: () -> ()

-- Runs the helper and checks its answer, then hands the next queued request on.
local function run(arguments: { string }, done: (limit: number?, drains: boolean?, message: string?) -> ())
	busy = true
	local function finish(result)
		busy = false
		local response = if result.exitCode == 0 and not result.timedOut
			then noctalia.json.decode(result.stdout)
			else nil
		local message: string? = nil
		if result.timedOut then
			message = "The charge-limit request timed out."
		elseif result.exitCode ~= 0 then
			message = noctalia.string.trim(result.stderr)
			if message == "" then
				message = "The charge-limit request failed with exit code " .. tostring(result.exitCode) .. "."
			end
		elseif
			typeof(response) ~= "table"
			or typeof(response.limit) ~= "number"
			or response.limit % 1 ~= 0
			or response.limit < 25
			or response.limit > 100
			or typeof(response.drains) ~= "boolean"
		then
			message = "The charge-limit helper returned an invalid response."
		end
		if message then
			done(nil, nil, message)
		else
			verifiedAt = os.time()
			done(response.limit, response.drains, nil)
		end
		pump()
	end
	if not noctalia.fileExists(helper) then
		finish({ exitCode = 1, timedOut = false, stdout = "", stderr = "The charge-limit helper is not installed." })
	elseif not noctalia.runAsync({ "/usr/bin/pkexec", table.unpack(arguments) }, finish) then
		finish({ exitCode = 1, timedOut = false, stdout = "", stderr = "The charge-limit helper could not be started." })
	end
end

local function failed(message: string, ack: string?)
	publish({ status = "failed", message = message, ack = ack or controller.ack })
	if message ~= lastNotified then
		lastNotified = message
		noctalia.notifyError("Charge limit", message)
	end
end

local function apply(limit: number, ack: string?, after: (() -> ())?)
	publish({ status = "applying", target = limit })
	run({ helper, "set", tostring(limit) }, function(confirmed, drains, message)
		if message or confirmed ~= limit then
			failedLimit, failedAt = limit, os.time()
			failed(message or "The controller returned a different charge limit.", ack)
			-- A failed write leaves the limit unknown.
			table.insert(queue, 1, { kind = "read" })
			return
		end
		lastNotified = nil
		publish({ status = "ready", limit = confirmed, drains = drains, ack = ack or controller.ack })
		if after then
			after()
		end
	end)
end

local function handle(request: Request)
	if request.kind == "read" then
		publish({ status = "reading" })
		run({ helper, "read" }, function(limit, drains, message)
			if message then
				failed(message, request.id)
			else
				lastNotified = nil
				publish({ status = "ready", limit = limit, drains = drains, ack = request.id or controller.ack })
				if request.id == nil then
					reconcile()
				end
			end
		end)
	elseif request.kind == "set" then
		-- A manual choice ends any target, and with working hours on it holds until midnight.
		local limit = request.limit :: number
		local next: planner.Intents = { workCharging = intents.workCharging }
		if readRules().work then
			next.override = { limit = limit, date = os.date("%Y-%m-%d", os.time()) }
		end
		if saveIntents(next) then
			apply(limit, request.id, reconcile)
		else
			failed("The charge plan could not be saved.", request.id)
		end
	elseif request.kind == "apply" then
		apply(assert(request.limit, "the plan needs a limit"), nil, reconcile)
	elseif request.kind == "target" then
		local limit, deadline = request.limit :: number, request.deadline :: number
		local next = table.clone(intents)
		next.target = { limit = limit, deadline = deadline, waitLimit = controller.limit or limit, started = false }
		if saveIntents(next) then
			publish({ ack = request.id })
			reconcile()
		else
			failed("The charge plan could not be saved.", request.id)
		end
	elseif request.kind == "cancel" or request.kind == "schedule" then
		local next = table.clone(intents)
		local ended = next.target
		if request.kind == "cancel" then
			next.target = nil
			-- Without a schedule, the limit returns to where the target started.
			if ended and readRules().work == nil then
				next.restore = ended.waitLimit
			end
		else
			next.override = nil
		end
		if not saveIntents(next) then
			failed("The charge plan could not be saved.", request.id)
			return
		end
		publish({ ack = request.id })
		reconcile()
	end
end

pump = function()
	if busy or #queue == 0 then
		return
	end
	handle(table.remove(queue, 1))
	pump()
end

local function enqueue(request: Request)
	table.insert(queue, request)
	pump()
end

reconcile = function()
	local now = os.time()
	local charge, plugged = power.charge(), power.plugged()
	local rules = readRules()
	if noctalia.getConfig("learn_rates") ~= true then
		rates = planner.defaultRates
	elseif now - ratesAt >= 10 * 60 then
		local path = power.historyPath()
		local history = path and noctalia.readFile(path)
		rates, ratesAt = if history then planner.parseHistory(history) else planner.defaultRates, now
	end
	if charge == nil or plugged == nil then
		noctalia.state.set("plan", { note = "The battery cannot be read.", scheduling = rules.work ~= nil })
		return
	end
	local result = planner.plan(now, charge, plugged, rules, intents, rates)
	-- An unsaved latch would be gone at the next tick and switch back, so nothing happens unsaved.
	if not sameIntents(result.intents, intents) and not saveIntents(result.intents) then
		return
	end
	noctalia.state.set("plan", {
		note = result.note,
		scheduling = rules.work ~= nil,
		overridden = intents.override ~= nil,
		target = intents.target,
	})
	-- The last confirmed limit goes stale after a while or a sleep, since the BIOS or another tool
	-- may have changed it; a stale one is read first, and the read plans again.
	if now - lastTick > gapSeconds then
		verifiedAt = 0
	end
	lastTick = now
	local fresh = now - verifiedAt < verifySeconds
	if intents.restore and fresh and controller.limit == intents.restore then
		local next = table.clone(intents)
		next.restore = nil
		saveIntents(next)
		return
	end
	local wanted = result.limit
	if wanted == nil or busy or #queue > 0 then
		return
	end
	if not fresh then
		enqueue({ kind = "read" })
	elseif wanted ~= controller.limit and not (wanted == failedLimit and now - failedAt < retrySeconds) then
		enqueue({ kind = "apply", limit = wanted })
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
reconcile()

function update()
	reconcile()
end

function onConfigChanged()
	reconcile()
end
