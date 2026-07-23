#!/usr/bin/env bash
set -euo pipefail

case "$#:$*" in
    0:) ;;
    1:--check) ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 2
        ;;
esac

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" != "--check" && "${AGENTS_ACTIVATE_ALREADY_RECONCILED:-}" != "1" ]]; then
    # Reconcile disabled skills first.  The flag prevents refresh.sh from
    # calling this wrapper again; this invocation generates the runtime below.
    AGENTS_ACTIVATE_RECONCILING=1 "${AGENTS_DIR}/refresh.sh" --skip-activation
fi
exec python3 "${AGENTS_DIR}/scripts/activate.py" "$@"
