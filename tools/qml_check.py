"""Check actual Omarchy imports without modifying or starting the user's shell."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
    qt = Path(os.environ.get("QML_BIN", "/usr/lib/qt6/bin"))
    if not (shell / "Ui/qmldir").is_file():
        print("Omarchy shell imports missing; set OMARCHY_PATH to the installed Omarchy root.")
        return 1
    qml_files = sorted(ROOT.glob("*.qml"))
    all_qml = sorted([*ROOT.glob("*.qml"), *(ROOT / "tests").rglob("*.qml")])
    for path in all_qml:
        formatted = subprocess.run(
            [str(qt / "qmlformat"), str(path)],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        ).stdout
        if formatted != path.read_text():
            print(f"QML formatting differs: {path.relative_to(ROOT)}; run make fix")
            return 1
    with tempfile.TemporaryDirectory(prefix="devports-qml-") as directory:
        imports = Path(directory)
        # `qs` is a synthetic root alias in the host. qmllint needs a filesystem mapping.
        (imports / "qs").symlink_to(shell, target_is_directory=True)
        subprocess.run(
            [str(qt / "qmllint"), "-I", str(imports), "-I", str(shell), *map(str, qml_files)],
            check=True,
            timeout=30,
        )
    subprocess.run(["omarchy", "plugin", "validate", str(ROOT)], check=True, timeout=15)
    env = dict(
        os.environ,
        QT_QPA_PLATFORM="offscreen",
        QT_QPA_PLATFORMTHEME="",
        QT_QUICK_CONTROLS_STYLE="Basic",
        GSETTINGS_BACKEND="memory",
    )
    # Theme-only fixtures isolate Settings from Quickshell's statically linked plugins.
    test = subprocess.run(
        [
            str(qt / "qmltestrunner"),
            "-input",
            str(ROOT / "tests/qml"),
            "-import",
            str(ROOT / "tests/qml/imports"),
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    print(test.stdout, end="")
    print(test.stderr, end="")
    return 1 if test.returncode or "QWARN" in test.stdout else 0


if __name__ == "__main__":
    raise SystemExit(main())
