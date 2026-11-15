#!/usr/bin/env bash
# 종합 성능 측정(PRF1116A01): 기기에 설치된 Release+BENCH 판을 `-autoBenchPerf`로 띄워 앱이 찍는 `PRFBENCH` 줄(숫자만)을 받는다.
# 사용: scripts/perf-bench.sh <UDID> <결과 파일> [추가 실행 인자]   (기기 잠금은 부르는 쪽이 쥔다)
set -uo pipefail
UDID="${1:?UDID}"; OUT="${2:?결과 파일}"; shift 2
mkdir -p "$(dirname "$OUT")"
# 콘솔 전체는 남기지 않고 PRFBENCH 줄만 적는다. `done`이 보이거나 12분이 지나면 끝낸다.
( xcrun devicectl device process launch --device "$UDID" --console --terminate-existing com.taption.plan -- \
    -autoBenchPerf -autoBenchMapPan "$@" 2>&1 | grep --line-buffered '^PRFBENCH' > "$OUT" ) &
for _ in $(seq 1 144); do
  sleep 5
  grep -q '^PRFBENCH done' "$OUT" 2>/dev/null && break
done
pkill -f "devicectl device process launch --device $UDID" 2>/dev/null || true
wait 2>/dev/null
grep -c '^PRFBENCH' "$OUT"
