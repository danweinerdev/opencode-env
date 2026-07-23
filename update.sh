#!/usr/bin/env bash
# update.sh — update every plugin submodule under ~/.agents/plugins, then refresh
# the skill symlinks.
#
# For each registered plugin submodule:
#   1. `git fetch --prune origin`
#   2. resolve its configured branch (or origin/HEAD, falling back to main)
#   3. fast-forward the checkout to origin/<branch>
# A submodule with local modifications, a different checked-out branch, or
# diverged history is reported and skipped — this script never discards local
# state.
# Updated submodule commits appear as gitlink changes in ~/.agents and must be
# reviewed and committed there separately.
#
# Ends by chaining ./refresh.sh, which rebuilds the skills/ symlinks and
# prunes any that no longer resolve to a SKILL.md (e.g. a skill removed or
# renamed upstream).
#
# Usage:
#   ./update.sh

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITMODULES="${AGENTS_DIR}/.gitmodules"

ERRORS=0

if [[ ! -f "${GITMODULES}" ]]; then
    echo "!!! ${GITMODULES} is missing; plugin submodules are not configured" >&2
    exit 1
fi

declare -a MODULE_NAMES=()
declare -a MODULE_PATHS=()
while IFS= read -r entry; do
    key="${entry%% *}"
    path="${entry#* }"
    case "${path}" in
        plugins/*)
            module="${key#submodule.}"
            module="${module%.path}"
            MODULE_NAMES+=("${module}")
            MODULE_PATHS+=("${path}")
            ;;
    esac
done < <(git -C "${AGENTS_DIR}" config --file .gitmodules --get-regexp '^submodule\..*\.path$' || true)

if [[ ${#MODULE_PATHS[@]} -eq 0 ]]; then
    echo "!!! no plugin submodules are registered under plugins/" >&2
    exit 1
fi

DISABLED_PLUGINS_FILE="${AGENTS_DIR}/disabled-plugins.txt"
is_safe_basename() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

declare -A DISABLED_PLUGINS=()
if [[ -f "${DISABLED_PLUGINS_FILE}" ]]; then
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "${entry}" || "${entry}" == \#* ]] && continue
        if ! is_safe_basename "${entry}"; then
            echo "!!! invalid disabled plugin basename: ${entry}" >&2
            exit 1
        fi
        if [[ -n "${DISABLED_PLUGINS[${entry}]:-}" ]]; then
            echo "!!! duplicate disabled plugin basename: ${entry}" >&2
            exit 1
        fi
        DISABLED_PLUGINS["${entry}"]=1
    done < "${DISABLED_PLUGINS_FILE}"
fi

declare -A REGISTERED_PLUGINS=()
for path in "${MODULE_PATHS[@]}"; do
    REGISTERED_PLUGINS["$(basename "${path}")"]=1
done
for plugin_name in "${!DISABLED_PLUGINS[@]}"; do
    if [[ -z "${REGISTERED_PLUGINS[${plugin_name}]:-}" ]]; then
        echo "!!! unknown disabled plugin basename: ${plugin_name}" >&2
        exit 1
    fi
done

declare -A REGISTERED_PLUGIN_PATHS=()
for path in "${MODULE_PATHS[@]}"; do
    REGISTERED_PLUGIN_PATHS["$(basename "${path}")"]="${path}"
done

DISABLED_PLUGIN_SKILLS_FILE="${AGENTS_DIR}/disabled-plugin-skills.txt"
if [[ ! -f "${DISABLED_PLUGIN_SKILLS_FILE}" ]]; then
    echo "!!! ${DISABLED_PLUGIN_SKILLS_FILE} is missing" >&2
    exit 1
fi
declare -A DISABLED_OWNER=()
while IFS= read -r entry || [[ -n "${entry}" ]]; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "${entry}" || "${entry}" == \#* ]] && continue
    read -r inventory_plugin inventory_skill extra <<< "${entry}"
    if [[ -z "${inventory_plugin:-}" || -z "${inventory_skill:-}" || -n "${extra:-}" ]] ||
       ! is_safe_basename "${inventory_plugin}" || ! is_safe_basename "${inventory_skill}"; then
        echo "!!! invalid disabled plugin skill inventory entry: ${entry}" >&2
        exit 1
    fi
    if [[ -z "${REGISTERED_PLUGINS[${inventory_plugin}]:-}" ]]; then
        echo "!!! unknown disabled plugin basename in skill inventory: ${inventory_plugin}" >&2
        exit 1
    fi
    if [[ -z "${DISABLED_PLUGINS[${inventory_plugin}]:-}" ]]; then
        echo "!!! skill inventory plugin is not disabled: ${inventory_plugin}" >&2
        exit 1
    fi
    if [[ -n "${DISABLED_OWNER[${inventory_skill}]:-}" ]]; then
        echo "!!! disabled skill inventory collision: '${inventory_skill}' owned by both" \
             "'${DISABLED_OWNER[${inventory_skill}]}' and '${inventory_plugin}'" >&2
        exit 1
    fi
    DISABLED_OWNER["${inventory_skill}"]="${inventory_plugin}"
done < "${DISABLED_PLUGIN_SKILLS_FILE}"

# Validate the trusted inventory and existing gitlinks before any enabled
# submodule initialization, fetch, or merge can mutate a checkout.
for plugin_name in "${!DISABLED_PLUGINS[@]}"; do
    plugin="${AGENTS_DIR}/${REGISTERED_PLUGIN_PATHS[${plugin_name}]}"
    [[ -d "${plugin}/skills" ]] || continue
    for skill in "${plugin}"/skills/*/; do
        [[ -f "${skill}/SKILL.md" ]] || continue
        skill_name="$(basename "${skill}")"
        if [[ "${DISABLED_OWNER[${skill_name}]:-}" != "${plugin_name}" ]]; then
            echo "!!! disabled source skill is missing from trusted inventory: ${plugin_name} ${skill_name}" >&2
            exit 1
        fi
    done
done
for path in "${MODULE_PATHS[@]}"; do
    name="$(basename "${path}")"
    [[ -n "${DISABLED_PLUGINS[${name}]:-}" ]] && continue
    status="$(git -C "${AGENTS_DIR}" submodule status -- "${path}" 2>/dev/null || true)"
    if [[ "${status:0:1}" == "+" || "${status:0:1}" == "U" ]]; then
        echo "!!! ${path}: submodule gitlink differs from the index; resolve it before update" >&2
        exit 1
    fi
done

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

declare -a UPDATED_GITLINKS=()
for index in "${!MODULE_PATHS[@]}"; do
    module="${MODULE_NAMES[${index}]}"
    path="${MODULE_PATHS[${index}]}"
    plugin="${AGENTS_DIR}/${path}"
    name="$(basename "${path}")"
    [[ -n "${DISABLED_PLUGINS[${name}]:-}" ]] && continue

    status="$(git -C "${AGENTS_DIR}" submodule status -- "${path}" 2>/dev/null || true)"
    if [[ "${status:0:1}" == "-" ]]; then
        echo ">>> init: ${name}"
        if ! git -C "${AGENTS_DIR}" submodule update --init --recursive -- "${path}"; then
            echo "!!! ${name}: initialization failed — skipping" >&2
            ERRORS=1
            continue
        fi
    fi
    initialize_missing_nested "${plugin}"

    echo ">>> fetch: ${name}"
    if ! git -C "${plugin}" fetch --prune origin; then
        echo "!!! ${name}: fetch failed — skipping" >&2
        ERRORS=1
        continue
    fi

    # Prefer an explicit submodule branch; otherwise use origin/HEAD, then main.
    branch="$(git -C "${AGENTS_DIR}" config --file .gitmodules --get "submodule.${module}.branch" 2>/dev/null || true)"
    if [[ "${branch}" == "." ]]; then
        branch="$(git -C "${AGENTS_DIR}" branch --show-current)"
        if [[ -z "${branch}" ]]; then
            echo "!!! ${name}: branch='.' but the parent repository is detached — skipping" >&2
            ERRORS=1
            continue
        fi
    fi
    if [[ -z "${branch}" ]]; then
        branch="$(git -C "${plugin}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        branch="${branch#origin/}"
    fi
    [[ -n "${branch}" ]] || branch="main"
    if ! git -C "${plugin}" rev-parse --verify --quiet "origin/${branch}" >/dev/null; then
        echo "!!! ${name}: origin/${branch} does not exist — skipping" >&2
        ERRORS=1
        continue
    fi

    if [[ -n "$(git -C "${plugin}" status --porcelain --ignore-submodules=none)" ]]; then
        echo "!!! ${name}: local modifications present — skipping update" >&2
        ERRORS=1
        continue
    fi

    current="$(git -C "${plugin}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ -n "${current}" && "${current}" != "${branch}" ]]; then
        echo "!!! ${name}: checked out on ${current}, expected ${branch} — skipping" >&2
        ERRORS=1
        continue
    fi

    before="$(git -C "${plugin}" rev-parse HEAD)"
    if git -C "${plugin}" merge-base --is-ancestor "origin/${branch}" HEAD; then
        echo ">>> ${name}: local checkout contains origin/${branch} (${before})"
    elif ! git -C "${plugin}" merge-base --is-ancestor HEAD "origin/${branch}"; then
        echo "!!! ${name}: has diverged from origin/${branch} — resolve manually" >&2
        ERRORS=1
    elif git -C "${plugin}" merge --ff-only --quiet "origin/${branch}"; then
        after="$(git -C "${plugin}" rev-parse HEAD)"
        if [[ "${before}" == "${after}" ]]; then
            echo ">>> ${name}: up to date (${after})"
        else
            echo ">>> ${name}: ${before} -> ${after}"
            UPDATED_GITLINKS+=("${path}=${after}")
        fi
        initialize_missing_nested "${plugin}"
    else
        echo "!!! ${name}: has diverged from origin/${branch} — resolve manually" >&2
        ERRORS=1
    fi
done

GITLINKS_DIFFER=0
for path in "${MODULE_PATHS[@]}"; do
    plugin="${AGENTS_DIR}/${path}"
    recorded="$(git -C "${AGENTS_DIR}" ls-files --stage -- "${path}" | { read -r _ oid _ _; printf '%s' "${oid:-}"; })"
    checked_out="$(git -C "${plugin}" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "${recorded}" && -n "${checked_out}" && "${recorded}" != "${checked_out}" ]]; then
        GITLINKS_DIFFER=1
        break
    fi
done
if [[ ${GITLINKS_DIFFER} -eq 1 ]]; then
    echo ">>> plugin gitlinks differ from the index; review and commit them in ${AGENTS_DIR}"
fi

echo ">>> refreshing skill symlinks"
if [[ ${#UPDATED_GITLINKS[@]} -gt 0 ]]; then
    REFRESH_ALLOWED_UPDATED_GITLINKS="$(printf '%s\n' "${UPDATED_GITLINKS[@]}")" \
        "${AGENTS_DIR}/refresh.sh" || ERRORS=1
else
    "${AGENTS_DIR}/refresh.sh" || ERRORS=1
fi

exit ${ERRORS}
