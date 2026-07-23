# opencode-env

Version-controlled OpenCode plugins, agents, skills, and runtime configuration.

## Layout

```text
plugins/<name>/                    registered Git submodules
disabled-plugins.txt               disabled plugin basenames
disabled-plugin-skills.txt         trusted disabled-plugin skill ownership inventory
.disabled-skills/<plugin>/<skill>  preserved copied skills from disabled plugins
models.json                        local global model-role defaults (ignored)
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
registered submodules. It never executes plugin-owned installer scripts. A
normal `activate.sh` first invokes refresh in its internal skip-activation mode;
refresh invokes activate with an already-reconciled environment marker, so the
two commands cannot recurse.
List registered plugin basenames in `disabled-plugins.txt` to disable them;
blank lines and lines beginning with `#` are ignored. Record every disabled
skill in `disabled-plugin-skills.txt` as `<plugin-basename> <skill-name>` on
each noncomment line. Refresh validates that each inventory owner is registered
and disabled, and rejects unsafe names, duplicates, and ownership collisions
before initializing enabled plugins. The inventory remains authoritative when a
disabled source is missing, uninitialized, or stale, so its listed symlinks are
always pruned. Unknown names fail before refresh, update, or activation succeeds. A disabled plugin source remains
registered but is not initialized, updated, linked into `skills/`, or included
in the OpenCode runtime module or inventory. If a disabled plugin's exact skill
was previously copied into `skills/` instead of linked, refresh moves it to
`.disabled-skills/<plugin>/<skill>` before activation rather than deleting it.
It refuses to move a non-symlink unless the available disabled source matches
exactly; an unavailable source also fails closed. Ambiguous ownership or an
unsafe quarantine destination fails refresh without activation. Plain
`refresh.sh` also rejects enabled submodules whose gitlink has advanced or is
conflicted. After intentionally advancing a clean checkout, `update.sh` passes
only exact `plugin-path=full-oid` pairs for those checkouts; refresh verifies
the syntax, registration, enabled state, checkout HEAD, and gitlink status
before accepting a pair.
`update.sh` fast-forwards clean plugin submodules and then refreshes generated
state. It permits refresh to accept only the exact gitlinks it advanced itself.
Use `activate.sh --check` to validate manifests, detect a listed disabled skill
still present under `skills/`, and detect stale runtime state without changing
files.

The global OpenCode configuration loads the stable generated entry point under:

```text
file://$HOME/.agents/runtime/opencode/plugin.js
```

`$HOME` above is documentation shorthand. The JSON configuration contains the
corresponding absolute file URI because JSON strings do not expand shell
variables; `activate.sh --check` verifies that resolved URI without recording it
in this repository.

`opencode-model-router` resolves the first valid complete model profile from the
active worktree's `.agents/models.json`, this repository's `models.json`, and
finally its bundled defaults. Files are selected as a whole and are never
merged.

`models.json` is intentionally ignored so each machine can choose providers
and local-model availability independently. Create the GPT+Qwen global profile
with:

```sh
cp "$HOME/.agents/plugins/opencode-model-router/examples/gpt-based.json.example" \
  "$HOME/.agents/models.json"
```

For an Anthropic-only profile, copy `claude-based.json.example` instead.
Restart OpenCode after changing the file because model routing is resolved at
startup.

Trusted projects may also commit exact routine verification commands in
`.agents/verification-allowlist.json`. The model-router applies supported
catalogue entries only to the implementer and bounded editor whenever that valid
file is present; see the plugin README and
`plugins/opencode-model-router/examples/verification-allowlist.json.example`
for the schema and Rust example.
