import subprocess
import unittest
from pathlib import Path


HELPER = Path(__file__).resolve().parents[1] / "scripts" / "t14-ps2-grub-entry.py"
TOKEN = "psmouse.synaptics_intertouch=0"


def check(config, root="501f6d9f-910b-4ff3-8820-ac4e2272bf8b", kernel="6.14.0-37-generic", cmdline="ro quiet splash"):
    return subprocess.run(
        ["python3", str(HELPER), root, kernel, TOKEN, cmdline],
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

    def test_equivalent_generic_and_version_entries_collapse(self):
        result = check("""
### BEGIN /etc/grub.d/30_os-prober ###
menuentry 'Linux Mint 22.3 Cinnamon (on /dev/nvme0n1p4)' --id 'osprober-mint' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet splash
}
menuentry 'Linux Mint 22.3 Cinnamon, with Linux 6.14.0-37-generic (on /dev/nvme0n1p4)' --id 'osprober-mint' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet splash
}
menuentry 'Linux Mint 22.3 Cinnamon, with Linux 6.14.0-37-generic (recovery mode) (on /dev/nvme0n1p4)' --id 'osprober-mint-recovery' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro recovery nomodeset
}
### END /etc/grub.d/30_os-prober ###
""")
        self.assertEqual(result.returncode, 0)
        self.assertIn("physical_matches=2", result.stdout)
        self.assertIn("logical_matches=1", result.stdout)
        self.assertIn("equivalent_entries=2", result.stdout)
        self.assertIn("menu_id=osprober-mint", result.stdout)

    def test_identical_entries_with_same_menu_id_collapse(self):
        entry = """menuentry 'duplicate' --id 'same-id' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro
}
"""
        result = check(entry + entry)
        self.assertEqual(result.returncode, 0)
        self.assertIn("equivalent_entries=2", result.stdout)

    def test_materially_different_matching_entries_remain_ambiguous(self):
        result = check("""
menuentry 'quiet' --id 'mint-quiet' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet splash
}
menuentry 'debug' --id 'mint-debug' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro debug
}
""")
        self.assertEqual(result.returncode, 3)

    def test_recovery_entry_selected_only_for_recovery_boot(self):
        result = check("""
menuentry 'normal' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro quiet
}
menuentry 'recovery mode' {
    linux /boot/vmlinuz-6.14.0-37-generic root=UUID=501f6d9f-910b-4ff3-8820-ac4e2272bf8b ro recovery nomodeset
}
""", cmdline="ro recovery nomodeset")
        self.assertEqual(result.returncode, 0)
        self.assertIn("title=recovery mode", result.stdout)


if __name__ == "__main__":
    unittest.main()
