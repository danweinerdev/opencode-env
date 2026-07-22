# opencode-env

Version-controlled OpenCode plugins, agents, skills, and runtime configuration.

## Layout

```text
plugins/<name>/                    registered Git submodules
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

The global OpenCode configuration loads the stable generated entry point:

```json
{
  "plugin": [
    "file:///home/daniel/.agents/runtime/opencode/plugin.js"
  ]
}
```
