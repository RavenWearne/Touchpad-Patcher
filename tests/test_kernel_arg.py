#!/usr/bin/env python3
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EDITOR = ROOT / "scripts" / "t14-ps2-kernel-arg.py"
TOKEN = "psmouse.synaptics_intertouch=0"


class KernelArgumentEditorTests(unittest.TestCase):
    def edit(self, initial, operation, form, variable=None, restore=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config"
            path.write_text(initial)
            command = [str(EDITOR), operation, form, str(path)]
            if variable:
                command.append(variable)
            if restore:
                command.append("--restore-conflict")
            subprocess.run(command, check=True)
            return path.read_text()

    def test_grub_preserves_arguments_and_comments(self):
        result = self.edit(
            'GRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n# keep\n',
            "add",
            "shell",
            "GRUB_CMDLINE_LINUX_DEFAULT",
        )
        self.assertIn(f"quiet splash {TOKEN}", result)
        self.assertIn("# keep", result)

    def test_inline_comment_is_preserved(self):
        result = self.edit(
            'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash" # local choice\n',
            "add",
            "shell",
            "GRUB_CMDLINE_LINUX_DEFAULT",
        )
        self.assertIn("# local choice", result)
        self.assertIn(f"quiet splash {TOKEN}", result)

    def test_check_ignores_commented_token(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config"
            path.write_text(f"# GRUB_CMDLINE_LINUX_DEFAULT='{TOKEN}'\n")
            result = subprocess.run(
                [str(EDITOR), "check", "shell", str(path), "GRUB_CMDLINE_LINUX_DEFAULT"]
            )
            self.assertEqual(result.returncode, 1)

    def test_add_is_idempotent_and_replaces_conflict(self):
        result = self.edit(
            f"LINUX_OPTIONS='{TOKEN} psmouse.synaptics_intertouch=1 quiet'\n",
            "add",
            "shell",
            "LINUX_OPTIONS",
        )
        self.assertEqual(result.count(TOKEN), 1)
        self.assertNotIn("synaptics_intertouch=1", result)

    def test_rollback_restores_explicit_conflict(self):
        result = self.edit(
            f"KERNEL_CMDLINE[default]='quiet {TOKEN}'\n",
            "remove",
            "shell",
            "KERNEL_CMDLINE[default]",
            restore=True,
        )
        self.assertIn("psmouse.synaptics_intertouch=1", result)
        self.assertNotIn(TOKEN, result)

    def test_raw_systemd_boot(self):
        result = self.edit("root=UUID=x quiet\n", "add", "raw")
        self.assertEqual(result, f"root=UUID=x quiet {TOKEN}\n")

    def test_refind_changes_only_default_entry(self):
        initial = (
            '"Boot using default options" "root=UUID=x quiet"\n'
            '"Boot using fallback initramfs" "root=UUID=x single"\n'
        )
        result = self.edit(initial, "add", "refind")
        self.assertIn(f'root=UUID=x quiet {TOKEN}', result)
        self.assertIn('"root=UUID=x single"', result)


if __name__ == "__main__":
    unittest.main()
