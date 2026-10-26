--!strict
-- The battery as sysfs shows it, for the panel and the service.
local power = {}

export type Activity = "charging" | "holding" | "draining" | "on battery"

-- A Framework has only BAT1 and calls its charger ACAD; a ThinkPad has BAT0 and AC.
power.batteryPath = if noctalia.fileExists("/sys/class/power_supply/BAT0/capacity")
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
	local percent = tonumber(read(power.batteryPath .. "capacity"))
	return if percent and percent >= 0 and percent <= 100 then percent else nil
end

function power.plugged(): boolean?
	local online = read(chargerPath)
	return if online == nil then nil else online ~= "0"
end

function power.activity(): Activity?
	local status, plugged = read(power.batteryPath .. "status"), power.plugged()
	if status == nil or plugged == nil then
		return nil
	elseif not plugged then
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

-- upower names its history after the battery's model and serial number.
function power.historyPath(): string?
	local model, serial = read(power.batteryPath .. "model_name"), read(power.batteryPath .. "serial_number")
	local names = noctalia.listDir("/var/lib/upower")
	if model == nil or serial == nil or names == nil then
		return nil
	end
	local prefix, suffix = "history-charge-" .. model .. "-", "-" .. serial .. ".dat"
	for _, name in names do
		if string.sub(name, 1, #prefix) == prefix and string.sub(name, -#suffix) == suffix then
			return "/var/lib/upower/" .. name
		end
	end
	return nil
end

return power
