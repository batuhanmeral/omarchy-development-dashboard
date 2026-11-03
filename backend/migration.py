"""Read-only, bounded import of the legacy widget's known settings."""

from __future__ import annotations

import json
import math
import os
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
        found=False, installed=(home / ".config/omarchy/plugins" / LEGACY_ID).is_dir(), settings={}
    )
    try:
        with (config_home / "omarchy/shell.json").open("rb") as stream:
            raw = stream.read(MAX_CONFIG_BYTES + 1)
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
                    and (key != "refreshInterval" or math.isfinite(entry[key]))
                }
                return dict(legacy=legacy)
    except (OSError, ValueError, TypeError, AttributeError, RecursionError):
        pass
    return dict(legacy=legacy)
