import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "t14-ps2-foreign-grub.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("foreign_grub", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)

TOKEN = "psmouse.synaptics_intertouch=0"
CONFLICT = "psmouse.synaptics_intertouch=1"
ROOT = "501f6d9f-910b-4ff3-8820-ac4e2272bf8b"
KERNEL = "6.14.0-37-generic"


def physical_config(arguments="ro quiet splash"):
    return f"""### BEGIN /etc/grub.d/30_os-prober ###
menuentry 'Linux Mint 22.3 Cinnamon (on /dev/nvme0n1p4)' --id mint {{
 linux /boot/vmlinuz-{KERNEL} root=UUID={ROOT} {arguments}
 initrd /boot/initrd.img-{KERNEL}
}}
menuentry 'Linux Mint 22.3 Cinnamon, with Linux {KERNEL} (on /dev/nvme0n1p4)' --id mint {{
 linux /boot/vmlinuz-{KERNEL} root=UUID={ROOT} {arguments}
 initrd /boot/initrd.img-{KERNEL}
}}
menuentry 'Linux Mint recovery mode (on /dev/nvme0n1p4)' --id mint-recovery {{
 linux /boot/vmlinuz-{KERNEL} root=UUID={ROOT} ro recovery
 initrd /boot/initrd.img-{KERNEL}
}}
### END /etc/grub.d/30_os-prober ###
"""


class ForeignGrubTests(unittest.TestCase):
    def test_render_preserves_equivalent_and_recovery_entries_and_patches_each(self):
        rendered = MODULE.render(physical_config(), ROOT, KERNEL, TOKEN, CONFLICT)
        self.assertTrue(rendered.startswith('#!/bin/sh\nexec tail -n +3 "$0"\n'))
        self.assertEqual(3, rendered.count("menuentry "))
        self.assertEqual(3, rendered.count(TOKEN))
        self.assertIn("recovery", rendered)
        self.assertIn(f"initrd /boot/initrd.img-{KERNEL}", rendered)

    def test_conflicting_argument_is_replaced(self):
        rendered = MODULE.render(physical_config(f"ro {CONFLICT}"), ROOT, KERNEL, TOKEN, CONFLICT)
        self.assertNotIn(CONFLICT, rendered)
        self.assertEqual(3, rendered.count(TOKEN))

    def test_verification_rejects_any_effective_unpatched_duplicate(self):
        mixed = physical_config().replace(
            "ro quiet splash\n initrd", f"ro quiet splash {TOKEN}\n initrd", 1
        )
        with self.assertRaises(SystemExit):
            MODULE.verify(mixed, ROOT, KERNEL, TOKEN)

    def test_verification_accepts_all_matching_entries(self):
        patched = physical_config().replace("ro quiet splash", f"ro quiet splash {TOKEN}").replace(
            "ro recovery", f"ro recovery {TOKEN}"
        )
        MODULE.verify(patched, ROOT, KERNEL, TOKEN)

    def test_skip_list_add_and_remove_preserve_unrelated_values(self):
        original = "GRUB_TIMEOUT=5\nGRUB_OS_PROBER_SKIP_LIST='other@/dev/sda1'\n"
        tokens = [ROOT, f"{ROOT}@/dev/nvme0n1p4"]
        added = MODULE.update_skip(original, "add", tokens)
        self.assertIn("other@/dev/sda1", added)
        self.assertTrue(all(token in added for token in tokens))
        removed = MODULE.update_skip(added, "remove", tokens)
        self.assertIn("other@/dev/sda1", removed)
        self.assertTrue(all(token not in removed for token in tokens))

    def test_skip_list_parser_exposes_existing_values_for_rollback_ownership(self):
        values, _ = MODULE.assignment_values(
            "GRUB_OS_PROBER_SKIP_LIST='existing one@/dev/sda2'\n",
            "GRUB_OS_PROBER_SKIP_LIST",
        )
        self.assertEqual(["existing", "one@/dev/sda2"], values)


if __name__ == "__main__":
    unittest.main()
