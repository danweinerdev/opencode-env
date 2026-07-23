#!/usr/bin/env python3
"""Validate plugin manifests and atomically generate the OpenCode loader."""

from __future__ import annotations

import argparse
import configparser
import json
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


class ManifestError(ValueError):
    pass


@dataclass(frozen=True)
class RuntimePlugin:
    name: str
    module: Path


def registered_plugins(root: Path) -> list[Path]:
    source = root / ".gitmodules"
    if not source.is_file():
        raise ManifestError(f"{source} is missing")

    parser = configparser.ConfigParser()
    parser.read(source)
    result: list[Path] = []
    for section in parser.sections():
        path = parser.get(section, "path", fallback="")
        if path.startswith("plugins/"):
            result.append(root / path)
    if not result:
        raise ManifestError("no registered plugin submodules under plugins/")
    return sorted(result)


def disabled_plugin_names(root: Path) -> set[str]:
    source = root / "disabled-plugins.txt"
    if not source.is_file():
        return set()
    return {
        line
        for raw_line in source.read_text().splitlines()
        if (line := raw_line.strip()) and not line.startswith("#")
    }


def validate_disabled_plugins(disabled: set[str], plugins: list[Path]) -> None:
    registered = {plugin.name for plugin in plugins}
    unknown = sorted(disabled - registered)
    if unknown:
        raise ManifestError(
            f"unknown disabled plugin basename(s): {', '.join(unknown)}"
        )


def is_safe_skill_token(value: str) -> bool:
    return bool(value) and value[0].isalnum() and all(
        character.isalnum() or character in "._-" for character in value
    )


def disabled_skill_owners(root: Path, disabled: set[str], plugins: list[Path]) -> dict[str, str]:
    source = root / "disabled-plugin-skills.txt"
    if not source.is_file():
        raise ManifestError(f"{source} is missing")
    registered = {plugin.name for plugin in plugins}
    owners: dict[str, str] = {}
    for raw_line in source.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 2 or not all(is_safe_skill_token(field) for field in fields):
            raise ManifestError(f"invalid disabled plugin skill inventory entry: {line}")
        plugin, skill = fields
        if plugin not in registered:
            raise ManifestError(f"unknown disabled plugin basename in skill inventory: {plugin}")
        if plugin not in disabled:
            raise ManifestError(f"skill inventory plugin is not disabled: {plugin}")
        if skill in owners:
            raise ManifestError(f"disabled skill inventory collision: {skill}")
        owners[skill] = plugin
    return owners


def contained_file(plugin: Path, relative: object, field: str) -> Path:
    if not isinstance(relative, str) or not relative:
        raise ManifestError(f"{plugin.name}: {field} must be a non-empty relative path")
    value = Path(relative)
    if value.is_absolute():
        raise ManifestError(f"{plugin.name}: {field} must be relative")

    root = plugin.resolve()
    candidate = (root / value).resolve()
    if not candidate.is_relative_to(root):
        raise ManifestError(f"{plugin.name}: {field} escapes the plugin root")
    if not candidate.is_file():
        raise ManifestError(f"{plugin.name}: {field} does not exist: {candidate}")
    if candidate.suffix not in {".js", ".mjs", ".ts"}:
        raise ManifestError(f"{plugin.name}: {field} must be a JavaScript or TypeScript module")
    return candidate


def load_runtime_plugins(root: Path) -> list[RuntimePlugin]:
    result: list[RuntimePlugin] = []
    owners: set[str] = set()
    registered = registered_plugins(root)
    disabled = disabled_plugin_names(root)
    validate_disabled_plugins(disabled, registered)
    for plugin in registered:
        if plugin.name in disabled:
            continue
        manifest_path = plugin / ".agents-plugin" / "plugin.json"
        if not manifest_path.is_file():
            continue
        try:
            manifest = json.loads(manifest_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ManifestError(f"{plugin.name}: invalid manifest: {error}") from error

        if manifest.get("schema_version") != 1:
            raise ManifestError(f"{plugin.name}: unsupported schema_version")
        name = manifest.get("name")
        if not isinstance(name, str) or not name:
            raise ManifestError(f"{plugin.name}: manifest name must be a non-empty string")
        if name in owners:
            raise ManifestError(f"duplicate runtime plugin name: {name}")
        owners.add(name)

        opencode = manifest.get("opencode")
        if opencode is None:
            continue
        if not isinstance(opencode, dict):
            raise ManifestError(f"{plugin.name}: opencode must be an object")
        module = contained_file(plugin, opencode.get("plugin"), "opencode.plugin")
        result.append(RuntimePlugin(name=name, module=module))
    return result


def render_loader(plugins: list[RuntimePlugin]) -> str:
    specs = [{"name": item.name, "url": item.module.as_uri()} for item in plugins]
    encoded = json.dumps(specs, indent=2)
    return f'''// Generated by ~/.agents/activate.sh. Do not edit.
const specs = {encoded}

export default async function aggregatedPlugin(input, options) {{
  const loaded = []
  for (const spec of specs) {{
    const module = await import(spec.url)
    if (typeof module.default !== "function") {{
      throw new TypeError(`Runtime plugin ${{spec.name}} has no default plugin function`)
    }}
    loaded.push({{ name: spec.name, hooks: await module.default(input, options) }})
  }}

  const merged = {{}}
  for (const entry of loaded) {{
    for (const [name, hook] of Object.entries(entry.hooks ?? {{}})) {{
      if (name === "tool") {{
        merged.tool ??= {{}}
        for (const [toolName, definition] of Object.entries(hook)) {{
          if (toolName in merged.tool) throw new Error(`Duplicate plugin tool: ${{toolName}}`)
          merged.tool[toolName] = definition
        }}
        continue
      }}
      if (name === "auth" || name === "provider") {{
        if (name in merged) throw new Error(`Multiple plugins define singleton hook: ${{name}}`)
        merged[name] = hook
        continue
      }}
      if (typeof hook !== "function") throw new TypeError(`Unsupported hook ${{name}} from ${{entry.name}}`)
      const previous = merged[name]
      merged[name] = previous
        ? async (...args) => {{ await previous(...args); await hook(...args) }}
        : hook
    }}
  }}
  return merged
}}
'''


def expected_files(root: Path, plugins: list[RuntimePlugin]) -> dict[str, str]:
    inventory = {
        "schema_version": 1,
        "plugins": [
            {"name": item.name, "module": str(item.module)} for item in plugins
        ],
    }
    return {
        "opencode/plugin.js": render_loader(plugins),
        "opencode/inventory.json": json.dumps(inventory, indent=2) + "\n",
    }


def check(root: Path, files: dict[str, str]) -> list[str]:
    errors: list[str] = []
    runtime = root / "runtime"
    for relative, expected in files.items():
        target = runtime / relative
        try:
            actual = target.read_text()
        except FileNotFoundError:
            errors.append(f"missing generated file: {target}")
            continue
        if actual != expected:
            errors.append(f"stale generated file: {target}")

    config = Path.home() / ".config" / "opencode" / "opencode.jsonc"
    loader_uri = (runtime / "opencode" / "plugin.js").as_uri()
    try:
        configured = config.read_text()
    except FileNotFoundError:
        errors.append(f"OpenCode config is missing: {config}")
    else:
        if loader_uri not in configured:
            errors.append(f"OpenCode config does not load {loader_uri}")
    return errors


def disabled_skills_remaining(root: Path, owners: dict[str, str]) -> list[str]:
    return [
        f"disabled skill remains under skills/: {skill} (owned by {owner})"
        for skill, owner in sorted(owners.items())
        if (root / "skills" / skill).exists() or (root / "skills" / skill).is_symlink()
    ]


def activate(root: Path, files: dict[str, str]) -> None:
    # Recheck immediately before replacing runtime/.  refresh.sh normally
    # removes these links first, but its reconciliation marker must not let a
    # stale disabled skill be represented by a freshly generated runtime.
    disabled = disabled_plugin_names(root)
    owners = disabled_skill_owners(root, disabled, registered_plugins(root))
    errors = disabled_skills_remaining(root, owners)
    if errors:
        raise ManifestError("; ".join(errors))

    runtime = root / "runtime"
    staging = Path(tempfile.mkdtemp(prefix=".runtime.", dir=root))
    backup = root / ".runtime.previous"
    try:
        for relative, content in files.items():
            target = staging / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        if backup.exists():
            shutil.rmtree(backup)
        if runtime.exists():
            os.replace(runtime, backup)
        os.replace(staging, runtime)
        if backup.exists():
            shutil.rmtree(backup)
    except BaseException:
        if not runtime.exists() and backup.exists():
            os.replace(backup, runtime)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        plugins = load_runtime_plugins(root)
        files = expected_files(root, plugins)
        if args.check:
            disabled = disabled_plugin_names(root)
            errors = check(root, files) + disabled_skills_remaining(
                root, disabled_skill_owners(root, disabled, registered_plugins(root))
            )
            if errors:
                for error in errors:
                    print(f"!!! {error}", file=sys.stderr)
                return 1
            print(f">>> runtime activation is current ({len(plugins)} plugin(s))")
            return 0
        activate(root, files)
        print(f">>> activated {len(plugins)} OpenCode runtime plugin(s)")
        return 0
    except (ManifestError, OSError) as error:
        print(f"!!! activation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
