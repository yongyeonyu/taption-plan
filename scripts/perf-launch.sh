#!/usr/bin/env bash
# 콜드 실행만 재기(PRF1117A01): 설치된 Release+BENCH 판을 회차마다 끝내고 다시 띄워 `PRFBENCH launch`·`stage` 줄을 받는다.
# 사용: scripts/perf-launch.sh <UDID> <결과 폴더> <회차> <이름=인자>...   예: a= b=-benchHide=flat   (기기 잠금은 부르는 쪽이 쥔다)
# 이름들을 회차마다 번갈아 돌린다(a b a b …). 결과는 <폴더>/<이름>-<회차>.txt, 회차마다 맥 부하를 <폴더>/load.txt에 남긴다.
set -uo pipefail
UDID="${1:?UDID}"; OUT="${2:?결과 폴더}"; ROUNDS="${3:?회차}"; shift 3
mkdir -p "$OUT"
for round in $(seq 1 "$ROUNDS"); do
  for variant in "$@"; do
    name="${variant%%=*}"; args="${variant#*=}"
    file="$OUT/$name-$round.txt"
    echo "$name $round $(uptime)" >> "$OUT/load.txt"
    # shellcheck disable=SC2086
    ( xcrun devicectl device process launch --device "$UDID" --console --terminate-existing com.taption.plan -- \
        -autoBenchPerf -benchLaunchOnly $args 2>&1 | grep --line-buffered '^PRFBENCH' > "$file" ) &
    for _ in $(seq 1 60); do
      sleep 1
      grep -q '^PRFBENCH done' "$file" 2>/dev/null && break
    done
    pkill -f "devicectl device process launch --device $UDID" 2>/dev/null || true
    wait 2>/dev/null
    echo "$name $round $(grep '^PRFBENCH launch' "$file" | tr '\n' ' ')"
    sleep 4
  done
done
