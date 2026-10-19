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
            main.__globals__["TOOL"] = tool
            main.__globals__["LOCK"] = root / "lock"
            with patch("os.geteuid", return_value=0):
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
                        {"limit": 50},
                        {"limit": 60},
                        {"limit": 70},
                        {"limit": 80},
                        {"limit": 80},
                    ],
                )
                previous_call = calls.read_text()
                for request in (
                    ["set", "0"],
                    ["set", "51"],
                    ["set", "101"],
                    ["--versions"],
                    ["read", "50"],
                ):
                    with self.assertRaisesRegex(ValueError, "request is invalid"):
                        main(request)
                    self.assertEqual(calls.read_text(), previous_call)
                reject.touch()
                with self.assertRaisesRegex(ValueError, "readback returned 80%"):
                    main(["set", "100"])
                maximum.write_text("unexpected")
                with self.assertRaisesRegex(ValueError, "invalid limit"):
                    main(["read"])
            with patch("os.geteuid", return_value=1000):
                with self.assertRaisesRegex(ValueError, "requires root"):
                    main(["set", "50"])


if __name__ == "__main__":
    unittest.main()
