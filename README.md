# opencode-env

Version-controlled OpenCode plugins, agents, skills, and runtime configuration.

## Layout

```text
plugins/<name>/                    registered Git submodules
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
catalogue entries only to the implementer and bounded editor after the worktree
is trusted through `OPENCODE_MODEL_ROUTER_TRUST_VERIFICATION_ALLOWLIST`; see the
plugin README and
`plugins/opencode-model-router/examples/verification-allowlist.json.example`
for the schema and Rust example.
