#!/usr/bin/env bash
# 재생 성능 측정(PLY1029A10): 기기에 설치된 앱을 어제 하루 자동 재생으로 띄우고, 끝나면 만든 로그 패키지에서
# playback_frame_stats를 읽어 출력한다. 사용: scripts/playback-bench.sh <UDID> <결과 디렉터리>
set -euo pipefail
UDID="${1:?UDID}"; OUT="${2:?out dir}"; shift 2; EXTRA=("$@")  # 추가 실행 인자(예: -benchMinute=none)
mkdir -p "$OUT/logs"
# 실행 전에 기기에 있던 패키지를 먼저 받아 기준으로 삼는다(그래야 "새 패키지"를 가릴 수 있다).
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier com.taption.plan \
  --source "Library/Application Support/TaptionPlan/Diagnostics/Packages" --destination "$OUT/logs" > /dev/null 2>&1 || true
BEFORE=$(ls -t "$OUT"/logs/*.gz 2>/dev/null | head -1 || true)
xcrun devicectl device process launch --device "$UDID" --terminate-existing com.taption.plan -- -autoStartDayPlayback -autoPlaybackYesterday "${EXTRA[@]+"${EXTRA[@]}"}" > "$OUT/launch.log" 2>&1
# 앱이 날짜 바꾸기·읽기 대기(약 23초) → 재생(끝까지 기다림, 최대 240초) → 로그 만들기. 새 패키지가 나올 때까지 기다린다.
for i in $(seq 1 60); do
  sleep 10
  xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier com.taption.plan \
    --source "Library/Application Support/TaptionPlan/Diagnostics/Packages" --destination "$OUT/logs" > /dev/null 2>&1 || true
  NEW=$(ls -t "$OUT"/logs/*.gz 2>/dev/null | head -1 || true)
  [ -n "$NEW" ] && [ "$NEW" != "$BEFORE" ] && break
done
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier com.taption.plan \
  --source "Library/Application Support/TaptionPlan/Diagnostics/Packages" --destination "$OUT/logs" > /dev/null 2>&1
F=$(ls -t "$OUT"/logs/*.gz | head -1)
gunzip -c "$F" > "$OUT/latest.txt"
echo "package: $(basename "$F")"
grep '"playback_frame_stats"' "$OUT/latest.txt" | tail -1 | python3 -c '
import sys,json
d=json.loads(sys.stdin.read()); m=d["metrics"]; t=max(1,m["ticks"])
print(d["timestamp"], "ticks", int(m["ticks"]), "over12 %d%%" % (100*m["over_12ms"]/t), "over20", int(m["over_20ms"]),
      "max", m["max_ms"], "overlay", m.get("overlay_evals"), "map_frames", m.get("map_frames"), "cam", m.get("camera_applies"), "wall_s", m.get("wall_s"), "drv_avg", m.get("drv_avg_ms"), "drv_max", m.get("drv_max_ms"),
      "hist<9/9-12/12-17/17-25/25-50/50+", [int(m.get(k,0)) for k in ("tk_lt9","tk_9_12","tk_12_17","tk_17_25","tk_25_50","tk_ge50")],
      "fps %.0f" % (m["ticks"]/m["wall_s"]) if m.get("wall_s",0) and m["wall_s"]>0 else "")'
# 함수별 시간(playback_probe): 합계 ms 큰 순서로 출력
grep '"playback_probe"' "$OUT/latest.txt" | tail -1 | python3 -c '
import sys,json
d=json.loads(sys.stdin.read()); m=d["metrics"]
names=sorted({k.rsplit("_",1)[0] for k in m if k.endswith("_ms")}, key=lambda n:-m.get(n+"_ms",0))
print("--- probes (total ms / calls / max ms)")
for n in names: print("%-22s %8.1f ms  %6d calls  max %.1f ms" % (n, m[n+"_ms"], m.get(n+"_n",0), m.get(n+"_max",0)))' || true
# 본문이 분을 읽은 위치(playback_reader_trace): swift demangle로 읽기 쉽게
grep '"playback_reader_trace"' "$OUT/latest.txt" | tail -1 | python3 -c '
import sys,json,subprocess
d=json.loads(sys.stdin.read())
print("--- body readers of the minute (count x call chain)")
for k in sorted(d["fields"], key=lambda x:int(x[1:])):
    v=d["fields"][k]
    print(subprocess.run(["xcrun","swift-demangle","--simplified"],input=v,capture_output=True,text=True).stdout.strip()[:260])' || true
