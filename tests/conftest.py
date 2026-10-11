"""Test harness for the Skytower plugin.

The plugin is not a regular Python package (it lives in ``skytower/`` inside a repo with a
hyphenated name), so two things are set up here:

1. ``skytower_plugin`` — ``skytower/`` imported as a package for the tests' own use
   (``from skytower_plugin.adapter import SkyTowerAdapter``).
2. A session-scoped ``HERMES_HOME`` containing a copy of the plugin under ``plugins/skytower-platform``
   with ``plugins.enabled`` set, so upstream's real discovery (``hermes_cli.plugins.discover_plugins``)
   loads it exactly as it would on an operator's machine. That registration is what makes
   ``Platform("skytower")`` resolve and what ``_apply_env_overrides`` consults.

Upstream Hermes sources are located via ``HERMES_AGENT_SRC`` or a few conventional paths.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import sys
import types
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = REPO_ROOT / "skytower"
PLUGIN_NAME = "skytower-platform"
TEST_PACKAGE = "skytower_plugin"
_PLUGIN_FILES = ("__init__.py", "adapter.py", "confinement.py", "skytower_files.py", "soul_sync.py", "plugin.yaml")


def _find_hermes_src() -> Path:
    candidates = [
        os.environ.get("HERMES_AGENT_SRC"),
        REPO_ROOT.parent / "hermes-agent",
        Path.home() / ".hermes" / "hermes-agent",
        Path(os.environ.get("LOCALAPPDATA", "")) / "hermes" / "hermes-agent",
    ]
    for c in candidates:
        if c and (Path(c) / "gateway" / "platforms" / "base.py").is_file():
            return Path(c).resolve()
    raise RuntimeError(
        "hermes-agent source not found. Set HERMES_AGENT_SRC=<path to a hermes-agent checkout> "
        "(CI checks out NousResearch/hermes-agent next to this repo)."
    )


def _import_plugin_as(name: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(
        name, PLUGIN_DIR / "__init__.py", submodule_search_locations=[str(PLUGIN_DIR)])
    module = importlib.util.module_from_spec(spec)
    module.__package__ = name
    module.__path__ = [str(PLUGIN_DIR)]
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


HERMES_SRC = _find_hermes_src()
if str(HERMES_SRC) not in sys.path:
    sys.path.insert(0, str(HERMES_SRC))

# Session HERMES_HOME must exist BEFORE anything imports hermes modules that read it at import time.
_SESSION_HOME = Path(os.environ.get("PYTEST_HERMES_HOME") or (REPO_ROOT / ".pytest-hermes-home")).resolve()
shutil.rmtree(_SESSION_HOME, ignore_errors=True)
_installed = _SESSION_HOME / "plugins" / PLUGIN_NAME
_installed.mkdir(parents=True)
for f in _PLUGIN_FILES:
    shutil.copy2(PLUGIN_DIR / f, _installed / f)
(_SESSION_HOME / "config.yaml").write_text(f"plugins:\n  enabled:\n    - {PLUGIN_NAME}\n", encoding="utf-8")
(_SESSION_HOME / ".env").write_text("", encoding="utf-8")
os.environ["HERMES_HOME"] = str(_SESSION_HOME)
for _k in ("SKYTOWER_TOKEN", "SKYTOWER_URL", "SKYTOWER_ALLOWED_USERS", "SKYTOWER_ALLOW_ALL_USERS"):
    os.environ.pop(_k, None)

_import_plugin_as(TEST_PACKAGE)


def pytest_sessionstart(session):
    """Register the plugin through upstream's real discovery once per session."""
    from hermes_cli.plugins import discover_plugins
    discover_plugins()
    from gateway.platform_registry import platform_registry
    assert platform_registry.get("skytower") is not None, "skytower plugin did not register via discovery"


@pytest.fixture(autouse=True)
def _clean_skytower_env(monkeypatch):
    for k in ("SKYTOWER_TOKEN", "SKYTOWER_URL", "SKYTOWER_ALLOWED_USERS", "SKYTOWER_ALLOW_ALL_USERS"):
        monkeypatch.delenv(k, raising=False)
    yield
