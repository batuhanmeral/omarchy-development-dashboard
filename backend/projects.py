"""Bounded project discovery and read-only Git inspection."""

from __future__ import annotations

import json
import os
import re
import stat
import tempfile
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
OBJECT_ID_LENGTHS = {"sha1": 40, "sha256": 64}

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


def run_project_git(
    project: Path,
    runner: CommandRunner,
    args: list[str],
    *,
    env: dict[str, str] | None = None,
) -> str:
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
            **(env or {}),
        },
    )


BOOLEAN_VALUES = {
    "true": "true",
    "yes": "true",
    "on": "true",
    "1": "true",
    "false": "false",
    "no": "false",
    "off": "false",
    "0": "false",
    "": "false",
}
# Repository-local settings that change what status reports, copied into the private
# Git directory after validation. Anything else in the repository config is never loaded.
STATUS_SETTINGS: dict[str, dict[str, str] | None] = {
    "core.filemode": BOOLEAN_VALUES,
    "core.ignorecase": BOOLEAN_VALUES,
    "core.symlinks": BOOLEAN_VALUES,
    "core.trustctime": BOOLEAN_VALUES,
    "core.precomposeunicode": BOOLEAN_VALUES,
    "core.autocrlf": BOOLEAN_VALUES | {"input": "input"},
    "core.eol": {"lf": "lf", "crlf": "crlf", "native": "native"},
    "core.checkstat": {"default": "default", "minimal": "minimal"},
    "core.excludesfile": None,
}
MAX_EXCLUDES = 1 << 20


def project_git_settings(project: Path, runner: CommandRunner) -> dict[str, str]:
    """Reject local filters and includes; return the validated local status settings."""
    names = "|".join(re.escape(name[5:]) for name in STATUS_SETTINGS)
    try:
        configured = run_project_git(
            project,
            runner,
            [
                "config",
                "--show-scope",
                "--no-includes",
                "-z",
                "--get-regexp",
                rf"^(filter|include|includeif)\.|^core\.({names})$",
            ],
        )
    except CommandFailed as exc:
        # git config exits 1 without stderr when no key matches.
        if exc.returncode != 1 or exc.stderr:
            raise
        return {}
    fields = configured.split("\0")
    settings: dict[str, str] = {}
    for scope, entry in zip(fields[0::2], fields[1::2], strict=False):
        if scope not in ("local", "worktree"):
            continue
        key, separator, value = entry.partition("\n")
        if key.startswith(("filter.", "include.", "includeif.")):
            raise CollectionError("Project uses local Git filters or includes.")
        allowed = STATUS_SETTINGS.get(key, {})
        if allowed is None:
            settings[key] = value
            continue
        normalized = allowed.get(value.lower() if separator else "true")
        if normalized is None:
            raise CollectionError("Project uses an unsupported Git status setting.")
        settings[key] = normalized
    return settings


def read_regular_bytes(path: Path, limit: int) -> bytes | None:
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            return None
        data = os.read(fd, limit + 1)
        return data if len(data) <= limit else None
    finally:
        os.close(fd)


def read_regular_file(path: Path, limit: int = 4096) -> str | None:
    data = read_regular_bytes(path, limit)
    return None if data is None else data.decode("utf-8", errors="strict")


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


def repository_paths(project: Path, runner: CommandRunner) -> tuple[Path, Path, Path, str]:
    """Return the index, object directory, exclude file and object format of a repository."""
    lines = run_project_git(
        project,
        runner,
        [
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "index",
            "--git-path",
            "objects",
            "--git-path",
            "info/exclude",
            "--show-object-format",
        ],
    ).splitlines()
    if (
        len(lines) != 4
        or lines[3] not in OBJECT_ID_LENGTHS
        or not all(Path(line).is_absolute() for line in lines[:3])
    ):
        raise CollectionError("unexpected repository layout")
    return Path(lines[0]), Path(lines[1]), Path(lines[2]), lines[3]


def head_commit(project: Path, runner: CommandRunner, object_format: str) -> str | None:
    try:
        raw = run_project_git(
            project, runner, ["rev-parse", "--quiet", "--verify", "HEAD^{commit}"]
        )
    except CommandFailed as exc:
        # An unborn branch exits 1 without stderr.
        if exc.returncode != 1 or exc.stderr:
            raise
        return None
    oid = raw.strip()
    if not re.fullmatch(f"[0-9a-f]{{{OBJECT_ID_LENGTHS[object_format]}}}", oid):
        raise CollectionError("unexpected HEAD")
    return oid


def current_branch(project: Path, runner: CommandRunner) -> str | None:
    """Return the checked-out branch, or None for a detached HEAD (also for reftable)."""
    try:
        raw = run_project_git(project, runner, ["symbolic-ref", "--quiet", "HEAD"])
    except CommandFailed as exc:
        if exc.returncode != 1 or exc.stderr:
            raise
        return None
    ref = raw.strip()
    if not ref.startswith("refs/heads/") or len(ref) == 11:
        raise CollectionError("unexpected HEAD")
    return ref[11:]


def ahead_behind(project: Path, runner: CommandRunner) -> tuple[int, int]:
    try:
        raw = run_project_git(
            project, runner, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}", "--"]
        )
    except CommandFailed:
        return 0, 0  # Unborn branch or no upstream.
    match = re.fullmatch(r"(\d+)\t(\d+)\n?", raw)
    return (int(match[1]), int(match[2])) if match else (0, 0)


def copy_patterns(source: Path, target: Path) -> None:
    """Copy an exclude file byte for byte; a missing file is an empty one."""
    try:
        data = read_regular_bytes(source, MAX_EXCLUDES)
    except FileNotFoundError:
        data = b""
    if data is None:
        raise CollectionError("unsupported exclude file")
    target.write_bytes(data)


def excludes_path(project: Path, value: str) -> Path:
    # Git resolves a relative core.excludesFile against the top of the work tree.
    if value == "~" or value.startswith("~/"):
        return Path.home() / value[2:]
    path = Path(value)
    if value.startswith(("~", "%(prefix)")) or not value:
        raise CollectionError("unsupported exclude file")
    return path if path.is_absolute() else project / path


def config_value(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_private_git_dir(
    gitdir: Path,
    project: Path,
    head: str | None,
    object_format: str,
    exclude: Path,
    settings: dict[str, str],
) -> None:
    """Create a Git directory whose configuration and attributes only this process controls."""
    for name in ("refs", "objects", "info"):
        (gitdir / name).mkdir()
    (gitdir / "HEAD").write_text(f"{head}\n" if head else "ref: refs/heads/main\n")
    copy_patterns(exclude, gitdir / "info" / "exclude")
    core = [
        f"\trepositoryFormatVersion = {1 if object_format == 'sha256' else 0}",
        "\tbare = false",
    ]
    for key, value in settings.items():
        if key == "core.excludesfile":
            copy_patterns(excludes_path(project, value), gitdir / "excludes")
            value = str(gitdir / "excludes")
        core.append(f"\t{key[5:]} = {config_value(value)}")
    extensions = "[extensions]\n\tobjectFormat = sha256\n" if object_format == "sha256" else ""
    (gitdir / "config").write_text(
        "[core]\n" + "\n".join(core) + "\n" + extensions, encoding="utf-8"
    )


def private_temp_root() -> str | None:
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    return runtime if os.path.isabs(runtime) and os.path.isdir(runtime) else None


def git_status(project: Path, runner: CommandRunner) -> dict[str, Any]:
    result = unknown_status(project)
    if not has_git_marker(project):
        return result
    try:
        # Rejects local filters and includes because status would be inaccurate without
        # them. It is not the security boundary: the configuration can change afterwards.
        settings = project_git_settings(project, runner)
        index, objects, exclude, object_format = repository_paths(project, runner)
        branch = current_branch(project, runner)
        head = head_commit(project, runner, object_format)
        if branch is None and head is None:
            raise CollectionError("HEAD does not name a commit")
        if head is not None and not index.is_file():
            raise CollectionError("index unavailable")
        ahead, behind = ahead_behind(project, runner) if branch is not None else (0, 0)
        # Status reads only the index, objects and work tree of the repository. Its
        # configuration and info/attributes come from a private directory, so filters,
        # includes or hooks added to the repository at any time are never loaded.
        with tempfile.TemporaryDirectory(
            prefix="development-dashboard-git-", dir=private_temp_root()
        ) as tmp:
            gitdir = Path(tmp)
            write_private_git_dir(gitdir, project, head, object_format, exclude, settings)
            raw = run_project_git(
                project,
                runner,
                [
                    "-c",
                    "core.untrackedCache=false",
                    f"--git-dir={gitdir}",
                    f"--work-tree={project}",
                    "status",
                    "--porcelain=v2",
                    "-z",
                    "--untracked-files=normal",
                    "--ignore-submodules=all",
                ],
                env={"GIT_INDEX_FILE": str(index), "GIT_OBJECT_DIRECTORY": str(objects)},
            )
        if branch is None and head is not None:
            result.update(branch=head[:7], detached=True)
        else:
            result.update(branch=clean(branch or "", 256) or None, detached=False)
        result.update(ahead=ahead, behind=behind)
        records = iter(raw.split("\0"))
        for record in records:
            if record.startswith(("1 ", "2 ")):
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
    except (CollectionError, OSError, UnicodeError):
        result = unknown_status(project)
    return result
