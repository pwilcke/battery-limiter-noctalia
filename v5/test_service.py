import os
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

if len(sys.argv) != 2:
    raise SystemExit("The Luau executable path is required.")

folder = Path(__file__).with_name("framework-charge")
berlin = ZoneInfo("Europe/Berlin")
monday1030 = int(datetime(2026, 10, 26, 10, 30, tzinfo=berlin).timestamp())
monday1300 = int(datetime(2026, 10, 26, 13, 0, tzinfo=berlin).timestamp())

source = f"""
local clock = {monday1030}
local deadline = {monday1300}
"""
source += r"""
local realOs = os
os = { time = function() return clock end, date = realOs.date, clock = realOs.clock }
local config = {
    work_hours = false, work_days = "weekdays", work_start = "08:00", work_end = "16:00",
    work_limit = "50", after_work_limit = "80", tolerance = 3, learn_rates = false,
}
local files = {
    ["/sys/class/power_supply/BAT1/capacity"] = "50\n",
    ["/sys/class/power_supply/BAT1/status"] = "Not charging\n",
    ["/sys/class/power_supply/ACAD/online"] = "1\n",
}
local helperCalls, notifications = {}, {}
local store, watchers = {}, {}
-- JSON stands in as references to copies, so the fake files hold whole tables.
local blobs = {}
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, field in value do out[key] = copy(field) end
    return out
end
noctalia = {
    getConfig = function(key) return config[key] end,
    pluginDataDir = function() return "/data" end,
    fileExists = function(path) return path == "/usr/local/libexec/framework-charge-limit" end,
    readFile = function(path) return files[path] end,
    writeFile = function(path, content) files[path] = content; return true end,
    renameFile = function(from, to) files[to] = files[from]; files[from] = nil; return true end,
    listDir = function() return {} end,
    json = {
        encode = function(value) local key = "#" .. tostring(#blobs + 1); blobs[#blobs + 1] = copy(value); return key end,
        decode = function(text) return copy(blobs[tonumber(string.sub(text, 2))]) end,
    },
    string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
    runAsync = function(argv, done) table.insert(helperCalls, { args = argv, done = done }); return true end,
    notifyError = function(_, message) table.insert(notifications, message) end,
    setUpdateInterval = function() end,
    state = {
        set = function(key, value)
            store[key] = value
            for _, watcher in watchers[key] or {} do watcher(value) end
        end,
        get = function(key) return store[key] end,
        watch = function(key, watcher)
            watchers[key] = watchers[key] or {}
            table.insert(watchers[key], watcher)
        end,
    },
}
-- The helper's answer to its latest call.
local function helper(limit)
    local call = table.remove(helperCalls, 1)
    call.done({ exitCode = 0, timedOut = false, stdout = noctalia.json.encode({ limit = limit, drains = true }), stderr = "" })
end
local sent = 0
local function request(kind, limit, when)
    sent += 1
    noctalia.state.set("request", { id = tostring(sent), kind = kind, limit = limit, deadline = when })
end
local function intents()
    return noctalia.json.decode(files["/data/intents.json"] or "#0") or {}
end
"""
source += "local modules = {}\n"
for name in ("planner", "power"):
    source += (
        f'modules["./{name}.luau"] = (function()\n'
        + folder.joinpath(f"{name}.luau").read_text().replace("--!strict", "")
        + "\nend)()\n"
    )
source += "require = function(path) return modules[path] end\n"
source += (
    "local function startService()\n"
    + folder.joinpath("service.luau").read_text().replace("--!strict", "")
    + "\nend\n"
)
source += r"""
-- Idle: working hours off and no target, so ticks never run the helper.
startService()
update()
clock += 60
update()
assert(#helperCalls == 0, "no helper call while idle")

-- The panel's read is answered and acknowledged.
request("read")
assert(helperCalls[1].args[3] == "read")
helper(50)
assert(store.controller.status == "ready" and store.controller.limit == 50 and store.controller.ack == "1")

-- A target is saved before it is acknowledged, waits, then raises the limit at its start.
request("target", 80, deadline)
assert(store.controller.ack == "2" and intents().target.limit == 80 and intents().target.waitLimit == 50)
assert(#helperCalls == 0 and store.plan.note == "80% by 13:00 · from 12:33")
-- Two hours later the last read is stale, so the service reads first and then writes.
clock = deadline - 26 * 60
update()
assert(helperCalls[1].args[3] == "read")
helper(50)
assert(helperCalls[1].args[3] == "set" and helperCalls[1].args[4] == "80")
assert(store.controller.status == "applying")
helper(80)
assert(store.controller.limit == 80 and intents().target.started == true)
clock += 60
update()
assert(#helperCalls == 0, "a steady plan does not write again")

-- A service restart keeps the target and the acknowledgement; the old request is not replayed.
watchers = {} -- the old runtime and its watchers are gone; noctalia.state stays
startService()
assert(#helperCalls == 1 and helperCalls[1].args[3] == "read", "a restarted service reads before it trusts")
helper(80)
assert(#helperCalls == 0, "the controller already has the planned limit")
assert(store.controller.ack == "2" and intents().target.started == true)

-- Cancelling without a schedule returns to the limit the target started from, through the same
-- check as every write: 20 minutes on, the last confirmation is stale, so it reads first.
clock += 20 * 60
request("cancel")
assert(intents().target == nil and intents().restore == 50 and helperCalls[1].args[3] == "read")
helper(80)
assert(helperCalls[1].args[4] == "50")
helper(50)
assert(store.controller.limit == 50 and intents().restore == nil, "confirmed, so the restore is done")
clock += 60
update()
assert(#helperCalls == 0, "nothing more happens")

-- A malformed request is answered, not acted on.
request("target", 55, deadline)
assert(store.controller.status == "failed" and store.controller.ack == tostring(sent) and #helperCalls == 0)

-- With working hours on, a manual choice is saved as an override, and "schedule" drops it.
config.work_hours = true
onConfigChanged()
assert(#helperCalls == 0 and store.plan.scheduling == true, "the controller already holds 50 %")
request("set", 70)
assert(intents().override.limit == 70 and intents().override.date == "2026-10-26")
assert(helperCalls[1].args[4] == "70")
helper(70)
assert(store.controller.ack == tostring(sent) and store.plan.overridden == true)
request("schedule")
assert(intents().override == nil and helperCalls[1].args[4] == "50")
helper(50)

-- A failed write is reported once and followed by a read.
config.work_limit = "60"
onConfigChanged()
table.remove(helperCalls, 1).done({ exitCode = 1, timedOut = false, stdout = "", stderr = "Controller request failed." })
assert(notifications[#notifications] == "Controller request failed.")
assert(store.controller.status == "reading" and helperCalls[1].args[3] == "read")
helper(50)
assert(store.controller.status == "ready" and store.controller.limit == 50)
assert(#helperCalls == 0, "the failed limit is not retried at once")
clock += 6 * 60
update()
assert(helperCalls[1].args[3] == "read")
helper(50)
assert(helperCalls[1].args[4] == "60", "after the pause it tries again")
helper(60)

-- A plan that cannot be saved does nothing: an unsaved latch would switch back at the next tick.
config.work_limit = "50"
clock = deadline + 2 * 3600 + 40 * 60 -- 15:40, inside the end-of-work charge
noctalia.writeFile = function() return false end
update()
assert(#helperCalls == 0, "no write without a saved latch")
noctalia.writeFile = function(path, content) files[path] = content; return true end
update()
assert(helperCalls[1].args[3] == "read")
helper(50)
assert(helperCalls[1].args[4] == "80" and intents().workCharging == "2026-10-26 960")
helper(80)

-- After a sleep, a failed read keeps the confirmation stale: the next tick reads again.
clock += 4 * 60
update()
table.remove(helperCalls, 1).done({ exitCode = 1, timedOut = false, stdout = "", stderr = "Busy." })
clock += 60
update()
assert(helperCalls[1].args[3] == "read", "still reading, not writing from an old confirmation")
helper(80)

-- Invalid working hours leave the controller alone and say why.
config.work_end = "07:00"
onConfigChanged()
assert(#helperCalls == 0 or helperCalls[1].args[4] ~= "60")
assert(store.plan.note == "Working hours: check Settings")
print("Idle, read, target wait and start, restart, cancel, override, back on schedule, failure, and invalid settings flows passed.")
"""

with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "service.luau"
    test.write_text(source)
    subprocess.run(
        [sys.argv[1], str(test)], check=True, env={**os.environ, "TZ": "Europe/Berlin"}
    )
