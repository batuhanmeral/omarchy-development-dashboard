"""Bounded project discovery and read-only Git inspection."""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

from collector import CollectionError, CommandRunner, clean

FORBIDDEN = (
    "/proc",
    "/sys",
    "/dev",
    "/run",
    "/boot",
    "/etc",
    "/usr",
    "/bin",
    "/sbin",
    "/lib",
    "/lib64",
    "/var/lib/docker",
)
PRUNED = {"node_modules", "vendor", "target", "build", "dist", "venv", "__pycache__"}


def validate_root(path: str) -> Path:
    try:
        if (
            not isinstance(path, str)
            or not path
            or len(path) > 4096
            or any(ch in path for ch in "\0\n\r")
            or not Path(path).is_absolute()
        ):
            raise ValueError
        path.encode("utf-8", errors="strict")
        resolved = Path(path).resolve()
        if (
            resolved == Path("/")
            or any(resolved == Path(root) or Path(root) in resolved.parents for root in FORBIDDEN)
            or not resolved.is_dir()
        ):
            raise ValueError
    except (ValueError, OSError, RuntimeError, UnicodeError) as exc:
        raise CollectionError("invalid project folder") from exc
    return resolved


def head_branch(project: Path) -> tuple[str | None, bool]:
    try:
        gitdir = project / ".git"
        if gitdir.is_file():
            with gitdir.open("r", encoding="utf-8") as stream:
                pointer = stream.read(4097)
            if len(pointer.encode("utf-8")) > 4096 or not pointer.startswith("gitdir: "):
                return None, False
            gitdir = project / pointer[8:].strip()
        with (gitdir / "HEAD").open("r", encoding="utf-8") as stream:
            head = stream.read(4097).strip()
        if head.startswith("ref: refs/heads/"):
            return clean(head[16:], 256) or None, False
        if re.fullmatch(r"[a-fA-F0-9]{40}|[a-fA-F0-9]{64}", head):
            return head[:7], True
    except (OSError, UnicodeError, ValueError):
        pass
    return None, False


def unknown_status(project: Path) -> dict[str, Any]:
    branch, detached = head_branch(project)
    return dict(
        branch=branch,
        detached=detached,
        ahead=0,
        behind=0,
        changed=0,
        untracked=0,
        conflicts=0,
        gitState="unknown",
    )


def discover(roots: list[str], depth: int, limit: int = 512) -> tuple[list[dict[str, Any]], int]:
    if not 1 <= depth <= 4 or len(roots) > 16 or not 1 <= limit <= 512:
        raise CollectionError("project scan limit exceeded")
    projects: list[dict[str, Any]] = []
    seen: set[Path] = set()
    skipped = 0

    def visit(path: Path, root: Path, level: int) -> None:
        nonlocal skipped
        if len(projects) >= limit:
            return
        try:
            str(path).encode("utf-8", errors="strict")
            real = path.resolve()
            if real in seen:
                return
            seen.add(real)
            with os.scandir(path) as entries:
                children = sorted(entries, key=lambda entry: entry.name)
            if any(
                entry.name == ".git"
                and (entry.is_file(follow_symlinks=False) or entry.is_dir(follow_symlinks=False))
                for entry in children
            ):
                projects.append(
                    dict(
                        id="project:" + str(real),
                        name=clean(real.name),
                        path=str(real),
                        root=str(root),
                        **unknown_status(real),
                    )
                )
                return
            if level >= depth:
                return
            for entry in children:
                if (
                    not entry.name.startswith(".")
                    and entry.name not in PRUNED
                    and entry.is_dir(follow_symlinks=False)
                ):
                    visit(Path(entry.path), root, level + 1)
        except UnicodeError:
            skipped += 1
        except (OSError, RuntimeError):
            pass

    for value in roots:
        root = validate_root(value)
        visit(root, root, 0)
    return projects, skipped


def git_status(project: Path, runner: CommandRunner) -> dict[str, Any]:
    result = unknown_status(project)
    try:
        raw = runner.run(
            [
                "git",
                "--no-optional-locks",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.untrackedCache=false",
                "-C",
                str(project),
                "status",
                "--porcelain=v2",
                "--branch",
                "-z",
                "--untracked-files=normal",
            ],
            timeout=2,
            env={"GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"},
        )
        records = iter(raw.split("\0"))
        for record in records:
            if record.startswith("# branch.head "):
                branch = record[14:]
                if branch == "(detached)":
                    result["detached"] = True
                else:
                    result.update(branch=clean(branch, 256), detached=False)
            elif record.startswith("# branch.ab "):
                match = re.fullmatch(r"# branch.ab \+(\d+) -(\d+)", record)
                if match:
                    result.update(ahead=int(match[1]), behind=int(match[2]))
            elif record.startswith(("1 ", "2 ")):
                result["changed"] += 1
                if record.startswith("2 "):
                    next(records, None)  # Rename source is a second NUL-delimited pathname.
            elif record.startswith("u "):
                result["conflicts"] += 1
            elif record.startswith("? "):
                result["untracked"] += 1
        result["gitState"] = (
            "dirty" if any(result[k] for k in ("changed", "untracked", "conflicts")) else "clean"
        )
    except CollectionError:
        pass
    return result
