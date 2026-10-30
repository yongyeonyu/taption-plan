#!/usr/bin/env bash
# 지도 이동 성능 측정(PRF1030A02): 기기에 설치된 앱을 `-autoBenchMapPan`으로 띄워 12초 동안 지도를 자동으로 밀고,
# 만든 로그 패키지에서 bench_pan 프레임 간격과 함수별 시간을 출력한다.
# 사용: scripts/map-pan-bench.sh <UDID> <결과 디렉터리> [추가 실행 인자(예: -benchMapStyle=standard)]
set -euo pipefail
UDID="${1:?UDID}"; OUT="${2:?out dir}"; shift 2; EXTRA=("$@")
SRC="Library/Application Support/TaptionPlan/Diagnostics/Packages"
mkdir -p "$OUT/logs"
pull() {
  xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier com.taption.plan \
    --source "$SRC" --destination "$OUT/logs" > /dev/null 2>&1 || true
}
pull
BEFORE=$(ls -t "$OUT"/logs/*.gz 2>/dev/null | head -1 || true)
xcrun devicectl device process launch --device "$UDID" --terminate-existing com.taption.plan -- -autoBenchMapPan "${EXTRA[@]+"${EXTRA[@]}"}" > "$OUT/launch.log" 2>&1
# 앱 읽기 대기(25초) → 자동 이동(12초) → 로그 만들기. 새 패키지가 나올 때까지 기다린다.
for _ in $(seq 1 24); do
  sleep 5
  pull
  NEW=$(ls -t "$OUT"/logs/*.gz 2>/dev/null | head -1 || true)
  [ -n "$NEW" ] && [ "$NEW" != "$BEFORE" ] && break
done
F=$(ls -t "$OUT"/logs/*.gz | head -1)
[ "$F" != "$BEFORE" ] || { echo "새 로그 패키지가 없습니다" >&2; exit 1; }
gunzip -c "$F" > "$OUT/latest.txt"
echo "package: $(basename "$F")"
python3 - "$OUT/latest.txt" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8", errors="replace") if l.startswith("{")]
pan = [d for d in lines if d.get("event") == "interaction_stats" and d.get("fields", {}).get("name") == "bench_pan"]
if pan:
    m = pan[-1]["metrics"]
    fps = m["frames"] / max(m["wall_ms"] / 1000, 0.001)
    print("bench_pan frames %d wall_ms %d fps %.1f over20 %d over40 %d over50 %d max_ms %d" % (
        m["frames"], m["wall_ms"], fps, m["over20"], m["over40"], m["over50"], m["max_ms"]))
probe = [d for d in lines if d.get("event") == "playback_probe"]
if probe:
    m = probe[-1]["metrics"]
    names = sorted({k.rsplit("_", 1)[0] for k in m if k.endswith("_ms")}, key=lambda n: -m.get(n + "_ms", 0))
    print("--- probes (total ms / calls / max ms)")
    for n in names:
        print("%-22s %8.1f ms  %6d calls  max %.1f ms" % (n, m[n + "_ms"], m.get(n + "_n", 0), m.get(n + "_max", 0)))
PY
