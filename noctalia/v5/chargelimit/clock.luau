--!strict
-- Local wall-clock times for the panel's "charge by" editor. It uses no noctalia.*, so its tests
-- can load it alone.
local clock = {}

local function minuteOf(time: number): number
	local wall = os.date("*t", time)
	return wall.hour * 60 + wall.min
end

-- Luau's os.time(table) reads the table as UTC, so a local time is found by moving `now` by the
-- difference in local minutes. If a DST change lies in between, one correction undoes the hour,
-- moving the shorter way round the clock so a time near midnight stays on its day. A time the
-- spring change skips becomes the moment after the gap; a time the autumn change repeats uses the
-- UTC offset that `now` has.
function clock.at(now: number, minuteOfDay: number): number
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

-- The next moment the clock shows minuteOfDay: today if that is still ahead, else tomorrow. A day
-- with a DST change has 23 or 25 hours, so tomorrow is found from its noon, not from now + 24 hours.
function clock.upcoming(now: number, minuteOfDay: number): number
	local today = clock.at(now, minuteOfDay)
	if today > now then
		return today
	end
	return clock.at(clock.at(now, 12 * 60) + 24 * 3600, minuteOfDay)
end

function clock.parse(text: string): number?
	local hour, minute = string.match(text, "^%s*(%d%d?):(%d%d)%s*$")
	local h, m = tonumber(hour), tonumber(minute)
	if h and m and h < 24 and m < 60 then
		return h * 60 + m
	end
	return nil
end

return clock
