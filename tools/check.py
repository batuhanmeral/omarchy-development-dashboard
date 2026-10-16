"""Offline project checks; never install packages or inspect secret files."""

from __future__ import annotations

import argparse
import dis
import shutil
import sys
import tomllib
import trace
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def executable_lines(code: types.CodeType) -> set[int]:
    lines = {line for _, line in dis.findlinestarts(code) if line is not None and line > 0}
    for const in code.co_consts:
        if isinstance(const, types.CodeType):
            lines.update(executable_lines(const))
    return lines


def coverage() -> bool:
    sys.path.insert(0, str(ROOT / "backend"))

    def run_tests():
        suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"))
        return unittest.TextTestRunner(verbosity=0).run(suite)

    tracer = trace.Trace(count=True, trace=False, ignoredirs=[sys.base_prefix, sys.prefix])
    result = tracer.runfunc(run_tests)
    counts = tracer.results().counts
    passed = result.wasSuccessful()
    for path in sorted((ROOT / "backend").glob("*.py")):
        source = path.read_text()
        lines = executable_lines(compile(source, str(path), "exec"))
        covered = {line for filename, line in counts if filename == str(path)}
        percentage = 100 * len(lines & covered) / max(1, len(lines))
        print(f"{path.relative_to(ROOT)}: {percentage:.1f}% executable-line coverage")
        passed = passed and percentage >= 85
    return passed


def dependencies() -> bool:
    config = tomllib.loads((ROOT / "pyproject.toml").read_text())
    declared = config["project"].get("dependencies", [])
    if declared or config["project"].get("optional-dependencies"):
        print("New Python dependencies require a lockfile and vulnerability audit.")
        return False
    print("Dependency audit: no third-party Python/JS packages; OS packages are host-managed.")
    return True


def prerequisites() -> bool:
    names = ["python3", "ss", "make", "ruff", "pyright", "node", "gitleaks", "omarchy"]
    missing = [name for name in names if not shutil.which(name)]
    for name in missing:
        print(f"Missing required tool: {name}")
    for name in ("qmllint", "qmlformat"):
        if not Path("/usr/lib/qt6/bin", name).exists() and not shutil.which(name):
            missing.append(name)
            print(f"Missing required tool: {name}")
    if not missing:
        print("Prerequisites found. No installation performed.")
    return not missing


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=["coverage", "dependencies", "prerequisites"])
    args = parser.parse_args()
    raise SystemExit(0 if globals()[args.check]() else 1)
