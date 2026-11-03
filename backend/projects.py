"""Bounded project discovery and read-only Git inspection."""

from __future__ import annotations

import os
import re
import stat
import time
from pathlib import Path
from typing import Any

from collector import CollectionError, CommandFailed, CommandRunner, clean

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
MAX_VISITED_DIRECTORIES = 20000
SCAN_BUDGET = 8.0
SCAN_STOPPED = "Project scan stopped early (limit reached); showing partial results."
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
        str(resolved).encode("utf-8", errors="strict")
        if (
            len(str(resolved)) > 4096
            or any(ch in str(resolved) for ch in "\0\n\r")
            or resolved == Path("/")
            or any(resolved == Path(root) or Path(root) in resolved.parents for root in FORBIDDEN)
            or not resolved.is_dir()
        ):
            raise ValueError
    except (ValueError, OSError, RuntimeError, UnicodeError) as exc:
        raise CollectionError("invalid project folder") from exc
    return resolved


def read_git_file(path: Path) -> str | None:
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
            return None
        return os.read(fd, 4096).decode("utf-8", errors="strict")
    finally:
        os.close(fd)


def head_branch(project: Path) -> tuple[str | None, bool]:
    try:
        gitdir = project / ".git"
        if not gitdir.is_dir():
            pointer = read_git_file(gitdir)
            if pointer is None or not pointer.startswith("gitdir: "):
                return None, False
            gitdir = project / pointer[8:].strip()
        if not gitdir.is_dir():
            return None, False
        raw = read_git_file(gitdir / "HEAD")
        if raw is None:
            return None, False
        head = raw.strip()
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


def discover(
    roots: list[str],
    depth: int,
    limit: int = 512,
    *,
    errors: list[str] | None = None,
) -> tuple[list[dict[str, Any]], int]:
    if not 1 <= depth <= 4 or len(roots) > 16 or not 1 <= limit <= 512:
        raise CollectionError("project scan limit exceeded")
    projects: list[dict[str, Any]] = []
    seen: set[Path] = set()
    skipped = 0
    visited = 0
    stopped = False
    deadline = time.monotonic() + SCAN_BUDGET

    def expired() -> bool:
        nonlocal stopped
        if time.monotonic() >= deadline:
            stopped = True
        return stopped

    def visit(path: Path, root: Path, level: int) -> None:
        nonlocal skipped, visited, stopped
        if len(projects) >= limit or expired():
            return
        try:
            if any(ch in str(path) for ch in "\0\n\r"):
                skipped += 1
                return
            str(path).encode("utf-8", errors="strict")
            real = path.resolve()
            if real in seen:
                return
            if visited >= MAX_VISITED_DIRECTORIES:
                stopped = True
                return
            visited += 1
            seen.add(real)
            try:
                marker = (path / ".git").lstat()
            except FileNotFoundError:
                marker = None
            if marker and (stat.S_ISDIR(marker.st_mode) or stat.S_ISREG(marker.st_mode)):
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
            # Stream entries so a huge directory cannot consume unbounded time or memory.
            with os.scandir(path) as entries:
                for entry in entries:
                    if len(projects) >= limit or expired():
                        return
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
        if expired():
            break
        root = validate_root(value)
        visit(root, root, 0)
    if stopped and errors is not None:
        errors.append(SCAN_STOPPED)
    return projects, skipped


def git_status(project: Path, runner: CommandRunner) -> dict[str, Any]:
    result = unknown_status(project)
    env = {"GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"}
    try:
        try:
            configured = runner.run(
                [
                    "git",
                    "-C",
                    str(project),
                    "config",
                    "--local",
                    "--name-only",
                    "--get-regexp",
                    r"^(filter|include|includeif)\.",
                ],
                timeout=2,
                env=env,
            )
        except CommandFailed as exc:
            # git config exits 1, without stderr, when no key matches the expression.
            if exc.returncode != 1 or exc.stderr:
                raise
            configured = ""
        if configured.strip():
            return result
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
                "--ignore-submodules=all",
            ],
            timeout=2,
            env=env,
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
