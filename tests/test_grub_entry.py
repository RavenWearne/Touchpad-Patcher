import subprocess
import unittest
from pathlib import Path


HELPER = Path(__file__).resolve().parents[1] / "scripts" / "t14-ps2-grub-entry.py"
TOKEN = "psmouse.synaptics_intertouch=0"


def check(config, root="501f6d9f-910b-4ff3-8820-ac4e2272bf8b", kernel="6.14.0-37-generic"):
    return subprocess.run(
        ["python3", str(HELPER), root, kernel, TOKEN],
        input=config,
        text=True,
        capture_output=True,
        check=False,
    )


class GrubEntryTests(unittest.TestCase):
    def test_finds_physical_os_prober_mint_entry(self):
        result = check("""
### BEGIN /etc/grub.d/30_os-prober ###
menuentry 'Linux Mint 22.3 Cinnamon (on /dev/nvme0n1p4)' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet splash
}
### END /etc/grub.d/30_os-prober ###
""")
        self.assertEqual(result.returncode, 0)
        self.assertIn("os_prober=1", result.stdout)
        self.assertIn("token=0", result.stdout)

    def test_checks_only_current_root_and_kernel_entry(self):
        result = check(f"""
menuentry 'wrong entry containing token' {{
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee ro {TOKEN}
}}
menuentry 'current entry' {{
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet
}}
""")
        self.assertEqual(result.returncode, 0)
        self.assertIn("title=current entry", result.stdout)
        self.assertIn("token=0", result.stdout)

    def test_ambiguous_current_entries_fail(self):
        entry = """menuentry 'duplicate' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro
}
"""
        result = check(entry + entry)
        self.assertEqual(result.returncode, 3)


if __name__ == "__main__":
    unittest.main()
