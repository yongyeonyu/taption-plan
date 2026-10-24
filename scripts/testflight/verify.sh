#!/usr/bin/env bash
# 이미 올린 빌드가 TestFlight에서 실제로 쓸 수 있는 상태인지 다시 확인한다.
#
#   bash scripts/testflight/verify.sh                # 최신 빌드
#   bash scripts/testflight/verify.sh --build 233
#
# 확인 항목: 처리 상태가 VALID인지, 내부 그룹에 연결됐는지, 그룹에 테스터가 있는지.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

ASC="scripts/testflight/asc.py"
BUILD_NUMBER=""
REQUEST_ID=""

usage() {
  cat <<'USAGE'
사용: verify.sh [옵션]

  --build N          확인할 빌드 번호(기본: App Store Connect의 최신 빌드)
  --request-id ID    로그 디렉터리 이름(기본: VFY<MMDD><일련번호>)
  -h, --help         이 도움말
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD_NUMBER="${2:?}"; shift 2 ;;
    --request-id) REQUEST_ID="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "알 수 없는 옵션: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(python3 "$ASC" latest-build)" \
    || { echo "최신 빌드를 읽지 못했습니다." >&2; exit 1; }
fi

if [[ -z "$REQUEST_ID" ]]; then
  today="$(date +%m%d)"
  serial=1
  while [[ -d "build/validation/VFY${today}A$(printf '%02d' "$serial")" ]]; do
    serial=$((serial + 1))
  done
  REQUEST_ID="VFY${today}A$(printf '%02d' "$serial")"
fi
LOG_DIR="build/validation/${REQUEST_ID}"
mkdir -p "$LOG_DIR"

printf '빌드 %s 검증 · 로그 %s\n\n' "$BUILD_NUMBER" "$LOG_DIR"

if python3 "$ASC" verify --build "$BUILD_NUMBER" \
  --out "${LOG_DIR}/testflight-report.json" \
  | tee "${LOG_DIR}/verify.log"; then
  printf '\n검증 통과: 빌드 %s는 VALID이고 내부 그룹에서 테스터에게 노출됩니다.\n' "$BUILD_NUMBER"
  exit 0
fi

printf '\n검증 실패: 빌드 %s\n' "$BUILD_NUMBER" >&2
printf '  - 처리 상태가 VALID인지\n  - 내부 그룹에 연결됐는지\n  - 그룹에 테스터가 있는지\n' >&2
exit 1
