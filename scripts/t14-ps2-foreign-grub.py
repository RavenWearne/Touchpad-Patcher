#!/usr/bin/env python3
"""Build and verify persistent GRUB entries for foreign Linux installations."""

from __future__ import annotations

import argparse
import importlib.util
import re
import shlex
import sys
from pathlib import Path


ENTRY_HELPER = Path(__file__).with_name("t14-ps2-grub-entry.py")
SPEC = importlib.util.spec_from_file_location("t14_ps2_grub_entry", ENTRY_HELPER)
assert SPEC and SPEC.loader
ENTRY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ENTRY)

LINUX_RE = ENTRY.LINUX_RE
ROOT_RE = re.compile(r"^root=UUID=(.+)$", re.IGNORECASE)
MANAGED_HEADER = "# Managed by ThinkPad T14 LEN2068 Touchpad Patcher"


def matching_entries(text: str, root_uuid: str, kernel: str) -> list[dict]:
    wanted_root = root_uuid.lower()
    wanted_image = f"vmlinuz-{kernel}"
    matches = []
    for entry in ENTRY.entries(text):
        for line in entry["lines"]:
            linux = LINUX_RE.match(line)
            if not linux:
                continue
            image, raw_arguments = linux.groups()
            arguments = raw_arguments.split()
            root = next(
                (match.group(1) for field in arguments if (match := ROOT_RE.match(field))),
                "",
            )
            if root.lower() == wanted_root and image.rsplit("/", 1)[-1] == wanted_image:
                matches.append(entry)
                break
    return matches


def patch_linux_line(line: str, token: str, conflict: str) -> str:
    match = LINUX_RE.match(line)
    if not match:
        return line
    image, raw_arguments = match.groups()
    arguments = [word for word in raw_arguments.split() if word not in {token, conflict}]
    arguments.append(token)
    indentation = line[: len(line) - len(line.lstrip())]
    command = line.lstrip().split(None, 1)[0]
    return f"{indentation}{command} {image} {' '.join(arguments)}"


def render(text: str, root_uuid: str, kernel: str, token: str, conflict: str) -> str:
    matches = matching_entries(text, root_uuid, kernel)
    if not matches:
        raise SystemExit("no authoritative GRUB entries match the requested foreign root and kernel")
    if not all(entry["os_prober"] or "(on /dev/" in entry["title"] for entry in matches):
        raise SystemExit("matching foreign entries are not positively identified as os-prober output")
    output = ["#!/bin/sh", 'exec tail -n +3 "$0"', MANAGED_HEADER]
    for entry in matches:
        output.append(entry["opening"])
        for line in entry["lines"]:
            output.append(patch_linux_line(line, token, conflict))
    return "\n".join(output) + "\n"


def verify(text: str, root_uuid: str, kernel: str, token: str) -> None:
    matches = matching_entries(text, root_uuid, kernel)
    if not matches:
        raise SystemExit("the regenerated authoritative GRUB has no matching foreign entry")
    for entry in matches:
        for line in entry["lines"]:
            linux = LINUX_RE.match(line)
            if not linux:
                continue
            image, raw_arguments = linux.groups()
            arguments = raw_arguments.split()
            root = next(
                (match.group(1) for field in arguments if (match := ROOT_RE.match(field))),
                "",
            )
            if root.lower() == root_uuid.lower() and image.rsplit("/", 1)[-1] == f"vmlinuz-{kernel}":
                if token not in arguments:
                    raise SystemExit(
                        f"effective foreign entry {entry['title']!r} lacks the required argument"
                    )
                break


def assignment_values(text: str, variable: str) -> tuple[list[str], re.Match[str] | None]:
    pattern = re.compile(
        rf"^(?P<prefix>\s*{re.escape(variable)}\s*=\s*)(?P<value>.*)$", re.MULTILINE
    )
    match = pattern.search(text)
    if not match:
        return [], None
    raw = match.group("value").strip()
    try:
        parsed = shlex.split(raw)
    except ValueError as error:
        raise SystemExit(f"cannot parse {variable}: {error}") from error
    value = parsed[0] if len(parsed) == 1 else " ".join(parsed)
    return value.split(), match


def quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def update_skip(text: str, operation: str, tokens: list[str]) -> str:
    variable = "GRUB_OS_PROBER_SKIP_LIST"
    values, match = assignment_values(text, variable)
    if operation == "add":
        for token in tokens:
            if token not in values:
                values.append(token)
    else:
        values = [value for value in values if value not in tokens]
    replacement = f"{variable}={quote(' '.join(values))}"
    if match:
        if not values and operation == "remove":
            start, end = match.span()
            if end < len(text) and text[end] == "\n":
                end += 1
            return text[:start] + text[end:]
        return text[: match.start()] + replacement + text[match.end() :]
    if operation == "remove":
        return text
    separator = "" if not text or text.endswith("\n") else "\n"
    return f"{text}{separator}{replacement}\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="action", required=True)
    for action in ("render", "verify"):
        child = subparsers.add_parser(action)
        child.add_argument("root_uuid")
        child.add_argument("kernel")
        child.add_argument("token")
        if action == "render":
            child.add_argument("conflict")
    for action in ("skip-add", "skip-remove"):
        child = subparsers.add_parser(action)
        child.add_argument("path", type=Path)
        child.add_argument("tokens", nargs="+")
    skip_list = subparsers.add_parser("skip-list")
    skip_list.add_argument("path", type=Path)
    args = parser.parse_args()
    if args.action == "render":
        sys.stdout.write(render(sys.stdin.read(), args.root_uuid, args.kernel, args.token, args.conflict))
    elif args.action == "verify":
        verify(sys.stdin.read(), args.root_uuid, args.kernel, args.token)
    elif args.action == "skip-list":
        values, _ = assignment_values(args.path.read_text(encoding="utf-8"), "GRUB_OS_PROBER_SKIP_LIST")
        print("\n".join(values))
    else:
        text = args.path.read_text(encoding="utf-8")
        args.path.write_text(update_skip(text, args.action.removeprefix("skip-"), args.tokens), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
