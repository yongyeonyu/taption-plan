#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"
forbidden_import='^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+TaptionRouteEngine([.[:space:]]|$)'

if rg -n --glob '*.swift' "$forbidden_import" "${repository_root}/TaptionPlan"; then
    printf '%s\n' 'TaptionPlan app sources must import TaptionPlanEngine, not TaptionRouteEngine.' >&2
    exit 1
fi

printf '%s\n' 'TaptionPlan engine import boundary passed.'
