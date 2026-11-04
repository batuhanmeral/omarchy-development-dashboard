"""Safe, explicit Docker, pidfd and project launch operations."""

import errno
import importlib
import io
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import collector as c

CID = "a" * 64


class ActionsTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(importlib.util.find_spec("actions"), "actions implementation missing")
        self.a = importlib.import_module("actions")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.uid = os.getuid() or 1000
        self.proc(os.getpid())
        (self.root / "self").symlink_to(self.root / str(os.getpid()), target_is_directory=True)
        uid = patch.object(self.a.os, "getuid", return_value=self.uid)
        uid.start()
        self.addCleanup(uid.stop)
        env = patch.dict(os.environ, {"DOCKER_HOST": "unix:///var/run/docker.sock"}, clear=True)
        env.start()
        self.addCleanup(env.stop)

    def proc(self, pid=4321, ticks="123", name="node", uid=None, ppid=1):
        directory = self.root / str(pid)
        directory.mkdir(exist_ok=True)
        fields = ["S", str(ppid)] + ["0"] * 17 + [ticks]
        (directory / "stat").write_text(f"{pid} ({name}) " + " ".join(fields))
        (directory / "comm").write_text(name)
        (directory / "status").write_text(
            "Uid:\t" + "\t".join([str(self.uid if uid is None else uid)] * 4) + "\n"
        )
        return directory

    def process_call(self, pid=4321, ticks="123", port=3000, **overrides):
        runner = Mock()
        runner.run.return_value = (
            'LISTEN 0 128 127.0.0.1:3000 *:* users:(("other",pid=999,fd=9),("node",pid=4321,fd=10))'
        )
        poller = Mock()
        poller.poll.return_value = [(99, select.POLLIN)]
        options = dict(
            proc_root=self.root,
            runner=runner,
            pidfd_open=Mock(return_value=99),
            send_signal=Mock(),
            poll_factory=Mock(return_value=poller),
            close_fd=Mock(),
        )
        options.update(overrides)
        return self.a.process_terminate(pid, ticks, port, **options), options

    def test_docker_lifecycle_fixed_argv_and_timeouts(self):
        for operation, args, timeout in [
            ("docker-start", ["start", CID], 30),
            ("docker-stop", ["stop", "--time", "10", CID], 30),
            ("docker-restart", ["restart", "--time", "10", CID], 40),
        ]:
            runner = Mock()
            runner.run.side_effect = ['"exited"', CID, '"running"']
            result = self.a.docker_action(operation, CID, runner)
            self.assertEqual(result, dict(containerId=CID, state="running"))
            prefix = ["docker", "--host", "unix:///var/run/docker.sock", "container"]
            self.assertEqual(
                runner.run.call_args_list[0].args[0],
                prefix + ["inspect", "--format", "{{json .State.Status}}", CID],
            )
            self.assertEqual(runner.run.call_args_list[1].args[0], prefix + args)
            self.assertEqual(runner.run.call_args_list[1].kwargs["timeout"], timeout)
            for call in runner.run.call_args_list:
                self.assertFalse({"kill", "rm", "prune"} & set(call.args[0]))
        with self.assertRaises(c.CollectionError):
            self.a.docker_action("docker-rm", CID, Mock())
        with self.assertRaisesRegex(c.CollectionError, "invalid container ID"):
            self.a.docker_action("docker-start", "a;rm", Mock())

    def test_docker_errors_remote_and_root_rejected(self):
        for detail, message in [
            ("permission denied", "Permission denied"),
            ("No such container: a", "no longer exists"),
            ("Cannot connect to the Docker daemon", "not running"),
        ]:
            runner = Mock()
            runner.run.side_effect = c.CommandFailed("docker failed (exit 1)", detail)
            with self.assertRaisesRegex(c.CollectionError, message):
                self.a.docker_action("docker-stop", CID, runner)
        runner = Mock()
        with (
            patch.dict(os.environ, {"DOCKER_HOST": "ssh://remote"}),
            self.assertRaisesRegex(c.CollectionError, "local Unix socket"),
        ):
            self.a.docker_action("docker-start", CID, runner)
        runner.run.assert_not_called()
        with patch.object(self.a.os, "getuid", return_value=0):
            for operation in ("docker-start", "docker-stop", "docker-restart"):
                with self.assertRaisesRegex(c.CollectionError, "root"):
                    self.a.docker_action(operation, CID, Mock())
            with self.assertRaisesRegex(c.CollectionError, "root"):
                self.process_call()

    def test_process_validation_self_ancestors_and_pidfd_unavailable(self):
        self.proc()
        for pid in (0, 1, -5, "12a", 2**31, os.getpid()):
            with self.subTest(pid=pid), self.assertRaises(c.CollectionError):
                self.process_call(pid)
        for ticks in ("", "12a", "1" * 21):
            with self.assertRaises(c.CollectionError):
                self.process_call(ticks=ticks)
        for port in (0, 65536, "bad"):
            with self.assertRaises(c.CollectionError):
                self.process_call(port=port)
        own = self.proc(os.getpid(), ppid=55)
        self.assertEqual((self.root / "self").resolve(), own)
        self.proc(55)
        with self.assertRaisesRegex(c.CollectionError, "ancestor"):
            self.process_call(55)
        for error in (AttributeError(), OSError(errno.ENOSYS, "unsupported")):
            with self.assertRaisesRegex(c.CollectionError, "kernel lacks pidfd support"):
                self.process_call(pidfd_open=Mock(side_effect=error))
        with self.assertRaises(c.CollectionError):
            self.process_call(pidfd_open=Mock(side_effect=PermissionError()))

    def test_process_termination_protects_rootless_container_helpers(self):
        names = (
            "rootlesskit",
            "rootlessport",
            "slirp4netns",
            "pasta",
            "conmon",
            "containerd-shim",
            "containerd-shim-runc-v2",
            "podman",
            "buildkitd",
        )
        for name in names:
            with self.subTest(name=name):
                self.proc(name=name)
                sender = Mock()
                with self.assertRaisesRegex(c.CollectionError, "critical"):
                    self.process_call(send_signal=sender)
                sender.assert_not_called()

    def test_process_ownership_identity_critical_names_and_listener_checks(self):
        proc = self.proc(ticks="999")
        with self.assertRaisesRegex(c.CollectionError, "PID reused"):
            self.process_call()
        self.proc(uid=0)
        with self.assertRaisesRegex(c.CollectionError, "not owned by you"):
            self.process_call()
        self.proc(uid=self.uid + 1)
        with self.assertRaisesRegex(c.CollectionError, "not owned by you"):
            self.process_call()
        self.proc()
        (proc / "status").write_text(f"Uid:\t{self.uid}\t{self.uid}\t{self.uid}\t0\n")
        with self.assertRaisesRegex(c.CollectionError, "not owned by you"):
            self.process_call()
        for name in ("systemd", "Hyprland", "quickshell", "dbus-broker-lau", "sshd", "node"):
            self.proc(name=name)
            if name != "node":
                with self.subTest(name=name), self.assertRaisesRegex(c.CollectionError, "critical"):
                    self.process_call()
        (proc / "exe").symlink_to("/usr/lib/systemd/systemd")
        with self.assertRaisesRegex(c.CollectionError, "critical"):
            self.process_call()
        (proc / "exe").unlink()
        runner = Mock()
        runner.run.return_value = 'LISTEN 0 128 127.0.0.1:3000 *:* users:(("node",pid=43210,fd=9))'
        with self.assertRaisesRegex(c.CollectionError, "no longer listening on port 3000"):
            self.process_call(runner=runner)

        def mutate(*args, **kwargs):
            self.proc(ticks="999")
            return 'LISTEN 0 128 127.0.0.1:3000 *:* users:(("node",pid=4321,fd=9))'

        runner.run.side_effect = mutate
        sender = Mock()
        closer = Mock()
        with self.assertRaisesRegex(c.CollectionError, "PID reused"):
            self.process_call(runner=runner, send_signal=sender, close_fd=closer)
        sender.assert_not_called()
        closer.assert_called_once_with(99)

    def test_process_results_fd_closed_and_only_term_sent(self):
        self.proc()
        result, options = self.process_call()
        self.assertEqual(result, dict(pid=4321, result="terminated"))
        options["send_signal"].assert_called_once_with(99, signal.SIGTERM)
        options["close_fd"].assert_called_once_with(99)
        poller = Mock()
        poller.poll.return_value = []
        result, _ = self.process_call(poll_factory=Mock(return_value=poller))
        self.assertEqual(result["result"], "signaled")
        poller.poll.assert_called_once_with(3000)
        for option in ("pidfd_open", "send_signal"):
            result, options = self.process_call(**{option: Mock(side_effect=ProcessLookupError())})
            self.assertEqual(result["result"], "already-exited")
            if option == "send_signal":
                options["close_fd"].assert_called_once_with(99)
        self.assertNotIn("SIG" + "KILL", (Path(self.a.__file__)).read_text())
        self.assertNotIn("os.kill(", (Path(self.a.__file__)).read_text())

    def test_launch_paths_programs_and_spawn_options(self):
        folder = self.root / "proje ; $(id)"
        folder.mkdir()
        binaries = {
            name: str(self.root / name)
            for name in ("xdg-open", "xdg-terminal-exec", "omarchy-launch-editor", "codex")
        }
        with (
            patch.object(
                self.a, "resolve_executable", side_effect=lambda name: Path(binaries[name])
            ),
            patch("launch.resolve_executable", side_effect=lambda name: Path(binaries[name])),
            patch.object(self.a, "spawn") as spawn,
        ):
            for operation, expected in [
                ("open-files", [binaries["xdg-open"], str(folder)]),
                ("open-editor", [binaries["omarchy-launch-editor"], str(folder)]),
                ("open-terminal", [binaries["xdg-terminal-exec"], f"--dir={folder}"]),
                (
                    "launch-tool",
                    [binaries["xdg-terminal-exec"], f"--dir={folder}", "--", binaries["codex"]],
                ),
            ]:
                with patch.object(
                    self.a,
                    "detect_tools",
                    return_value=dict(
                        tools=[dict(id="codex", available=True, path=binaries["codex"], args=[])]
                    ),
                ):
                    result = self.a.launch_action(
                        operation, str(folder), [str(self.root)], tool="codex"
                    )
                self.assertEqual(result["launched"], Path(expected[0]).name)
                spawn.assert_called_with(expected, folder.resolve())
        with patch.object(self.a.subprocess, "Popen") as popen:
            popen.return_value.wait.side_effect = subprocess.TimeoutExpired("test", 0.5)
            self.a.spawn(["/usr/bin/xdg-open", str(folder)], folder)
            options = popen.call_args.kwargs
            self.assertFalse(options["shell"])
            self.assertEqual(options["cwd"], folder)
            self.assertTrue(options["start_new_session"])
            self.assertTrue(options["close_fds"])
            self.assertEqual(options["stdin"], subprocess.DEVNULL)
            self.assertEqual(options["stdout"], subprocess.DEVNULL)
            self.assertEqual(options["stderr"], subprocess.DEVNULL)
            popen.return_value.terminate.assert_not_called()
            popen.return_value.kill.assert_not_called()
            popen.return_value.wait.side_effect = None
            popen.return_value.wait.return_value = 0
            self.a.spawn(["/usr/bin/xdg-open"], folder)
            popen.return_value.wait.return_value = 2
            with self.assertRaisesRegex(c.CollectionError, "xdg-open exited with status 2"):
                self.a.spawn(["/usr/bin/xdg-open"], folder)
            popen.side_effect = OSError("failure")
            with self.assertRaises(c.CollectionError):
                self.a.spawn(["/missing"], folder)

    def test_launch_rejects_outside_dotdot_symlink_and_missing_tool(self):
        folder = self.root / "project"
        folder.mkdir()
        for path in (str(self.root), str(folder / ".."), "/etc", "relative", str(folder) + "\n"):
            with self.subTest(path=path), self.assertRaises(c.CollectionError):
                self.a.launch_action("open-files", path, [str(folder)])
        link = folder / "external"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(c.CollectionError, "path is not inside a project folder"):
            self.a.launch_action("open-files", str(link), [str(folder)])
        with self.assertRaises(c.CollectionError):
            self.a.launch_action("open-files", str(folder), [])
        with patch.object(self.a, "detect_tools", return_value={"tools": []}):
            with self.assertRaisesRegex(c.CollectionError, "tool"):
                self.a.launch_action("launch-tool", str(folder), [str(self.root)], tool="missing")
        with self.assertRaises(c.CollectionError):
            self.a.launch_action("invalid", str(folder), [str(self.root)])

    def test_action_cli_envelopes_all_operations_and_failure(self):
        cases = [
            (
                ["docker-start", "--container-id", CID],
                "docker_action",
                {"containerId": CID, "state": "running"},
            ),
            (
                ["process-terminate", "--pid", "4321", "--start-ticks", "123", "--port", "3000"],
                "process_terminate",
                {"pid": 4321, "result": "terminated"},
            ),
            (
                ["open-terminal", "--path", str(self.root), "--project-root", str(self.root)],
                "launch_action",
                {"launched": "xdg-terminal-exec"},
            ),
        ]
        for argv, method, data in cases:
            out = io.StringIO()
            with (
                patch.object(sys, "argv", ["actions.py", *argv]),
                patch.object(self.a, method, return_value=data),
                patch("sys.stdout", out),
            ):
                self.assertEqual(self.a.main(), 0)
            self.assertEqual(
                json.loads(out.getvalue()),
                dict(schemaVersion=1, kind="action", action=argv[0], ok=True, errors=[], data=data),
            )
        out = io.StringIO()
        with (
            patch.object(sys, "argv", ["actions.py", "docker-stop", "--container-id", "bad"]),
            patch("sys.stdout", out),
        ):
            self.assertEqual(self.a.main(), 1)
        self.assertFalse(json.loads(out.getvalue())["ok"])

    @unittest.skipUnless(
        shutil.which("ss")
        and hasattr(os, "pidfd_open")
        and hasattr(signal, "pidfd_send_signal")
        and os.getuid() != 0,
        "ss/pidfd/non-root required",
    )
    def test_real_listening_child_terminates_with_pidfd(self):
        code = (
            'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); '
            "print(s.getsockname()[1],flush=True); time.sleep(30)"
        )
        with subprocess.Popen(
            [sys.executable, "-c", code], stdout=subprocess.PIPE, text=True
        ) as child:
            try:
                port = int(child.stdout.readline())
                ticks = Path(f"/proc/{child.pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]
                result = self.a.process_terminate(child.pid, ticks, port)
                self.assertEqual(result, dict(pid=child.pid, result="terminated"))
                child.wait(timeout=3)
                self.assertEqual(child.returncode, -signal.SIGTERM)
            finally:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=3)

    def test_compose_action_discovers_members_and_reports_partial_failure(self):
        other_id = "b" * 64
        runner = Mock()
        runner.run.side_effect = [
            f"{CID}\n{other_id}\n{CID}\n",
            '"running"',
            "",
            '"exited"',
            c.CommandFailed("docker failed", "No such container"),
        ]
        result = self.a.docker_compose_action(
            "docker-compose-stop", "shop_prod.v2", [CID, other_id], runner
        )
        self.assertEqual(result["project"], "shop_prod.v2")
        self.assertEqual(result["containers"], [{"id": CID, "state": "exited"}])
        self.assertEqual(result["failed"][0]["id"], other_id)
        self.assertIn("no longer exists", result["failed"][0]["error"])
        calls = [call.args[0][4:] for call in runner.run.call_args_list]
        self.assertEqual(
            calls[0],
            ["ls", "-aq", "--no-trunc", "--filter=label=com.docker.compose.project=shop_prod.v2"],
        )
        self.assertEqual(calls[2], ["stop", "--time", "10", CID])
        self.assertEqual(len(calls), 5)

    def test_compose_invalid_name_or_members_never_runs_a_container_action(self):
        for project in ("--all", "shop\n", "A", "a" * 65, "one/two"):
            runner = Mock()
            with self.assertRaisesRegex(c.CollectionError, "invalid Compose project"):
                self.a.docker_compose_action("docker-compose-start", project, [CID], runner)
            runner.run.assert_not_called()
        for members in (CID + "\nmalformed", "\n".join(f"{index:064x}" for index in range(65))):
            runner = Mock()
            runner.run.return_value = members
            with self.assertRaises(c.CollectionError):
                self.a.docker_compose_action("docker-compose-restart", "shop", [CID], runner)
            self.assertEqual(runner.run.call_count, 1)

    def test_compose_cli_keeps_partial_results_and_returns_failure(self):
        result = {
            "project": "shop",
            "containers": [],
            "failed": [{"id": CID, "error": "operation failed"}],
        }
        out = io.StringIO()
        with (
            patch.object(
                sys,
                "argv",
                ["actions.py", "docker-compose-restart", "--project=shop", f"--container-id={CID}"],
            ),
            patch("sys.stdout", out),
            patch.object(self.a, "docker_compose_action", return_value=result) as action,
        ):
            self.assertEqual(self.a.main(), 1)
        action.assert_called_once_with("docker-compose-restart", "shop", [CID])
        self.assertEqual(json.loads(out.getvalue())["data"], result)

    def test_compose_changes_only_members_captured_by_the_caller(self):
        later = "b" * 64
        disappeared = "c" * 64
        runner = Mock()
        runner.run.side_effect = [f"{CID}\n{later}\n", '"running"', "", '"exited"']
        result = self.a.docker_compose_action(
            "docker-compose-stop", "shop", [CID, disappeared], runner
        )
        self.assertEqual(result["containers"], [{"id": CID, "state": "exited"}])
        self.assertEqual(result["failed"], [])
        changed = [call.args[0][-1] for call in runner.run.call_args_list if "stop" in call.args[0]]
        self.assertEqual(changed, [CID])

    def test_compose_rejects_empty_intersection_and_empty_discovery(self):
        for output in ("", "b" * 64):
            with self.subTest(output=output):
                runner = Mock()
                runner.run.return_value = output
                with self.assertRaisesRegex(
                    c.CollectionError, "No containers of this Compose project remain"
                ):
                    self.a.docker_compose_action("docker-compose-stop", "shop", [CID], runner)
                self.assertEqual(runner.run.call_count, 1)

    def test_compose_rejects_invalid_snapshots_without_contacting_docker(self):
        for members in ([], ["invalid"], [CID] * 65):
            runner = Mock()
            with self.assertRaises(c.CollectionError):
                self.a.docker_compose_action("docker-compose-start", "shop", members, runner)
            runner.run.assert_not_called()
