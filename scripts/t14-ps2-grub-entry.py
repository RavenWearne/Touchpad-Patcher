#!/usr/bin/env python3
"""Locate the generated GRUB menu entry that boots the running installation."""

from __future__ import annotations

import argparse
import re
import sys


LINUX_RE = re.compile(r"^\s*(?:linux|linuxefi|linux16)\s+(\S+)(.*)$")
MENU_RE = re.compile(r"^\s*menuentry\s+(['\"])(.*?)\1")
MENU_ID_RE = re.compile(r"(?:^|\s)--id(?:=|\s+)(?:'([^']+)'|\"([^\"]+)\"|(\S+))")
RECOVERY_ARGUMENTS = {
    "single",
    "recovery",
    "rescue",
    "emergency",
    "systemd.unit=rescue.target",
    "systemd.unit=emergency.target",
}


def is_recovery(title: str, fields: list[str]) -> bool:
    lowered = title.lower()
    return "recovery mode" in lowered or "rescue" in lowered or bool(RECOVERY_ARGUMENTS.intersection(fields))


def menu_id(line: str) -> str:
    match = MENU_ID_RE.search(line)
    return next((value for value in match.groups() if value is not None), "") if match else ""


def entries(text: str):
    current = None
    depth = 0
    os_prober = False
    for line in text.splitlines():
        if line.startswith("### BEGIN "):
            os_prober = "30_os-prober" in line
        match = MENU_RE.match(line)
        if match and current is None:
            current = {
                "title": match.group(2),
                "id": menu_id(line),
                "lines": [],
                "os_prober": os_prober,
            }
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
    parser.add_argument("current_cmdline", nargs="?", default="")
    args = parser.parse_args()
    wanted_root = f"root=UUID={args.root_uuid}".lower()
    wanted_kernel = f"vmlinuz-{args.kernel}"
    current_recovery = bool(RECOVERY_ARGUMENTS.intersection(args.current_cmdline.split()))
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
            if is_recovery(entry["title"], fields) != current_recovery:
                continue
            matches.append((entry, fields))
            break
    logical = {}
    for entry, fields in matches:
        key = (wanted_kernel, tuple(fields))
        logical.setdefault(key, []).append((entry, fields))
    print(f"physical_matches={len(matches)}")
    print(f"logical_matches={len(logical)}")
    if len(logical) != 1:
        return 2 if not logical else 3
    equivalents = next(iter(logical.values()))
    entry, fields = equivalents[0]
    print(f"title={entry['title']}")
    ids = sorted({candidate["id"] for candidate, _ in equivalents if candidate["id"]})
    print(f"menu_id={ids[0] if len(ids) == 1 else ''}")
    print(f"equivalent_entries={len(equivalents)}")
    print(f"os_prober={int(any(candidate['os_prober'] or '(on /dev/' in candidate['title'] for candidate, _ in equivalents))}")
    print(f"token={int(args.token in fields)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
