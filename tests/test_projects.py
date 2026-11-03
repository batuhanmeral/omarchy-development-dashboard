"""Bounded project discovery and read-only Git state."""

import importlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import collector as c


class ProjectsTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(
            importlib.util.find_spec("projects"), "projects implementation missing"
        )
        self.p = importlib.import_module("projects")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def repo(self, path, head="ref: refs/heads/main\n"):
        path.mkdir(parents=True, exist_ok=True)
        (path / ".git").mkdir()
        (path / ".git" / "HEAD").write_text(head)
        return path

    def test_discovery_unicode_depth_pruning_symlinks_dedup_and_limit(self):
        first = self.repo(self.root / "proje ğüş 🚀")
        self.repo(first / "nested")
        second = self.repo(self.root / "group" / "app")
        self.repo(self.root / ".hidden" / "hidden")
        self.repo(self.root / "node_modules" / "ignored")
        self.repo(self.root / "group" / "deep" / "too-deep")
        (self.root / "loop").symlink_to(self.root, target_is_directory=True)
        with tempfile.TemporaryDirectory() as outside:
            self.repo(Path(outside) / "external")
            (self.root / "outside").symlink_to(outside, target_is_directory=True)
            found, skipped = self.p.discover([str(self.root), str(first)], 2)
        self.assertEqual({row["path"] for row in found}, {str(first), str(second)})
        self.assertEqual(skipped, 0)
        found, _ = self.p.discover([str(self.root)], 1)
        self.assertEqual([row["path"] for row in found], [str(first)])
        self.assertEqual(len(self.p.discover([str(self.root)], 4, limit=1)[0]), 1)
        self.assertEqual(self.p.discover([str(first)], 1)[0][0]["root"], str(first))

    def test_invalid_roots_paths_and_surrogate_names(self):
        for value in (
            "relative",
            "/",
            "/proc",
            "/proc/self",
            "/etc",
            "/usr/bin",
            "/var/lib/docker/x",
            str(self.root / "missing"),
            str(self.root) + "\n",
            "/x\0",
        ):
            with self.subTest(value=value), self.assertRaises(c.CollectionError):
                self.p.validate_root(value)
        file = self.root / "file"
        file.touch()
        with self.assertRaises(c.CollectionError):
            self.p.validate_root(str(file))
        bad = os.fsencode(self.root) + b"/bad-\xff"
        os.mkdir(bad)
        self.assertEqual(self.p.discover([str(self.root)], 2)[1], 1)
        with self.assertRaises(c.CollectionError):
            self.p.discover([str(self.root)], 5)

    def test_head_branch_worktree_detached_missing_and_malformed(self):
        project = self.repo(self.root / "repo")
        self.assertEqual(self.p.head_branch(project), ("main", False))
        head = project / ".git" / "HEAD"
        head.write_text("a" * 40)
        self.assertEqual(self.p.head_branch(project), ("aaaaaaa", True))
        head.write_text("not a head")
        self.assertEqual(self.p.head_branch(project), (None, False))
        head.unlink()
        self.assertEqual(self.p.head_branch(project), (None, False))
        worktree = self.root / "worktree"
        worktree.mkdir()
        (worktree / ".git").write_text("gitdir: ../repo/.git\n")
        head.write_text("ref: refs/heads/feature/test\n")
        self.assertEqual(self.p.head_branch(worktree), ("feature/test", False))
        (worktree / ".git").write_text("garbage")
        self.assertEqual(self.p.head_branch(worktree), (None, False))

    def test_porcelain_v2_counts_and_rename_second_path(self):
        class Fake:
            calls = []

            def run(self, argv, **kwargs):
                self.calls.append((argv, kwargs))
                return (
                    "# branch.oid abc\0# branch.head main\0# branch.ab +2 -3\0"
                    + "1 M. x\0"
                    + "2 R. x\0? old-name\0"
                    + "? new-file\0u UU conflict\0"
                )

        runner = Fake()
        result = self.p.git_status(self.root, runner)
        self.assertEqual(
            result,
            dict(
                branch="main",
                detached=False,
                ahead=2,
                behind=3,
                changed=2,
                untracked=1,
                conflicts=1,
                gitState="dirty",
            ),
        )
        argv, kwargs = runner.calls[0]
        self.assertEqual(
            argv,
            [
                "git",
                "--no-optional-locks",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.untrackedCache=false",
                "-C",
                str(self.root),
                "status",
                "--porcelain=v2",
                "--branch",
                "-z",
                "--untracked-files=normal",
            ],
        )
        self.assertEqual(kwargs["timeout"], 2)
        self.assertEqual(kwargs["env"]["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(kwargs["env"]["GIT_OPTIONAL_LOCKS"], "0")
        with patch.object(Fake, "run", side_effect=c.CollectionError("git timeout")):
            self.assertEqual(self.p.git_status(self.root, runner)["gitState"], "unknown")

    def test_projects_collect_partial_errors_status_limit_and_cli(self):
        for index in range(66):
            self.repo(self.root / f"r{index:02}")

        class Fake:
            calls = 0

            def run(self, argv, **kwargs):
                self.calls += 1
                return "# branch.head main\0"

        runner = Fake()
        result = c.collect(
            "projects", runner=runner, project_roots=["relative", str(self.root)], project_depth=2
        )
        self.assertFalse(result["ok"])
        self.assertEqual(len(result["errors"]), 1)
        self.assertEqual(len(result["data"]["projects"]), 66)
        self.assertEqual(runner.calls, 64)
        self.assertEqual(result["data"]["projects"][-1]["gitState"], "unknown")
        for row in result["data"]["projects"]:
            self.assertEqual(row["id"], "project:" + row["path"])
        out = io.StringIO()
        with (
            patch.object(
                sys,
                "argv",
                [
                    "collector.py",
                    "projects",
                    "--project-root",
                    str(self.root),
                    "--project-depth",
                    "1",
                ],
            ),
            patch("sys.stdout", out),
            patch.object(c, "Runner", return_value=Fake()),
        ):
            self.assertEqual(c.main(), 0)
        self.assertEqual(json.loads(out.getvalue())["kind"], "projects")

    @unittest.skipUnless(shutil.which("git"), "git unavailable")
    def test_real_git_init_status(self):
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.root)], check=True)
        (self.root / "new.txt").write_text("hello")
        result = c.collect("projects", project_roots=[str(self.root)])
        self.assertTrue(result["ok"], result["errors"])
        row = result["data"]["projects"][0]
        self.assertEqual(row["branch"], "main")
        self.assertEqual(row["untracked"], 1)
        self.assertEqual(row["gitState"], "dirty")
