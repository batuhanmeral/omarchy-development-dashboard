"""Read-only, bounded import of the legacy widget's known settings."""

from __future__ import annotations

import json
import math
import os
import stat
from pathlib import Path
from typing import Any

LEGACY_ID = "io.github.batuhanmeral.devports"
MAX_CONFIG_BYTES = 1024 * 1024
SETTING_TYPES = {
    "refreshInterval": (int, float),
    "dockerEnabled": (bool,),
    "exposure": (str,),
    "hiddenPorts": (str,),
    "visibleTabs": (str,),
    "sortBy": (str,),
    "compact": (bool,),
    "sqliteFiles": (str,),
}


def legacy_settings(config_home: Path | None = None, home: Path | None = None) -> dict[str, Any]:
    home = home or Path.home()
    config_home = config_home or Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
    legacy: dict[str, Any] = dict(
        found=False, installed=(config_home / "omarchy/plugins" / LEGACY_ID).is_dir(), settings={}
    )
    try:
        # Symlinked configurations are supported, but their targets must be regular files.
        fd = os.open(config_home / "omarchy/shell.json", os.O_RDONLY | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_CONFIG_BYTES:
                return dict(legacy=legacy)
            raw = os.read(fd, MAX_CONFIG_BYTES + 1)
        finally:
            os.close(fd)
        if len(raw) > MAX_CONFIG_BYTES:
            return dict(legacy=legacy)
        config = json.loads(raw)
        layout = config.get("bar", {}).get("layout", {})
        if not isinstance(layout, dict):
            return dict(legacy=legacy)
        for section in layout.values():
            if not isinstance(section, list):
                continue
            for entry in section:
                if not isinstance(entry, dict) or entry.get("id") != LEGACY_ID:
                    continue
                legacy["found"] = True
                legacy["settings"] = {
                    key: entry[key]
                    for key, types in SETTING_TYPES.items()
                    if type(entry.get(key)) in types
                    and (
                        key != "refreshInterval"
                        or type(entry[key]) is int
                        or math.isfinite(entry[key])
                    )
                }
                return dict(legacy=legacy)
    except (OSError, ValueError, TypeError, AttributeError, RecursionError):
        pass
    return dict(legacy=legacy)
