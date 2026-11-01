"""Acceptance tests use synthetic OS/CLI data, never the user's containers."""

import importlib.util
import socket
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
SPEC = importlib.util.find_spec("collector")
if SPEC:
    import collector as c
else:
    c = None


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(c, "collector implementation is missing")

    def test_ipv4_ipv6_and_exposure(self):
        cases = [
            ("127.0.0.1:3000", "127.0.0.1", 3000, "localhost"),
            ("0.0.0.0:80", "0.0.0.0", 80, "all"),  # noqa: S104 — parser fixture
            ("[::1]:5173", "::1", 5173, "localhost"),
            ("[::]:8080", "::", 8080, "all"),
            ("192.168.1.8:5432", "192.168.1.8", 5432, "lan"),
            ("[fe80::1%eth0]:80", "fe80::1%eth0", 80, "lan"),
        ]
        for value, address, port, exposure in cases:
            with self.subTest(value=value):
                self.assertEqual(c.endpoint(value), (address, port))
                self.assertEqual(c.exposure(address), exposure)
        # Zones are ASCII interface names, matching the UI boundary in Model.js.
        self.assertIsNone(c.endpoint("[fe80::1%ethı]:80"))
        for value in ("bad", "localhost:30", "127.0.0.1:0", "127.0.0.1:65536", "[::1]:x"):
            self.assertIsNone(c.endpoint(value))

    def test_ss_empty_malformed_and_large(self):
        self.assertEqual(c.parse_ss(""), [])
        self.assertEqual(c.parse_ss("not ss output\nLISTEN 0"), [])
        output = "\n".join(f"LISTEN 0 128 127.0.0.1:{p} 0.0.0.0:*" for p in range(10000, 12000))
        rows = c.parse_ss(output)
        self.assertEqual(len(rows), 2000)
        self.assertEqual(rows[0]["process"], "Unknown")
        self.assertIsNone(rows[0]["pid"])

    def test_ss_processes_dedup_and_untrusted_text(self):
        line = 'LISTEN 0 128 [::1]:3000 [::]:* users:(("<node>",pid=123,fd=9))'
        rows = c.parse_ss(line + "\n" + line)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["pid"], 123)
        self.assertEqual(rows[0]["address"], "::1")
        self.assertEqual(rows[0]["process"], "<node>")

    def test_proc_metadata_handles_stat_parentheses_and_permissions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            proc = root / "123"
            proc.mkdir()
            (root / "stat").write_text("cpu 1 2 3\nbtime 1700000000\n")
            # field 22 (starttime) is index 19 after the closing command parenthesis.
            fields = ["S"] + ["0"] * 18 + ["200"] + ["0"] * 10
            (proc / "stat").write_text("123 (worker (odd)) " + " ".join(fields))
            (proc / "comm").write_text("postgres\n")
            (proc / "cwd").symlink_to(root, target_is_directory=True)
            with patch.object(c.os, "sysconf", return_value=100):
                meta = c.process_metadata(123, root)
            self.assertEqual(meta["process"], "postgres")
            # A start timestamp, unlike an uptime, is identical on every poll of the same process.
            self.assertEqual(meta["startedAt"], 1700000002)
            self.assertEqual(meta["cwd"], str(root))
            self.assertNotEqual(meta["owner"], "Unknown")
            self.assertEqual(c.process_metadata(999, root)["process"], "Unknown")
            with patch.object(Path, "read_text", side_effect=PermissionError):
                self.assertEqual(c.process_metadata(123, root)["process"], "Unknown")

    def test_runner_timeout_failure_and_output_limit(self):
        with self.assertRaisesRegex(c.CollectionError, "timeout"):
            c.Runner(timeout=0.05).run([sys.executable, "-c", "import time; time.sleep(2)"])
        with self.assertRaisesRegex(c.CollectionError, "failed"):
            c.Runner().run([sys.executable, "-c", "raise SystemExit(4)"])
        with self.assertRaisesRegex(c.CollectionError, "limit"):
            c.Runner(max_bytes=100).run([sys.executable, "-c", 'print("a" * 1000)'])
        with self.assertRaisesRegex(c.CollectionError, "unavailable"):
            c.Runner().run(["/nonexistent/devports-test-command"])
        with self.assertRaisesRegex(c.CollectionError, "budget"):
            c.Runner(budget=0).run([sys.executable, "-c", "print(1)"])
        self.assertEqual(c.Runner().run([sys.executable, "-c", 'print("ok")']).strip(), "ok")

    def test_collect_ports_envelope_failure_and_no_docker(self):
        class Fake:
            def run(self, argv, **kwargs):
                if argv[0] != "ss":
                    raise AssertionError("Docker called while disabled")
                return "LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*"

        result = c.collect("ports", False, [], Fake())
        self.assertTrue(result["ok"])
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["data"]["ports"][0]["port"], 3000)
        with patch.object(Fake, "run", side_effect=c.CollectionError("timeout")):
            result = c.collect("ports", False, [], Fake())
        self.assertFalse(result["ok"])
        self.assertIn("timeout", result["errors"][0])
        self.assertNotIn("ports", result["data"])

    def test_real_listening_socket(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.bind(("127.0.0.1", 0))
            server.listen()
            port = server.getsockname()[1]
            result = c.collect("ports", False, [], c.Runner())
        self.assertTrue(result["ok"], result["errors"])
        self.assertTrue(
            any(
                row["port"] == port and row["exposure"] == "localhost"
                for row in result["data"]["ports"]
            )
        )


if __name__ == "__main__":
    unittest.main()
