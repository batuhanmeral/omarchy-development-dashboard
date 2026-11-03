"""Executable trust, custom tool grammar and literal launch arguments."""

import importlib
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import collector as c


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(importlib.util.find_spec("launch"), "launch implementation missing")
        self.l = importlib.import_module("launch")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        env = patch.dict(os.environ, {"PATH": str(self.root)}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        extra = patch.object(self.l, "EXTRA_DIRS", ())
        extra.start()
        self.addCleanup(extra.stop)

    def executable(self, name, mode=0o755):
        file = self.root / name
        file.write_text("#!/bin/sh\nexit 0\n")
        file.chmod(mode)
        return file

    def test_resolve_permissions_regular_files_and_symlink_targets(self):
        good = self.executable("good")
        self.assertEqual(self.l.resolve_executable("good"), good)
        self.assertEqual(self.l.resolve_executable(str(good)), good)
        for name, mode, reason in [
            ("unsafe", 0o777, "unsafe permissions"),
            ("noexec", 0o644, "not executable"),
        ]:
            file = self.executable(name, mode)
            with self.assertRaisesRegex(c.CollectionError, reason):
                self.l.resolve_executable(str(file))
        link = self.root / "link"
        link.symlink_to(good)
        self.assertEqual(self.l.resolve_executable("link"), link)
        good.chmod(0o777)
        with self.assertRaisesRegex(c.CollectionError, "unsafe permissions"):
            self.l.resolve_executable("link")
        with self.assertRaisesRegex(c.CollectionError, "not found"):
            self.l.resolve_executable("missing")
        with self.assertRaises(c.CollectionError):
            self.l.resolve_executable(str(self.root))
        for name in ("a/b", "$(id)", "`id`", "; rm -rf ~", "x\n", "x\0"):
            with self.subTest(name=name), self.assertRaises(c.CollectionError):
                self.l.resolve_executable(name)
        with patch.object(self.l.os, "getuid", return_value=999999):
            if os.getuid() != 0:
                with self.assertRaisesRegex(c.CollectionError, "unsafe permissions"):
                    self.l.resolve_executable("link")

    def test_search_extra_directories(self):
        good = self.executable("extra")
        with (
            patch.dict(os.environ, {"PATH": ""}),
            patch.object(self.l, "EXTRA_DIRS", (str(self.root),)),
        ):
            self.assertEqual(self.l.resolve_executable("extra"), good)

    def test_custom_grammar_literal_arguments_and_limits(self):
        row = self.l.parse_custom_tool(" My Tool | codex | --flag $(id) `id` ; ", 2)
        self.assertEqual(row["id"], "custom-2")
        self.assertEqual(row["name"], "My Tool")
        self.assertEqual(row["args"], ["--flag", "$(id)", "`id`", ";"])
        self.assertEqual(self.l.parse_custom_tool("Name | /usr/bin/cli", 1)["args"], [])
        for line in ("", "  # comment"):
            self.assertIsNone(self.l.parse_custom_tool(line, 1))
        for line in (
            "bad",
            "| codex",
            "a | a | a | b",
            "a | ../x",
            "a | /tmp/../x",
            "a | $(id)",
            "a | x\0",
            "a | codex | x\n",
            "a | codex | " + " ".join(["x"] * 17),
            "a | x | " + "x" * 257,
            "a" * 49 + " | x",
        ):
            with (
                self.subTest(line=line),
                self.assertRaisesRegex(c.CollectionError, "invalid definition"),
            ):
                self.l.parse_custom_tool(line, 1)

    def test_tools_order_availability_invalid_and_limit(self):
        good = self.executable("codex")
        result = self.l.detect_tools(["# skip", "Extra | codex | --local", "invalid"])
        rows = result["tools"]
        self.assertEqual(
            [r["id"] for r in rows],
            ["claude", "codex", "gemini", "opencode", "custom-1", "custom-2"],
        )
        self.assertFalse(rows[0]["available"])
        self.assertEqual(rows[0]["reason"], "not found")
        self.assertEqual(rows[1]["path"], str(good))
        self.assertTrue(rows[4]["available"])
        self.assertFalse(rows[4]["builtin"])
        self.assertEqual(rows[5]["reason"], "invalid definition")
        with self.assertRaises(c.CollectionError):
            self.l.detect_tools(["a | codex"] * 9)
        result = c.collect("tools", custom_tools=["Extra | codex"])
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["data"]["tools"]), 5)

    def test_terminal_builders_keep_path_and_command_literal(self):
        directory = "/home/u/proje ; $(id)"
        command = ["/usr/bin/codex", "--help", "`id`"]
        cases = [
            ("default", "xdg-terminal-exec", [f"--dir={directory}"], ["--"]),
            ("alacritty", "alacritty", ["--working-directory", directory], ["-e"]),
            ("foot", "foot", [f"--working-directory={directory}"], []),
            ("ghostty", "ghostty", [f"--working-directory={directory}"], ["-e"]),
            ("kitty", "kitty", ["--directory", directory], []),
        ]
        for name, executable, flags, separator in cases:
            binary = self.executable(executable)
            self.assertEqual(
                self.l.terminal_argv(name, directory, command),
                [str(binary), *flags, *separator, *command],
            )
            self.assertEqual(self.l.terminal_argv(name, directory, None), [str(binary), *flags])
        with self.assertRaises(c.CollectionError):
            self.l.terminal_argv("bad", directory, None)

    def test_editor_builders_and_rejected_controls(self):
        default = self.executable("omarchy-launch-editor")
        custom = self.executable("editor")
        self.assertEqual(self.l.editor_argv("", "/my project"), [str(default), "/my project"])
        self.assertEqual(
            self.l.editor_argv("editor --wait $(id)", "/my project"),
            [str(custom), "--wait", "$(id)", "/my project"],
        )
        for spec in ("editor\n", "editor\0", "editor " + "x " * 9, "x" * 257):
            with self.assertRaises(c.CollectionError):
                self.l.editor_argv(spec, "/my project")
