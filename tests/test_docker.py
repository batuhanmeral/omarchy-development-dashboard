"""Read-only Docker discovery, bounded diagnostics and evidence-based databases."""

import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import collector as c

CID = "a" * 64
STOPPED = "b" * 64
IMAGE = "sha256:" + "c" * 64


def container(cid=CID, state="running"):
    return dict(
        id=cid,
        name="/database",
        image="postgres:17",
        imageId=IMAGE,
        state=state,
        health="healthy" if state == "running" else None,
        ports={
            "5432/tcp": [{"HostIp": "127.0.0.1", "HostPort": "5432"}],
            "9999/tcp": None,
            "53/udp": [{"HostIp": "127.0.0.1", "HostPort": "53"}],
        },
        bindings={},
        restart="unless-stopped",
        compose="workbench",
        mounts=[{"Type": "volume", "Name": "pgdata", "Destination": "/data"}],
    )


class DockerRunner:
    def __init__(self, containers=None, unavailable=False):
        self.containers = (
            [container(), container(STOPPED, "exited")] if containers is None else containers
        )
        self.unavailable = unavailable
        self.calls = []

    def run(self, argv, **kwargs):
        self.calls.append(argv)
        if argv[:3] == ["docker", "context", "inspect"]:
            return '"unix:///var/run/docker.sock"'
        if argv[:3] != ["docker", "--host", "unix:///var/run/docker.sock"]:
            raise AssertionError(f"unexpected command: {argv}")
        command = argv[3:]
        if self.unavailable:
            raise c.CollectionError("docker failed (exit 1)")
        if command[:2] == ["container", "ls"]:
            return "\n".join(row["id"] for row in self.containers)
        if command[:2] == ["container", "inspect"]:
            return "\n".join(json.dumps(row) for row in self.containers)
        if command[:2] == ["container", "stats"]:
            return json.dumps({"ID": CID, "CPUPerc": "1.25%", "MemUsage": "12MiB / 1GiB"})
        if command[:2] == ["image", "ls"]:
            return json.dumps({"ID": IMAGE, "Repository": "postgres", "Tag": "17", "Size": "430MB"})
        if command[:2] == ["volume", "ls"]:
            return "pgdata\n"
        if command[:2] == ["volume", "inspect"]:
            return json.dumps(
                {"name": "pgdata", "mountpoint": "/var/lib/docker/volumes/pgdata/_data"}
            )
        if command[:1] == ["logs"]:
            return "ready\n"
        raise AssertionError(f"unexpected command: {argv}")


class DockerTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(hasattr(c, "docker_inventory"), "Docker implementation missing")
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_containers_health_stats_metadata_and_internal_ports(self):
        result = c.collect("docker", True, [], DockerRunner())
        self.assertTrue(result["ok"], result["errors"])
        rows = result["data"]["containers"]
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["health"], "healthy")
        self.assertEqual(rows[0]["cpu"], "1.25%")
        self.assertEqual(rows[0]["memory"], "12MiB / 1GiB")
        self.assertEqual(rows[0]["restart"], "unless-stopped")
        self.assertEqual(rows[0]["compose"], "workbench")
        self.assertEqual(rows[0]["database"], "PostgreSQL")
        self.assertEqual(rows[1]["state"], "exited")
        self.assertEqual(rows[1]["publishedPorts"], [])
        self.assertEqual([p["port"] for p in rows[0]["publishedPorts"]], [5432])

    def test_container_format_tolerates_missing_health(self):
        # Docker 29 renders inspect templates against a raw JSON map, so a field
        # path into an absent State.Health aborts the whole batch with
        # "map has no entry for key". Only index lookups are missing-key safe.
        self.assertNotIn(".State.Health", c.CONTAINER_FORMAT)
        self.assertIn('{{with index .State "Health"}}', c.CONTAINER_FORMAT)

    def test_docker_unavailable_and_disabled(self):
        result = c.collect("docker", True, [], DockerRunner(unavailable=True))
        self.assertFalse(result["ok"])
        self.assertEqual(result["data"]["dockerStatus"], "unavailable")
        runner = DockerRunner()
        result = c.collect("docker", False, [], runner)
        self.assertTrue(result["ok"])
        self.assertEqual(result["data"]["dockerStatus"], "disabled")
        self.assertEqual(runner.calls, [])

    def test_no_remote_docker_access(self):
        with patch.dict(os.environ, {"DOCKER_HOST": "ssh://remote"}):
            runner = DockerRunner()
            result = c.collect("docker", True, [], runner)
        self.assertFalse(result["ok"])
        self.assertEqual(runner.calls, [])
        self.assertIn("local Unix socket", result["errors"][0])

    def test_assets_image_usage_and_volumes_no_size_estimate(self):
        result = c.collect("assets", True, [], DockerRunner())
        self.assertTrue(result["ok"], result["errors"])
        image = result["data"]["images"][0]
        volume = result["data"]["volumes"][0]
        self.assertEqual(image["tags"], ["postgres:17"])
        self.assertEqual(image["size"], "430MB")
        self.assertTrue(image["used"])
        self.assertEqual(volume["name"], "pgdata")
        self.assertEqual(volume["containers"], ["database"])
        self.assertIsNone(volume["size"])
        self.assertEqual(volume["mountpoint"], "/var/lib/docker/volumes/pgdata/_data")

    def test_empty_inventory(self):
        runner = DockerRunner(containers=[])
        result = c.collect("docker", True, [], runner)
        self.assertTrue(result["ok"])
        self.assertEqual(result["data"]["containers"], [])
        self.assertFalse(any("stats" in call or "inspect" in call[3:] for call in runner.calls))

    def test_projection_never_collects_credentials(self):
        runner = DockerRunner()
        c.collect("docker", True, [], runner)
        commands = " ".join(" ".join(call) for call in runner.calls)
        for forbidden in (".Config.Env", ".Config.Cmd", ".Config.Labels}}", "{{json .}} --"):
            self.assertNotIn(forbidden, commands)
        self.assertIn("com.docker.compose.project", commands)

    def test_database_evidence_and_no_guess_from_port(self):
        for value, expected in [
            ("postgres", "PostgreSQL"),
            ("mysql:8", "MySQL"),
            ("mariadb:11", "MariaDB"),
            ("mongo:8", "MongoDB"),
            ("redis:7", "Redis"),
            ("mcr.microsoft.com/mssql/server:2025", "Microsoft SQL Server"),
        ]:
            self.assertEqual(c.database_type(value), expected)
        self.assertIsNone(c.database_type("notpostgres-app"))
        self.assertIsNone(c.database_type("node"))
        self.assertIsNone(c.parse_ss("LISTEN 0 10 127.0.0.1:5432 *:*")[0]["database"])

    def test_configured_sqlite_only_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "app.sqlite"
            db.write_bytes(b"do not inspect these contents")
            rows = c.sqlite_inventory([str(db), str(Path(tmp) / "missing.sqlite")])
            self.assertEqual(rows[0]["state"], "configured")
            self.assertEqual(rows[1]["state"], "unavailable")
            self.assertEqual(rows[0]["database"], "SQLite")
            self.assertNotIn("contents", json.dumps(rows))
        self.assertEqual(c.sqlite_inventory([]), [])
        with self.assertRaises(c.CollectionError):
            c.sqlite_inventory(["relative.sqlite"])

    def test_invalid_docker_json_and_ids(self):
        class Broken(DockerRunner):
            def run(self, argv, **kwargs):
                if "container" in argv and "inspect" in argv:
                    return "{broken json"
                return super().run(argv, **kwargs)

        result = c.collect("docker", True, [], Broken())
        self.assertFalse(result["ok"])
        self.assertEqual(result["data"]["dockerStatus"], "unavailable")
        with self.assertRaises(c.CollectionError):
            c.read_logs("a;rm", DockerRunner())
        self.assertEqual(c.read_logs(CID, DockerRunner())["text"], "ready\n")

    def test_cli_one_json_object_and_stderr_diagnostics(self):
        out, err = io.StringIO(), io.StringIO()
        with (
            patch.object(sys, "argv", ["collector.py", "docker"]),
            patch.object(c, "Runner", return_value=DockerRunner(unavailable=True)),
            patch("sys.stdout", out),
            patch("sys.stderr", err),
        ):
            status = c.main()
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(out.getvalue())["schemaVersion"], 1)
        self.assertTrue(err.getvalue())
