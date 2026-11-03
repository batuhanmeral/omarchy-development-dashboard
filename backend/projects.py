"""Bounded project discovery and read-only Git inspection."""

from __future__ import annotations

import json
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

ENV_PORT = re.compile(
    r"""^[^\S\n]*(?:export[^\S\n]+)?(?:PORT|(?:[A-Za-z_][A-Za-z0-9_]*)?_PORT)[^\S\n]*=[^\S\n]*"""
    r"""(["']?)0*(?P<port>[0-9]{1,5})\1[^\S\n]*(?:#[^\n]*)?$""",
    re.MULTILINE,
)
SCRIPT_PORT = re.compile(
    r"(?:^|[\s;&|])(?:--port[= \t]+|-p[ \t]+|PORT=)0*(?P<port>[0-9]{1,5})(?=$|[\s;&|])"
)
COMPOSE_PORT = re.compile(
    r"""(["'])(?:[\w.]+:|\[[\da-fA-F:]+\]:)?0*(?P<port>[0-9]{1,5}):[0-9]{1,5}(?:/(?:tcp|udp))?\1"""
)


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


def project_directory(path: str, roots: list[str]) -> Path:
    if ".." in Path(path).parts or len(roots) > 16:
        raise CollectionError("path is not inside a project folder")
    directory = validate_root(path)
    resolved_roots = [validate_root(root) for root in roots]
    if not any(directory == root or root in directory.parents for root in resolved_roots):
        raise CollectionError("path is not inside a project folder")
    try:
        if directory.stat().st_uid != os.getuid():
            raise CollectionError("The project folder is not owned by you")
    except OSError as exc:
        raise CollectionError("The project folder is not owned by you") from exc
    return directory


def has_git_marker(project: Path) -> bool:
    try:
        mode = (project / ".git").lstat().st_mode
    except OSError:
        return False
    return stat.S_ISDIR(mode) or stat.S_ISREG(mode)


def run_project_git(project: Path, runner: CommandRunner, args: list[str]) -> str:
    return runner.run(
        [
            "git",
            "--no-optional-locks",
            "-c",
            "protocol.allow=never",
            "-c",
            "core.fsmonitor=false",
            "-C",
            str(project),
            *args,
        ],
        timeout=2,
        env={
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_ALLOW_PROTOCOL": "",
            "GIT_CEILING_DIRECTORIES": str(project.parent),
        },
    )


def check_project_git_config(project: Path, runner: CommandRunner) -> None:
    try:
        configured = run_project_git(
            project,
            runner,
            [
                "config",
                "--show-scope",
                "--no-includes",
                "--name-only",
                "--get-regexp",
                r"^(filter|include|includeif)\.",
            ],
        )
    except CommandFailed as exc:
        # git config exits 1 without stderr when no key matches.
        if exc.returncode != 1 or exc.stderr:
            raise
        return
    if any(line.partition("\t")[0] in ("local", "worktree") for line in configured.splitlines()):
        raise CollectionError("Project uses local Git filters or includes.")


def read_regular_file(path: Path, limit: int = 4096) -> str | None:
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            return None
        data = os.read(fd, limit + 1)
        return data.decode("utf-8", errors="strict") if len(data) <= limit else None
    finally:
        os.close(fd)


def expected_ports(project: Path) -> list[dict[str, int | str]]:
    result: list[dict[str, int | str]] = []
    seen: set[tuple[int, str]] = set()
    patterns = (
        (".env", ENV_PORT),
        (".env.local", ENV_PORT),
        (".env.development", ENV_PORT),
        ("package.json", SCRIPT_PORT),
        ("docker-compose.yml", COMPOSE_PORT),
        ("compose.yaml", COMPOSE_PORT),
    )
    for name, pattern in patterns:
        try:
            content = read_regular_file(project / name, 65536)
        except (OSError, UnicodeError):
            continue
        if content is None:
            continue
        inputs = [content]
        if name == "package.json":
            try:
                package = json.loads(content)
            except (ValueError, RecursionError):
                continue
            scripts = package.get("scripts") if isinstance(package, dict) else None
            if not isinstance(scripts, dict):
                continue
            inputs = [value for value in scripts.values() if isinstance(value, str)]
        for value in inputs:
            for match in pattern.finditer(value):
                number = int(match["port"])
                entry = (number, name)
                if not 1 <= number <= 65535 or entry in seen:
                    continue
                seen.add(entry)
                result.append({"port": number, "source": name})
                if len(result) == 16:
                    return result
    return result


def head_branch(project: Path) -> tuple[str | None, bool]:
    try:
        gitdir = project / ".git"
        if not gitdir.is_dir():
            pointer = read_regular_file(gitdir)
            if pointer is None or not pointer.startswith("gitdir: "):
                return None, False
            gitdir = project / pointer[8:].strip()
        if not gitdir.is_dir():
            return None, False
        raw = read_regular_file(gitdir / "HEAD")
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
            if has_git_marker(path):
                projects.append(
                    dict(
                        id="project:" + str(real),
                        name=clean(real.name),
                        path=str(real),
                        root=str(root),
                        expectedPorts=expected_ports(real),
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
    if not has_git_marker(project):
        return result
    try:
        check_project_git_config(project, runner)
        raw = run_project_git(
            project,
            runner,
            [
                "-c",
                "core.untrackedCache=false",
                "status",
                "--porcelain=v2",
                "--branch",
                "-z",
                "--untracked-files=normal",
                "--ignore-submodules=all",
            ],
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
