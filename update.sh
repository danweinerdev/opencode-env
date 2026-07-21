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

for index in "${!MODULE_PATHS[@]}"; do
    module="${MODULE_NAMES[${index}]}"
    path="${MODULE_PATHS[${index}]}"
    plugin="${AGENTS_DIR}/${path}"
    name="$(basename "${path}")"

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

    before="$(git -C "${plugin}" rev-parse --short HEAD)"
    if git -C "${plugin}" merge-base --is-ancestor "origin/${branch}" HEAD; then
        echo ">>> ${name}: local checkout contains origin/${branch} (${before})"
    elif ! git -C "${plugin}" merge-base --is-ancestor HEAD "origin/${branch}"; then
        echo "!!! ${name}: has diverged from origin/${branch} — resolve manually" >&2
        ERRORS=1
    elif git -C "${plugin}" merge --ff-only --quiet "origin/${branch}"; then
        after="$(git -C "${plugin}" rev-parse --short HEAD)"
        if [[ "${before}" == "${after}" ]]; then
            echo ">>> ${name}: up to date (${after})"
        else
            echo ">>> ${name}: ${before} -> ${after}"
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
"${AGENTS_DIR}/refresh.sh" || ERRORS=1

exit ${ERRORS}
