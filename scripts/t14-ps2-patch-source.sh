#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: %s KERNEL_SOURCE [--check]\n' "$0"
}

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
source_dir=$(readlink -f -- "$1")
mode=${2:-apply}
target="$source_dir/drivers/input/mouse/synaptics.c"

[[ -f "$target" ]] || {
	printf 'Not a Linux kernel source tree: %s\n' "$source_dir" >&2
	exit 1
}

[[ "$mode" == apply || "$mode" == --check ]] || { usage >&2; exit 2; }

python3 - "$target" "$mode" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text()
array_pattern = re.compile(
    r'(static\s+const\s+char\s*\*\s*const\s+smbus_pnp_ids\s*\[\s*\]\s*=\s*\{)'
    r'(.*?)'
    r'(^\s*\};)',
    re.MULTILINE | re.DOTALL,
)
array_match = array_pattern.search(text)
if not array_match:
    raise SystemExit("unsupported kernel source: Synaptics smbus_pnp_ids array was not found")

body = array_match.group(2)
entry_pattern = re.compile(r'(?m)^(?P<indent>[ \t]*)"LEN2068"\s*,[^\n]*(?:\n|$)')
entries = list(entry_pattern.finditer(body))
markers = (
    "Do not force InterTouch on ThinkPad T14 Gen 1 (LEN2068)",
    "T14 LEN2068 touchpad patch",
)

if not entries:
    if any(marker in body for marker in markers):
        print(f"Patch already present in {path}")
    else:
        print(f"No patch needed: this kernel does not force LEN2068 in smbus_pnp_ids ({path})")
    raise SystemExit(0)
if len(entries) != 1:
    raise SystemExit(
        f"refusing patch: expected at most one LEN2068 entry in smbus_pnp_ids, found {len(entries)}"
    )
if mode == "--check":
    print(f"Patch is applicable to {path}")
    raise SystemExit(0)

entry = entries[0]
indent = entry.group("indent")
replacement = (
    f"{indent}/* T14 LEN2068 touchpad patch: do not force InterTouch.\n"
    f"{indent} * TM3471-020 systems can intermittently lose light taps over RMI4;\n"
    f"{indent} * SynPS/2 remains reliable and InterTouch can still be forced manually.\n"
    f"{indent} */\n"
)
new_body = body[:entry.start()] + replacement + body[entry.end():]
updated = text[:array_match.start(2)] + new_body + text[array_match.end(2):]
path.write_text(updated)
print(f"Patched {path}")
PY
