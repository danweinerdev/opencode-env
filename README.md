# opencode-env

Version-controlled OpenCode plugins, agents, skills, and runtime configuration.

## Layout

```text
plugins/<name>/                    registered Git submodules
models.json                        global model-role defaults
skills/<name>                      generated skill symlinks
runtime/opencode/plugin.js         generated OpenCode plugin loader
runtime/opencode/inventory.json    generated activation inventory
```

Plugins expose skills through `skills/*/SKILL.md`. A plugin can additionally
declare an OpenCode runtime module in `.agents-plugin/plugin.json`:

```json
{
  "schema_version": 1,
  "name": "example",
  "skills": "skills",
  "opencode": {
    "plugin": "opencode/plugin.js"
  }
}
```

`refresh.sh` reconciles skill links and regenerates the runtime loader from
registered submodules. It never executes plugin-owned installer scripts.
`update.sh` fast-forwards clean plugin submodules and then refreshes generated
state. Use `activate.sh --check` to validate manifests and detect stale runtime
state without changing files.

The global OpenCode configuration loads the stable generated entry point under:

```text
file://$HOME/.agents/runtime/opencode/plugin.js
```

`$HOME` above is documentation shorthand. The JSON configuration contains the
corresponding absolute file URI because JSON strings do not expand shell
variables; `activate.sh --check` verifies that resolved URI without recording it
in this repository.

`opencode-frugal` resolves the first valid complete model profile from the
active worktree's `.agents/models.json`, this repository's `models.json`, and
finally its bundled defaults. Files are selected as a whole and are never
merged.
