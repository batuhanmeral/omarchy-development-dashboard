"""Resolve trusted executable files and construct literal argument vectors."""

from __future__ import annotations

import os
import re
import stat
from pathlib import Path
from typing import Any

from collector import CollectionError

EXTRA_DIRS = (
    "~/.local/bin",
    "~/bin",
    "~/.npm-global/bin",
    "~/.bun/bin",
    "~/.volta/bin",
    "~/.opencode/bin",
    "~/.local/share/mise/shims",
    "~/.cargo/bin",
)
BUILTINS = (
    ("claude", "Claude Code", "claude"),
    ("codex", "OpenAI Codex CLI", "codex"),
    ("gemini", "Gemini CLI", "gemini"),
    ("opencode", "OpenCode", "opencode"),
)
BARE_NAME = re.compile(r"[A-Za-z0-9._+-]{1,64}")


def valid_executable(value: str) -> bool:
    try:
        value.encode("utf-8", errors="strict")
    except UnicodeError:
        return False
    return bool(
        value
        and len(value) <= 4096
        and not any(c in value for c in "\0\n\r")
        and ".." not in Path(value).parts
        and (Path(value).is_absolute() or BARE_NAME.fullmatch(value))
    )


def resolve_executable(name_or_path: str) -> Path:
    if not valid_executable(name_or_path):
        raise CollectionError("not found")
    search_dirs = [
        Path(directory)
        for directory in os.environ.get("PATH", "").split(os.pathsep)
        if directory and Path(directory).is_absolute()
    ]
    search_dirs.extend(Path(directory).expanduser() for directory in EXTRA_DIRS)
    candidates = (
        [Path(name_or_path)]
        if Path(name_or_path).is_absolute()
        else [directory / name_or_path for directory in search_dirs if directory.is_absolute()]
    )
    for candidate in candidates:
        try:
            link = candidate.lstat()
            target = candidate.resolve(strict=True)
            if not valid_executable(str(target)):
                raise CollectionError("not executable")
            info = target.stat()
            # Linux symlink mode bits are always 0777 and have no access semantics.
            if (
                link.st_uid not in (0, os.getuid())
                or info.st_uid not in (0, os.getuid())
                or info.st_mode & 0o022
                or (not stat.S_ISLNK(link.st_mode) and link.st_mode & 0o022)
            ):
                raise CollectionError("unsafe permissions")
            if not stat.S_ISREG(info.st_mode) or not os.access(target, os.X_OK):
                raise CollectionError("not executable")
            return candidate.absolute()
        except (FileNotFoundError, NotADirectoryError):
            continue
        except (OSError, RuntimeError) as exc:
            raise CollectionError("not executable") from exc
    raise CollectionError("not found")


def parse_custom_tool(line: str, index: int) -> dict[str, Any] | None:
    if not line.strip() or line.lstrip().startswith("#"):
        return None
    parts = line.split("|")
    if len(parts) not in (2, 3) or any(not ch.isprintable() for ch in line):
        raise CollectionError("invalid definition")
    name, executable = (value.strip() for value in parts[:2])
    args = parts[2].split() if len(parts) == 3 else []
    if (
        not 1 <= len(name) <= 48
        or not valid_executable(executable)
        or len(args) > 16
        or any(len(arg) > 256 for arg in args)
    ):
        raise CollectionError("invalid definition")
    return dict(id=f"custom-{index}", name=name, builtin=False, executable=executable, args=args)


def detect_tools(custom_lines: list[str]) -> dict[str, Any]:
    lines = [line for line in custom_lines if line.strip() and not line.lstrip().startswith("#")]
    if len(lines) > 8:
        raise CollectionError("custom tool limit exceeded (8)")
    definitions: list[dict[str, Any]] = [
        dict(id=id_, name=name, builtin=True, executable=exe, args=[])
        for id_, name, exe in BUILTINS
    ]
    for index, line in enumerate(lines, 1):
        try:
            definition = parse_custom_tool(line, index)
            if definition is not None:
                definitions.append(definition)
        except CollectionError:
            definitions.append(
                dict(
                    id=f"custom-{index}",
                    name=f"Custom tool {index}",
                    builtin=False,
                    executable="",
                    args=[],
                )
            )
    for row in definitions:
        row.update(path=None, available=False, reason="")
        try:
            if not row["executable"]:
                raise CollectionError("invalid definition")
            row.update(path=str(resolve_executable(row["executable"])), available=True)
        except CollectionError as exc:
            row["reason"] = str(exc)
    return dict(tools=definitions)


def terminal_argv(name: str, directory: str, command: list[str] | None) -> list[str]:
    terminals = {
        "default": ("xdg-terminal-exec", [f"--dir={directory}"], ["--"]),
        "alacritty": ("alacritty", ["--working-directory", directory], ["-e"]),
        "foot": ("foot", [f"--working-directory={directory}"], []),
        "ghostty": ("ghostty", [f"--working-directory={directory}"], ["-e"]),
        "kitty": ("kitty", ["--directory", directory], []),
    }
    if name not in terminals:
        raise CollectionError("invalid terminal")
    executable, args, separator = terminals[name]
    return [str(resolve_executable(executable)), *args, *(separator + command if command else [])]


def editor_argv(spec: str, directory: str) -> list[str]:
    if len(spec) > 256 or any(not ch.isprintable() for ch in spec):
        raise CollectionError("invalid editor")
    parts = spec.split() if spec.strip() else ["omarchy-launch-editor"]
    if len(parts) > 9:
        raise CollectionError("invalid editor")
    return [str(resolve_executable(parts[0])), *parts[1:], directory]
