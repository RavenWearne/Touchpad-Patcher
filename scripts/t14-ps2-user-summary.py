#!/usr/bin/env python3
"""Render concise end-user summaries from the deep machine inventory."""

from __future__ import annotations

import argparse
import json
import sys


def groups(items: list[dict]) -> list[dict]:
    grouped: dict[str, dict] = {}
    for item in items:
        key = item.get("installation_id") or item.get("root_uuid") or item["distribution"]
        group = grouped.setdefault(key, {"name": item["distribution"], "items": [], "current": False})
        group["items"].append(item)
        if item["current"]:
            group["current"] = True
            group["name"] = item["distribution"]
            group["current_item"] = item
    return list(grouped.values())


def patched(item: dict) -> bool:
    return bool(item["kernel_patched"] or item["native_configured"])


def family_name(name: str) -> str:
    if name.startswith("Fedora"):
        return "Fedora"
    return name.split(" (", 1)[0]


def current(data: dict) -> int:
    current_item = next((item for item in data["installations"] if item["current"]), None)
    if not current_item:
        print("✗ Current Linux installation could not be identified safely.")
        return 1
    print("\nCurrent system")
    print("──────────────")
    print(current_item["distribution"])
    print(f"Kernel: {current_item['kernel']}\n")
    if current_item["kernel_patched"]:
        print("✓ Kernel-level touchpad patch active")
    if current_item.get("native_active"):
        print("✓ Native touchpad patch active" if current_item["kernel_patched"] else "✓ Touchpad patch active")
    elif current_item["native_configured"] and not current_item["kernel_patched"]:
        print("○ Touchpad patch awaiting reboot")
    elif not current_item["kernel_patched"]:
        print("⚠ Touchpad patch required")
    return 0


def multi(data: dict, result: bool = False) -> int:
    installations = groups(data["installations"])
    current_group = next((group for group in installations if group["current"]), None)
    lines: list[str] = []
    if current_group:
        current_kernel = current_group["current_item"]["kernel"]
        current_item = current_group["current_item"]
        if result and patched(current_item) and not current_item.get("runtime_verified"):
            lines.append(f"✓ {current_group['name']} patched")
            lines.append(f"○ Reboot {current_group['name']} for runtime verification")
        stock = [item for item in current_group["items"] if item["kernel"] != current_kernel]
        if stock:
            complete = all(patched(item) for item in stock)
            lines.append(f"{'✓' if complete else '⚠'} {family_name(current_group['name'])} stock kernels {'patched' if complete else 'require the touchpad patch'}")
    for group in installations:
        if group["current"]:
            continue
        complete = all(patched(item) for item in group["items"])
        verified = any(item.get("runtime_verified") for item in group["items"])
        if complete:
            lines.append(f"✓ {group['name']} patched")
            if not verified:
                lines.append(f"○ Boot {group['name']} for runtime verification")
        else:
            lines.append(f"{'✗' if result else '⚠'} {group['name']} {'still requires the touchpad patch' if result else 'detected — touchpad patch required'}")
    if lines:
        print("\nMulti-boot")
        print("──────────")
        print("\n".join(lines))
    return 0


def patched_complete(data: dict) -> bool:
    return bool(data["installations"]) and all(patched(item) for item in data["installations"])


def complete(data: dict) -> bool:
    installations = groups(data["installations"])
    return patched_complete(data) and all(
        any(item.get("runtime_verified") for item in group["items"])
        for group in installations
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("current", "multi", "result", "patched", "complete"))
    parser.add_argument("inventory")
    args = parser.parse_args()
    with open(args.inventory, encoding="utf-8") as inventory:
        data = json.load(inventory)
    if args.mode == "current":
        return current(data)
    if args.mode in {"multi", "result"}:
        return multi(data, args.mode == "result")
    if args.mode == "patched":
        return 0 if patched_complete(data) else 1
    return 0 if complete(data) else 1


if __name__ == "__main__":
    raise SystemExit(main())
