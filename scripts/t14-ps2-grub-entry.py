#!/usr/bin/env python3
"""Locate the generated GRUB menu entry that boots the running installation."""

from __future__ import annotations

import argparse
import re
import sys


LINUX_RE = re.compile(r"^\s*(?:linux|linuxefi|linux16)\s+(\S+)(.*)$")
MENU_RE = re.compile(r"^\s*menuentry\s+(['\"])(.*?)\1")


def entries(text: str):
    current = None
    depth = 0
    os_prober = False
    for line in text.splitlines():
        if line.startswith("### BEGIN "):
            os_prober = "30_os-prober" in line
        match = MENU_RE.match(line)
        if match and current is None:
            current = {"title": match.group(2), "lines": [], "os_prober": os_prober}
            depth = line.count("{") - line.count("}")
            continue
        if current is not None:
            current["lines"].append(line)
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                yield current
                current = None
        if line.startswith("### END "):
            os_prober = False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root_uuid")
    parser.add_argument("kernel")
    parser.add_argument("token")
    args = parser.parse_args()
    wanted_root = f"root=UUID={args.root_uuid}".lower()
    wanted_kernel = f"vmlinuz-{args.kernel}"
    matches = []
    for entry in entries(sys.stdin.read()):
        for line in entry["lines"]:
            linux = LINUX_RE.match(line)
            if not linux:
                continue
            image, arguments = linux.groups()
            fields = arguments.split()
            if wanted_root not in (field.lower() for field in fields):
                continue
            if image.rsplit("/", 1)[-1] != wanted_kernel:
                continue
            matches.append((entry, fields))
            break
    if len(matches) != 1:
        print(f"matches={len(matches)}")
        return 2 if not matches else 3
    entry, fields = matches[0]
    print(f"title={entry['title']}")
    print(f"os_prober={int(entry['os_prober'] or '(on /dev/' in entry['title'])}")
    print(f"token={int(args.token in fields)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
