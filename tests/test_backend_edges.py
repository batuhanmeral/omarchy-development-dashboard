"""Regression tests for command boundaries and security-sensitive edge cases."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import actions as a
import collector as c
import migration as m

ROOT = Path(__file__).resolve().parents[1]


class BackendEdges(unittest.TestCase):
    def test_real_collector_cli_retains_json_on_new_scope_errors(self):
        for args in (
            ["projects", "--project-root", "relative"],
            ["tools", *[value for _ in range(9) for value in ("--custom-tool", "Example | cli")]],
        ):
            result = subprocess.run(
                [sys.executable, str(ROOT / "backend/collector.py"), *args],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertEqual(len(result.stdout.splitlines()), 1, result.stderr)
            payload = json.loads(result.stdout)
            self.assertFalse(payload["ok"])
            self.assertEqual(payload["kind"], args[0])
            self.assertNotIn("Traceback", result.stderr)

    def test_cli_argument_errors_are_json(self):
        for name, args in (
            ("collector", ["projects", "--project-depth", "9"]),
            ("actions", ["process-terminate", "--pid", "12a"]),
            ("actions", ["docker-rm"]),
        ):
            result = subprocess.run(
                [sys.executable, str(ROOT / f"backend/{name}.py"), *args],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertEqual(len(result.stdout.splitlines()), 1)
            self.assertFalse(json.loads(result.stdout)["ok"])

    def test_pid_in_process_name_is_not_listening_evidence(self):
        raw = 'LISTEN 0 128 127.0.0.1:3000 *:* users:(("node pid=4321,",pid=999,fd=9))'
        self.assertFalse(a.listening_on(raw, 4321, 3000))
        self.assertTrue(a.listening_on(raw, 999, 3000))

    def test_malformed_docker_preflight_never_mutates(self):
        runner = Mock()
        runner.run.side_effect = ["null", "changed", '"running"']
        with (
            patch.object(a.os, "getuid", return_value=1000),
            patch.dict(a.os.environ, {"DOCKER_HOST": "unix:///var/run/docker.sock"}, clear=True),
        ):
            with self.assertRaisesRegex(c.CollectionError, "invalid Docker state"):
                a.docker_action("docker-start", "a" * 64, runner)
        self.assertEqual(runner.run.call_count, 1)

    def test_incomplete_or_malformed_stat_never_exposes_management_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / "123"
            directory.mkdir()
            (directory / "comm").write_text("node")
            fields = "123 (node) " + " ".join(["S"] + ["0"] * 18 + ["123"])
            original = Path.read_text
            for second in ("123 (bad)", fields.replace("123", "invalid")):
                calls = iter([fields, second])

                def read(path, *args, calls=calls, **kwargs):
                    return (
                        next(calls)
                        if path == directory / "stat"
                        else original(path, *args, **kwargs)
                    )

                with patch.object(Path, "read_text", read):
                    meta = c.process_metadata(123, root)
                self.assertFalse(meta["ownedByUser"])
                self.assertIsNone(meta["startTicks"])

    def test_runner_resolves_program_and_stderr_is_bounded_in_bytes(self):
        with patch.object(c.subprocess, "Popen", wraps=subprocess.Popen) as popen:
            c.Runner().run(["python3", "-c", "print(1)"])
        self.assertTrue(Path(popen.call_args.args[0][0]).is_absolute())
        with self.assertRaises(c.CollectionError) as caught:
            c.Runner().run(
                [
                    sys.executable,
                    "-c",
                    'import sys; sys.stderr.buffer.write(b"\\xff"*5000); exit(1)',
                ]
            )
        self.assertLessEqual(len(caught.exception.stderr.encode("utf-8")), 4096)

    def test_discovered_and_compose_paths_reject_line_breaks(self):
        import projects

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bad = root / "bad\nname"
            (bad / ".git").mkdir(parents=True)
            rows, skipped = projects.discover([str(root)], 1)
            with self.subTest(boundary="discovery"):
                self.assertEqual(rows, [])
                self.assertEqual(skipped, 1)
        for path in ("/home/u/bad\nname", "/home/u/bad\rname", "/home/u/bad\0name"):
            with self.subTest(boundary="compose", path=path):
                self.assertIsNone(c.normalized_container(dict(id="a", workdir=path))["composeDir"])

    def test_symlink_targets_must_be_safe_utf8_paths(self):
        import launch
        import projects

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for index, name in enumerate((b"bad-\xff", b"bad-\n")):
                target = os.fsencode(root) + b"/" + name
                os.mkdir(target)
                link = root / f"root-link-{index}"
                os.symlink(target, os.fsencode(link))
                with self.subTest(kind="root", name=name), self.assertRaises(c.CollectionError):
                    projects.validate_root(str(link))
                binary = target + b"/cli"
                with open(binary, "wb") as stream:
                    stream.write(b"#!/bin/sh\nexit 0\n")
                os.chmod(binary, 0o700)
                command = root / f"tool-link-{index}"
                os.symlink(binary, os.fsencode(command))
                with (
                    self.subTest(kind="executable", name=name),
                    self.assertRaises(c.CollectionError),
                ):
                    launch.resolve_executable(str(command))

    def test_tool_search_rejects_relative_and_empty_path_entries(self):
        import launch

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / "bin"
            directory.mkdir()
            executable = directory / "example"
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)
            (root / "example").write_bytes(executable.read_bytes())
            (root / "example").chmod(0o700)
            previous = Path.cwd()
            try:
                os.chdir(root)
                for search_path in ("bin", "", ":bin"):
                    with (
                        self.subTest(search_path=search_path),
                        patch.dict(os.environ, {"PATH": search_path}),
                        patch.object(launch, "EXTRA_DIRS", ()),
                    ):
                        with self.assertRaises(c.CollectionError):
                            launch.resolve_executable("example")
            finally:
                os.chdir(previous)

    def test_large_legacy_integer_remains_a_valid_number(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "omarchy/shell.json"
            path.parent.mkdir()
            path.write_text(
                json.dumps(
                    dict(
                        bar=dict(layout=dict(left=[dict(id=m.LEGACY_ID, refreshInterval=10**500)]))
                    )
                )
            )
            self.assertEqual(
                m.legacy_settings(root, root)["legacy"]["settings"]["refreshInterval"], 10**500
            )
