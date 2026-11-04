#!/usr/bin/env python3
"""On-demand, local-only inventory. Stdout is exactly one versioned JSON object."""

from __future__ import annotations

import argparse
import functools
import ipaddress
import json
import os
import pwd
import re
import selectors
import shutil
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, NoReturn, Protocol

MAX_ROWS = 4096
MAX_BYTES = 2 * 1024 * 1024


class CollectionError(Exception):
    """A safe, non-sensitive diagnostic suitable for the UI."""


class CLIParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise CollectionError("invalid arguments")


class CommandFailed(CollectionError):
    """A failed command with bounded, display-safe stderr for classification."""

    def __init__(self, message: str, stderr: str, returncode: int | None = None):
        super().__init__(message)
        self.returncode = returncode
        safe = "\n".join(clean(line, 4096) for line in stderr.splitlines())
        self.stderr = safe.encode("utf-8", errors="replace")[-4096:].decode(
            "utf-8", errors="ignore"
        )


class CommandRunner(Protocol):
    def run(
        self,
        argv: list[str],
        *,
        merge_stderr: bool = False,
        timeout: float | None = None,
        env: dict[str, str] | None = None,
    ) -> str: ...


class Runner:
    """Bound wall time and memory while draining both pipes; always reap children."""

    def __init__(self, timeout: float = 3.0, budget: float = 12.0, max_bytes: int = MAX_BYTES):
        self.timeout = timeout
        self.deadline = time.monotonic() + budget
        self.max_bytes = max_bytes

    def run(
        self,
        argv: list[str],
        *,
        merge_stderr: bool = False,
        timeout: float | None = None,
        env: dict[str, str] | None = None,
    ) -> str:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise CollectionError("request budget exceeded")
        deadline = time.monotonic() + min(remaining, self.timeout if timeout is None else timeout)
        inherited = dict(os.environ)
        if Path(argv[0]).name == "git":
            inherited = {
                key: value for key, value in inherited.items() if not key.startswith("GIT_")
            }
        env = inherited | (env or {})
        search_path = os.pathsep.join(
            entry for entry in env.get("PATH", os.defpath).split(os.pathsep) if os.path.isabs(entry)
        )
        env["PATH"] = search_path
        env["LC_ALL"] = "C"
        # Explicit local --host always wins over ambient Docker contexts.
        env.pop("DOCKER_CONTEXT", None)
        try:
            executable = shutil.which(argv[0], path=search_path)
            if executable is None or not os.path.isabs(executable):
                raise FileNotFoundError
            resolved_argv = [executable, *argv[1:]]
            # Internal callers build argv and environment separately from external data.
            # The executable is absolute and no shell interprets the individual arguments.
            child = subprocess.Popen(  # noqa: S603 — internal fixed argv, never a shell
                resolved_argv,  # nosemgrep: dangerous-subprocess-use-tainted-env-args
                shell=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )
        except OSError as exc:
            raise CollectionError(f"{Path(argv[0]).name} unavailable") from exc
        output = bytearray()
        stderr = bytearray()
        size = 0
        try:
            with selectors.DefaultSelector() as selector:
                if child.stdout is None or child.stderr is None:
                    raise CollectionError("command pipes unavailable")
                selector.register(child.stdout, selectors.EVENT_READ, "stdout")
                selector.register(child.stderr, selectors.EVENT_READ, "stderr")
                while selector.get_map():
                    wait = deadline - time.monotonic()
                    if wait <= 0:
                        raise CollectionError(f"{Path(argv[0]).name} timeout")
                    for key, _ in selector.select(min(wait, 0.1)):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        size += len(chunk)
                        if size > self.max_bytes:
                            raise CollectionError("command output limit exceeded")
                        if key.data == "stderr":
                            stderr.extend(chunk)
                            del stderr[:-4096]
                        if key.data == "stdout" or merge_stderr:
                            output.extend(chunk)
                try:
                    status = child.wait(timeout=max(0.001, deadline - time.monotonic()))
                except subprocess.TimeoutExpired as exc:
                    raise CollectionError("command timeout") from exc
                if status != 0:
                    raise CommandFailed(
                        f"{Path(argv[0]).name} failed (exit {status})",
                        stderr.decode("utf-8", errors="replace"),
                        returncode=status,
                    )
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
            if child.stdout:
                child.stdout.close()
            if child.stderr:
                child.stderr.close()
        return output.decode("utf-8", errors="replace")


def clean(value: Any, limit: int = 512) -> str:
    """Keep external text bounded and remove terminal control characters."""
    return "".join(ch for ch in str(value or "") if ch.isprintable())[:limit]


def docker_error(exc: CollectionError) -> str:
    detail = getattr(exc, "stderr", "")
    lowered = detail.lower()
    if "permission denied" in lowered:
        return "Permission denied: your user cannot use the Docker socket."
    if "no such container" in lowered:
        return "The container no longer exists."
    if "cannot connect to the docker daemon" in lowered:
        return "The Docker daemon is not running."
    if "timeout" in str(exc).lower() or "budget" in str(exc).lower():
        return "Docker did not answer in time."
    first = clean(detail.splitlines()[0], 200) if detail else ""
    return str(exc) + (": " + first if first else "")


SECRET_NAME = re.compile(
    r"pw|pass|passwd|secret|token|key|apikey|auth|credential|cred|jwt|bearer|session|sig",
    re.IGNORECASE,
)
SECRET_HEADER = re.compile(r"(?:^|=)([A-Za-z0-9_-]+):(\s*)(.*)$", re.DOTALL)
URL_USERINFO = re.compile(r"(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*://)(?=[^/\s?#]*@)[^\s]*@")
DSN_USERINFO = re.compile(r"""(?<![^\s="'(])[^=\s:@/;"'()]+:(?!//)[^\s@]+@""")
PASSWORD_VALUE = re.compile(r"\b((?:password|pwd)=)[^;&\s]*", re.IGNORECASE)
PROVIDER_TOKEN = re.compile(
    r"(?<![A-Za-z0-9_-])(?:ghp_|gho_|github_pat_|glpat-|sk-|xox[abp]-)[A-Za-z0-9_-]+"
)
MAX_COMMAND_CHARS = 512
MAX_ARGUMENT_CHARS = 4096


def redact_inline(value: str) -> str:
    value = URL_USERINFO.sub(r"\1***@", value)
    value = DSN_USERINFO.sub("***@", value)
    value = PASSWORD_VALUE.sub(r"\1***", value)
    return PROVIDER_TOKEN.sub("***", value)


def redact_user(value: str) -> str:
    user, separator, _ = value.partition(":")
    return redact_inline(user) + (":***" if separator else "")


def redact_argument(value: str, next_value: str) -> tuple[str, str]:
    if next_value == "secret" or len(value) > MAX_ARGUMENT_CHARS:
        return "***", ""
    if next_value == "user":
        return redact_user(value), ""

    header = SECRET_HEADER.search(value)
    if header and (SECRET_NAME.search(header[1]) or header[1].lower() in ("cookie", "set-cookie")):
        prefix = value[: header.start(3)]
        return (prefix + "***", "") if header[3] else (prefix.rstrip(), "secret")

    name, separator, argument = value.partition("=")
    if name in ("-u", "--user"):
        return (name + separator + redact_user(argument), "") if separator else (name, "user")
    if value.startswith("-u") and ":" in value[2:]:
        return "-u" + redact_user(value[2:]), ""
    if value.startswith(("-p", "-P")):
        if len(value) == 2:
            return value, "secret"
        return value[:2] + ("=" if value[2] == "=" else "") + "***", ""
    if name.lower().lstrip("-") == "pat" or (
        SECRET_NAME.search(name) and (value.startswith("-") or separator)
    ):
        return (name + "=***", "") if separator else (name, "secret")
    return redact_inline(value), ""


def redact_command(argv: list[str]) -> str:
    parts: list[str] = []
    remaining = MAX_COMMAND_CHARS
    next_value = ""
    for value in argv:
        if parts:
            parts.append(" ")
            remaining -= 1
            if remaining == 0:
                break
        # Mask the entire argument before clipping, even when its @ or delimiters
        # are past the output budget.
        masked, next_value = redact_argument(value, next_value)
        part = clean(masked, remaining)
        parts.append(part)
        remaining -= len(part)
        if remaining == 0:
            break
    return "".join(parts)


def endpoint(value: str) -> tuple[str, int] | None:
    try:
        host, raw_port = value.rsplit(":", 1)
        host = host.strip("[]")
        if host == "*":
            host = "0.0.0.0"  # noqa: S104 — parsing a wildcard, not binding a socket
        ipaddress.ip_address(host.split("%", 1)[0])
        port = int(raw_port)
        if not 1 <= port <= 65535:
            return None
        if "%" in host and not re.fullmatch(r"[0-9A-Fa-f.:]+%[A-Za-z0-9_.-]+", host):
            return None
        return host, port
    except (ValueError, TypeError):
        return None


def exposure(address: str) -> str:
    ip = ipaddress.ip_address(address.split("%", 1)[0])
    return "localhost" if ip.is_loopback else "all" if ip.is_unspecified else "lan"


def port_row(address: str, port: int) -> dict[str, Any]:
    return dict(
        id=f"tcp:{address}:{port}",
        address=address,
        port=port,
        exposure=exposure(address),
        process="Unknown",
        pid=None,
        owner="Unknown",
        cwd=None,
        startedAt=None,
        uid=None,
        ownedByUser=False,
        startTicks=None,
        command=None,
        containerIds=[],
        database=None,
        protocol=None,
        state="running",
    )


def parse_ss(output: str) -> list[dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for line in output.splitlines():
        fields = line.split(None, 5)
        if len(fields) < 5 or fields[0] != "LISTEN":
            continue
        parsed = endpoint(fields[3])
        if parsed is None:
            continue
        row = port_row(*parsed)
        match = re.search(r'\("([^"\n]*)",pid=(\d+)', fields[5] if len(fields) > 5 else "")
        if match:
            row.update(process=clean(match[1]), pid=int(match[2]))
        rows[row["id"]] = row
        if len(rows) > MAX_ROWS:
            raise CollectionError("port row limit exceeded")
    return sorted(rows.values(), key=lambda row: (row["port"], row["address"]))


@functools.cache
def boot_time(proc_root: Path) -> int | None:
    """Read once per collector run; /proc/stat is large on many-core machines."""
    try:
        boot = re.search(r"^btime (\d+)$", (proc_root / "stat").read_text(), re.MULTILINE)
    except OSError:
        return None
    return int(boot[1]) if boot else None


def process_metadata(pid: int, proc_root: Path = Path("/proc")) -> dict[str, Any]:
    unknown: dict[str, Any] = dict(
        process="Unknown",
        owner="Unknown",
        cwd=None,
        startedAt=None,
        uid=None,
        ownedByUser=False,
        startTicks=None,
        command=None,
    )
    result = dict(unknown)
    directory = proc_root / str(pid)
    try:
        before = (directory / "stat").read_text().rsplit(") ", 1)[1].split()[19]
        if not re.fullmatch(r"[0-9]+", before):
            return unknown
        result["process"] = clean((directory / "comm").read_text().strip()) or "Unknown"
        uid = directory.stat().st_uid
        result.update(uid=uid, ownedByUser=uid == os.getuid() and uid != 0, startTicks=before)
        try:
            with (directory / "cmdline").open("rb") as stream:
                raw = stream.read(65536)
            result["command"] = redact_command(
                raw.decode("utf-8", errors="replace").split("\0")[:-1]
            )
        except OSError:
            pass
        try:
            result["owner"] = clean(pwd.getpwuid(uid).pw_name)
        except KeyError:
            result["owner"] = str(uid)
        try:
            result["cwd"] = clean(os.readlink(directory / "cwd"), 2048)
        except OSError:
            pass
        # Boot time plus the start tick is stable across polls, so unchanged rows stay unchanged.
        boot = boot_time(proc_root)
        if boot is not None:
            result["startedAt"] = boot + int(before) // os.sysconf("SC_CLK_TCK")
        after = (directory / "stat").read_text().rsplit(") ", 1)[1].split()[19]
        if before != after:
            return unknown
    except (OSError, ValueError, IndexError):
        return unknown
    return result


# Project only fields needed by the UI: never Env, Cmd, complete Labels or health logs.
CONTAINER_FORMAT = (
    '{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},'
    '"imageId":{{json .Image}},"state":{{json .State.Status}},'
    # Missing-key safe: Docker 29 omits State.Health when no healthcheck exists.
    '"health":{{with index .State "Health"}}{{json .Status}}{{else}}null{{end}},'
    '"ports":{{json .NetworkSettings.Ports}},"bindings":{{json .HostConfig.PortBindings}},'
    '"restart":{{json .HostConfig.RestartPolicy.Name}},'
    '"compose":{{json (index .Config.Labels "com.docker.compose.project")}},'
    '"exposed":{{json .Config.ExposedPorts}},'
    '"workdir":{{json (index .Config.Labels "com.docker.compose.project.working_dir")}},'
    '"mounts":{{json .Mounts}}}'
)
VOLUME_FORMAT = '{"name":{{json .Name}},"mountpoint":{{json .Mountpoint}}}'
ID_PATTERN = re.compile(r"[a-f0-9]{64}")


def json_lines(raw: str) -> list[dict[str, Any]]:
    rows = []
    try:
        for line in raw.splitlines():
            if not line.strip():
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError("not an object")
            rows.append(value)
            if len(rows) > MAX_ROWS:
                raise CollectionError("inventory row limit exceeded")
    except (ValueError, TypeError) as exc:
        raise CollectionError("invalid Docker JSON") from exc
    return rows


def database_type(evidence: str) -> str | None:
    value = evidence.lower()
    name = value.rsplit("/", 1)[-1].split(":", 1)[0].split("@", 1)[0]
    known = {
        "postgres": "PostgreSQL",
        "postgresql": "PostgreSQL",
        "mysqld": "MySQL",
        "mysql": "MySQL",
        "mariadb": "MariaDB",
        "mariadbd": "MariaDB",
        "mongo": "MongoDB",
        "mongod": "MongoDB",
        "redis": "Redis",
        "redis-server": "Redis",
        "sqlservr": "Microsoft SQL Server",
    }
    if value.startswith("mcr.microsoft.com/mssql/server:"):
        return "Microsoft SQL Server"
    return known.get(name)


def web_protocol(evidence: str) -> str | None:
    name = evidence.lower().rsplit("/", 1)[-1].split(":", 1)[0]
    # A process/image name does not prove its TLS configuration. Leave scheme unknown.
    # URL actions require explicit user selection in the details view.
    return "http" if name in ("vite", "http-server") else None


def local_docker(runner: CommandRunner) -> list[str]:
    host = os.environ.get("DOCKER_HOST", "")
    context = os.environ.get("DOCKER_CONTEXT", "")
    if context or not host:
        args = ["docker", "context", "inspect"]
        if context:
            if context.startswith("-") or len(context) > 256:
                raise CollectionError("invalid Docker context")
            args.append(context)
        args += ["--format", "{{json .Endpoints.docker.Host}}"]
        try:
            host = json.loads(runner.run(args).strip())
        except (ValueError, TypeError) as exc:
            raise CollectionError("invalid Docker context") from exc
    if not isinstance(host, str) or not re.fullmatch(r"unix:///[^\x00-\x20]+", host):
        raise CollectionError("Docker requires a local Unix socket; remote contexts are disabled")
    return ["docker", "--host", host]


def inspected_containers(runner: CommandRunner, prefix: list[str]) -> list[dict[str, Any]]:
    raw = runner.run(prefix + ["container", "ls", "-aq", "--no-trunc"])
    ids = list(dict.fromkeys(raw.split()))
    if len(ids) > 512:
        raise CollectionError("container limit exceeded (512)")
    if any(not ID_PATTERN.fullmatch(value) for value in ids):
        raise CollectionError("invalid container ID")
    rows = []
    for offset in range(0, len(ids), 64):
        batch = ids[offset : offset + 64]
        inspected = json_lines(
            runner.run(prefix + ["container", "inspect", "--format", CONTAINER_FORMAT] + batch)
        )
        for row in inspected:
            if row.get("id") not in batch:
                raise CollectionError("container identity mismatch")
            rows.append(row)
    return rows


def published_ports(raw: dict[str, Any]) -> list[dict[str, Any]]:
    if raw.get("state") != "running":
        return []
    rows = {}
    for target, bindings in (raw.get("ports") or {}).items():
        if not target.endswith("/tcp") or not isinstance(bindings, list):
            continue
        for binding in bindings:
            if not isinstance(binding, dict):
                continue
            host = binding.get("HostIp") or "0.0.0.0"  # noqa: S104 — existing binding metadata
            parsed = endpoint(f"{host}:{binding.get('HostPort', '')}")
            if parsed:
                row = port_row(*parsed)
                row.update(
                    containerIds=[raw["id"]],
                    process=clean(raw.get("name", "")).lstrip("/"),
                    database=database_type(str(raw.get("image", ""))),
                    targetPort=clean(target),
                    protocol=web_protocol(str(raw.get("image", ""))),
                )
                rows[row["id"]] = row
    return list(rows.values())


def normalized_container(raw: dict[str, Any]) -> dict[str, Any]:
    return dict(
        id=raw["id"],
        name=clean(raw.get("name", "")).lstrip("/") or "Unknown",
        image=clean(raw.get("image")),
        imageId=clean(raw.get("imageId")),
        state=clean(raw.get("state")) or "unknown",
        health=clean(raw.get("health")) or None,
        publishedPorts=published_ports(raw),
        exposedPorts=sorted({clean(key) for key in (raw.get("exposed") or {})})[:64],
        composeDir=(
            clean(raw["workdir"], 4096)
            if isinstance(raw.get("workdir"), str)
            and Path(raw["workdir"]).is_absolute()
            and not any(ch in raw["workdir"] for ch in "\0\n\r")
            else None
        ),
        cpu=None,
        memory=None,
        restart=clean(raw.get("restart")) or "Unknown",
        compose=clean(raw.get("compose")) or None,
        database=database_type(str(raw.get("image", ""))),
    )


def docker_inventory(runner: CommandRunner, assets: bool = False) -> dict[str, Any]:
    prefix = local_docker(runner)
    raw_containers = inspected_containers(runner, prefix)
    containers = [normalized_container(row) for row in raw_containers]
    result: dict[str, Any] = dict(dockerStatus="available", containers=containers, warnings=[])
    if not assets:
        running = [row["id"] for row in containers if row["state"] == "running"]
        if running:
            try:
                stats = json_lines(
                    runner.run(
                        prefix
                        + [
                            "container",
                            "stats",
                            "--no-stream",
                            "--no-trunc",
                            "--format",
                            "{{json .}}",
                        ]
                        + running
                    )
                )
                by_id = {row.get("ID"): row for row in stats}
                for row in containers:
                    values = by_id.get(row["id"], {})
                    row["cpu"] = clean(values.get("CPUPerc")) or None
                    row["memory"] = clean(values.get("MemUsage")) or None
            except CollectionError as exc:
                result["warnings"].append("Docker resource usage unavailable: " + str(exc))
        return result
    images: dict[str, dict[str, Any]] = {}
    used_images = {row["imageId"] for row in containers}
    for row in json_lines(
        runner.run(prefix + ["image", "ls", "--no-trunc", "--format", "{{json .}}"])
    ):
        image_id = clean(row.get("ID"))
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", image_id):
            raise CollectionError("invalid image ID")
        entry = images.setdefault(
            image_id,
            dict(id=image_id, tags=[], size=clean(row.get("Size")), used=image_id in used_images),
        )
        tag = clean(row.get("Repository")) + ":" + clean(row.get("Tag"))
        if tag not in entry["tags"]:
            entry["tags"].append(tag)
    names = list(dict.fromkeys(runner.run(prefix + ["volume", "ls", "-q"]).split()))
    if len(names) > MAX_ROWS or any(
        not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", n) for n in names
    ):
        raise CollectionError("invalid volume list or volume limit exceeded")
    volumes = []
    for offset in range(0, len(names), 64):
        batch = names[offset : offset + 64]
        for volume in json_lines(
            runner.run(prefix + ["volume", "inspect", "--format", VOLUME_FORMAT] + batch)
        ):
            name = volume.get("name")
            if name not in batch:
                raise CollectionError("volume identity mismatch")
            attached = set()
            destinations = set()
            for row in raw_containers:
                for mount in row.get("mounts") or []:
                    if mount.get("Type") == "volume" and mount.get("Name") == name:
                        attached.add(clean(row.get("name")).lstrip("/"))
                        destinations.add(clean(mount.get("Destination")))
            volumes.append(
                dict(
                    id="volume:" + name,
                    name=name,
                    mountpoint=clean(volume.get("mountpoint"), 2048),
                    containers=sorted(attached),
                    destinations=sorted(destinations),
                    size=None,
                )
            )
    result.update(images=list(images.values()), volumes=volumes)
    return result


def sqlite_inventory(files: list[str]) -> list[dict[str, Any]]:
    if len(files) > 32:
        raise CollectionError("SQLite file limit exceeded (32)")
    rows = []
    for value in dict.fromkeys(files):
        if not isinstance(value, str) or not Path(value).is_absolute() or "\0" in value:
            raise CollectionError("SQLite paths must be absolute")
        path = Path(value)
        try:
            state = "configured" if path.is_file() else "unavailable"
        except OSError:
            state = "unavailable"
        rows.append(
            dict(
                id="sqlite:" + value,
                name=clean(path.name),
                path=clean(value, 2048),
                database="SQLite",
                state=state,
            )
        )
    return rows


# Docker prefixes each line with an RFC 3339 UTC time down to the nanosecond.
TIMESTAMP_PATTERN = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?Z ", re.MULTILINE)


def local_stamp(match: re.Match[str]) -> str:
    try:
        moment = datetime.fromisoformat(match[1]).replace(tzinfo=UTC).astimezone()
    except (ValueError, OverflowError):
        return match[0]
    return moment.strftime("%m-%d %H:%M:%S  ")


def read_logs(container_id: str, runner: CommandRunner) -> dict[str, Any]:
    if not ID_PATTERN.fullmatch(container_id):
        raise CollectionError("invalid container ID")
    prefix = local_docker(runner)
    raw = runner.run(
        prefix + ["logs", "--tail", "100", "--timestamps", container_id], merge_stderr=True
    )
    # Log content is displayed only after an explicit click, never cached or written to disk.
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw)
    text = TIMESTAMP_PATTERN.sub(local_stamp, text)
    text = "".join(ch for ch in text if ch.isprintable() or ch in "\n\t")
    return dict(containerId=container_id, text=text[:32768], truncated=len(text) > 32768)


def collect(
    scope: str,
    include_docker: bool = True,
    sqlite_files: list[str] | None = None,
    runner: CommandRunner | None = None,
    *,
    project_roots: list[str] | None = None,
    project_depth: int = 3,
    custom_tools: list[str] | None = None,
) -> dict[str, Any]:
    runner = runner or Runner(budget=20 if scope == "projects" else 12)
    data: dict[str, Any] = {}
    errors: list[str] = []
    try:
        if scope == "ports":
            output = runner.run(["ss", "-H", "-lntp"])
            rows = parse_ss(output)
            if output.strip() and not rows:
                raise CollectionError("unrecognized ss output")
            metadata: dict[int, dict[str, Any]] = {}
            for row in rows:
                if row["pid"]:
                    pid = row["pid"]
                    if pid not in metadata:
                        metadata[pid] = process_metadata(pid)
                    meta = metadata[pid]
                    row.update({k: v for k, v in meta.items() if v not in (None, "Unknown")})
            for row in rows:
                row["database"] = database_type(row["process"])
                row["protocol"] = web_protocol(row["process"])
            data["ports"] = rows
            data["sqlite"] = sqlite_inventory(sqlite_files or [])
        elif scope == "legacy":
            from migration import legacy_settings

            data.update(legacy_settings())
        elif scope == "tools":
            from launch import detect_tools

            data.update(detect_tools(custom_tools or []))
        elif scope == "projects":
            from projects import discover, git_status, validate_root

            roots = project_roots or []
            if len(roots) > 16:
                raise CollectionError("project root limit exceeded (16)")
            valid = []
            for root in roots:
                try:
                    valid.append(str(validate_root(root)))
                except CollectionError:
                    errors.append("Invalid project folder: " + clean(root, 4096))
            projects, skipped = discover(valid, project_depth, errors=errors)
            for project in projects[:64]:
                project.update(git_status(Path(project["path"]), runner))
            data.update(projects=projects, skipped=skipped)
        elif scope in ("docker", "assets"):
            if include_docker:
                data.update(docker_inventory(runner, assets=scope == "assets"))
                errors.extend(data.pop("warnings"))
            else:
                data.update(dockerStatus="disabled", containers=[], images=[], volumes=[])
        else:
            raise CollectionError("unsupported scope")
    except CollectionError as exc:
        errors.append(str(exc))
        if scope in ("docker", "assets"):
            data["dockerStatus"] = "unavailable"
    except (ValueError, TypeError, KeyError, AttributeError) as exc:
        errors.append("malformed inventory: " + type(exc).__name__)
        if scope in ("docker", "assets"):
            data["dockerStatus"] = "unavailable"
    return dict(schemaVersion=1, kind=scope, ok=not errors, errors=errors, data=data)


def main() -> int:
    parser = CLIParser(description=__doc__)
    parser.add_argument(
        "scope",
        choices=[
            "ports",
            "docker",
            "assets",
            "logs",
            "projects",
            "tools",
            "legacy",
        ],
    )
    parser.add_argument("--no-docker", action="store_true")
    parser.add_argument("--sqlite-file", action="append", default=[])
    parser.add_argument("--container-id", default="")
    parser.add_argument("--project-root", action="append", default=[])
    parser.add_argument("--project-depth", type=int, choices=range(1, 5), default=3)
    parser.add_argument("--custom-tool", action="append", default=[])
    try:
        args = parser.parse_args()
    except CollectionError as exc:
        result = dict(
            schemaVersion=1,
            kind=clean(sys.argv[1], 64) if len(sys.argv) > 1 else "",
            ok=False,
            errors=[str(exc)],
            data={},
        )
        print(json.dumps(result, separators=(",", ":")))
        return 1
    result: dict[str, Any]
    if args.scope == "logs":
        try:
            if args.no_docker:
                raise CollectionError("Docker disabled")
            result = dict(
                schemaVersion=1,
                kind="logs",
                ok=True,
                errors=[],
                data=read_logs(args.container_id, Runner()),
            )
        except CollectionError as exc:
            result = dict(schemaVersion=1, kind="logs", ok=False, errors=[str(exc)], data={})
    else:
        result = collect(
            args.scope,
            not args.no_docker,
            args.sqlite_file,
            project_roots=args.project_root,
            project_depth=args.project_depth,
            custom_tools=args.custom_tool,
        )
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    for error in result["errors"]:
        print(error, file=sys.stderr)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    # Sibling modules import collector's shared exceptions and Runner. Keep one module identity.
    sys.modules["collector"] = sys.modules[__name__]
    raise SystemExit(main())
