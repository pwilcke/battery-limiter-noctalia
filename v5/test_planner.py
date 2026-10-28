import os
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

if len(sys.argv) != 2:
    raise SystemExit("The Luau executable path is required.")

berlin = ZoneInfo("Europe/Berlin")


def at(text):
    return int(
        datetime.strptime(text, "%Y-%m-%d %H:%M").replace(tzinfo=berlin).timestamp()
    )


# 2026-10-26 is a Monday; Berlin leaves daylight saving time at 03:00 on 2026-10-25.
times = {
    "mon0700": at("2026-10-26 07:00"),
    "mon1000": at("2026-10-26 10:00"),
    "mon1030": at("2026-10-26 10:30"),
    "mon1240": at("2026-10-26 12:40"),
    "mon1300": at("2026-10-26 13:00"),
    "mon1310": at("2026-10-26 13:10"),
    "mon1534": at("2026-10-26 15:34"),
    "mon1540": at("2026-10-26 15:40"),
    "mon1600": at("2026-10-26 16:00"),
    "tue1000": at("2026-10-27 10:00"),
    "sat1000": at("2026-10-31 10:00"),
    "dst0100": at("2026-10-25 01:00"),
    "dst0400": at("2026-10-25 04:00"),
    "spring0030": at("2026-03-29 00:30"),
    "spring0330": at("2026-03-29 03:30"),
    "spring2330": at("2026-03-29 23:30"),
    "spring0400": at("2026-03-29 04:00"),
    "mon2000": at("2026-10-26 20:00"),
    "sat2330": at("2026-03-28 23:30"),
    "sun0700": at("2026-03-29 07:00"),
    "dst0030": at("2026-10-25 00:30"),
    "dst0015": at("2026-10-26 00:15"),
}
source = "local planner = (function()\n"
source += (
    Path(__file__)
    .with_name("framework-charge")
    .joinpath("planner.luau")
    .read_text()
    .replace("--!strict", "")
)
source += "\nend)()\n"
source += "local T = {\n" + "".join(f"  {k} = {v},\n" for k, v in times.items()) + "}\n"
source += r"""
local rates = { below80 = 1.0, from80 = 1.6 }
local work = { days = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }, startMinute = 480, endMinute = 960, during = 50, after = 80 }
local scheduled = { work = work, tolerance = 3 }
local plain = { tolerance = 3 }
local function target(limit, deadline, started)
    return { limit = limit, deadline = deadline, waitLimit = 50, started = started or false }
end

assert(planner.minutesNeeded(70, 90, rates) == 26)
assert(planner.minutesNeeded(90, 80, rates) == 0)
assert(planner.parseClock("08:00") == 480 and planner.parseClock(" 7:05 ") == 425)
assert(planner.parseClock("24:00") == nil and planner.parseClock("8") == nil)
assert(planner.at(T.dst0100, 240) == T.dst0400, "04:00 after the autumn change")
assert(planner.at(T.spring0030, 150) == T.spring0330, "02:30 does not exist; the moment after the gap")
assert(planner.at(T.spring0030, 1410) == T.spring2330, "23:30 stays on the day of the change")
assert(planner.at(T.spring0400, 150) == T.spring0330, "asked from later that day, 02:30 still means 03:30")
assert(planner.clock(T.tue1000, T.mon1000) == "Tue 10:00")
for _, case in {
    { T.mon1000, 780, T.mon1300, "later today" },
    { T.mon1300, 600, T.tue1000, "earlier, so tomorrow" },
    { T.mon1000, 600, T.tue1000, "this very minute, so tomorrow" },
    { T.sat2330, 420, T.sun0700, "the night before the spring change: not the day after tomorrow" },
    { T.dst0030, 15, T.dst0015, "the autumn change's long day: not today again" },
} do
    assert(planner.upcoming(case[1], case[2]) == case[3], case[4])
end

-- now, charge, plugged, rules, intents -> limit, note, and what the intents become
local cases = {
    { T.mon0700, 70, true, scheduled, {}, 80, "80% outside work hours" },
    { T.sat1000, 70, true, scheduled, {}, 80, "80% outside work hours" },
    { T.mon1000, 50, true, scheduled, {}, 50, "Holding 50% · 80% from 15:33" },
    { T.mon1540, 50, true, scheduled, {}, 80, "Charging to 80% by 16:00" },
    -- once the end-of-work charge has begun it stays on, though at 53 % the start would be 15:36
    { T.mon1534, 53, true, scheduled, { workCharging = "2026-10-26 960" }, 80, "Charging to 80% by 16:00" },
    { T.mon1000, 50, true, scheduled, { override = { limit = 60, date = "2026-10-26" } }, 60, "Your 60% until midnight" },
    { T.tue1000, 50, true, scheduled, { override = { limit = 60, date = "2026-10-26" } }, 50, "Holding 50% · 80% from 15:33" },
    { T.mon1000, 50, true, plain, { override = { limit = 60, date = "2026-10-26" } }, nil, nil },
    { T.mon1000, 50, true, { tolerance = 3, workProblem = "Working hours: check Settings" }, {}, nil, "Working hours: check Settings" },
    { T.mon1030, 50, true, plain, { target = target(80, T.mon1300) }, 50, "80% by 13:00 · from 12:33" },
    { T.mon1030, 50, true, { tolerance = 10 }, { target = target(80, T.mon1300) }, 50, "80% by 13:00 · from 12:40" },
    { T.mon1240, 50, true, plain, { target = target(80, T.mon1300) }, 80, "Charging to 80% by 13:00" },
    { T.mon1030, 55, true, plain, { target = target(80, T.mon1300, true) }, 80, "Charging to 80% by 13:00" },
    { T.mon1310, 78, true, plain, { target = target(80, T.mon1300, true) }, 80, "Holding 80% until unplugged" },
    { T.mon1310, 78, false, plain, { target = target(80, T.mon1300, true) }, 50, nil },
    { T.mon1000, 50, true, scheduled, { target = target(100, T.mon1300) }, 50, "100% by 13:00 · from 12:02" },
    -- a latch for another end time does not hold: the end time was edited
    { T.mon1534, 53, true, scheduled, { workCharging = "2026-10-26 900" }, 50, "Holding 50% · 80% from 15:36" },
    -- the schedule already holds more than the target, which waits for tomorrow's drop instead of ending
    { T.mon2000, 80, true, scheduled, { target = target(80, T.tue1000 + 3 * 3600) }, 80, "80% outside work hours" },
    { T.tue1000, 50, true, scheduled, { target = target(80, T.tue1000 + 3 * 3600) }, 50, "80% by 13:00 · from 12:33" },
}
for index, case in cases do
    local result = planner.plan(case[1], case[2], case[3], case[4], case[5], rates)
    assert(result.limit == case[6], `case {index}: limit {result.limit}`)
    assert(result.note == case[7], `case {index}: note {result.note}`)
end

local latched = planner.plan(T.mon1240, 50, true, plain, { target = target(80, T.mon1300) }, rates)
assert(latched.intents.target.started == true)
local ended = planner.plan(T.mon1310, 78, false, plain, { target = target(80, T.mon1300, true) }, rates)
assert(ended.intents.target == nil and ended.intents.restore == 50 and ended.limit == 50)
-- The restore keeps asking for the old limit until the service confirms it, unless a schedule decides.
assert(planner.plan(T.mon1310, 78, false, plain, { restore = 50 }, rates).limit == 50)
local scheduledRestore = planner.plan(T.mon1000, 78, true, scheduled, { restore = 70 }, rates)
assert(scheduledRestore.limit == 50 and scheduledRestore.intents.restore == nil)
-- A manual choice keeps the latch, so going back on schedule keeps charging.
local held = planner.plan(T.mon1534, 53, true, scheduled, { override = { limit = 80, date = "2026-10-26" }, workCharging = "2026-10-26 960" }, rates)
assert(held.limit == 80 and held.intents.workCharging == "2026-10-26 960")
local resumed = planner.plan(T.mon1534, 53, true, scheduled, { workCharging = held.intents.workCharging }, rates)
assert(resumed.limit == 80, "back on schedule after the latch: still charging")
local expired = planner.plan(T.tue1000, 50, true, scheduled, { override = { limit = 60, date = "2026-10-26" }, workCharging = "2026-10-26 960" }, rates)
assert(expired.intents.override == nil and expired.intents.workCharging == nil)

-- Two sessions: below 80 one at 1 and one at 0.5 minutes per percent, the median takes the slower;
-- from 80 only one with three steps at 2. An "unknown" row ends a session.
local history = table.concat({
    "1000\t50.000\tcharging", "1060\t51.000\tcharging", "1120\t52.000\tcharging", "1180\t53.000\tcharging",
    "1200\t0.000\tunknown",
    "5000\t60.000\tcharging", "5030\t61.000\tcharging", "5060\t62.000\tcharging", "5090\t63.000\tcharging",
    "9000\t79.000\tcharging", "9120\t80.000\tcharging", "9240\t81.000\tcharging", "9360\t82.000\tcharging",
    "9480\t83.000\tcharging", "not a row",
}, "\n")
local learned = planner.parseHistory(history)
assert(learned.below80 == 1 and learned.from80 == 2, `learned {learned.below80} {learned.from80}`)
-- A step from 78 to 82 % gains two percent in each band, so its minutes split evenly.
local split = planner.parseHistory(table.concat({
    "100\t75.000\tcharging", "160\t76.000\tcharging", "220\t77.000\tcharging", "280\t78.000\tcharging",
    "520\t82.000\tcharging", "580\t83.000\tcharging",
}, "\n"))
assert(split.below80 == 1 and split.from80 == 1, `split {split.below80} {split.from80}`)
local fallback = planner.parseHistory("")
assert(fallback.below80 == 1.0 and fallback.from80 == 1.6)
print("Working hours, manual hold, charge-by targets, latches, DST, and learned rates passed.")
"""

with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "planner.luau"
    test.write_text(source)
    subprocess.run(
        [sys.argv[1], str(test)], check=True, env={**os.environ, "TZ": "Europe/Berlin"}
    )
