#!/usr/bin/env python3
"""Build a machine-level inventory from an authoritative GRUB configuration."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys

_entry_path = Path(__file__).with_name("t14-ps2-grub-entry.py")
_entry_spec = importlib.util.spec_from_file_location("t14_ps2_grub_entry", _entry_path)
assert _entry_spec and _entry_spec.loader
_entry_module = importlib.util.module_from_spec(_entry_spec)
_entry_spec.loader.exec_module(_entry_module)
LINUX_RE = _entry_module.LINUX_RE
entries = _entry_module.entries
is_recovery = _entry_module.is_recovery


ROOT_RE = re.compile(r"^root=UUID=(.+)$", re.IGNORECASE)
PATCH_SUFFIXES = ("t14-len2068-touchpad-patch", "t14ps2quirk1")


def distribution(title: str) -> str:
    lowered = title.lower()
    if "linux mint" in lowered:
        return "Linux Mint"
    if "fedora" in lowered:
        return "Fedora"
    if "ubuntu" in lowered:
        return "Ubuntu"
    if "debian" in lowered:
        return "Debian"
    return title.split(",", 1)[0].strip() or "Linux"


def collect(text: str, token: str) -> list[dict]:
    logical: dict[tuple, dict] = {}
    for entry in entries(text):
        for line in entry["lines"]:
            match = LINUX_RE.match(line)
            if not match:
                continue
            image, raw_arguments = match.groups()
            arguments = raw_arguments.split()
            if is_recovery(entry["title"], arguments):
                continue
            root_uuid = next(
                (root.group(1) for field in arguments if (root := ROOT_RE.match(field))), ""
            )
            kernel_image = image.rsplit("/", 1)[-1]
            kernel = kernel_image.removeprefix("vmlinuz-")
            if not root_uuid or not kernel:
                continue
            key = (root_uuid.lower(), kernel, tuple(arguments))
            target = logical.setdefault(
                key,
                {
                    "distribution": distribution(entry["title"]),
                    "title": entry["title"],
                    "root_uuid": root_uuid,
                    "kernel": kernel,
                    "arguments": arguments,
                    "menu_ids": [],
                    "equivalent_entries": 0,
                    "os_prober": False,
                    "native_configured": token in arguments,
                    "kernel_patched": any(suffix in kernel for suffix in PATCH_SUFFIXES),
                },
            )
            target["equivalent_entries"] += 1
            target["os_prober"] = target["os_prober"] or bool(entry["os_prober"] or "(on /dev/" in entry["title"])
            if entry["id"] and entry["id"] not in target["menu_ids"]:
                target["menu_ids"].append(entry["id"])
            break
    return list(logical.values())


def collect_bls(text: str, token: str) -> list[dict]:
    targets = []
    for block in text.split("\n@@BLS "):
        if not block.strip():
            continue
        lines = block.splitlines()
        identifier = lines.pop(0).strip() if not block.startswith("@@BLS ") else lines.pop(0).removeprefix("@@BLS ").strip()
        values: dict[str, str] = {}
        for line in lines:
            key, _, value = line.partition(" ")
            if key in {"title", "version", "linux", "options"} and value:
                values[key] = value.strip()
        arguments = values.get("options", "").split()
        root_uuid = next((m.group(1) for field in arguments if (m := ROOT_RE.match(field))), "")
        kernel = values.get("version", "") or values.get("linux", "").rsplit("/", 1)[-1].removeprefix("vmlinuz-")
        if not kernel:
            continue
        targets.append({
            "distribution": distribution(values.get("title", "Fedora")),
            "title": values.get("title", identifier),
            "root_uuid": root_uuid,
            "kernel": kernel,
            "arguments": arguments,
            "menu_ids": [identifier],
            "equivalent_entries": 1,
            "os_prober": False,
            "native_configured": token in arguments,
            "kernel_patched": any(suffix in kernel for suffix in PATCH_SUFFIXES),
            "bls": True,
        })
    return targets


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", required=True)
    parser.add_argument("--current-root", default="")
    parser.add_argument("--current-kernel", default="")
    parser.add_argument("--current-os", default="")
    parser.add_argument("--owner", default="")
    parser.add_argument("--bls-data", default="")
    args = parser.parse_args()
    targets = collect(sys.stdin.read(), args.token)
    targets.extend(collect_bls(args.bls_data, args.token))
    for target in targets:
        target["current"] = (
            target["root_uuid"].lower() == args.current_root.lower()
            and target["kernel"] == args.current_kernel
        )
        if target["current"] and args.current_os:
            target["distribution"] = args.current_os
        target["boot_method"] = (f"{args.owner} BLS" if target.get("bls") else
            f"{args.owner} GRUB / os-prober" if target["os_prober"] else f"{args.owner} GRUB").strip()
        if target["kernel_patched"] and target["native_configured"]:
            target["remediation"] = "kernel-patched + native-configured"
        elif target["kernel_patched"]:
            target["remediation"] = "kernel-patched"
        elif target["native_configured"]:
            target["remediation"] = "native-configured"
        else:
            target["remediation"] = "unconfigured"
        target["runtime"] = "current-live-evidence" if target["current"] else "pending-runtime-verification"
    json.dump({"bootloader_owner": args.owner, "installations": targets}, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
