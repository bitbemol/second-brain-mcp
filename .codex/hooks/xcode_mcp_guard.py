#!/usr/bin/env python3
"""Block high-confidence project mutations that bypass Xcode MCP."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shlex
import sys


MUTATING_PROGRAMS = {
    "cp",
    "install",
    "ln",
    "mkdir",
    "mv",
    "rm",
    "rmdir",
    "tee",
    "touch",
    "truncate",
}
MUTATING_GIT_SUBCOMMANDS = {
    "am",
    "apply",
    "checkout",
    "clean",
    "mv",
    "reset",
    "restore",
    "rm",
}


def deny(reason: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


def is_within(path: Path, root: Path) -> bool:
    try:
        return os.path.commonpath((str(path), str(root))) == str(root)
    except ValueError:
        return False


def targets_project(token: str, cwd: Path, root: Path) -> bool:
    candidate = token.strip().strip("\"'")
    if not candidate or candidate == "-":
        return False
    if any(marker in candidate for marker in ("$", "`", "*", "?", "[")):
        return not candidate.startswith(("/tmp/", "/private/tmp/"))
    path = Path(candidate).expanduser()
    if not path.is_absolute():
        path = cwd / path
    return is_within(path.resolve(strict=False), root)


def command_tokens(segment: str) -> list[str]:
    try:
        return shlex.split(segment)
    except ValueError:
        return []


def program_index(tokens: list[str]) -> int | None:
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if "=" in token and not token.startswith(("/", "./", "../")):
            index += 1
            continue
        if os.path.basename(token) == "env":
            index += 1
            continue
        if os.path.basename(token) == "sudo":
            index += 1
            continue
        return index
    return None


def git_subcommand(tokens: list[str], index: int) -> str | None:
    cursor = index + 1
    options_with_values = {"-C", "-c", "--exec-path", "--git-dir", "--work-tree"}
    while cursor < len(tokens):
        token = tokens[cursor]
        if token in options_with_values:
            cursor += 2
            continue
        if token.startswith("-"):
            cursor += 1
            continue
        return token
    return None


def mutation_reason(command: str, cwd: Path, root: Path) -> str | None:
    for redirected in re.findall(r"(?:^|[^<])>{1,2}\s*([^\s;&|]+)", command):
        if targets_project(redirected, cwd, root):
            return "Shell redirection would write a project file outside Xcode MCP."

    for segment in re.split(r"(?:&&|\|\||;|\n)", command):
        tokens = command_tokens(segment)
        index = program_index(tokens)
        if index is None:
            continue

        program = os.path.basename(tokens[index])
        if program == "git":
            subcommand = git_subcommand(tokens, index)
            if subcommand in MUTATING_GIT_SUBCOMMANDS:
                return f"git {subcommand} can mutate project files outside Xcode MCP."
            continue

        if program == "swift" and tokens[index + 1 : index + 3] == ["package", "update"]:
            return "swift package update mutates project dependency files outside Xcode MCP."

        if program in {"sed", "perl"}:
            in_place = any(
                token == "--in-place" or token.startswith("-i") or token.startswith("-p") and "i" in token
                for token in tokens[index + 1 :]
            )
            if in_place and tokens and targets_project(tokens[-1], cwd, root):
                return f"{program} in-place editing would bypass Xcode MCP."
            continue

        if program not in MUTATING_PROGRAMS:
            continue

        operands = [token for token in tokens[index + 1 :] if not token.startswith("-")]
        if program in {"cp", "install", "ln"}:
            targets = operands[-1:]
        else:
            targets = operands
        if any(targets_project(token, cwd, root) for token in targets):
            return f"{program} would mutate project content outside Xcode MCP."

    return None


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return

    root = Path(__file__).resolve().parents[2]
    cwd_value = payload.get("cwd")
    if not isinstance(cwd_value, str):
        return
    cwd = Path(cwd_value).resolve(strict=False)
    if not is_within(cwd, root):
        return

    tool_name = payload.get("tool_name")
    if tool_name == "apply_patch":
        deny("Project apply_patch is disabled. Use Xcode MCP file tools, or obtain explicit user permission for a fallback.")
        return
    if tool_name != "Bash":
        return

    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return
    command = tool_input.get("command", tool_input.get("cmd", ""))
    if not isinstance(command, str):
        return
    reason = mutation_reason(command, cwd, root)
    if reason:
        deny(f"{reason} Use Xcode MCP, or obtain explicit user permission for a fallback.")


if __name__ == "__main__":
    main()
