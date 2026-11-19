import os
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

if len(sys.argv) != 2:
    raise SystemExit("The Luau executable path is required.")

folder = Path(__file__).with_name("chargelimit")
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
local cli = "/usr/local/bin/chargelimit"
local statusPath = "/run/chargelimit/status.json"
local config = {
    work_hours = false, work_days = "mon_sat", work_start = "08:00", work_end = "16:00",
    work_limit = "50", after_work_limit = "80", tolerance = 3, learn_rates = false,
}
local mapped = {
    ["work-hours"] = "off", ["work-days"] = "mon-sat", ["work-start"] = "08:00", ["work-end"] = "16:00",
    ["work-limit"] = "50", ["after-work-limit"] = "80", ["tolerance"] = "3", ["learn-rates"] = "off",
}
local files = {}
local calls, notifications = {}, {}
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
    fileExists = function(path) return path == cli end,
    readFile = function(path) return files[path] end,
    json = {
        encode = function(value) local key = "#" .. tostring(#blobs + 1); blobs[#blobs + 1] = copy(value); return key end,
        decode = function(text) return copy(blobs[tonumber(string.sub(text, 2))]) end,
    },
    string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
    runAsync = function(argv, done) table.insert(calls, { args = argv, done = done }); return true end,
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
local idle = { scheduling = false, overridden = false }
local current = { limit = 50, drains = true, plan = idle, settings = copy(mapped) }
current.settings["work-hours"] = "on"
-- The daemon reconciles: the status file gets these changes and a fresh time.
local function daemon(changes)
    for key, value in changes or {} do current[key] = value end
    current.at = clock
    current.error = (changes or {}).error
    files[statusPath] = noctalia.json.encode(current)
    return files[statusPath]
end
local function args()
    return table.concat(calls[1].args, " ")
end
local function answer(changes)
    table.remove(calls, 1).done({ exitCode = 0, timedOut = false, stdout = daemon(changes), stderr = "" })
end
local function fail(message)
    table.remove(calls, 1).done({ exitCode = 1, timedOut = false, stdout = "", stderr = message .. "\n" })
end
local sent = 0
local function request(kind, limit, when)
    sent += 1
    noctalia.state.set("request", { id = tostring(sent), kind = kind, limit = limit, deadline = when })
end
"""
source += (
    "local function startService()\n"
    + folder.joinpath("service.luau").read_text().replace("--!strict", "")
    + "\nend\n"
)
source += r"""
-- Start-up: the daemon's schedule differs from this plugin's settings, so all of them are sent.
daemon()
startService()
assert(store.controller.status == "ready" and store.controller.limit == 50)
assert(args() == cli .. " config work-hours=off work-days=mon-sat work-start=08:00 work-end=16:00"
    .. " work-limit=50 after-work-limit=80 tolerance=3 learn-rates=off", args())
answer({ settings = copy(mapped) })
assert(#calls == 0 and store.controller.status == "ready")

-- A read takes the status file as it is now.
daemon({ limit = 60 })
request("read")
assert(#calls == 0 and store.controller.limit == 60 and store.controller.ack == "1")

-- A set shows the spinner's target until the CLI answers.
request("set", 80)
assert(args() == cli .. " set 80")
assert(store.controller.status == "applying" and store.controller.target == 80 and store.controller.ack == "1")
answer({ limit = 80 })
assert(store.controller.status == "ready" and store.controller.limit == 80 and store.controller.target == nil)
assert(store.controller.ack == "2")

-- Charge by, cancel, and back on schedule each run one command; its answer carries the plan.
request("target", 100, deadline)
assert(args() == cli .. " charge-by 100 @" .. deadline)
answer({ plan = { note = "100% by 13:00 · from 12:02", scheduling = false, overridden = false,
    target = { limit = 100, deadline = deadline } } })
assert(store.controller.ack == "3" and store.plan.target.limit == 100 and store.plan.note == "100% by 13:00 · from 12:02")
request("cancel")
assert(args() == cli .. " charge-by off")
answer({ plan = idle })
assert(store.controller.ack == "4" and store.plan.target == nil)
request("schedule")
assert(args() == cli .. " resume")
answer({ plan = { note = "Holding 50% · 80% from 15:33", scheduling = true, overridden = false } })
assert(store.controller.ack == "5" and store.plan.scheduling == true)

-- A failed command is reported, then the panel gets the daemon's status back.
local seen = {}
noctalia.state.watch("controller", function(controller) table.insert(seen, controller.status) end)
request("set", 70)
fail("Request dismissed.")
assert(notifications[#notifications] == "Request dismissed.")
assert(table.concat(seen, " ") == "applying failed ready", table.concat(seen, " "))
assert(store.controller.limit == 80 and store.controller.ack == "6")
assert(store.plan.note == "Holding 50% · 80% from 15:33", "the plan stays")

-- A settings change sends all settings; changes made meanwhile share one waiting command.
config.work_hours = true
onConfigChanged()
config.work_start = "8:61"
onConfigChanged()
onConfigChanged()
assert(string.find(args(), "work-hours=on work-days=mon-sat work-start=08:00", 1, true))
answer()
assert(#calls == 1 and string.find(args(), "work-start=8:61", 1, true))
fail("The setting work-start must be a 24-hour time like 08:00, got '8:61'.")
assert(#calls == 0 and notifications[#notifications] == "The setting work-start must be a 24-hour time like 08:00, got '8:61'.")
assert(store.controller.status == "ready" and store.controller.ack == "6")

-- Every minute the status file is read again, so the daemon's own changes appear.
clock += 60
daemon({ limit = 50 })
update()
assert(#calls == 0 and store.controller.status == "ready" and store.controller.limit == 50)
daemon({ error = "No battery was found." })
update()
assert(store.controller.status == "failed" and store.controller.message == "No battery was found.")

-- An old or missing status file means the daemon is not running; that is reported once.
clock += 4 * 60
update()
assert(store.controller.status == "failed" and store.controller.message == "The chargelimit service is not running.")
assert(store.plan.note == nil)
local reported = #notifications
files[statusPath] = nil
clock += 60
update()
assert(#notifications == reported and store.controller.message == "The chargelimit service is not running.")

-- A malformed request is answered, not acted on.
daemon()
request("target", 55, deadline)
assert(store.controller.status == "failed" and store.controller.ack == tostring(sent) and #calls == 0)

-- A restart with matching settings runs nothing and does not replay the last request.
config.work_start = "08:00"
daemon({ settings = { ["work-hours"] = "on", ["work-days"] = "mon-sat", ["work-start"] = "08:00",
    ["work-end"] = "16:00", ["work-limit"] = "50", ["after-work-limit"] = "80", ["tolerance"] = "3",
    ["learn-rates"] = "off" } })
watchers = {} -- the old runtime and its watchers are gone; noctalia.state stays
startService()
assert(#calls == 0 and store.controller.status == "ready" and store.controller.ack == tostring(sent))
print("Start-up settings push, read, set, charge-by, cancel, resume, failure, settings change, minute re-read, not running, and restart flows passed.")
"""

with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "service.luau"
    test.write_text(source)
    subprocess.run(
        [sys.argv[1], str(test)], check=True, env={**os.environ, "TZ": "Europe/Berlin"}
    )
