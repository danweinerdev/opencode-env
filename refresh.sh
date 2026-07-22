#!/usr/bin/env bash
# refresh.sh — maintain ~/.agents as an aggregator of skill plugins.
#
# Layout:
#   ~/.agents/plugins/<name>/   git submodule for a skills plugin (skills/ + shared/)
#   ~/.agents/skills/<skill>    RELATIVE symlink -> ../plugins/<name>/skills/<skill>
#
# Agent runtimes (e.g. opencode) discover skills via ~/.agents/skills/*/SKILL.md.
# Relative symlinks keep the whole tree self-contained, so bind-mounting
# ~/.agents into a container resolves without any extra mounts.
#
# Usage:
#   ./refresh.sh           # discover plugins, (re)build symlinks, prune stale ones
#   ./refresh.sh --pull    # update plugin submodules first (delegates to update.sh)
#
# Collision policy: a skill name provided by two plugins is an error — the
# existing link is kept, the conflict is reported, and the script exits 1.
# Resolve by renaming the skill dir in one plugin or removing a plugin.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="${AGENTS_DIR}/plugins"
SKILLS_DIR="${AGENTS_DIR}/skills"

case "${1:-}" in
    "") ;;
    --pull)
        exec "${AGENTS_DIR}/update.sh"
        ;;
    *)
        echo "usage: $0 [--pull]" >&2
        exit 2
        ;;
esac

mkdir -p "${PLUGINS_DIR}" "${SKILLS_DIR}"

# --- 1. Load and initialize registered plugin submodules. -------------------
GITMODULES="${AGENTS_DIR}/.gitmodules"
if [[ ! -f "${GITMODULES}" ]]; then
    echo "!!! ${GITMODULES} is missing; plugin submodules are not configured" >&2
    exit 1
fi

declare -a PLUGIN_PATHS=()
while IFS= read -r entry; do
    path="${entry#* }"
    case "${path}" in
        plugins/*) PLUGIN_PATHS+=("${path}") ;;
    esac
done < <(git -C "${AGENTS_DIR}" config --file .gitmodules --get-regexp '^submodule\..*\.path$' || true)

if [[ ${#PLUGIN_PATHS[@]} -eq 0 ]]; then
    echo "!!! no plugin submodules are registered under plugins/" >&2
    exit 1
fi

git -C "${AGENTS_DIR}" submodule sync --recursive

initialize_missing_nested() {
    local repo="$1"
    local nested_gitmodules="${repo}/.gitmodules"
    local entry nested status

    [[ -f "${nested_gitmodules}" ]] || return 0
    git -C "${repo}" submodule sync --recursive
    while IFS= read -r entry; do
        nested="${entry#* }"
        status="$(git -C "${repo}" submodule status -- "${nested}" 2>/dev/null || true)"
        if [[ "${status:0:1}" == "-" ]]; then
            echo ">>> init nested: ${repo}/${nested}"
            git -C "${repo}" submodule update --init --recursive -- "${nested}"
        else
            initialize_missing_nested "${repo}/${nested}"
        fi
    done < <(git -C "${repo}" config --file .gitmodules --get-regexp '^submodule\..*\.path$' || true)
}

for path in "${PLUGIN_PATHS[@]}"; do
    plugin="${AGENTS_DIR}/${path}"
    status="$(git -C "${AGENTS_DIR}" submodule status -- "${path}" 2>/dev/null || true)"
    if [[ "${status:0:1}" == "-" ]]; then
        echo ">>> init: ${path}"
        git -C "${AGENTS_DIR}" submodule update --init --recursive -- "${path}"
    fi
    initialize_missing_nested "${plugin}"
done

# --- 2. Build the expected skill-link inventory from registered submodules. --
declare -A OWNER=()            # skill name -> plugin name
declare -A EXPECTED_TARGET=()  # skill name -> relative symlink target
declare -a SKILL_NAMES=()
ERRORS=0
PLUGIN_COUNT=0

for path in "${PLUGIN_PATHS[@]}"; do
    plugin="${AGENTS_DIR}/${path}/"
    plugin_name="$(basename "${path}")"
    [[ -d "${plugin}/skills" ]] || { echo ">>> skip: ${plugin_name} (no skills/)"; continue; }
    PLUGIN_COUNT=$((PLUGIN_COUNT + 1))

    for skill in "${plugin}"skills/*/; do
        [[ -f "${skill}/SKILL.md" ]] || continue
        skill_name="$(basename "${skill}")"
        target="../${path}/skills/${skill_name}"

        if [[ -n "${OWNER[${skill_name}]:-}" ]]; then
            echo "!!! collision: skill '${skill_name}' provided by both" \
                 "'${OWNER[${skill_name}]}' and '${plugin_name}' — keeping the former" >&2
            ERRORS=1
            continue
        fi
        OWNER[${skill_name}]="${plugin_name}"
        EXPECTED_TARGET[${skill_name}]="${target}"
        SKILL_NAMES+=("${skill_name}")
    done
done

# --- 3. Prune links not owned by the current registered submodules. ---------
for link in "${SKILLS_DIR}"/*; do
    [[ -L "${link}" ]] || continue
    skill_name="$(basename "${link}")"
    if [[ -z "${EXPECTED_TARGET[${skill_name}]:-}" ]]; then
        echo ">>> prune: skills/${skill_name} (not provided by a registered plugin)"
        rm "${link}"
    fi
done

# --- 4. Create or repair the expected relative symlinks. --------------------
LINKED=0
for skill_name in "${SKILL_NAMES[@]}"; do
    target="${EXPECTED_TARGET[${skill_name}]}"
    link="${SKILLS_DIR}/${skill_name}"

    if [[ -L "${link}" ]]; then
        if [[ "$(readlink "${link}")" != "${target}" ]]; then
            echo ">>> relink: skills/${skill_name} -> ${target}"
            ln -sfn "${target}" "${link}"
        fi
    elif [[ -e "${link}" ]]; then
        echo "!!! skills/${skill_name} exists and is not a symlink — leaving it alone" >&2
        ERRORS=1
        continue
    else
        echo ">>> link: skills/${skill_name} -> ${target}"
        ln -s "${target}" "${link}"
    fi
    LINKED=$((LINKED + 1))
done

echo ">>> ${LINKED} skill(s) linked from ${PLUGIN_COUNT} plugin submodule(s)"
echo ">>> activating declarative runtime plugins"
if ! "${AGENTS_DIR}/activate.sh"; then
    ERRORS=1
fi
exit ${ERRORS}
