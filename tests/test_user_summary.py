import importlib.util
import io
import pathlib
import sys
import unittest
from contextlib import redirect_stdout


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "t14-ps2-user-summary.py"
SPEC = importlib.util.spec_from_file_location("user_summary", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class UserSummaryTests(unittest.TestCase):
    def setUp(self):
        self.data = {
            "installations": [
                {
                    "distribution": "Fedora Linux 44",
                    "kernel": "7.1.8-t14ps2quirk1",
                    "installation_id": "fedora-root",
                    "current": True,
                    "kernel_patched": True,
                    "native_configured": True,
                    "native_active": False,
                },
                {
                    "distribution": "Fedora",
                    "kernel": "7.1.8-200.fc44.x86_64",
                    "installation_id": "fedora-root",
                    "current": False,
                    "kernel_patched": False,
                    "native_configured": True,
                    "native_active": False,
                },
                {
                    "distribution": "Fedora",
                    "kernel": "6.19.10-300.fc44.x86_64",
                    "installation_id": "fedora-root",
                    "current": False,
                    "kernel_patched": False,
                    "native_configured": True,
                    "native_active": False,
                },
                {
                    "distribution": "Linux Mint 22.3",
                    "kernel": "6.14.0-37-generic",
                    "installation_id": "mint-root",
                    "current": False,
                    "kernel_patched": False,
                    "native_configured": False,
                    "native_active": False,
                },
            ]
        }

    def capture(self, function, *args):
        output = io.StringIO()
        with redirect_stdout(output):
            status = function(*args)
        return status, output.getvalue()

    def test_current_system_is_reported_first_and_concisely(self):
        status, output = self.capture(MODULE.current, self.data)
        self.assertEqual(0, status)
        self.assertIn("Current system", output)
        self.assertIn("Fedora Linux 44", output)
        self.assertIn("Kernel: 7.1.8-t14ps2quirk1", output)
        self.assertIn("Kernel-level touchpad patch active", output)
        self.assertNotIn("BLS", output)
        self.assertNotIn("psmouse.synaptics_intertouch", output)

    def test_kernels_are_grouped_by_installation(self):
        _, output = self.capture(MODULE.multi, self.data)
        self.assertEqual(1, output.count("Fedora stock kernels"))
        self.assertNotIn("7.1.8-200.fc44.x86_64", output)
        self.assertNotIn("6.19.10-300.fc44.x86_64", output)
        self.assertEqual(1, output.count("Linux Mint 22.3"))

    def test_complete_requires_every_kernel_target_to_be_patched(self):
        self.assertFalse(MODULE.complete(self.data))
        self.data["installations"][-1]["native_configured"] = True
        self.assertTrue(MODULE.complete(self.data))


if __name__ == "__main__":
    unittest.main()
