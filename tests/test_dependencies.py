#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "t14-ps2-kernel-installer.sh"


def function_body(source: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}\(\) \{{\n(?P<body>.*?)^\}}", source, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(f"function not found: {name}")
    return match.group("body")


class DependencyRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = INSTALLER.read_text()

    def test_debian_installs_gawk_for_fallback_builds(self):
        body = function_body(self.source, "dependency_packages_debian")
        self.assertRegex(body, r"\bgawk\b")

    def test_readiness_check_requires_gawk(self):
        body = function_body(self.source, "verify_build_requirements")
        required = re.search(r"required_commands=\((?P<items>.*?)\n\s*\)", body, re.DOTALL)
        self.assertIsNotNone(required)
        self.assertRegex(required.group("items"), r"\bgawk\b")

    def test_fallback_tool_audit_covers_build_and_archive_commands(self):
        body = function_body(self.source, "verify_build_requirements")
        required = re.search(r"required_commands=\((?P<items>.*?)\n\s*\)", body, re.DOTALL)
        words = set(re.findall(r"[A-Za-z0-9_.+-]+", required.group("items")))
        expected = {
            "make", "gcc", "ld", "as", "objcopy", "bc", "bison", "flex",
            "gawk", "perl", "python3", "find", "grep", "sed", "diff", "file", "tar",
            "xz", "gzip", "bzip2", "zstd", "lz4", "lzop", "curl", "openssl",
            "pkg-config", "rsync", "cpio", "depmod", "sha256sum",
        }
        self.assertFalse(expected - words, f"missing audited commands: {sorted(expected - words)}")


if __name__ == "__main__":
    unittest.main()
