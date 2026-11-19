--!strict
-- The battery as sysfs shows it, for the panel's status line.
local power = {}

export type Activity = "charging" | "holding" | "draining" | "on battery"

-- A Framework has only BAT1 and calls its charger ACAD; a ThinkPad has BAT0 and AC.
local batteryPath = if noctalia.fileExists("/sys/class/power_supply/BAT0/capacity")
	then "/sys/class/power_supply/BAT0/"
	else "/sys/class/power_supply/BAT1/"
local chargerPath = if noctalia.fileExists("/sys/class/power_supply/AC/online")
	then "/sys/class/power_supply/AC/online"
	else "/sys/class/power_supply/ACAD/online"

local function read(path: string): string?
	local text = noctalia.readFile(path)
	return text and noctalia.string.trim(text)
end

function power.charge(): number?
	local percent = tonumber(read(batteryPath .. "capacity"))
	return if percent and percent >= 0 and percent <= 100 then percent else nil
end

function power.activity(): Activity?
	local status, online = read(batteryPath .. "status"), read(chargerPath)
	if status == nil or online == nil then
		return nil
	elseif online == "0" then
		return "on battery"
	elseif status == "Charging" then
		return "charging"
	elseif status == "Discharging" then
		return "draining"
	elseif status == "Not charging" or status == "Full" then
		return "holding"
	end
	return nil
end

return power
