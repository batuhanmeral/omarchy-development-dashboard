"""Regression evidence for the dashboard backend review findings."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import actions
import collector as c
import launch
import projects


class ReviewRegressions(unittest.TestCase):
    def test_symlink_shims_keep_the_invoked_basename(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dispatcher = root / "dispatcher"
            dispatcher.write_text(
                f"#!{sys.executable}\nimport os,sys\nprint(os.path.basename(sys.argv[0]))\n"
            )
            dispatcher.chmod(0o700)
            shim = root / "codex"
            shim.symlink_to(dispatcher)
            with patch.dict(os.environ, {"PATH": str(root)}):
                with self.subTest(boundary="resolver"):
                    resolved = launch.resolve_executable("codex")
                    result = subprocess.run(
                        [str(resolved)], capture_output=True, text=True, check=True
                    )
                    self.assertEqual(result.stdout.strip(), "codex")
                    self.assertEqual(resolved, shim)
                with self.subTest(boundary="inventory"):
                    self.assertEqual(launch.detect_tools([])["tools"][1]["path"], str(shim))
                with self.subTest(boundary="runner"):
                    self.assertEqual(c.Runner().run(["codex"]).strip(), "codex")

    @unittest.skipUnless(shutil.which("git"), "git unavailable")
    def test_git_status_does_not_run_repository_clean_filters(self):
        for attributes in (".gitattributes", ".git/info/attributes"):
            with self.subTest(attributes=attributes), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)

                def git(*args, root=root):
                    return subprocess.run(
                        ["git", "-C", str(root), *args], check=True, capture_output=True
                    )

                git("init", "-q")
                tracked = root / "tracked.txt"
                tracked.write_text("original")
                git("add", "tracked.txt")
                (root / attributes).write_text("tracked.txt filter=fixture\n")
                marker = root / "filter-ran"
                script = root / "filter.py"
                script.write_text(
                    "import pathlib,sys\n"
                    f"pathlib.Path({str(marker)!r}).touch()\n"
                    "sys.stdout.write(sys.stdin.read())\n"
                )
                git("config", "--local", "filter.fixture.clean", f"{sys.executable} {script}")
                tracked.write_text("modified")
                result = projects.git_status(root, c.Runner())
                self.assertFalse(marker.exists(), "git status executed the repository's filter")
                self.assertEqual(result["gitState"], "unknown")

    def test_git_config_include_preflight_is_fail_closed(self):
        from unittest.mock import Mock

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".git").mkdir()
            for definition in ("filter.fixture.clean", "include.path", "includeif.gitdir:*/.path"):
                runner = Mock()
                runner.run.return_value = "local\t" + definition + "\n"
                result = projects.git_status(root, runner)
                self.assertEqual(result["gitState"], "unknown")
                self.assertEqual(runner.run.call_count, 1)
                self.assertIn("config", runner.run.call_args.args[0])
                self.assertEqual(runner.run.call_args.kwargs["timeout"], 2)
                self.assertEqual(runner.run.call_args.kwargs["env"]["GIT_TERMINAL_PROMPT"], "0")

    def test_discovery_does_not_block_on_fifo_head(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".git").mkdir()
            os.mkfifo(root / ".git/HEAD")
            code = (
                "import sys; sys.path.insert(0, sys.argv[1]); import projects; "
                "rows, skipped = projects.discover([sys.argv[2]], 1); "
                "assert len(rows) == 1 and rows[0]['branch'] is None"
            )
            try:
                result = subprocess.run(
                    [sys.executable, "-c", code, str(Path(c.__file__).parent), str(root)],
                    capture_output=True,
                    text=True,
                    timeout=1,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                self.fail("discover blocked on a FIFO HEAD for over one second")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_head_and_gitdir_pointer_must_be_regular_not_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / "project"
            project.mkdir()
            gitdir = project / ".git"
            gitdir.mkdir()
            head = root / "head"
            head.write_text("ref: refs/heads/main\n")
            (gitdir / "HEAD").symlink_to(head)
            with self.subTest(file="HEAD"):
                self.assertEqual(projects.head_branch(project), (None, False))
            (gitdir / "HEAD").unlink()
            (gitdir / "HEAD").write_text("ref: refs/heads/main\n")
            worktree = root / "worktree"
            worktree.mkdir()
            pointer = root / "pointer"
            pointer.write_text("gitdir: ../project/.git\n")
            (worktree / ".git").symlink_to(pointer)
            with self.subTest(file=".git"):
                self.assertEqual(projects.head_branch(worktree), (None, False))
            (gitdir / "HEAD").write_bytes(b"a" * 4097)
            self.assertEqual(projects.head_branch(project), (None, False))

    def test_redaction_covers_short_flags_headers_and_ambiguous_userinfo(self):
        cases = [
            (["cli", "--pw", "FAKE"], "cli --pw ***"),
            (["cli", "--jwt=FAKE"], "cli --jwt=***"),
            (["SESSION=FAKE", "--bearer", "FAKE"], "SESSION=*** --bearer ***"),
            (["cli", "--sig", "FAKE"], "cli --sig ***"),
            (["db", "-pFAKE", "-P", "FAKE"], "db -p*** -P ***"),
            (["db", "-p=FAKE"], "db -p=***"),
            (
                ["curl", "--header", "Authorization: Bearer FAKE"],
                "curl --header Authorization: ***",
            ),
            (["curl", "--header=X-Api-Key: FAKE"], "curl --header=X-Api-Key: ***"),
            (["curl", "CustomToken: FAKE"], "curl CustomToken: ***"),
            (
                ["curl", "--header", "Authorization:", "Bearer FAKE"],
                "curl --header Authorization: ***",
            ),
            (["postgres://u:p@ss/w@h/db"], "postgres://***@h/db"),
            (["https://u:p@ss@host/path"], "https://***@host/path"),
            (
                ["https://host/path/user@example", "--port", "80"],
                "https://host/path/user@example --port 80",
            ),
        ]
        for argv, expected in cases:
            with self.subTest(argv=argv):
                self.assertEqual(c.redact_command(argv), expected)

    def test_project_directory_visit_limit_retains_partial_data_and_error(self):
        from unittest.mock import Mock

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("first", "second", "third"):
                (root / name / ".git").mkdir(parents=True)
            runner = Mock()
            runner.run.return_value = ""
            with patch.object(projects, "MAX_VISITED_DIRECTORIES", 2, create=True):
                result = c.collect("projects", project_roots=[str(root)], runner=runner)
            self.assertEqual(len(result["data"]["projects"]), 1)
            self.assertFalse(result["ok"])
            self.assertEqual(
                result["errors"],
                ["Project scan stopped early (limit reached); showing partial results."],
            )

    def test_project_time_budget_retains_partial_data_and_error(self):
        import time
        from unittest.mock import Mock

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("first", "second", "third"):
                (root / name / ".git").mkdir(parents=True)
            elapsed = [0.0]
            original = projects.head_branch

            def expire_after_first_project(project):
                branch = original(project)
                elapsed[0] = 9.0
                return branch

            runner = Mock()
            runner.run.return_value = ""
            with (
                patch.object(time, "monotonic", side_effect=lambda: elapsed[0]),
                patch.object(projects, "head_branch", side_effect=expire_after_first_project),
            ):
                result = c.collect("projects", project_roots=[str(root)], runner=runner)
            self.assertEqual(len(result["data"]["projects"]), 1)
            self.assertFalse(result["ok"])
            self.assertEqual(
                result["errors"],
                ["Project scan stopped early (limit reached); showing partial results."],
            )

    def test_project_launch_requires_directory_owned_by_current_user(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / "project"
            project.mkdir()
            owner = project.stat().st_uid
            with patch.object(actions.os, "getuid", return_value=owner + 1):
                with self.assertRaisesRegex(
                    c.CollectionError, "The project folder is not owned by you"
                ):
                    actions.project_directory(str(project), [str(root)])
            with patch.object(actions.os, "getuid", return_value=owner):
                self.assertEqual(actions.project_directory(str(project), [str(root)]), project)
