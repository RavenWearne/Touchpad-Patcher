import importlib.util
import io
import json
import pathlib
import sys
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "t14-ps2-machine-inventory.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("machine_inventory", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


TOKEN = "psmouse.synaptics_intertouch=0"
MINT_UUID = "501f6d9f-910b-4ff3-8820-ac4e2272bf8b"


class MachineInventoryTests(unittest.TestCase):
    def test_fedora_bls_patched_and_mint_os_prober_are_separate_installations(self):
        config = f"""### BEGIN /etc/grub.d/30_os-prober ###
menuentry 'Linux Mint 22.3 Cinnamon (on /dev/nvme0n1p4)' --id mint {{
 linux /boot/vmlinuz-6.14.0-37-generic root=UUID={MINT_UUID} ro quiet splash
}}
menuentry 'Linux Mint 22.3 Cinnamon, with Linux 6.14.0-37-generic (on /dev/nvme0n1p4)' --id mint {{
 linux /boot/vmlinuz-6.14.0-37-generic root=UUID={MINT_UUID} ro quiet splash
}}
menuentry 'Linux Mint recovery mode (on /dev/nvme0n1p4)' {{
 linux /boot/vmlinuz-6.14.0-37-generic root=UUID={MINT_UUID} ro recovery
}}
### END /etc/grub.d/30_os-prober ###
"""
        targets = MODULE.collect(config, TOKEN)
        targets += MODULE.collect_bls(
            "@@BLS 4076-7.1.8-t14ps2quirk1.conf\n"
            "title Fedora Linux\nversion 7.1.8-t14ps2quirk1\n"
            "linux /vmlinuz-7.1.8-t14ps2quirk1\n"
            "options root=UUID=fedora-root ro quiet\n",
            TOKEN,
        )
        self.assertEqual(2, len(targets))
        mint, fedora = targets
        self.assertEqual(2, mint["equivalent_entries"])
        self.assertTrue(mint["os_prober"])
        self.assertFalse(mint["native_configured"])
        self.assertTrue(fedora["kernel_patched"])

    def test_patched_kernel_and_native_parameter_are_compatible(self):
        targets = MODULE.collect_bls(
            "@@BLS patched.conf\ntitle Fedora Linux\nversion 7.1.8-t14ps2quirk1\n"
            f"options root=UUID=fedora ro {TOKEN}\n",
            TOKEN,
        )
        self.assertTrue(targets[0]["kernel_patched"])
        self.assertTrue(targets[0]["native_configured"])

    def test_fedora_bls_argument_does_not_propagate_to_mint_os_prober(self):
        mint_config = f"""### BEGIN /etc/grub.d/30_os-prober ###
menuentry 'Linux Mint 22.3 (on /dev/nvme0n1p4)' {{
 linux /boot/vmlinuz-6.14.0-37-generic root=UUID={MINT_UUID} ro quiet splash
}}
### END /etc/grub.d/30_os-prober ###
"""
        mint = MODULE.collect(mint_config, TOKEN)[0]
        fedora = MODULE.collect_bls(
            "@@BLS fedora.conf\ntitle Fedora Linux\nversion 7.1.8-200.fc44.x86_64\n"
            f"options root=UUID=fedora ro {TOKEN}\n",
            TOKEN,
        )[0]
        self.assertTrue(fedora["native_configured"])
        self.assertFalse(mint["native_configured"])

    def test_fedora_rescue_bls_entry_is_excluded(self):
        targets = MODULE.collect_bls(
            "@@BLS machine-0-rescue.conf\n"
            "title Fedora Linux (0-rescue-machine)\n"
            "version 0-rescue-machine\n"
            "options root=UUID=fedora ro\n",
            TOKEN,
        )
        self.assertEqual([], targets)

    def test_materially_different_entries_remain_separate_targets(self):
        config = f"""menuentry 'Mint A' {{
 linux /vmlinuz-6.14.0-37-generic root=UUID={MINT_UUID} ro quiet
}}
menuentry 'Mint B' {{
 linux /vmlinuz-6.14.0-37-generic root=UUID={MINT_UUID} ro debug
}}
"""
        self.assertEqual(2, len(MODULE.collect(config, TOKEN)))

    def test_exact_token_is_required(self):
        config = "menuentry 'Fedora' {\n linux /vmlinuz-6.8 root=UUID=x ro psmouse.synaptics_intertouch=01\n}\n"
        self.assertFalse(MODULE.collect(config, TOKEN)[0]["native_configured"])

    def test_main_marks_only_matching_root_and_kernel_current(self):
        config = f"menuentry 'Linux Mint' {{\n linux /vmlinuz-6.14 root=UUID={MINT_UUID} ro\n}}\n"
        argv = [str(SCRIPT), "--token", TOKEN, "--current-root", MINT_UUID, "--current-kernel", "6.14", "--current-os", "Linux Mint 22.3", "--owner", "Fedora"]
        output = io.StringIO()
        with mock.patch.object(sys, "argv", argv), mock.patch("sys.stdin", io.StringIO(config)), mock.patch("sys.stdout", output):
            self.assertEqual(0, MODULE.main())
        result = json.loads(output.getvalue())
        self.assertTrue(result["installations"][0]["current"])
        self.assertEqual("current-live-evidence", result["installations"][0]["runtime"])


if __name__ == "__main__":
    unittest.main()
