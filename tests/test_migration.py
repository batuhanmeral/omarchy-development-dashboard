"""Legacy import reads only known typed keys and never writes shell settings."""

import importlib
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


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(importlib.util.find_spec("migration"), "legacy implementation missing")
        self.m = importlib.import_module("migration")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.config = self.home / "custom-config"
        self.file = self.config / "omarchy" / "shell.json"
        self.file.parent.mkdir(parents=True)

    def test_missing_invalid_oversized_and_wrong_structure(self):
        expected = dict(legacy=dict(found=False, installed=False, settings={}))
        self.assertEqual(self.m.legacy_settings(self.config, self.home), expected)
        for content in (
            b"broken json",
            b"x" * (1024 * 1024 + 1),
            b"[]",
            b'{"bar":[]}',
            b'{"bar":{"layout":[]}}',
            b"\xff",
        ):
            self.file.write_bytes(content)
            self.assertEqual(self.m.legacy_settings(self.config, self.home), expected)
        with patch.object(os, "open", side_effect=PermissionError):
            self.assertEqual(self.m.legacy_settings(self.config, self.home), expected)

    def test_first_entry_whitelist_types_installation_and_read_only(self):
        data = dict(
            bar=dict(
                layout=dict(
                    left=[
                        "invalid",
                        dict(id="other"),
                        dict(
                            id="io.github.batuhanmeral.devports",
                            refreshInterval=5,
                            dockerEnabled=True,
                            exposure="all",
                            hiddenPorts="80",
                            visibleTabs="Localhost",
                            sortBy="name",
                            compact=False,
                            sqliteFiles="/a.db",
                            evil="x",
                            settingsVersion=999,
                        ),
                    ],
                    right=[dict(id="io.github.batuhanmeral.devports", refreshInterval=99)],
                )
            )
        )
        self.file.write_text(json.dumps(data))
        before = self.file.read_bytes(), self.file.stat().st_mtime_ns
        installed = self.config / "omarchy/plugins/io.github.batuhanmeral.devports"
        installed.mkdir(parents=True)
        result = self.m.legacy_settings(self.config, self.home)
        self.assertEqual(
            result,
            dict(
                legacy=dict(
                    found=True,
                    installed=True,
                    settings=dict(
                        refreshInterval=5,
                        dockerEnabled=True,
                        exposure="all",
                        hiddenPorts="80",
                        visibleTabs="Localhost",
                        sortBy="name",
                        compact=False,
                        sqliteFiles="/a.db",
                    ),
                )
            ),
        )
        self.assertEqual(before, (self.file.read_bytes(), self.file.stat().st_mtime_ns))
        entry = data["bar"]["layout"]["left"][2]
        entry.update(
            refreshInterval=True,
            dockerEnabled=1,
            exposure=[],
            compact="true",
            hiddenPorts=1,
            visibleTabs=None,
            sortBy=False,
            sqliteFiles={},
        )
        self.file.write_text(json.dumps(data))
        self.assertEqual(self.m.legacy_settings(self.config, self.home)["legacy"]["settings"], {})

    def test_legacy_config_rejects_fifo_without_blocking_and_follows_regular_symlink(self):
        os.mkfifo(self.file)
        with (
            patch.object(
                Path, "open", side_effect=AssertionError("Must not open FIFO in blocking mode")
            ),
            patch.object(os, "open", wraps=os.open) as opener,
        ):
            self.assertFalse(self.m.legacy_settings(self.config, self.home)["legacy"]["found"])
        self.assertTrue(opener.call_args.args[1] & os.O_NONBLOCK)
        self.file.unlink()
        target = self.file.with_name("settings.json")
        target.write_text(json.dumps({"bar": {"layout": {"left": [{"id": self.m.LEGACY_ID}]}}}))
        self.file.symlink_to(target)
        self.assertTrue(self.m.legacy_settings(self.config, self.home)["legacy"]["found"])

    def test_installed_follows_xdg_config_home(self):
        default_plugin = self.home / ".config/omarchy/plugins" / self.m.LEGACY_ID
        default_plugin.mkdir(parents=True)
        with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.config)}):
            self.assertFalse(self.m.legacy_settings(home=self.home)["legacy"]["installed"])
            (self.config / "omarchy/plugins" / self.m.LEGACY_ID).mkdir(parents=True)
            self.assertTrue(self.m.legacy_settings(home=self.home)["legacy"]["installed"])

    def test_environment_defaults_and_collector_cli(self):
        with (
            patch.dict(c.os.environ, {"XDG_CONFIG_HOME": str(self.config)}),
            patch.object(Path, "home", return_value=self.home),
        ):
            result = c.collect("legacy")
            self.assertTrue(result["ok"])
            self.assertFalse(result["data"]["legacy"]["found"])
            self.file.write_text(
                '{"bar":{"layout":{"left":[{"id":"io.github.batuhanmeral.devports","compact":true}]}}}'
            )
            out = io.StringIO()
            with patch.object(sys, "argv", ["collector.py", "legacy"]), patch("sys.stdout", out):
                self.assertEqual(c.main(), 0)
            self.assertTrue(json.loads(out.getvalue())["data"]["legacy"]["found"])
        fallback = self.home / ".config/omarchy/shell.json"
        fallback.parent.mkdir(parents=True)
        fallback.write_bytes(self.file.read_bytes())
        with (
            patch.dict(c.os.environ, {}, clear=True),
            patch.object(Path, "home", return_value=self.home),
        ):
            self.assertTrue(c.collect("legacy")["data"]["legacy"]["found"])
