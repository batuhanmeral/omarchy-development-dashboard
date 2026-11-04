"""Dashboard backend contracts and bounded command diagnostics."""

import json
import os
import sys
import tempfile
import time
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import collector as c

ROOT = Path(__file__).resolve().parents[1]


class DashboardContracts(unittest.TestCase):
    def test_dashboard_metadata(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        package = tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]
        self.assertEqual(manifest["id"], "io.github.batuhanmeral.development-dashboard")
        self.assertEqual(manifest["name"], "Development Dashboard")
        self.assertEqual(manifest["barWidget"]["displayName"], manifest["name"])
        self.assertEqual(manifest["version"], "2.0.0")
        self.assertTrue(
            {"dashboard", "projects", "devports"} <= set(manifest["barWidget"]["aliases"])
        )
        self.assertEqual(package["name"], "omarchy-development-dashboard")
        self.assertEqual(package["version"], "2.0.0")

    def test_runner_captures_bounded_stderr_and_counts_it_against_limit(self):
        with self.assertRaises(c.CollectionError) as caught:
            c.Runner().run(
                [sys.executable, "-c", 'import sys; sys.stderr.write("x"*5000); exit(7)']
            )
        self.assertEqual(type(caught.exception).__name__, "CommandFailed")
        self.assertEqual(str(caught.exception), "python3 failed (exit 7)")
        self.assertEqual(caught.exception.stderr, "x" * 4096)
        with self.assertRaisesRegex(c.CollectionError, "output limit"):
            c.Runner(max_bytes=100).run(
                [sys.executable, "-c", 'import sys; sys.stderr.write("x"*101)']
            )
        text = c.Runner().run(
            [sys.executable, "-c", 'import sys; print("out"); print("err", file=sys.stderr)'],
            merge_stderr=True,
        )
        self.assertIn("out", text)
        self.assertIn("err", text)

    def test_runner_per_operation_timeout_and_environment(self):
        with self.assertRaisesRegex(c.CollectionError, "timeout"):
            c.Runner(timeout=2).run(
                [sys.executable, "-c", "import time; time.sleep(1)"], timeout=0.02
            )
        self.assertEqual(
            c.Runner()
            .run(
                [sys.executable, "-c", 'import os; print(os.environ["GIT_TERMINAL_PROMPT"])'],
                env={"GIT_TERMINAL_PROMPT": "0"},
            )
            .strip(),
            "0",
        )

    def test_docker_error_classification(self):
        cases = [
            ("permission denied", "Permission denied: your user cannot use the Docker socket."),
            ("Error: No such container: a", "The container no longer exists."),
            ("Cannot connect to the Docker daemon", "The Docker daemon is not running."),
            ("some error\nprivate detail", "docker failed (exit 4): some error"),
        ]
        for stderr, expected in cases:
            with self.subTest(stderr=stderr):
                self.assertEqual(
                    c.docker_error(c.CommandFailed("docker failed (exit 4)", stderr)), expected
                )
        self.assertEqual(
            c.docker_error(c.CollectionError("docker timeout")), "Docker did not answer in time."
        )

    def test_redaction_table(self):
        cases = [
            (["node", "--password=sample"], "node --password=***"),
            (["node", "--TOKEN", "sample", "ok"], "node --TOKEN *** ok"),
            (["API_KEY=sample", "--auth-user=x"], "API_KEY=*** --auth-user=***"),
            (["https://user:sample@example.test/a"], "https://***@example.test/a"),
            (["node", "--port", "3000", "a\nb\x1b"], "node --port 3000 ab"),
        ]
        for argv, expected in cases:
            with self.subTest(argv=argv):
                self.assertEqual(c.redact_command(argv), expected)
        self.assertEqual(len(c.redact_command(["x" * 1000])), 512)

    def test_redaction_bounds_large_arguments_and_stops_at_output_limit(self):
        start = time.perf_counter()
        self.assertEqual(c.redact_command(["0" * 65536]), "***")
        self.assertLess(time.perf_counter() - start, 0.05)

        class BoundedArgs(list):
            def __iter__(self):
                yield "0" * 512
                raise AssertionError("Visited arguments past the output budget")

        self.assertEqual(c.redact_command(BoundedArgs()), "0" * 512)
        self.assertEqual(
            c.redact_command(["0" * 495, "https://user:" + "4" * 128 + "@example.test"]),
            "0" * 495 + " https://***@exam",
        )

    def test_process_metadata_redacts_a_large_cmdline_promptly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            proc = root / "321"
            proc.mkdir()
            (proc / "stat").write_text("321 (fixture) " + " ".join(["S"] + ["0"] * 18 + ["1234"]))
            (proc / "comm").write_text("fixture")
            (proc / "cmdline").write_bytes(b"fixture\0" + b"6" * 60000 + b"\0")
            start = time.perf_counter()
            self.assertEqual(c.process_metadata(321, root)["command"], "fixture ***")
            self.assertLess(time.perf_counter() - start, 0.05)

    def test_redacts_credentials_in_cli_dsn_headers_and_provider_tokens(self):
        cases = [
            (["curl", "-u", "alice:fixture"], "curl -u alice:***"),
            (["curl", "--user=alice:fixture"], "curl --user=alice:***"),
            (["curl", "--user", "alice"], "curl --user alice"),
            (["u:fixture@tcp(h)/d"], "***@tcp(h)/d"),
            (["--dsn=u:fixture@tcp(h)/d"], "--dsn=***@tcp(h)/d"),
            (["Server=h;Password=fixture;"], "Server=h;Password=***;"),
            (["--dsn=Server=h;Pwd=fixture&other=abc"], "--dsn=Server=h;Pwd=***&other=abc"),
            (["Cookie: sid=fixture"], "Cookie: ***"),
            (["--pat", "fixture", "ok"], "--pat *** ok"),
            (["pat", "fixture"], "pat ***"),
            (["pat=fixture"], "pat=***"),
        ]
        for prefix in ("ghp_", "gho_", "github_pat_", "glpat-", "sk-", "xoxa-", "xoxb-", "xoxp-"):
            cases.append((["option=" + prefix + "fixture"], "option=***"))
        for argv, expected in cases:
            with self.subTest(argv=argv):
                self.assertEqual(c.redact_command(argv), expected)

    def test_runner_strips_ambient_git_variables_and_relative_path_entries(self):
        inherited = {
            "PATH": ":tools:/usr/bin:.:/bin:",
            "GIT_DIR": "/fixture/example",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "example.key",
            "GIT_CONFIG_VALUE_0": "fixture",
            "GIT_SSH_COMMAND": "fixture",
            "GIT_PROXY_COMMAND": "fixture",
            "GIT_EXEC_PATH": "/fixture/example",
            "GIT_ASKPASS": "fixture",
            "GIT_CONFIG_GLOBAL": "/fixture/example",
            "GIT_TERMINAL_PROMPT": "1",
            "UNCHANGED": "yes",
        }
        with (
            patch.dict(os.environ, inherited, clear=True),
            patch.object(c.shutil, "which", return_value="/usr/bin/git") as which,
            patch.object(c.subprocess, "Popen", side_effect=OSError) as child,
            self.assertRaisesRegex(c.CollectionError, "git unavailable"),
        ):
            c.Runner().run(
                ["git", "version"], env={"GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"}
            )
        which.assert_called_once_with("git", path="/usr/bin:/bin")
        env = child.call_args.kwargs["env"]
        self.assertEqual(
            {key: value for key, value in env.items() if key.startswith("GIT_")},
            {"GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1"},
        )
        self.assertEqual(env["UNCHANGED"], "yes")

    def test_process_metadata_new_fields_and_missing_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            proc = root / "321"
            proc.mkdir()
            (root / "stat").write_text("btime 1700000000\n")
            (proc / "stat").write_text("321 (node) " + " ".join(["S"] + ["0"] * 18 + ["1234"]))
            (proc / "comm").write_text("node")
            (proc / "cmdline").write_bytes(b"node\0--token\0sample\0")
            with patch.object(c.os, "getuid", return_value=proc.stat().st_uid):
                meta = c.process_metadata(321, root)
            self.assertEqual(meta["uid"], os.getuid())
            self.assertEqual(meta["ownedByUser"], os.getuid() != 0)
            self.assertEqual(meta["startTicks"], "1234")
            self.assertEqual(meta["command"], "node --token ***")
            (proc / "cmdline").unlink()
            self.assertIsNone(c.process_metadata(321, root)["command"])
            self.assertFalse(c.process_metadata(999, root)["ownedByUser"])
            row = c.port_row("127.0.0.1", 3000)
            self.assertIsNone(row["uid"])
            self.assertIsNone(row["startTicks"])
            self.assertFalse(row["ownedByUser"])

    def test_container_exposed_ports_and_compose_directory(self):
        row = c.normalized_container(
            dict(id="a" * 64, exposed={"8080/tcp": {}, "53/udp": {}}, workdir="/home/u/app")
        )
        self.assertEqual(row["exposedPorts"], ["53/udp", "8080/tcp"])
        self.assertEqual(row["composeDir"], "/home/u/app")
        self.assertIsNone(c.normalized_container(dict(id="a", workdir="relative"))["composeDir"])
        self.assertIn(".Config.ExposedPorts", c.CONTAINER_FORMAT)
        self.assertIn("com.docker.compose.project.working_dir", c.CONTAINER_FORMAT)

    def test_runner_rejects_a_nonabsolute_resolved_executable(self):
        with (
            patch.dict(os.environ, {"PATH": "/usr/bin"}, clear=True),
            patch.object(c.shutil, "which", return_value="./fixture"),
            patch.object(c.subprocess, "Popen", side_effect=OSError) as child,
            self.assertRaisesRegex(c.CollectionError, "fixture unavailable"),
        ):
            c.Runner().run(["fixture"])
        self.assertEqual(child.call_count, 0)
