--!strict
-- Decides which charge limit should apply at a given moment. It uses no noctalia.*, so its
-- tests can load it alone; the service feeds it and carries out the result.
local planner = {}

export type Work = {
	days: { [number]: boolean }, -- os.date's wday: 1 is Sunday
	startMinute: number, -- minutes after local midnight
	endMinute: number,
	during: number, -- the limit while at work
	after: number, -- the limit to reach by the end of work, and to keep outside it
}
export type Rules = {
	work: Work?, -- nil while working hours are off or invalid
	workProblem: string?, -- why the settings were rejected, for the panel
	tolerance: number, -- how many percent short of a target still counts as on time
}
export type Override = { limit: number, date: string } -- a manual choice, for that local date
export type Target = { limit: number, deadline: number, waitLimit: number, started: boolean }
export type Intents = {
	override: Override?,
	target: Target?,
	-- "<local date> <end minute>" once that day's end-of-work charge has begun; the end minute
	-- makes an edited end time start over.
	workCharging: string?,
	-- After a target ends without a schedule: the limit it started from, kept until the service
	-- has confirmed the controller holds it.
	restore: number?,
}
export type Rates = { below80: number, from80: number } -- minutes per percent
export type Plan = {
	limit: number?, -- nil leaves the controller alone
	note: string?, -- one line for the panel
	intents: Intents, -- with expired entries dropped and latches set
}

planner.defaultRates = { below80 = 1.0, from80 = 1.6 } :: Rates

function planner.minutesNeeded(from: number, to: number, rates: Rates): number
	local below = math.max(0, math.min(to, 80) - from)
	local above = math.max(0, to - math.max(from, 80))
	return below * rates.below80 + above * rates.from80
end

local function minuteOf(time: number): number
	local wall = os.date("*t", time)
	return wall.hour * 60 + wall.min
end

-- Luau's os.time(table) reads the table as UTC, so a local time is found by moving `now` by the
-- difference in local minutes. If a DST change lies in between, one correction undoes the hour,
-- moving the shorter way round the clock so a time near midnight stays on its day. A time the
-- spring change skips becomes the moment after the gap; a time the autumn change repeats uses the
-- UTC offset that `now` has.
function planner.at(now: number, minuteOfDay: number): number
	local time = now - os.date("*t", now).sec + (minuteOfDay - minuteOf(now)) * 60
	local drift = (minuteOfDay - minuteOf(time) + 720) % 1440 - 720
	local corrected = time + drift * 60
	if minuteOf(corrected) == minuteOfDay then
		return corrected
	elseif minuteOf(time) == minuteOfDay then
		return time
	end
	return math.max(time, corrected) -- the time does not exist: the moment after the gap
end

function planner.parseClock(text: string): number?
	local hour, minute = string.match(text, "^%s*(%d%d?):(%d%d)%s*$")
	local h, m = tonumber(hour), tonumber(minute)
	if h and m and h < 24 and m < 60 then
		return h * 60 + m
	end
	return nil
end

function planner.clock(time: number, now: number): string
	local text = os.date("%H:%M", time)
	if os.date("%Y-%m-%d", time) ~= os.date("%Y-%m-%d", now) then
		return "tomorrow " .. text
	end
	return text
end

-- upower writes one "unix<TAB>percent<TAB>state" row per percent change. A charging session is a
-- run of "charging" rows with rising percent and gaps under 10 minutes. Each step's minutes are
-- split between the bands by the percent it gained in each. A band's rate is the median over the
-- last five sessions with at least three percent in it, the slower middle value for an even count.
function planner.parseHistory(text: string): Rates
	type Session = { minutes: { below80: number, from80: number }, percent: { below80: number, from80: number } }
	local sessions: { Session } = {}
	local current: Session? = nil
	local lastTime, lastPercent = 0, 0
	for line in string.gmatch(text, "[^\n]+") do
		local time, percent, state = string.match(line, "^(%d+)\t([%d.]+)\t(%S+)")
		local t, p = tonumber(time), tonumber(percent)
		if t and p and state == "charging" and current and t > lastTime and t - lastTime < 600 and p > lastPercent then
			local minutesPerPercent = (t - lastTime) / 60 / (p - lastPercent)
			local below = math.max(0, math.min(p, 80) - lastPercent)
			local above = math.max(0, p - math.max(lastPercent, 80))
			current.minutes.below80 += below * minutesPerPercent
			current.minutes.from80 += above * minutesPerPercent
			current.percent.below80 += below
			current.percent.from80 += above
			lastTime, lastPercent = t, p
		elseif t and p and state == "charging" then
			current = { minutes = { below80 = 0, from80 = 0 }, percent = { below80 = 0, from80 = 0 } }
			table.insert(sessions, current :: Session)
			lastTime, lastPercent = t, p
		else
			current = nil
		end
	end
	local function median(band: "below80" | "from80"): number
		local rates = {}
		for index = #sessions, 1, -1 do
			local session = sessions[index]
			if session.percent[band] >= 3 then
				table.insert(rates, session.minutes[band] / session.percent[band])
			end
			if #rates == 5 then
				break
			end
		end
		if #rates == 0 then
			return planner.defaultRates[band]
		end
		table.sort(rates)
		return rates[#rates // 2 + 1]
	end
	return { below80 = median("below80"), from80 = median("from80") }
end

function planner.plan(now: number, charge: number, plugged: boolean, rules: Rules, intents: Intents, rates: Rates): Plan
	local today = os.date("%Y-%m-%d", now)
	local override = intents.override
	if override and (override.date ~= today or rules.work == nil) then
		override = nil
	end
	local target = intents.target and table.clone(intents.target)
	-- A manual choice keeps today's end-of-work latch, so going back on schedule does not drain.
	local workCharging = if intents.workCharging and string.sub(intents.workCharging, 1, #today) == today
		then intents.workCharging
		else nil

	-- What the schedule wants now: a manual choice, else working hours.
	local scheduleLimit: number?, scheduleNote: string? = nil, rules.workProblem
	local work = rules.work
	if override then
		scheduleLimit = override.limit
		scheduleNote = `Your {override.limit}% until midnight`
	elseif work then
		local wall = os.date("*t", now)
		local minute = wall.hour * 60 + wall.min
		if work.days[wall.wday] and minute >= work.startMinute and minute < work.endMinute then
			local latch = `{today} {work.endMinute}`
			local finish = planner.at(now, work.endMinute)
			local start = finish - planner.minutesNeeded(charge, work.after - rules.tolerance, rates) * 60
			if intents.workCharging == latch or now >= start then
				workCharging = latch
				scheduleLimit = work.after
				scheduleNote = `Charging to {work.after}% by {planner.clock(finish, now)}`
			else
				scheduleLimit = work.during
				scheduleNote = `Holding {work.during}% · {work.after}% from {planner.clock(start, now)}`
			end
		else
			scheduleLimit = work.after
			scheduleNote = `{work.after}% outside work hours`
		end
	end

	local limit, note = scheduleLimit, scheduleNote
	local restore = intents.restore
	if target then
		-- A target only ever raises the schedule's limit. It ends once its deadline has passed and
		-- the laptop is unplugged: ending while plugged in would drain it right at the desk.
		local base = scheduleLimit or target.waitLimit
		local deadline = planner.clock(target.deadline, now)
		local start = target.deadline - planner.minutesNeeded(charge, target.limit - rules.tolerance, rates) * 60
		if now >= target.deadline and not plugged then
			restore = target.waitLimit
			target = nil
			limit = base
		elseif now >= target.deadline then
			limit, note = math.max(base, target.limit), `Holding {target.limit}% until unplugged`
		elseif target.started or now >= start then
			target.started = true
			limit, note = math.max(base, target.limit), `Charging to {target.limit}% by {deadline}`
		elseif base < target.limit then
			limit, note = base, `{target.limit}% by {deadline} · from {planner.clock(start, now)}`
		end
	end
	-- A schedule or a running target decides the limit instead of a restore.
	if scheduleLimit ~= nil or target ~= nil then
		restore = nil
	end
	return {
		limit = limit or restore,
		note = note,
		intents = { override = override, target = target, workCharging = workCharging, restore = restore },
	}
end

return planner
