#!/bin/bash
# 실기기 하나를 여러 작업(에이전트)이 함께 쓸 때 한 번에 하나만 실행하게 한다.
# 사용: scripts/with-device-lock.sh <명령...>   (예: xcodebuild ... test)
# 잠금 폴더는 저장소 공통(.git 안)이라 워크트리가 달라도 같은 잠금을 쓴다.
set -u
common="$(git rev-parse --git-common-dir)"
lock="$common/taption-device.lock"
waited=0
while ! mkdir "$lock" 2>/dev/null; do
  # 소유 프로세스가 사라졌으면 오래된 잠금으로 보고 치운다.
  owner="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$lock"; continue; fi
  sleep 5; waited=$((waited + 5))
  [ $waited -ge 3600 ] && { echo "device lock wait timed out" >&2; exit 75; }
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT INT TERM
"$@"
