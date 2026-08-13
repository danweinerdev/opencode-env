#!/usr/bin/env bash
# refresh.sh — maintain ~/.agents as an aggregator of skill plugins.
#
# Layout:
#   ~/.agents/plugins/<name>/   git submodule containing skills/ or .opencode-plugin/
#   ~/.agents/skills/<skill>    RELATIVE symlink -> the plugin's OpenCode skill
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

SKIP_ACTIVATION=0
case "${1:-}" in
    "") ;;
    --skip-activation)
        if [[ "${AGENTS_ACTIVATE_RECONCILING:-}" != "1" ]]; then
            echo "!!! --skip-activation is reserved for activate.sh" >&2
            exit 2
        fi
        SKIP_ACTIVATION=1
        ;;
    --pull)
        exec "${AGENTS_DIR}/update.sh"
        ;;
    *)
        echo "usage: $0 [--pull|--skip-activation]" >&2
        exit 2
        ;;
esac

mkdir -p "${PLUGINS_DIR}" "${SKILLS_DIR}"

# --- 1. Read registered plugins and validate disabled ownership. ------------
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

is_safe_basename() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

plugin_source_root() {
    local checkout="$1"
    if [[ -f "${checkout}/.opencode-plugin/plugin.json" ]]; then
        printf '%s' "${checkout}/.opencode-plugin"
    else
        printf '%s' "${checkout}"
    fi
}

DISABLED_PLUGINS_FILE="${AGENTS_DIR}/disabled-plugins.txt"
declare -a DISABLED_PLUGINS=()
contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

registered_path_for() {
    local wanted="$1" path
    REGISTERED_PATH=""
    for path in "${PLUGIN_PATHS[@]}"; do
        if [[ "$(basename "${path}")" == "${wanted}" ]]; then
            REGISTERED_PATH="${path}"
            return 0
        fi
    done
    return 1
}

if [[ -f "${DISABLED_PLUGINS_FILE}" ]]; then
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "${entry}" || "${entry}" == \#* ]] && continue
        if ! is_safe_basename "${entry}"; then
            echo "!!! invalid disabled plugin basename: ${entry}" >&2
            exit 1
        fi
        if contains "${entry}" "${DISABLED_PLUGINS[@]+"${DISABLED_PLUGINS[@]}"}"; then
            echo "!!! duplicate disabled plugin basename: ${entry}" >&2
            exit 1
        fi
        DISABLED_PLUGINS+=("${entry}")
    done < "${DISABLED_PLUGINS_FILE}"
fi

for ((index = 0; index < ${#DISABLED_PLUGINS[@]}; index++)); do
    plugin_name="${DISABLED_PLUGINS[${index}]}"
    if ! registered_path_for "${plugin_name}"; then
        echo "!!! unknown disabled plugin basename: ${plugin_name}" >&2
        exit 1
    fi
done

# This checked-in inventory is authoritative even when a disabled submodule is
# absent or stale. It lets us remove its generated links without trusting a
# checkout that is deliberately not initialized.
DISABLED_PLUGIN_SKILLS_FILE="${AGENTS_DIR}/disabled-plugin-skills.txt"
if [[ ! -f "${DISABLED_PLUGIN_SKILLS_FILE}" ]]; then
    echo "!!! ${DISABLED_PLUGIN_SKILLS_FILE} is missing" >&2
    exit 1
fi
declare -a DISABLED_SKILL_NAMES=()
declare -a DISABLED_SKILL_OWNERS=()
disabled_owner_for() {
    local wanted="$1" index
    DISABLED_OWNER_VALUE=""
    for ((index = 0; index < ${#DISABLED_SKILL_NAMES[@]}; index++)); do
        if [[ "${DISABLED_SKILL_NAMES[${index}]}" == "${wanted}" ]]; then
            DISABLED_OWNER_VALUE="${DISABLED_SKILL_OWNERS[${index}]}"
            return 0
        fi
    done
    return 1
}

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
    if ! registered_path_for "${inventory_plugin}"; then
        echo "!!! unknown disabled plugin basename in skill inventory: ${inventory_plugin}" >&2
        exit 1
    fi
    if ! contains "${inventory_plugin}" "${DISABLED_PLUGINS[@]+"${DISABLED_PLUGINS[@]}"}"; then
        echo "!!! skill inventory plugin is not disabled: ${inventory_plugin}" >&2
        exit 1
    fi
    disabled_owner_for "${inventory_skill}" || true
    if [[ -n "${DISABLED_OWNER_VALUE}" ]]; then
        echo "!!! disabled skill inventory collision: '${inventory_skill}' owned by both" \
             "'${DISABLED_OWNER_VALUE}' and '${inventory_plugin}'" >&2
        exit 1
    fi
    DISABLED_SKILL_NAMES+=("${inventory_skill}")
    DISABLED_SKILL_OWNERS+=("${inventory_plugin}")
done < "${DISABLED_PLUGIN_SKILLS_FILE}"

# If a disabled checkout is available, its current skills must all be named in
# the checked-in inventory.  Do this before touching enabled submodules.
for ((index = 0; index < ${#DISABLED_PLUGINS[@]}; index++)); do
    plugin_name="${DISABLED_PLUGINS[${index}]}"
    registered_path_for "${plugin_name}"
    plugin="$(plugin_source_root "${AGENTS_DIR}/${REGISTERED_PATH}")"
    [[ -d "${plugin}/skills" ]] || continue
    for skill in "${plugin}"/skills/*/; do
        [[ -f "${skill}/SKILL.md" ]] || continue
        skill_name="$(basename "${skill}")"
        disabled_owner_for "${skill_name}" || true
        if [[ "${DISABLED_OWNER_VALUE}" != "${plugin_name}" ]]; then
            echo "!!! disabled source skill is missing from trusted inventory: ${plugin_name} ${skill_name}" >&2
            exit 1
        fi
    done
done

# update.sh may allow only exact path=checkout-oid pairs that it advanced
# itself. A conflict is never allowed, and a plain refresh has no allowances.
declare -a ALLOWED_GITLINK_PATHS=()
declare -a ALLOWED_GITLINK_OIDS=()
allowed_oid_for() {
    local wanted="$1" index
    ALLOWED_OID_VALUE=""
    for ((index = 0; index < ${#ALLOWED_GITLINK_PATHS[@]}; index++)); do
        if [[ "${ALLOWED_GITLINK_PATHS[${index}]}" == "${wanted}" ]]; then
            ALLOWED_OID_VALUE="${ALLOWED_GITLINK_OIDS[${index}]}"
            return 0
        fi
    done
    return 1
}

if [[ -n "${REFRESH_ALLOWED_UPDATED_GITLINKS:-}" ]]; then
    while IFS= read -r entry; do
        if ! [[ "${entry}" =~ ^plugins/([A-Za-z0-9][A-Za-z0-9._-]*/)*[A-Za-z0-9][A-Za-z0-9._-]*=[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
            echo "!!! invalid REFRESH_ALLOWED_UPDATED_GITLINKS entry: ${entry}" >&2
            exit 1
        fi
        path="${entry%%=*}"
        oid="${entry#*=}"
        if ! contains "${path}" "${PLUGIN_PATHS[@]}"; then
            echo "!!! unregistered REFRESH_ALLOWED_UPDATED_GITLINKS path: ${path}" >&2
            exit 1
        fi
        plugin_name="$(basename "${path}")"
        if contains "${plugin_name}" "${DISABLED_PLUGINS[@]+"${DISABLED_PLUGINS[@]}"}"; then
            echo "!!! disabled REFRESH_ALLOWED_UPDATED_GITLINKS path: ${path}" >&2
            exit 1
        fi
        if contains "${path}" "${ALLOWED_GITLINK_PATHS[@]+"${ALLOWED_GITLINK_PATHS[@]}"}"; then
            echo "!!! duplicate REFRESH_ALLOWED_UPDATED_GITLINKS path: ${path}" >&2
            exit 1
        fi
        checked_out="$(git -C "${AGENTS_DIR}/${path}" rev-parse --verify HEAD 2>/dev/null || true)"
        if [[ "${checked_out}" != "${oid}" ]]; then
            echo "!!! ${path}: REFRESH_ALLOWED_UPDATED_GITLINKS OID does not match checkout HEAD" >&2
            exit 1
        fi
        ALLOWED_GITLINK_PATHS+=("${path}")
        ALLOWED_GITLINK_OIDS+=("${oid}")
    done <<< "${REFRESH_ALLOWED_UPDATED_GITLINKS}"
fi
for path in "${PLUGIN_PATHS[@]}"; do
    plugin_name="$(basename "${path}")"
    contains "${plugin_name}" "${DISABLED_PLUGINS[@]+"${DISABLED_PLUGINS[@]}"}" && continue
    index_entries=()
    while IFS= read -r index_entry; do
        index_entries+=("${index_entry}")
    done < <(git -C "${AGENTS_DIR}" ls-files --stage -- "${path}")
    for ((index = 0; index < ${#index_entries[@]}; index++)); do
        index_entry="${index_entries[${index}]}"
        read -r index_mode recorded_oid index_stage indexed_path <<< "${index_entry}"
        if [[ "${index_stage}" != "0" ]]; then
            echo "!!! ${path}: submodule gitlink has unmerged index entries; resolve it first" >&2
            exit 1
        fi
    done
    if [[ ${#index_entries[@]} -ne 1 ]]; then
        echo "!!! ${path}: submodule gitlink differs from the index; run update.sh or resolve it first" >&2
        exit 1
    fi
    read -r index_mode recorded_oid index_stage indexed_path <<< "${index_entries[0]}"
    if [[ "${index_mode}" != "160000" || "${indexed_path}" != "${path}" ]]; then
        echo "!!! ${path}: submodule gitlink differs from the index; run update.sh or resolve it first" >&2
        exit 1
    fi
    checked_out="$(git -C "${AGENTS_DIR}/${path}" rev-parse --verify HEAD 2>/dev/null || true)"
    allowed_oid_for "${path}" || true
    if [[ -n "${checked_out}" ]] &&
       { { [[ "${recorded_oid}" != "${checked_out}" ]] && [[ "${ALLOWED_OID_VALUE}" != "${checked_out}" ]]; } ||
          { [[ "${recorded_oid}" == "${checked_out}" ]] && [[ -n "${ALLOWED_OID_VALUE}" ]]; }; }; then
        echo "!!! ${path}: submodule gitlink differs from the index; run update.sh or resolve it first" >&2
        exit 1
    fi
done

# --- 2. Load and initialize enabled plugin submodules. ----------------------
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
    plugin_name="$(basename "${path}")"
    contains "${plugin_name}" "${DISABLED_PLUGINS[@]+"${DISABLED_PLUGINS[@]}"}" && continue
    status="$(git -C "${AGENTS_DIR}" submodule status -- "${path}" 2>/dev/null || true)"
    if [[ "${status:0:1}" == "-" ]]; then
        echo ">>> init: ${path}"
        git -C "${AGENTS_DIR}" submodule update --init --recursive -- "${path}"
    fi
    initialize_missing_nested "${plugin}"
done

# --- 3. Build skill inventories from available plugin sources. ---------------
declare -a SKILL_NAMES=()
declare -a SKILL_OWNERS=()
declare -a SKILL_TARGETS=()
skill_details_for() {
    local wanted="$1" index
    SKILL_OWNER_VALUE=""
    SKILL_TARGET_VALUE=""
    for ((index = 0; index < ${#SKILL_NAMES[@]}; index++)); do
        if [[ "${SKILL_NAMES[${index}]}" == "${wanted}" ]]; then
            SKILL_OWNER_VALUE="${SKILL_OWNERS[${index}]}"
            SKILL_TARGET_VALUE="${SKILL_TARGETS[${index}]}"
            return 0
        fi
    done
    return 1
}

ERRORS=0
PLUGIN_COUNT=0

for path in "${PLUGIN_PATHS[@]}"; do
    plugin="$(plugin_source_root "${AGENTS_DIR}/${path}")/"
    plugin_name="$(basename "${path}")"
    contains "${plugin_name}" "${DISABLED_PLUGINS[@]+"${DISABLED_PLUGINS[@]}"}" && continue
    [[ -d "${plugin}/skills" ]] || { echo ">>> skip: ${plugin_name} (no skills/)"; continue; }
    PLUGIN_COUNT=$((PLUGIN_COUNT + 1))

    for skill in "${plugin}"skills/*/; do
        [[ -f "${skill}/SKILL.md" ]] || continue
        skill_name="$(basename "${skill}")"
        if [[ "${plugin}" == "${AGENTS_DIR}/${path}/.opencode-plugin/" ]]; then
            target="../${path}/.opencode-plugin/skills/${skill_name}"
        else
            target="../${path}/skills/${skill_name}"
        fi

        disabled_owner_for "${skill_name}" || true
        if [[ -n "${DISABLED_OWNER_VALUE}" ]]; then
            echo "!!! collision: skill '${skill_name}' is enabled from '${plugin_name}'" \
                 "and disabled from '${DISABLED_OWNER_VALUE}'" >&2
            ERRORS=1
            continue
        fi
        skill_details_for "${skill_name}" || true
        if [[ -n "${SKILL_OWNER_VALUE}" ]]; then
            echo "!!! collision: skill '${skill_name}' provided by both" \
                 "'${SKILL_OWNER_VALUE}' and '${plugin_name}' — keeping the former" >&2
            ERRORS=1
            continue
        fi
        SKILL_NAMES+=("${skill_name}")
        SKILL_OWNERS+=("${plugin_name}")
        SKILL_TARGETS+=("${target}")
    done
done

# Do not alter skills or activate runtimes when disabled ownership is ambiguous.
[[ ${ERRORS} -eq 0 ]] || exit ${ERRORS}

# --- 4. Prune links and quarantine copied disabled-plugin skills. -----------
for link in "${SKILLS_DIR}"/*; do
    skill_name="$(basename "${link}")"
    disabled_owner_for "${skill_name}" || true
    skill_details_for "${skill_name}" || true
    if [[ -L "${link}" && -n "${DISABLED_OWNER_VALUE}" ]]; then
        echo ">>> prune: skills/${skill_name} (listed for disabled plugin)"
        rm "${link}"
    elif [[ -L "${link}" && -z "${SKILL_TARGET_VALUE}" ]]; then
        echo ">>> prune: skills/${skill_name} (not provided by a registered plugin)"
        rm "${link}"
    elif [[ -n "${DISABLED_OWNER_VALUE}" && ! -L "${link}" && ( -f "${link}" || -d "${link}" ) ]]; then
        plugin_name="${DISABLED_OWNER_VALUE}"
        registered_path_for "${plugin_name}"
        source_root="$(plugin_source_root "${AGENTS_DIR}/${REGISTERED_PATH}")"
        source="${source_root}/skills/${skill_name}"
        if [[ ! -d "${source}" || ! -f "${source}/SKILL.md" ]]; then
            echo "!!! cannot quarantine skills/${skill_name}: disabled source is unavailable" >&2
            ERRORS=1
            continue
        fi
        if ! git diff --no-index --quiet --no-ext-diff -- "${source}" "${link}"; then
            echo "!!! refusing to quarantine skills/${skill_name}: content differs from disabled source" >&2
            ERRORS=1
            continue
        fi
        quarantine_root="${AGENTS_DIR}/.disabled-skills"
        quarantine_plugin_dir="${quarantine_root}/${plugin_name}"
        quarantine_destination="${quarantine_plugin_dir}/${skill_name}"

        if { [[ -e "${quarantine_root}" || -L "${quarantine_root}" ]] &&
             { ! -d "${quarantine_root}" || -L "${quarantine_root}"; }; } ||
           { [[ -e "${quarantine_plugin_dir}" || -L "${quarantine_plugin_dir}" ]] &&
             { ! -d "${quarantine_plugin_dir}" || -L "${quarantine_plugin_dir}"; }; } ||
           [[ -e "${quarantine_destination}" || -L "${quarantine_destination}" ]]; then
            echo "!!! cannot safely quarantine skills/${skill_name} at ${quarantine_destination}" >&2
            ERRORS=1
            continue
        fi
        if ! mkdir -p "${quarantine_plugin_dir}" || [[ -L "${quarantine_root}" || -L "${quarantine_plugin_dir}" ]] ||
           [[ -e "${quarantine_destination}" || -L "${quarantine_destination}" ]]; then
            echo "!!! cannot safely create quarantine for skills/${skill_name}" >&2
            ERRORS=1
            continue
        fi
        echo ">>> quarantine: skills/${skill_name} -> .disabled-skills/${plugin_name}/${skill_name}"
        if ! mv "${link}" "${quarantine_destination}"; then
            echo "!!! failed to quarantine skills/${skill_name}" >&2
            ERRORS=1
        fi
    fi
done

# A failed quarantine leaves a disabled copied skill discoverable; do not
# activate a runtime state that would claim the disabled plugin is inactive.
[[ ${ERRORS} -eq 0 ]] || exit ${ERRORS}

# --- 5. Create or repair the expected relative symlinks. --------------------
LINKED=0
for ((index = 0; index < ${#SKILL_NAMES[@]}; index++)); do
    skill_name="${SKILL_NAMES[${index}]}"
    skill_details_for "${skill_name}"
    target="${SKILL_TARGET_VALUE}"
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
if [[ ${SKIP_ACTIVATION} -eq 0 ]]; then
    echo ">>> activating declarative runtime plugins"
    if ! AGENTS_ACTIVATE_ALREADY_RECONCILED=1 "${AGENTS_DIR}/activate.sh"; then
        ERRORS=1
    fi
fi
exit ${ERRORS}
