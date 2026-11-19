import contextlib
from datetime import datetime
import io
import json
import os
from pathlib import Path
import runpy
import tempfile
import time
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo

os.environ["TZ"] = "Europe/Berlin"
time.tzset()
# run_path returns a copy of the globals; the functions read the real ones, which the tests patch.
program = runpy.run_path(str(Path(__file__).with_name("chargelimit")))["main"].__globals__
State, Settings, Target, Override, Power, Rates = (
    program[name] for name in ("State", "Settings", "Target", "Override", "Power", "Rates")
)
berlin = ZoneInfo("Europe/Berlin")


def at(text):
    return int(datetime.strptime(text, "%Y-%m-%d %H:%M").replace(tzinfo=berlin).timestamp())


# 2026-10-26 is a Monday; Berlin leaves daylight saving time at 03:00 on 2026-10-25 and enters
# it at 02:00 on 2026-03-29.
mon0700, mon1000, mon1030, mon1240 = at("2026-10-26 07:00"), at("2026-10-26 10:00"), at("2026-10-26 10:30"), at("2026-10-26 12:40")
mon1300, mon1310, mon1534, mon1540 = at("2026-10-26 13:00"), at("2026-10-26 13:10"), at("2026-10-26 15:34"), at("2026-10-26 15:40")
mon2000, tue1000, sat1000 = at("2026-10-26 20:00"), at("2026-10-27 10:00"), at("2026-10-31 10:00")
rates = Rates(1.0, 1.6)
work = Settings(work_hours=True)
plain = Settings()


def target(limit, deadline, started=False):
    return Target(limit, deadline, started)


class Planner(unittest.TestCase):
    def test_clocks_and_local_times(self):
        self.assertEqual(program["minutes_needed"](70, 90, rates), 26)
        self.assertEqual(program["minutes_needed"](90, 80, rates), 0)
        for text, minute in [("08:00", 480), (" 7:05 ", 425), ("24:00", None), ("8", None)]:
            self.assertEqual(program["parse_clock"](text), minute, text)
        for now, minute, expected, why in [
            (at("2026-10-25 01:00"), 240, at("2026-10-25 04:00"), "04:00 after the autumn change"),
            (at("2026-03-29 00:30"), 150, at("2026-03-29 03:30"), "02:30 does not exist: the moment after the gap"),
            (at("2026-03-29 00:30"), 1410, at("2026-03-29 23:30"), "23:30 stays on the day of the change"),
            (at("2026-03-29 04:00"), 150, at("2026-03-29 03:30"), "asked later that day, 02:30 still means 03:30"),
        ]:
            self.assertEqual(program["at"](now, minute), expected, why)
        for now, minute, expected, why in [
            (mon1000, 780, mon1300, "later today"),
            (mon1300, 600, tue1000, "earlier, so tomorrow"),
            (mon1000, 600, tue1000, "this very minute, so tomorrow"),
            (at("2026-03-28 23:30"), 420, at("2026-03-29 07:00"), "the night before the spring change"),
            (at("2026-10-25 00:30"), 15, at("2026-10-26 00:15"), "the autumn change's long day: not today again"),
        ]:
            self.assertEqual(program["upcoming"](now, minute), expected, why)
        self.assertEqual(program["clock"](tue1000, mon1000), "Tue 10:00")
        self.assertEqual(program["clock"](mon1300, mon1000), "13:00")

    def test_plan(self):
        # now, charge, plugged, settings, intents -> limit and note; chosen is 50 throughout
        for index, (now, charge, plugged, settings, intents, limit, note) in enumerate([
            (mon0700, 70, True, work, {}, 80, "80% outside work hours"),
            (sat1000, 70, True, work, {}, 80, "80% outside work hours"),
            (mon1000, 50, True, work, {}, 50, "Holding 50% · 80% from 15:33"),
            (mon1540, 50, True, work, {}, 80, "Charging to 80% by 16:00"),
            # once the end-of-work charge has begun it stays on, though at 53 % the start would be 15:36
            (mon1534, 53, True, work, {"work_charging": "2026-10-26 960"}, 80, "Charging to 80% by 16:00"),
            (mon1000, 50, True, work, {"override": Override(60, "2026-10-26")}, 60, "Your 60% until midnight"),
            (tue1000, 50, True, work, {"override": Override(60, "2026-10-26")}, 50, "Holding 50% · 80% from 15:33"),
            (mon1000, 50, True, plain, {"override": Override(60, "2026-10-26")}, 50, None),
            (mon1000, 50, True, Settings(work_hours=True, work_end=420), {}, 50, "Working hours: check Settings"),
            (mon1030, 50, True, plain, {"target": target(80, mon1300)}, 50, "80% by 13:00 · from 12:33"),
            (mon1030, 50, True, Settings(tolerance=10), {"target": target(80, mon1300)}, 50, "80% by 13:00 · from 12:40"),
            (mon1240, 50, True, plain, {"target": target(80, mon1300)}, 80, "Charging to 80% by 13:00"),
            (mon1030, 55, True, plain, {"target": target(80, mon1300, True)}, 80, "Charging to 80% by 13:00"),
            (mon1310, 78, True, plain, {"target": target(80, mon1300, True)}, 80, "Holding 80% until unplugged"),
            (mon1310, 78, False, plain, {"target": target(80, mon1300, True)}, 50, None),
            (mon1000, 50, True, work, {"target": target(100, mon1300)}, 50, "100% by 13:00 · from 12:02"),
            # a latch for another end time does not hold: the end time was edited
            (mon1534, 53, True, work, {"work_charging": "2026-10-26 900"}, 50, "Holding 50% · 80% from 15:36"),
            # the schedule already holds more than the target, which waits for tomorrow's drop
            (mon2000, 80, True, work, {"target": target(80, tue1000 + 3 * 3600)}, 80, "80% outside work hours"),
            (tue1000, 50, True, work, {"target": target(80, tue1000 + 3 * 3600)}, 50, "80% by 13:00 · from 12:33"),
        ]):
            result = program["plan"](now, Power(charge, plugged), State(50, settings, **intents), rates)
            self.assertEqual((result.limit, result.note), (limit, note), f"case {index}")

    def test_plan_latches_and_expiry(self):
        plan = program["plan"]
        latched = plan(mon1240, Power(50, True), State(50, plain, target=target(80, mon1300)), rates)
        self.assertTrue(latched.state.target.started)
        ended = plan(mon1310, Power(78, False), State(50, plain, target=target(80, mon1300, True)), rates)
        self.assertEqual((ended.state.target, ended.limit), (None, 50))
        # A manual choice keeps the latch, so going back on schedule keeps charging.
        held = plan(mon1534, Power(53, True), State(80, work, override=Override(80, "2026-10-26"), work_charging="2026-10-26 960"), rates)
        self.assertEqual((held.limit, held.state.work_charging), (80, "2026-10-26 960"))
        resumed = plan(mon1534, Power(53, True), State(80, work, work_charging=held.state.work_charging), rates)
        self.assertEqual(resumed.limit, 80)
        expired = plan(tue1000, Power(50, True), State(50, work, override=Override(60, "2026-10-26"), work_charging="2026-10-26 960"), rates)
        self.assertEqual((expired.state.override, expired.state.work_charging), (None, None))

    def test_history(self):
        parse = program["parse_history"]
        # Two sessions: below 80 one at 1 and one at 0.5 minutes per percent, the median takes
        # the slower; from 80 only one with three steps at 2. An "unknown" row ends a session.
        history = "\n".join([
            "1000\t50.000\tcharging", "1060\t51.000\tcharging", "1120\t52.000\tcharging", "1180\t53.000\tcharging",
            "1200\t0.000\tunknown",
            "5000\t60.000\tcharging", "5030\t61.000\tcharging", "5060\t62.000\tcharging", "5090\t63.000\tcharging",
            "9000\t79.000\tcharging", "9120\t80.000\tcharging", "9240\t81.000\tcharging", "9360\t82.000\tcharging",
            "9480\t83.000\tcharging", "not a row",
        ])
        self.assertEqual(parse(history), Rates(1, 2))
        # A step from 78 to 82 % gains two percent in each band, so its minutes split evenly.
        split = "\n".join([
            "100\t75.000\tcharging", "160\t76.000\tcharging", "220\t77.000\tcharging", "280\t78.000\tcharging",
            "520\t82.000\tcharging", "580\t83.000\tcharging",
        ])
        self.assertEqual(parse(split), Rates(1, 1))
        self.assertEqual(parse(""), Rates(1.0, 1.6))


class Flow(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.supply = self.root / "power_supply"
        for path, text in {
            "BAT0/type": "Battery", "BAT0/capacity": "70", "BAT0/status": "Not charging",
            "BAT0/charge_control_start_threshold": "75", "BAT0/charge_control_end_threshold": "80",
            "BAT0/charge_behaviour": "[auto] inhibit-charge force-discharge",
            "BAT0/model_name": "5B10W51867", "BAT0/serial_number": "1234",
            "AC/type": "Mains", "AC/online": "1",
            "ucsi-source-psy-USBC000:001/type": "USB", "ucsi-source-psy-USBC000:001/online": "0",
        }.items():
            (self.supply / path).parent.mkdir(parents=True, exist_ok=True)
            (self.supply / path).write_text(text + "\n")
        self.vendor = self.root / "sys_vendor"
        self.vendor.write_text("LENOVO\n")
        program.update(
            POWER_SUPPLY=self.supply, DMI_VENDOR=self.vendor, STATE=self.root / "lib" / "state.json",
            RUN=self.root / "run", TOOL=self.root / "framework_tool", UPOWER=self.root / "upower",
            wake_daemon=lambda: None,
        )
        self.clock = mon1030
        for patcher in (patch("os.geteuid", return_value=0), patch("time.time", lambda: self.clock)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def battery(self, name):
        return (self.supply / "BAT0" / name).read_text().strip()

    def run_cli(self, *arguments):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            program["main"](list(arguments))
        return json.loads(output.getvalue())

    def tick(self):
        return program["reconcile"](None, may_drain=True)

    def test_thinkpad(self):
        with self.assertRaisesRegex(ValueError, "not running"):
            self.run_cli("status", "--json")

        # The first run adopts the limit the hardware holds.
        self.assertEqual(self.tick()["limit"], 80)
        # A start threshold another tool left behind is put back.
        (self.supply / "BAT0/charge_control_start_threshold").write_text("40\n")
        self.assertEqual(self.tick()["limit"], 80)
        self.assertEqual(self.battery("charge_control_start_threshold"), "75")
        self.assertEqual(json.loads(program["STATE"].read_text())["chosen"], 80)

        # A lower limit is set at once; the CLI never drains, the next daemon tick does.
        status = self.run_cli("set", "60")
        self.assertEqual((status["limit"], status["drains"]), (60, True))
        self.assertEqual((self.battery("charge_control_start_threshold"), self.battery("charge_control_end_threshold")), ("55", "60"))
        self.assertEqual(self.battery("charge_behaviour"), "[auto] inhibit-charge force-discharge")
        self.tick()
        self.assertEqual(self.battery("charge_behaviour"), "force-discharge")
        (self.supply / "BAT0/capacity").write_text("60\n")
        self.tick()
        self.assertEqual(self.battery("charge_behaviour"), "auto")

        # charge-by waits until the last moment it needs, then raises the limit.
        status = self.run_cli("charge-by", "80", f"@{mon1300}")
        self.assertEqual((status["limit"], status["plan"]["note"]), (60, "80% by 13:00 · from 12:43"))
        self.assertEqual(status["plan"]["target"], {"limit": 80, "deadline": mon1300})
        self.clock = at("2026-10-26 12:45")
        self.assertEqual(self.tick()["limit"], 80)
        # After the deadline it holds until unplugged, then falls back to the chosen limit.
        self.clock = mon1310
        self.assertEqual(self.tick()["plan"]["note"], "Holding 80% until unplugged")
        (self.supply / "AC/online").write_text("0\n")
        status = self.tick()
        self.assertEqual((status["limit"], status["plan"]["target"]), (60, None))

        # Working hours hold 50 %; a manual choice holds until midnight; resume drops it.
        status = self.run_cli("config", "work-hours=on", "tolerance=3")
        self.assertEqual((status["limit"], status["plan"]["note"], status["plan"]["scheduling"]), (50, "Holding 50% · 80% from 15:43", True))
        self.assertEqual(status["settings"]["work-hours"], "on")
        status = self.run_cli("set", "70")
        self.assertEqual((status["limit"], status["plan"]["note"], status["plan"]["overridden"]), (70, "Your 70% until midnight", True))
        self.assertEqual(self.run_cli("resume")["limit"], 50)

        # Bad input fails before anything runs; inconsistent hours only switch the schedule off.
        for arguments in [("config", "work-start=8"), ("config", "tolerance=0"), ("set", "55"), ("charge-by", "80", "13")]:
            with self.assertRaises(ValueError, msg=arguments):
                program["main"](list(arguments))
        with self.assertRaisesRegex(ValueError, "has passed"):
            program["main"](["charge-by", "80", f"@{mon1000}"])
        status = self.run_cli("config", "work-end=07:00")
        self.assertEqual((status["plan"]["note"], status["plan"]["scheduling"], status["limit"]), ("Working hours: check Settings", False, 70))

        # A failing tick turns draining off, so a broken read never leaves the battery draining.
        # The kernel lists every mode in charge_behaviour; the fake file only holds the last write.
        (self.supply / "BAT0/charge_behaviour").write_text("[auto] inhibit-charge force-discharge\n")
        (self.supply / "AC/online").write_text("1\n")
        (self.supply / "BAT0/capacity").write_text("90\n")
        self.tick()
        self.assertEqual(self.battery("charge_behaviour"), "force-discharge")
        (self.supply / "BAT0/capacity").unlink()
        with self.assertRaisesRegex(ValueError, "No battery"):
            self.tick()
        self.assertEqual(self.battery("charge_behaviour"), "auto")
        self.assertIn("No battery", self.run_cli("status", "--json")["error"])

    def test_two_batteries_get_the_same_limit_and_never_drain(self):
        (self.supply / "BAT1").mkdir()
        for name in ("type", "capacity", "charge_control_start_threshold", "charge_control_end_threshold", "charge_behaviour"):
            (self.supply / "BAT1" / name).write_text((self.supply / "BAT0" / name).read_text())
        (self.supply / "BAT1/charge_control_end_threshold").write_text("100\n")
        status = self.run_cli("set", "80")
        self.assertEqual((status["limit"], status["drains"]), (80, False))
        self.assertEqual((self.supply / "BAT1/charge_control_end_threshold").read_text().strip(), "80")
        self.run_cli("set", "60")
        self.tick()
        self.assertEqual(self.battery("charge_behaviour"), "[auto] inhibit-charge force-discharge")

    def test_framework_reapplies_after_the_bios_resets_it(self):
        self.vendor.write_text("Framework\n")
        maximum = self.root / "maximum"
        maximum.write_text("80")
        program["TOOL"].write_text(
            "#!/usr/bin/python3\nimport sys\nfrom pathlib import Path\n"
            "assert sys.argv[1:4] == ['--driver', 'cros-ec', '--charge-limit']\n"
            f"maximum = Path({str(maximum)!r})\n"
            "if len(sys.argv) == 5:\n    maximum.write_text(sys.argv[4])\n"
            "print(f'Minimum 0%, Maximum {maximum.read_text()}%')\n"
        )
        program["TOOL"].chmod(0o755)
        status = self.run_cli("set", "60")
        self.assertEqual((status["limit"], status["drains"]), (60, True))
        self.assertEqual(self.battery("charge_behaviour"), "[auto] inhibit-charge force-discharge", "the EC drains by itself")
        maximum.write_text("100")
        self.assertEqual(self.tick()["limit"], 60)
        self.assertEqual(maximum.read_text(), "60")


if __name__ == "__main__":
    unittest.main()
