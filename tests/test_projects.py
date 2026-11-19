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
        root = self.root

        class Fake:
            calls = []

            def run(self, argv, **kwargs):
                self.calls.append((argv, kwargs))
                if "config" in argv:
                    return ""
                if "--show-object-format" in argv:
                    return (
                        f"{root}/.git/index\n{root}/.git/objects\n{root}/.git/info/exclude\nsha1\n"
                    )
                if "--verify" in argv:
                    return "a" * 40 + "\n"
                if "symbolic-ref" in argv:
                    return "refs/heads/main\n"
                if "rev-list" in argv:
                    return "2\t3\n"
                gitdir = Path(next(a for a in argv if a.startswith("--git-dir="))[10:])
                self.private = (gitdir / "HEAD").read_text(), (gitdir / "config").read_text()
                return "1 M. x\0" + "2 R. x\0? old-name\0" + "? new-file\0u UU conflict\0"

        runner = Fake()
        self.repo(self.root)
        (self.root / ".git/index").touch()
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
        self.assertEqual(len(runner.calls), 6)
        self.assertEqual(runner.private[0], "a" * 40 + "\n")
        self.assertNotIn("filter", runner.private[1])
        self.assertNotIn("include", runner.private[1])
        argv, kwargs = runner.calls[5]
        gitdir = argv[10][10:]
        self.assertFalse(Path(gitdir).exists(), "private Git directory was not removed")
        self.assertEqual(
            argv,
            [
                "git",
                "--no-optional-locks",
                "-c",
                "protocol.allow=never",
                "-c",
                "core.fsmonitor=false",
                "-C",
                str(self.root),
                "-c",
                "core.untrackedCache=false",
                f"--git-dir={gitdir}",
                f"--work-tree={self.root}",
                "status",
                "--porcelain=v2",
                "-z",
                "--untracked-files=normal",
                "--ignore-submodules=all",
            ],
        )
        self.assertEqual(kwargs["timeout"], 2)
        self.assertEqual(kwargs["env"]["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(kwargs["env"]["GIT_OPTIONAL_LOCKS"], "0")
        self.assertEqual(kwargs["env"]["GIT_INDEX_FILE"], f"{self.root}/.git/index")
        self.assertEqual(kwargs["env"]["GIT_OBJECT_DIRECTORY"], f"{self.root}/.git/objects")
        with patch.object(Fake, "run", side_effect=c.CollectionError("git timeout")):
            self.assertEqual(self.p.git_status(self.root, runner)["gitState"], "unknown")

    def test_projects_collect_partial_errors_status_limit_and_cli(self):
        for index in range(66):
            self.repo(self.root / f"r{index:02}")

        class Fake:
            calls = 0

            def run(self, argv, **kwargs):
                if "config" in argv:
                    return ""
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

    @unittest.skipUnless(shutil.which("git"), "git unavailable")
    def test_real_git_status_keeps_upstream_staging_excludes_and_worktrees(self):
        identity = ["-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        for object_format in ("sha1", "sha256"):
            with self.subTest(object_format=object_format), tempfile.TemporaryDirectory() as tmp:
                repo = Path(tmp) / "repo"

                def git(*argv, cwd=repo):
                    return subprocess.run(
                        ["git", "-C", str(cwd), *argv], check=True, capture_output=True, text=True
                    ).stdout.strip()

                def commit(message, *parents, cwd=repo):
                    tree = git("write-tree", cwd=cwd)
                    flags = [item for parent in parents for item in ("-p", parent)]
                    # Plumbing only: the user's global commit hooks never see this fixture.
                    return git(*identity, "commit-tree", tree, *flags, "-m", message, cwd=cwd)

                subprocess.run(
                    ["git", "init", "-q", "-b", "main", f"--object-format={object_format}", repo],
                    check=True,
                )
                (repo / "a.txt").write_text("one\n")
                git("add", "a.txt")
                base = commit("test: base")
                (repo / "a.txt").write_text("two\n")
                git("add", "a.txt")
                local = commit("test: local", base)
                git("update-ref", "refs/heads/main", local)
                git("update-ref", "refs/remotes/origin/main", base)
                git("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
                git("config", "branch.main.remote", "origin")
                git("config", "branch.main.merge", "refs/heads/main")
                (repo / "staged.txt").write_text("new\n")
                git("add", "staged.txt")
                (repo / "ignored.log").write_text("x\n")
                (repo / "visible.txt").write_text("x\n")
                (repo / ".git/info/exclude").write_text("*.log\n")

                result = self.p.git_status(repo, c.Runner())
                self.assertEqual(
                    {k: result[k] for k in ("branch", "ahead", "behind", "changed", "untracked")},
                    dict(branch="main", ahead=1, behind=0, changed=1, untracked=1),
                )
                self.assertEqual(result["gitState"], "dirty")

                linked = Path(tmp) / "linked"
                git("worktree", "add", "-q", "-b", "side", str(linked), base)
                (linked / "a.txt").write_text("changed in worktree\n")
                result = self.p.git_status(linked, c.Runner())
                self.assertEqual(
                    {k: result[k] for k in ("branch", "changed", "untracked", "gitState")},
                    dict(branch="side", changed=1, untracked=0, gitState="dirty"),
                )

    @unittest.skipUnless(shutil.which("git"), "git unavailable")
    def test_real_git_status_keeps_branch_and_local_status_settings(self):
        repo = self.root / "repo"

        def git(*argv):
            return subprocess.run(
                ["git", "-C", str(repo), *argv], check=True, capture_output=True, text=True
            ).stdout.strip()

        subprocess.run(
            ["git", "init", "-q", "-b", "trunk", "--ref-format=reftable", str(repo)], check=True
        )
        (repo / "run.sh").write_text("echo\n")
        git("add", "run.sh")
        tree = git("write-tree")
        identity = ["-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        head = git(*identity, "commit-tree", tree, "-m", "test: base")
        git("update-ref", "refs/heads/trunk", head)
        git("config", "core.filemode", "false")
        git("config", "core.excludesFile", ".git/local-excludes")
        (repo / ".git/local-excludes").write_text("*.tmp\n")
        (repo / "run.sh").chmod(0o755)
        (repo / "scratch.tmp").write_text("x\n")
        result = self.p.git_status(repo, c.Runner())
        self.assertEqual(
            {k: result[k] for k in ("branch", "detached", "changed", "untracked", "gitState")},
            dict(branch="trunk", detached=False, changed=0, untracked=0, gitState="clean"),
        )

        git("checkout", "-q", "--detach")
        result = self.p.git_status(repo, c.Runner())
        self.assertEqual((result["branch"], result["detached"]), (head[:7], True))

    @unittest.skipUnless(shutil.which("git"), "git unavailable")
    def test_real_git_status_is_unknown_without_index_or_with_broken_head(self):
        repo = self.root / "repo"

        def git(*argv):
            return subprocess.run(
                ["git", "-C", str(repo), *argv], check=True, capture_output=True, text=True
            ).stdout.strip()

        subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
        (repo / "a.txt").write_text("a\n")
        git("add", "a.txt")
        tree = git("write-tree")
        identity = ["-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        git("update-ref", "refs/heads/main", git(*identity, "commit-tree", tree, "-m", "test: a"))
        (repo / ".git/index").unlink()
        self.assertEqual(self.p.git_status(repo, c.Runner())["gitState"], "unknown")

        git("read-tree", "HEAD")
        self.assertEqual(self.p.git_status(repo, c.Runner())["gitState"], "clean")
        (repo / ".git/HEAD").write_text("0" * 40 + "\n")
        self.assertEqual(self.p.git_status(repo, c.Runner())["gitState"], "unknown")

    @unittest.skipUnless(shutil.which("git"), "git unavailable")
    def test_real_git_status_fails_closed_on_unsupported_settings_and_temp_errors(self):
        repo = self.root / "repo"

        def git(*argv):
            subprocess.run(["git", "-C", str(repo), *argv], check=True, capture_output=True)

        subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
        self.assertEqual(self.p.git_status(repo, c.Runner())["gitState"], "clean")
        with patch.object(self.p.tempfile, "TemporaryDirectory", side_effect=OSError("full")):
            self.assertEqual(self.p.git_status(repo, c.Runner())["gitState"], "unknown")
        (repo / ".git/info/exclude").write_bytes(b"#" * (self.p.MAX_EXCLUDES + 1))
        self.assertEqual(self.p.git_status(repo, c.Runner())["gitState"], "unknown")
        (repo / ".git/info/exclude").write_bytes(b"caf\xe9\n")
        self.assertEqual(self.p.git_status(repo, c.Runner())["gitState"], "clean")
        git("config", "core.eol", "bogus")
        self.assertEqual(self.p.git_status(repo, c.Runner())["gitState"], "unknown")

    def test_expected_ports_only_exports_numbers_and_filenames(self):
        project = self.repo(self.root / "app")
        (project / ".env").write_text(
            "PORT=3000\nDB_PORT='5432'\nPASSWORD=private\nBAD_PORT=65536\n"
        )
        (project / ".env.local").write_text(
            "export PORT=004000 # local\n_PORT=004001\n" + "MALFORMED_PORT=\"5000'\n"
        )
        (project / ".env.development").write_bytes(b"PORT=1000\n\xff")
        (project / "package.json").write_text(
            json.dumps(
                {
                    "scripts": {
                        "dev": "vite --port=5173",
                        "other": "PORT=9090 app -p 8080 --port 9999",
                    },
                    "description": "--port=1234",
                }
            )
        )
        (project / "compose.yaml").write_text('ports:\n  - "127.0.0.1:6380:6379"\n  - "8000:80"\n')
        result = c.collect("projects", project_roots=[str(self.root)])
        self.assertEqual(
            [
                (entry["port"], entry["source"])
                for entry in result["data"]["projects"][0]["expectedPorts"]
            ],
            [
                (3000, ".env"),
                (5432, ".env"),
                (4000, ".env.local"),
                (4001, ".env.local"),
                (5173, "package.json"),
                (9090, "package.json"),
                (8080, "package.json"),
                (9999, "package.json"),
                (6380, "compose.yaml"),
                (8000, "compose.yaml"),
            ],
        )
        self.assertNotIn("private", json.dumps(result))

    def test_expected_ports_skips_special_and_oversized_files_and_caps_results(self):
        project = self.repo(self.root / "app")
        outside = self.root / "outside"
        outside.write_text("PORT=7777")
        (project / ".env").symlink_to(outside)
        os.mkfifo(project / ".env.local")
        (project / ".env.development").write_text("PORT=8888\n" + " " * 65536)
        (project / "docker-compose.yml").write_text(
            "".join(f'- "{port}:80"\n' for port in range(9000, 9020))
        )
        result = c.collect("projects", project_roots=[str(self.root)])
        self.assertEqual(
            [entry["port"] for entry in result["data"]["projects"][0]["expectedPorts"]],
            list(range(9000, 9016)),
        )

    def test_project_preview_scope_is_no_longer_available(self):
        result = c.collect("project-detail")
        self.assertFalse(result["ok"])
        self.assertEqual(result["errors"], ["unsupported scope"])

    def test_project_git_commands_apply_offline_controls_to_config_and_status(self):
        project = self.repo(self.root / "app")

        class Fake:
            calls = []

            def run(_, argv, **kwargs):
                _.calls.append((argv, kwargs))
                if "--show-object-format" in argv:
                    return f"{project}/i\n{project}/o\n{project}/e\nsha256\n"
                if "symbolic-ref" in argv:
                    return "refs/heads/main\n"
                return "b" * 64 if "--verify" in argv else ""

        (project / "i").touch()
        runner = Fake()
        self.assertEqual(self.p.git_status(project, runner)["gitState"], "clean")
        self.assertEqual(len(runner.calls), 6)
        for argv, kwargs in runner.calls:
            self.assertIn("protocol.allow=never", argv)
            self.assertEqual(kwargs["env"]["GIT_NO_LAZY_FETCH"], "1")
            self.assertEqual(kwargs["env"]["GIT_ALLOW_PROTOCOL"], "")
            self.assertEqual(kwargs["env"]["GIT_CEILING_DIRECTORIES"], str(self.root))

    def test_project_git_commands_require_an_own_repository_marker(self):
        parent = self.repo(self.root / "parent")
        child = parent / "child"
        child.mkdir()

        class Fake:
            def run(self, argv, **kwargs):
                raise AssertionError("Git must not run for a nested non-repository directory")

        for marker_type in ("missing", "symlink"):
            with self.subTest(marker_type=marker_type):
                if marker_type == "symlink":
                    (child / ".git").symlink_to(parent / ".git")
                self.assertEqual(self.p.git_status(child, Fake())["gitState"], "unknown")

    @unittest.skipUnless(shutil.which("git"), "git unavailable")
    def test_status_preflight_includes_worktree_local_configuration(self):
        def git(*argv):
            subprocess.run(["git", "-C", str(self.root), *argv], check=True, capture_output=True)

        git("init", "--quiet")
        git("config", "--local", "extensions.worktreeConfig", "true")
        git("config", "--worktree", "filter.fixture.required", "false")
        self.assertEqual(self.p.git_status(self.root, c.Runner())["gitState"], "unknown")


class LazyFetchExploitTests(unittest.TestCase):
    """A promisor repository with a missing object must not make Git run its configured commands."""

    def make_repo(self, root: Path, marker: Path) -> Path:
        repo = root / "repo"
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0")

        def git(*args: str) -> str:
            return subprocess.run(
                ["git", "-C", str(repo), *args],
                check=True,
                capture_output=True,
                text=True,
                env=env,
            ).stdout.strip()

        repo.mkdir()
        git("init", "-q")
        (repo / "f.txt").write_text("a\n")
        blob = git("hash-object", "-w", "f.txt")
        git("update-index", "--add", "--cacheinfo", f"100644,{blob},f.txt")
        tree = git("write-tree")
        # Plumbing only: no commit hooks run, so the user's global hooks never see this fixture.
        identity = ["-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        first = git(*identity, "commit-tree", tree, "-m", "test: first")
        second = git(*identity, "commit-tree", tree, "-p", first, "-m", "test: second")
        git("update-ref", "refs/heads/main", second)
        git("symbolic-ref", "HEAD", "refs/heads/main")
        git("config", "extensions.partialClone", "origin")
        git("config", "remote.origin.promisor", "true")
        git("config", "remote.origin.url", "ssh://example.invalid/x")
        git("config", "core.sshCommand", f"touch {marker}")
        (repo / ".git/objects" / second[:2] / second[2:]).unlink()
        return repo

    @unittest.skipUnless(shutil.which("git"), "git unavailable")
    def test_status_and_detail_do_not_run_repository_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker = root / "PWNED"
            repo = self.make_repo(root, marker)
            # The fixture is only meaningful if plain Git really runs the command.
            subprocess.run(
                ["git", "-C", str(repo), "log", "-1"],
                capture_output=True,
                env=dict(os.environ, GIT_TERMINAL_PROMPT="0"),
                check=False,
            )
            self.assertTrue(marker.exists(), "fixture no longer reproduces the lazy fetch")
            marker.unlink()
            projects = importlib.import_module("projects")
            projects.git_status(repo, c.Runner(budget=20))
            self.assertFalse(marker.exists(), "git status ran a repository-configured command")
