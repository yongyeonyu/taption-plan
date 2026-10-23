#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_directory}/.." && pwd)"

failed=0

# 1) 앱 소스는 엔진 패키지를 직접 부르지 않는다. TaptionPlanEngine 하나만 통과시킨다.
forbidden_engine='^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(TaptionRouteEngine|TaptionActivityEngine)([.[:space:]]|$)'
if rg -n --glob '*.swift' "$forbidden_engine" "${repository_root}/TaptionPlan"; then
    printf '%s\n' 'TaptionPlan app sources must import TaptionPlanEngine, not a concrete engine package.' >&2
    failed=1
fi

# 2) UI·UX 계층은 엔진을 아예 모른다. 엔진은 Core/ 어댑터 뒤에만 있다.
#    뷰가 엔진 타입을 직접 쓰면 화면 하나를 고치려고 엔진을 다시 빌드해야 한다.
forbidden_in_ui='^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+TaptionPlanEngine([.[:space:]]|$)'
if rg -n --glob '*.swift' "$forbidden_in_ui" \
    "${repository_root}/TaptionPlan/UI" "${repository_root}/TaptionPlan/UX"; then
    printf '%s\n' 'UI/UX sources must not import TaptionPlanEngine; go through a Core adapter.' >&2
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf '%s\n' 'TaptionPlan engine import boundary passed.'
