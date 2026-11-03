#!/usr/bin/env python3
"""Explicit local management and project launch operations; never invoke a shell."""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import select
import signal
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import Any

from collector import (
    ID_PATTERN,
    CollectionError,
    CommandRunner,
    Runner,
    clean,
    docker_error,
    endpoint,
    local_docker,
)
from launch import detect_tools, editor_argv, resolve_executable, terminal_argv
from projects import validate_root

CRITICAL = {
    "systemd",
    "(sd-pam)",
    "init",
    "dbus-daemon",
    "dbus-broker",
    "dbus-broker-lau",
    "Hyprland",
    "quickshell",
    "qs",
    "omarchy-shell",
    "Xwayland",
    "sshd",
    "pipewire",
    "pipewire-pulse",
    "wireplumber",
    "gnome-keyring-d",
    "polkitd",
    "uwsm",
    "hypridle",
    "hyprlock",
    "mako",
    "sddm",
    "gdm",
    "login",
    "agetty",
    "gpg-agent",
    "ssh-agent",
    "dockerd",
    "containerd",
    "docker-proxy",
    "xdg-desktop-por",
    "xdg-document-po",
    "xdg-permission-",
    "systemd-resolve",
    "NetworkManager",
    "iwd",
    "cupsd",
    "avahi-daemon",
    "bluetoothd",
}
CHANGED = "The process changed since the list was loaded (PID reused). Refresh and try again."


def require_user() -> None:
    if os.getuid() == 0:
        raise CollectionError("Management actions cannot run as root")


def docker_action(
    operation: str, container_id: str, runner: CommandRunner | None = None
) -> dict[str, Any]:
    require_user()
    if operation not in ("docker-start", "docker-stop", "docker-restart"):
        raise CollectionError("unsupported Docker operation")
    if not ID_PATTERN.fullmatch(container_id):
        raise CollectionError("invalid container ID")
    runner = runner or Runner(budget=45)
    try:
        prefix = local_docker(runner) + ["container"]
        inspect = prefix + ["inspect", "--format", "{{json .State.Status}}", container_id]
        json.loads(runner.run(inspect))
        verb = operation.removeprefix("docker-")
        args = [verb] + (["--time", "10"] if verb != "start" else []) + [container_id]
        runner.run(prefix + args, timeout=40 if verb == "restart" else 30)
        state = json.loads(runner.run(inspect))
        if not isinstance(state, str):
            raise ValueError
        return dict(containerId=container_id, state=clean(state, 64))
    except CollectionError as exc:
        raise CollectionError(docker_error(exc)) from exc
    except (ValueError, TypeError) as exc:
        raise CollectionError("invalid Docker state") from exc


def proc_stat(directory: Path) -> tuple[str, int]:
    fields = (directory / "stat").read_text().rsplit(") ", 1)[1].split()
    return fields[19], int(fields[1])


def ancestors(proc_root: Path) -> set[int]:
    result = {os.getpid()}
    directory = proc_root / "self"
    while True:
        _, parent = proc_stat(directory)
        if parent <= 1 or parent in result:
            return result
        result.add(parent)
        directory = proc_root / str(parent)


def listening_on(output: str, pid: int, port: int) -> bool:
    for line in output.splitlines():
        fields = line.split(None, 5)
        if len(fields) < 6 or fields[0] != "LISTEN":
            continue
        parsed = endpoint(fields[3])
        if (
            parsed
            and parsed[1] == port
            and any(
                int(value) == pid
                for value in re.findall(
                    r"\bpid=(\d+)(?=[,)\s]|$)", fields[5].partition("users:")[2]
                )
            )
        ):
            return True
    return False


def process_terminate(
    pid: int,
    start_ticks: str,
    port: int,
    *,
    proc_root: Path = Path("/proc"),
    runner: CommandRunner | None = None,
    pidfd_open: Callable[[int], int] | None = None,
    send_signal: Callable[[int, int], None] | None = None,
    poll_factory: Callable[[], Any] | None = None,
    close_fd: Callable[[int], None] | None = None,
) -> dict[str, Any]:
    require_user()
    if type(pid) is not int or not 2 <= pid <= 4194304:
        raise CollectionError("invalid PID")
    if not isinstance(start_ticks, str) or not re.fullmatch(r"[0-9]{1,20}", start_ticks):
        raise CollectionError("invalid start ticks")
    if type(port) is not int or not 1 <= port <= 65535:
        raise CollectionError("invalid port")
    try:
        if pid in ancestors(proc_root):
            raise CollectionError("Cannot terminate this process or an ancestor")
    except (OSError, ValueError, IndexError) as exc:
        raise CollectionError("Cannot verify process ancestors") from exc
    result = dict(pid=pid, result="already-exited")
    try:
        opener = pidfd_open or os.pidfd_open
        fd = opener(pid)
    except ProcessLookupError:
        return result
    except (AttributeError, OSError) as exc:
        if isinstance(exc, AttributeError) or exc.errno == errno.ENOSYS:
            raise CollectionError("kernel lacks pidfd support") from exc
        raise CollectionError("Cannot open process handle") from exc
    try:
        directory = proc_root / str(pid)
        if proc_stat(directory)[0] != start_ticks:
            raise CollectionError(CHANGED)
        status = (directory / "status").read_text()
        match = re.search(r"^Uid:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", status, re.MULTILINE)
        if not match or any(
            int(value) != os.getuid() or int(value) == 0 for value in match.groups()
        ):
            raise CollectionError("The process is not owned by you")
        comm = (directory / "comm").read_text().strip()
        try:
            executable = Path(os.path.realpath(os.readlink(directory / "exe")))
        except FileNotFoundError:
            executable = Path("/")
        if comm in CRITICAL or Path("/usr/lib/systemd") in executable.parents:
            raise CollectionError("Cannot terminate a critical system process")
        runner = runner or Runner()
        if not listening_on(runner.run(["ss", "-H", "-lntp"]), pid, port):
            raise CollectionError(f"The process is no longer listening on port {port}")
        if proc_stat(directory)[0] != start_ticks:
            raise CollectionError(CHANGED)
        try:
            sender = send_signal or signal.pidfd_send_signal
            sender(fd, signal.SIGTERM)
        except AttributeError as exc:
            raise CollectionError("kernel lacks pidfd support") from exc
        poller = (poll_factory or select.poll)()
        poller.register(fd, select.POLLIN)
        terminated = any(events & select.POLLIN for _, events in poller.poll(3000))
        result["result"] = "terminated" if terminated else "signaled"
        if not terminated:
            result["message"] = (
                "Sent SIGTERM; the process is still running. It was not force-killed."
            )
        return result
    except (ProcessLookupError, FileNotFoundError):
        return dict(pid=pid, result="already-exited")
    except (OSError, ValueError, IndexError) as exc:
        raise CollectionError("Cannot verify or signal the process") from exc
    finally:
        (close_fd or os.close)(fd)


def project_directory(path: str, roots: list[str]) -> Path:
    if ".." in Path(path).parts or len(roots) > 16:
        raise CollectionError("path is not inside a project folder")
    directory = validate_root(path)
    resolved_roots = [validate_root(root) for root in roots]
    if not any(directory == root or root in directory.parents for root in resolved_roots):
        raise CollectionError("path is not inside a project folder")
    return directory


def spawn(argv: list[str], cwd: Path) -> None:
    try:
        child = subprocess.Popen(  # noqa: S603 — resolved executable and literal arguments
            argv,
            cwd=cwd,
            shell=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
            env=dict(os.environ),
        )
        try:
            status = child.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            return
        if status:
            raise CollectionError(f"{Path(argv[0]).name} exited with status {status}")
    except OSError as exc:
        raise CollectionError(f"{Path(argv[0]).name} unavailable") from exc


def launch_action(
    operation: str,
    path: str,
    project_roots: list[str],
    *,
    terminal: str = "default",
    editor: str = "",
    tool: str = "",
    custom_tools: list[str] | None = None,
) -> dict[str, Any]:
    directory = project_directory(path, project_roots)
    if operation == "open-files":
        argv = [str(resolve_executable("xdg-open")), str(directory)]
    elif operation == "open-editor":
        argv = editor_argv(editor, str(directory))
    elif operation == "open-terminal":
        argv = terminal_argv(terminal, str(directory), None)
    elif operation == "launch-tool":
        tools = detect_tools(custom_tools or [])["tools"]
        selected = next((row for row in tools if row["id"] == tool), None)
        if selected is None or not selected["available"]:
            raise CollectionError("The selected tool is unavailable")
        argv = terminal_argv(terminal, str(directory), [selected["path"], *selected["args"]])
    else:
        raise CollectionError("unsupported launch operation")
    spawn(argv, directory)
    result = dict(launched=Path(argv[0]).name)
    if operation == "launch-tool":
        result["tool"] = tool
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    for operation in ("docker-start", "docker-stop", "docker-restart"):
        command = commands.add_parser(operation)
        command.add_argument("--container-id", required=True)
    command = commands.add_parser("process-terminate")
    command.add_argument("--pid", type=int, required=True)
    command.add_argument("--start-ticks", required=True)
    command.add_argument("--port", type=int, required=True)
    for operation in ("open-terminal", "open-editor", "open-files", "launch-tool"):
        command = commands.add_parser(operation)
        command.add_argument("--path", required=True)
        command.add_argument("--project-root", action="append", default=[])
        command.add_argument("--terminal", default="default")
        command.add_argument("--editor", default="")
        command.add_argument("--tool", default="")
        command.add_argument("--custom-tool", action="append", default=[])
    args = parser.parse_args()
    result: dict[str, Any] = dict(
        schemaVersion=1, kind="action", action=args.operation, ok=True, errors=[], data={}
    )
    try:
        if args.operation.startswith("docker-"):
            result["data"] = docker_action(args.operation, args.container_id)
        elif args.operation == "process-terminate":
            result["data"] = process_terminate(args.pid, args.start_ticks, args.port)
        else:
            result["data"] = launch_action(
                args.operation,
                args.path,
                args.project_root,
                terminal=args.terminal,
                editor=args.editor,
                tool=args.tool,
                custom_tools=args.custom_tool,
            )
    except CollectionError as exc:
        result.update(ok=False, errors=[str(exc)])
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
