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
    "mon1000": at("2026-10-26 10:00"),
    "mon1300": at("2026-10-26 13:00"),
    "tue1000": at("2026-10-27 10:00"),
    "dst0100": at("2026-10-25 01:00"),
    "dst0400": at("2026-10-25 04:00"),
    "spring0030": at("2026-03-29 00:30"),
    "spring0330": at("2026-03-29 03:30"),
    "spring2330": at("2026-03-29 23:30"),
    "spring0400": at("2026-03-29 04:00"),
    "sat2330": at("2026-03-28 23:30"),
    "sun0700": at("2026-03-29 07:00"),
    "dst0030": at("2026-10-25 00:30"),
    "dst0015": at("2026-10-26 00:15"),
}
source = "local clock = (function()\n"
source += (
    Path(__file__)
    .with_name("chargelimit")
    .joinpath("clock.luau")
    .read_text()
    .replace("--!strict", "")
)
source += "\nend)()\n"
source += "local T = {\n" + "".join(f"  {k} = {v},\n" for k, v in times.items()) + "}\n"
source += r"""
assert(clock.parse("08:00") == 480 and clock.parse(" 7:05 ") == 425)
assert(clock.parse("24:00") == nil and clock.parse("8") == nil)
assert(clock.at(T.dst0100, 240) == T.dst0400, "04:00 after the autumn change")
assert(clock.at(T.spring0030, 150) == T.spring0330, "02:30 does not exist; the moment after the gap")
assert(clock.at(T.spring0030, 1410) == T.spring2330, "23:30 stays on the day of the change")
assert(clock.at(T.spring0400, 150) == T.spring0330, "asked from later that day, 02:30 still means 03:30")
for _, case in {
    { T.mon1000, 780, T.mon1300, "later today" },
    { T.mon1300, 600, T.tue1000, "earlier, so tomorrow" },
    { T.mon1000, 600, T.tue1000, "this very minute, so tomorrow" },
    { T.sat2330, 420, T.sun0700, "the night before the spring change: not the day after tomorrow" },
    { T.dst0030, 15, T.dst0015, "the autumn change's long day: not today again" },
} do
    assert(clock.upcoming(case[1], case[2]) == case[3], case[4])
end
print("Clock parsing, DST, and upcoming passed.")
"""

with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "clock.luau"
    test.write_text(source)
    subprocess.run(
        [sys.argv[1], str(test)], check=True, env={**os.environ, "TZ": "Europe/Berlin"}
    )
