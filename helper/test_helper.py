import contextlib
import io
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


class ChargeLimitFlow(unittest.TestCase):
    def test_read_set_readback_and_rejected_requests(self):
        main = runpy.run_path(str(Path(__file__).with_name("framework-charge-limit")))[
            "main"
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / "framework_tool"
            maximum = root / "maximum"
            calls = root / "calls"
            reject = root / "reject"
            maximum.write_text("50")
            tool.write_text(
                "#!/usr/bin/python3\n"
                "from pathlib import Path\nimport sys\n"
                "assert sys.argv[1:4] == ['--driver', 'cros-ec', '--charge-limit']\n"
                f"maximum = Path({str(maximum)!r})\n"
                f"Path({str(calls)!r}).write_text(' '.join(sys.argv[1:]))\n"
                f"if len(sys.argv) == 5 and not Path({str(reject)!r}).exists():\n"
                "    maximum.write_text(sys.argv[4])\n"
                "print(f'Minimum 0%, Maximum {maximum.read_text()}%')\n"
            )
            tool.chmod(0o755)
            state = root / "state" / "limit"
            main.__globals__["TOOL"] = tool
            main.__globals__["LOCK"] = root / "lock"
            main.__globals__["STATE"] = state
            dmi = {
                "/sys/class/dmi/id/sys_vendor": "Framework\n",
                "/sys/class/dmi/id/product_name": "Laptop 13 Pro (Intel Core Ultra Series 3)\n",
                "/sys/class/dmi/id/product_version": "A9\n",
            }
            read_text = Path.read_text
            with (
                patch("os.geteuid", return_value=0),
                patch.object(
                    Path,
                    "read_text",
                    lambda path: dmi.get(str(path)) or read_text(path),
                ),
            ):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    main(["read"])
                    main(["set", "60"])
                    main(["set", "70"])
                    main(["set", "80"])
                    main(["read"])
                self.assertEqual(
                    [json.loads(line) for line in output.getvalue().splitlines()],
                    [
                        {"limit": 50, "drains": True},
                        {"limit": 60, "drains": True},
                        {"limit": 70, "drains": True},
                        {"limit": 80, "drains": True},
                        {"limit": 80, "drains": True},
                    ],
                )
                self.assertEqual(state.read_text(), "80\n")
                previous_call = calls.read_text()
                for request in (
                    ["set", "0"],
                    ["set", "51"],
                    ["set", "101"],
                    ["--versions"],
                    ["read", "50"],
                    ["restore", "50"],
                ):
                    with self.assertRaisesRegex(ValueError, "request is invalid"):
                        main(request)
                    self.assertEqual(calls.read_text(), previous_call)
                reject.touch()
                with self.assertRaisesRegex(ValueError, "readback returned 80%"):
                    main(["set", "100"])
                self.assertEqual(state.read_text(), "80\n")
                # A reboot: the BIOS puts its own limit back, and restore reapplies the
                # saved one. Without a saved limit, restore keeps the current limit and
                # saves it, unless it is not a preset.
                reject.unlink()
                maximum.write_text("100")
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    main(["restore"])
                    self.assertEqual(maximum.read_text(), "80")
                    state.unlink()
                    maximum.write_text("100")
                    main(["restore"])
                    self.assertEqual(state.read_text(), "100\n")
                    state.unlink()
                    maximum.write_text("55")
                    main(["restore"])
                    self.assertFalse(state.exists())
                self.assertEqual(
                    [json.loads(line) for line in output.getvalue().splitlines()],
                    [
                        {"limit": 80, "drains": True},
                        {"limit": 100, "drains": True},
                        {"limit": 55, "drains": True},
                    ],
                )
                self.assertEqual(calls.read_text(), "--driver cros-ec --charge-limit")
                state.write_text("55\n")
                with self.assertRaisesRegex(ValueError, "saved charge limit '55'"):
                    main(["restore"])
                maximum.write_text("unexpected")
                with self.assertRaisesRegex(ValueError, "invalid limit"):
                    main(["read"])
            with patch("os.geteuid", return_value=1000):
                with self.assertRaisesRegex(ValueError, "requires root"):
                    main(["set", "50"])

    def test_thinkpad_thresholds_follow_the_limit(self):
        main = runpy.run_path(str(Path(__file__).with_name("framework-charge-limit")))[
            "main"
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            battery = root / "BAT0"
            battery.mkdir()
            start = battery / "charge_control_start_threshold"
            end = battery / "charge_control_end_threshold"
            start.write_text("40\n")
            end.write_text("50\n")
            main.__globals__["POWER_SUPPLY"] = root
            main.__globals__["LOCK"] = root / "lock"
            main.__globals__["STATE"] = root / "state" / "limit"
            dmi = {
                "/sys/class/dmi/id/sys_vendor": "LENOVO\n",
                "/sys/class/dmi/id/product_name": "21MCCTO1WW\n",
                "/sys/class/dmi/id/product_version": "ThinkPad T14 Gen 5\n",
            }
            read_text = Path.read_text
            with (
                patch("os.geteuid", return_value=0),
                patch.object(
                    Path,
                    "read_text",
                    lambda path: dmi.get(str(path)) or read_text(path),
                ),
            ):
                output = io.StringIO()
                thresholds = []
                with contextlib.redirect_stdout(output):
                    main(["read"])
                    for limit in ("80", "100", "50"):
                        main(["set", limit])
                        thresholds.append((start.read_text(), end.read_text()))
                self.assertEqual(
                    [json.loads(line) for line in output.getvalue().splitlines()],
                    [
                        {"limit": 50, "drains": False},
                        {"limit": 80, "drains": False},
                        {"limit": 100, "drains": False},
                        {"limit": 50, "drains": False},
                    ],
                )
                self.assertEqual(thresholds, [("75", "80"), ("0", "100"), ("45", "50")])
                # The service's restore writes the saved thresholds back after a reset.
                start.write_text("0\n")
                end.write_text("100\n")
                with contextlib.redirect_stdout(io.StringIO()):
                    main(["restore"])
                self.assertEqual((start.read_text(), end.read_text()), ("45", "50"))
                dmi["/sys/class/dmi/id/sys_vendor"] = "Dell Inc.\n"
                with self.assertRaisesRegex(ValueError, "does not support Dell Inc."):
                    main(["read"])


if __name__ == "__main__":
    unittest.main()
