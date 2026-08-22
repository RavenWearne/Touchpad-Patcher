#!/usr/bin/env python3
"""Persist and reconcile runtime verification without overriding live boot state."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile


SCHEMA = 1


def empty_state() -> dict:
    return {"schema": SCHEMA, "installations": {}}


def load_state(path: Path) -> dict:
    if not path.exists():
        return empty_state()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return empty_state()
    if data.get("schema") != SCHEMA or not isinstance(data.get("installations"), dict):
        return empty_state()
    return data


def installation_key(item: dict) -> str:
    root_uuid = str(item.get("root_uuid", "")).lower()
    return root_uuid if root_uuid else str(item.get("installation_id", ""))


def valid_record(item: dict, record: dict) -> bool:
    if not (item.get("kernel_patched") or item.get("native_configured")):
        return False
    return all(
        (
            record.get("root_uuid") == str(item.get("root_uuid", "")).lower(),
            record.get("distribution_id") == item.get("distribution_id"),
            record.get("kernel") == item.get("kernel"),
            record.get("boot_target_fingerprint") == item.get("boot_target_fingerprint"),
            record.get("kernel_patched") == bool(item.get("kernel_patched")),
            record.get("native_configured") == bool(item.get("native_configured")),
        )
    )


def reconcile(inventory: dict, state: dict) -> dict:
    records = state.get("installations", {})
    for item in inventory.get("installations", []):
        record = records.get(installation_key(item), {})
        item["runtime_verified"] = bool(valid_record(item, record))
        if item["runtime_verified"]:
            item["verified_at"] = record.get("verified_at", "")
            item["runtime"] = "runtime-verified"
    return inventory


def current_item(inventory: dict) -> dict:
    matches = [item for item in inventory.get("installations", []) if item.get("current")]
    if len(matches) != 1:
        raise SystemExit("current installation cannot be identified uniquely for runtime state")
    return matches[0]


def record(inventory: dict, state: dict) -> dict:
    item = current_item(inventory)
    if not (item.get("kernel_patched") or item.get("native_configured")):
        raise SystemExit("current installation has no persistent remediation to verify")
    key = installation_key(item)
    state["installations"][key] = {
        "root_uuid": str(item.get("root_uuid", "")).lower(),
        "distribution": item.get("distribution"),
        "distribution_id": item.get("distribution_id"),
        "kernel": item.get("kernel"),
        "boot_target_fingerprint": item.get("boot_target_fingerprint"),
        "kernel_patched": bool(item.get("kernel_patched")),
        "native_configured": bool(item.get("native_configured")),
        "remediation": item.get("remediation"),
        "verified_at": datetime.now(timezone.utc).isoformat(),
    }
    return state


def invalidate(inventory: dict, state: dict) -> dict:
    item = current_item(inventory)
    state["installations"].pop(installation_key(item), None)
    return state


def write_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".runtime-verification.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(state, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("reconcile", "record", "invalidate"))
    parser.add_argument("state", type=Path)
    args = parser.parse_args()
    inventory = json.load(__import__("sys").stdin)
    state = load_state(args.state)
    if args.action == "reconcile":
        json.dump(reconcile(inventory, state), __import__("sys").stdout, indent=2)
        print()
    else:
        updated = record(inventory, state) if args.action == "record" else invalidate(inventory, state)
        write_state(args.state, updated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
