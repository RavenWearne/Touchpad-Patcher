#!/usr/bin/env python3
"""Safely add or remove the Touchpad Patcher kernel argument."""

from __future__ import annotations

import argparse
import re
import shlex
from pathlib import Path

TOKEN = "psmouse.synaptics_intertouch=0"
CONFLICT = "psmouse.synaptics_intertouch=1"


def update_words(value: str, operation: str, restore_conflict: bool) -> str:
    words = shlex.split(value)
    words = [word for word in words if word not in {TOKEN, CONFLICT}]
    if operation == "add":
        words.append(TOKEN)
    elif restore_conflict:
        words.append(CONFLICT)
    return " ".join(words)


def quote_shell(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def split_inline_comment(raw: str) -> tuple[str, str]:
    quote = None
    escaped = False
    for index, character in enumerate(raw):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quote != "'":
            escaped = True
            continue
        if character in {"'", '"'}:
            if quote == character:
                quote = None
            elif quote is None:
                quote = character
            continue
        if character == "#" and quote is None and (
            index == 0 or raw[index - 1].isspace()
        ):
            return raw[:index].rstrip(), raw[index:]
    return raw.rstrip(), ""


def update_assignment(text: str, variable: str, operation: str, restore: bool) -> str:
    pattern = re.compile(
        rf"^(?P<prefix>\s*{re.escape(variable)}\s*=\s*)(?P<value>.*?)(?P<suffix>\s*)$",
        re.MULTILINE,
    )
    match = pattern.search(text)
    if match:
        raw, comment = split_inline_comment(match.group("value").strip())
        try:
            parsed = shlex.split(raw)
        except ValueError as error:
            raise SystemExit(f"cannot parse {variable}: {error}") from error
        current = parsed[0] if len(parsed) == 1 else " ".join(parsed)
        replacement = match.group("prefix") + quote_shell(update_words(current, operation, restore))
        if comment:
            replacement += "  " + comment
        return text[: match.start()] + replacement + text[match.end() :]
    if operation == "remove":
        return text
    separator = "" if not text or text.endswith("\n") else "\n"
    return f"{text}{separator}{variable}={quote_shell(TOKEN)}\n"


def update_raw(text: str, operation: str, restore: bool) -> str:
    trailing = "\n" if text.endswith("\n") else ""
    return update_words(text.strip(), operation, restore) + trailing


def update_refind(text: str, operation: str, restore: bool) -> str:
    pattern = re.compile(
        r'^(?P<prefix>\s*"Boot using default options"\s+")(?P<value>[^"]*)(?P<suffix>".*)$',
        re.MULTILINE,
    )
    match = pattern.search(text)
    if not match:
        raise SystemExit('rEFInd entry "Boot using default options" was not found')
    replacement = (
        match.group("prefix")
        + update_words(match.group("value"), operation, restore)
        + match.group("suffix")
    )
    return text[: match.start()] + replacement + text[match.end() :]


def contains_token(text: str, form: str, variable: str | None) -> bool:
    if form == "raw":
        return TOKEN in shlex.split(text)
    if form == "refind":
        match = re.search(
            r'^\s*"Boot using default options"\s+"(?P<value>[^"]*)"',
            text,
            re.MULTILINE,
        )
        return bool(match and TOKEN in shlex.split(match.group("value")))
    if not variable:
        raise SystemExit("shell format requires a variable")
    match = re.search(
        rf"^\s*{re.escape(variable)}\s*=\s*(?P<value>.*?)\s*$",
        text,
        re.MULTILINE,
    )
    if not match:
        return False
    raw, _ = split_inline_comment(match.group("value"))
    parsed = shlex.split(raw)
    current = parsed[0] if len(parsed) == 1 else " ".join(parsed)
    return TOKEN in shlex.split(current)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("add", "remove", "check"))
    parser.add_argument("format", choices=("shell", "raw", "refind"))
    parser.add_argument("path", type=Path)
    parser.add_argument("variable", nargs="?")
    parser.add_argument("--restore-conflict", action="store_true")
    args = parser.parse_args()

    text = args.path.read_text()
    if args.operation == "check":
        raise SystemExit(0 if contains_token(text, args.format, args.variable) else 1)
    if args.format == "shell":
        if not args.variable:
            parser.error("shell format requires a variable")
        updated = update_assignment(
            text, args.variable, args.operation, args.restore_conflict
        )
    elif args.format == "raw":
        updated = update_raw(text, args.operation, args.restore_conflict)
    else:
        updated = update_refind(text, args.operation, args.restore_conflict)
    args.path.write_text(updated)


if __name__ == "__main__":
    main()
