#!/usr/bin/env bash
# TestFlight 릴리스 자동화.
#
#   bash scripts/testflight/release.sh                 # 전체: 번호 증가 → 아카이브 → 익스포트 → 업로드 → 그룹 연결 → 검증
#   bash scripts/testflight/release.sh --preflight     # 설정·인증·버전만 확인
#   bash scripts/testflight/release.sh --no-upload     # 아카이브·익스포트·번들 검증까지만
#   bash scripts/testflight/release.sh --build-number 240 --yes
#
# 모든 단계는 build/validation/<요청 ID>/ 에 로그를 남긴다.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CONFIG="scripts/testflight/config.json"
ASC="scripts/testflight/asc.py"
PLIST_BUDDY=/usr/libexec/PlistBuddy

# ---------------------------------------------------------------- 인자

MODE="full"
BUILD_NUMBER=""
REQUEST_ID=""
ASSUME_YES=0
WITH_TESTS=0
SKIP_BUMP=0
ALLOW_DIRTY=0
REUSE_ARCHIVE=""

usage() {
  cat <<'USAGE'
사용: release.sh [옵션]

  --preflight            설정·인증·버전 일치만 확인하고 끝낸다
  --no-upload            아카이브·익스포트·번들 버전 검증까지만 한다
  --build-number N       빌드 번호를 N으로 고정한다(기본: 현재 + 1)
  --no-bump              빌드 번호를 바꾸지 않는다(이미 올린 번들 재확인용)
  --reuse-archive PATH   기존 .xcarchive를 다시 쓴다(빌드 번호 증가·아카이브 생략)
  --with-tests           아카이브 전에 앱 단위 테스트를 실행한다
  --allow-dirty          작업 트리가 깨끗하지 않아도 진행한다
  --request-id ID        로그 디렉터리 이름(기본: TFB<MMDD><일련번호>)
  --yes                  확인 질문 없이 진행한다
  -h, --help             이 도움말
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight) MODE="preflight"; shift ;;
    --no-upload) MODE="no-upload"; shift ;;
    --build-number) BUILD_NUMBER="${2:?}"; shift 2 ;;
    --no-bump) SKIP_BUMP=1; shift ;;
    --reuse-archive) REUSE_ARCHIVE="${2:?}"; shift 2 ;;
    --with-tests) WITH_TESTS=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --request-id) REQUEST_ID="${2:?}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "알 수 없는 옵션: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 로그

if [[ -z "$REQUEST_ID" ]]; then
  today="$(date +%m%d)"
  serial=1
  while [[ -d "build/validation/TFB${today}A$(printf '%02d' "$serial")" ]]; do
    serial=$((serial + 1))
  done
  REQUEST_ID="TFB${today}A$(printf '%02d' "$serial")"
fi
LOG_DIR="build/validation/${REQUEST_ID}"
mkdir -p "$LOG_DIR"
exec > >(tee -a "${LOG_DIR}/release.log") 2>&1

step() { printf '\n=== %s ===\n' "$1"; }
fail() { printf '\n실패: %s\n' "$1" >&2; exit 1; }

printf '요청 ID: %s\n로그: %s\n' "$REQUEST_ID" "$LOG_DIR"

config_value() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path
keys = sys.argv[1].split(".")
value = json.loads(Path("scripts/testflight/config.json").read_text())
for key in keys:
    value = value[key]
print(value)
PY
}

PROJECT="$(config_value app.project)"
SCHEME="$(config_value app.scheme)"
CONFIGURATION="$(config_value app.configuration)"
EXPORT_OPTIONS="$(config_value app.exportOptionsPlist)"
KEY_ID="$(config_value appStoreConnect.keyId)"
ISSUER_ID="$(config_value appStoreConnect.issuerId)"

# ---------------------------------------------------------------- 1. 사전 점검

step "1/9 사전 점검"

if ! python3 "$ASC" preflight --json > "${LOG_DIR}/preflight.json"; then
  cat "${LOG_DIR}/preflight.json"
  fail "사전 점검을 통과하지 못했습니다."
fi
python3 - "${LOG_DIR}/preflight.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for check in data["checks"]:
    print(f"[{'OK  ' if check['ok'] else 'FAIL'}] {check['check']}: {check['detail']}")
PY

# 번들 네 곳의 버전이 같은지 확인한다(AGENTS.md 규칙).
read_plist_version() {
  "$PLIST_BUDDY" -c "Print :CFBundleVersion" "$1" 2>/dev/null || echo "MISSING"
}

PRODUCT_PLISTS=$(python3 - <<'PY'
import json
from pathlib import Path
config = json.loads(Path("scripts/testflight/config.json").read_text())
print("\n".join(product["infoPlist"] for product in config["app"]["products"]))
PY
)

declare -a VERSIONS=()
while IFS= read -r plist; do
  [[ -z "$plist" ]] && continue
  version="$(read_plist_version "$plist")"
  printf '  %-42s CFBundleVersion=%s\n' "$plist" "$version"
  VERSIONS+=("$version")
done <<< "$PRODUCT_PLISTS"

CURRENT_BUILD="${VERSIONS[0]}"
for version in "${VERSIONS[@]}"; do
  if [[ "$version" != "$CURRENT_BUILD" ]]; then
    fail "번들 버전이 서로 다릅니다(${VERSIONS[*]}). --build-number로 다시 맞춘 뒤 실행하세요."
  fi
done
if [[ "$CURRENT_BUILD" == "MISSING" ]]; then
  fail "CFBundleVersion을 읽지 못했습니다."
fi
PBX_MISMATCH=$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$PROJECT/project.pbxproj" \
  | awk '{print $3}' | sort -u | grep -vx "$CURRENT_BUILD" || true)
if [[ -n "$PBX_MISMATCH" ]]; then
  fail "project.pbxproj의 CURRENT_PROJECT_VERSION(${PBX_MISMATCH})이 Info.plist(${CURRENT_BUILD})와 다릅니다."
fi
printf '  네 제품 번들 + project.pbxproj 모두 %s 로 일치\n' "$CURRENT_BUILD"

if [[ "$ALLOW_DIRTY" -eq 0 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    fail "작업 트리가 깨끗하지 않습니다. 커밋하거나 --allow-dirty를 쓰세요."
  fi
  printf '  작업 트리 깨끗함 (%s)\n' "$(git rev-parse --short HEAD)"
fi

if [[ "$MODE" == "preflight" ]]; then
  printf '\n사전 점검만 수행했습니다. 로그: %s\n' "$LOG_DIR"
  exit 0
fi

# ---------------------------------------------------------------- 2. 빌드 번호

step "2/9 빌드 번호"

if [[ -n "$REUSE_ARCHIVE" ]]; then
  [[ -d "$REUSE_ARCHIVE" ]] || fail "아카이브가 없습니다: $REUSE_ARCHIVE"
  TARGET_BUILD="$("$PLIST_BUDDY" -c "Print :CFBundleVersion" \
    "${REUSE_ARCHIVE}/Products/Applications/TaptionPlan.app/Info.plist" 2>/dev/null || true)"
  [[ -n "$TARGET_BUILD" ]] || fail "아카이브에서 빌드 번호를 읽지 못했습니다."
  [[ "$TARGET_BUILD" == "$CURRENT_BUILD" ]] \
    || fail "아카이브 빌드 번호(${TARGET_BUILD})가 소스(${CURRENT_BUILD})와 다릅니다."
  printf '  --reuse-archive: 아카이브의 %s 사용\n' "$TARGET_BUILD"
elif [[ "$SKIP_BUMP" -eq 1 ]]; then
  TARGET_BUILD="$CURRENT_BUILD"
  printf '  --no-bump: %s 유지\n' "$TARGET_BUILD"
else
  if [[ -z "$BUILD_NUMBER" ]]; then
    TARGET_BUILD=$((CURRENT_BUILD + 1))
  else
    TARGET_BUILD="$BUILD_NUMBER"
  fi
  if ! [[ "$TARGET_BUILD" =~ ^[0-9]+$ ]]; then
    fail "빌드 번호는 숫자여야 합니다: $TARGET_BUILD"
  fi
  if [[ "$TARGET_BUILD" -le "$CURRENT_BUILD" ]]; then
    fail "빌드 번호는 현재(${CURRENT_BUILD})보다 커야 합니다: $TARGET_BUILD"
  fi
  EXISTING="$(python3 "$ASC" builds --limit 200 | awk -v n="$TARGET_BUILD" '$1 == n {print $2}')"
  if [[ -n "$EXISTING" ]]; then
    fail "빌드 ${TARGET_BUILD}은 이미 App Store Connect에 있습니다(${EXISTING}). 다른 번호를 쓰세요."
  fi

  while IFS= read -r plist; do
    [[ -z "$plist" ]] && continue
    "$PLIST_BUDDY" -c "Set :CFBundleVersion ${TARGET_BUILD}" "$plist"
  done <<< "$PRODUCT_PLISTS"

  python3 - "$PROJECT/project.pbxproj" "$TARGET_BUILD" <<'PY'
import re, sys
from pathlib import Path
path, target = Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
updated, count = re.subn(
    r"CURRENT_PROJECT_VERSION = \d+;", f"CURRENT_PROJECT_VERSION = {target};", text
)
if count == 0:
    raise SystemExit("CURRENT_PROJECT_VERSION을 찾지 못했습니다.")
path.write_text(updated, encoding="utf-8")
print(f"  project.pbxproj {count}곳 갱신")
PY

  while IFS= read -r plist; do
    [[ -z "$plist" ]] && continue
    actual="$(read_plist_version "$plist")"
    [[ "$actual" == "$TARGET_BUILD" ]] \
      || fail "$plist 갱신 실패: $actual"
  done <<< "$PRODUCT_PLISTS"
  printf '  빌드 번호 %s → %s (4개 번들 + pbxproj)\n' "$CURRENT_BUILD" "$TARGET_BUILD"
fi

# ---------------------------------------------------------------- 3. 테스트(선택)

step "3/9 테스트"
if [[ "$WITH_TESTS" -eq 1 ]]; then
  # 단위 테스트는 구체적인 시뮬레이터에서만 돈다. generic destination은
  # "Tests must be run on a concrete device"로 끝난다(2026-10-28).
  TEST_SIMULATOR_UDID="${TEST_SIMULATOR_UDID:-$(xcrun simctl list devices available \
    | awk -F '[()]' '/iPhone/ {print $2; exit}')}"
  [[ -n "$TEST_SIMULATOR_UDID" ]] \
    || fail "사용 가능한 iPhone 시뮬레이터가 없습니다. TEST_SIMULATOR_UDID로 지정하세요."
  printf '  시뮬레이터 %s\n' "$TEST_SIMULATOR_UDID"
  # CODE_SIGNING_ALLOWED=NO로 돌리면 서명이 필요한 시험(StoreKit 구매·백업 연결·
  # HealthKit 이력·GPS 로그)이 한꺼번에 실패한다(2026-10-28). 시뮬레이터는
  # 서명 없이도 빌드되므로 이 플래그를 빼고 돌린다.
  xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=${TEST_SIMULATOR_UDID}" \
    -skipPackagePluginValidation \
    COMPILER_INDEX_STORE_ENABLE=NO \
    OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' \
    -only-testing:TaptionPlanTests \
    > "${LOG_DIR}/tests.log" 2>&1 || fail "단위 테스트가 실패했습니다: ${LOG_DIR}/tests.log"
  printf '  단위 테스트 통과\n'
else
  printf '  --with-tests 없음: 생략(아카이브 컴파일로 빌드만 확인)\n'
fi

# ---------------------------------------------------------------- 4. 아카이브

step "4/9 아카이브"
if [[ -n "$REUSE_ARCHIVE" ]]; then
  ARCHIVE_PATH="$REUSE_ARCHIVE"
  printf '  기존 아카이브 재사용: %s\n' "$ARCHIVE_PATH"
else
  ARCHIVE_PATH="${LOG_DIR}/TaptionPlan${TARGET_BUILD}.xcarchive"
  if [[ -d "$ARCHIVE_PATH" ]]; then
    fail "아카이브가 이미 있습니다: $ARCHIVE_PATH (덮어쓰지 않습니다)"
  fi
  xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "build/${REQUEST_ID}-archive-dd" \
    -allowProvisioningUpdates -skipPackagePluginValidation \
    OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' \
    > "${LOG_DIR}/archive.log" 2>&1 || fail "아카이브 실패: ${LOG_DIR}/archive.log"
  printf '  %s\n' "$ARCHIVE_PATH"
fi

# ---------------------------------------------------------------- 5. 익스포트

step "5/9 익스포트"
EXPORT_DIR="${LOG_DIR}/export"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  > "${LOG_DIR}/export.log" 2>&1 || fail "익스포트 실패: ${LOG_DIR}/export.log"
IPA_PATH="$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 | head -1)"
[[ -n "$IPA_PATH" ]] || fail "IPA를 찾지 못했습니다: $EXPORT_DIR"
printf '  %s\n' "$IPA_PATH"

# ---------------------------------------------------------------- 6. 산출물 번들 검증

step "6/9 산출물 번들 버전 검증"
APP_PATH="${ARCHIVE_PATH}/Products/Applications"
FOUND_BUNDLES=0
MISMATCH=0
FOUND_IDS=""
while IFS= read -r info; do
  [[ -z "$info" ]] && continue
  bundle_id="$("$PLIST_BUDDY" -c "Print :CFBundleIdentifier" "$info" 2>/dev/null || echo "?")"
  bundle_version="$("$PLIST_BUDDY" -c "Print :CFBundleVersion" "$info" 2>/dev/null || echo "?")"
  case "$bundle_id" in
    com.taption.plan*) ;;
    *) continue ;;
  esac
  FOUND_BUNDLES=$((FOUND_BUNDLES + 1))
  FOUND_IDS="${FOUND_IDS}${bundle_id}"$'\n'
  if [[ "$bundle_version" != "$TARGET_BUILD" ]]; then
    MISMATCH=$((MISMATCH + 1))
    printf '  [FAIL] %-42s %s\n' "$bundle_id" "$bundle_version"
  else
    printf '  [OK  ] %-42s %s\n' "$bundle_id" "$bundle_version"
  fi
done < <(find "$APP_PATH" -name Info.plist -not -path '*/_CodeSignature/*' | sort)

if [[ "$FOUND_BUNDLES" -eq 0 ]]; then
  fail "산출물에서 com.taption.plan* 번들을 찾지 못했습니다. 아카이브 내용을 확인하세요."
fi
if ! printf '%s' "$FOUND_IDS" | grep -qx "com.taption.plan"; then
  fail "산출물에 앱 번들(com.taption.plan)이 없습니다."
fi
[[ "$MISMATCH" -eq 0 ]] || fail "산출물 번들 버전이 ${TARGET_BUILD}과 다릅니다."
printf '  %s개 번들 모두 %s\n' "$FOUND_BUNDLES" "$TARGET_BUILD"

# Watch 앱은 이 프로젝트에서 iOS 앱에 embed되지 않는 별도 target이다(Embed Watch
# Content 단계 없음, TaptionPlanWatch.app은 project.pbxproj에 등장하지 않음).
# 산출물에 없는 제품은 실패가 아니라 사실대로 알린다. 네 plist의 버전 일치는 1/9에서 확인한다.
MISSING_PRODUCTS=""
while IFS=$'\t' read -r name bundle_id; do
  [[ -z "$bundle_id" ]] && continue
  printf '%s' "$FOUND_IDS" | grep -qx "$bundle_id" || MISSING_PRODUCTS="${MISSING_PRODUCTS} ${name}(${bundle_id})"
done < <(python3 - <<'PY'
import json
from pathlib import Path
config = json.loads(Path("scripts/testflight/config.json").read_text())
for product in config["app"]["products"]:
    print(f"{product['name']}\t{product['bundleId']}")
PY
)
if [[ -n "$MISSING_PRODUCTS" ]]; then
  printf '  산출물에 없는 제품(별도 target):%s\n' "$MISSING_PRODUCTS"
fi

if [[ "$MODE" == "no-upload" ]]; then
  printf '\n업로드를 건너뛰었습니다(--no-upload). IPA: %s\n' "$IPA_PATH"
  exit 0
fi

# ---------------------------------------------------------------- 7. 업로드

step "7/9 업로드"
if [[ "$ASSUME_YES" -eq 0 ]]; then
  printf '빌드 %s(%s)을 TestFlight에 올립니다. 계속하려면 Enter: ' "$TARGET_BUILD" "$ISSUER_ID"
  read -r _
fi
xcrun altool --upload-app -f "$IPA_PATH" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID" \
  > "${LOG_DIR}/upload.log" 2>&1 || fail "업로드 실패: ${LOG_DIR}/upload.log"
grep -qE "No errors uploading|UPLOAD SUCCEEDED" "${LOG_DIR}/upload.log" \
  || fail "업로드 응답을 확인하지 못했습니다: ${LOG_DIR}/upload.log"
printf '  업로드 요청 완료\n'

# ---------------------------------------------------------------- 8. 처리 대기 + 그룹 연결

step "8/9 처리 대기 및 내부 그룹 연결"
python3 "$ASC" wait --build "$TARGET_BUILD" \
  > "${LOG_DIR}/processing.log" 2>&1 \
  || { tail -5 "${LOG_DIR}/processing.log"; fail "처리가 끝나지 않았습니다."; }
tail -1 "${LOG_DIR}/processing.log"
python3 "$ASC" attach --build "$TARGET_BUILD" \
  > "${LOG_DIR}/attach.log" 2>&1 || fail "그룹 연결 실패: ${LOG_DIR}/attach.log"
cat "${LOG_DIR}/attach.log"

# ---------------------------------------------------------------- 9. 검증

step "9/9 검증"
if ! python3 "$ASC" verify --build "$TARGET_BUILD" \
  --out "${LOG_DIR}/testflight-report.json" \
  > "${LOG_DIR}/verify.log" 2>&1; then
  cat "${LOG_DIR}/verify.log"
  fail "검증을 통과하지 못했습니다. 빌드·그룹·테스터 노출을 확인하세요."
fi
cat "${LOG_DIR}/verify.log"

printf '\n완료: 빌드 %s\n' "$TARGET_BUILD"
printf '  처리 상태: VALID\n'
printf '  내부 그룹 연결: 확인\n'
printf '  보고서: %s\n' "${LOG_DIR}/testflight-report.json"
printf '  로그: %s\n' "$LOG_DIR"
printf '\n빌드 번호 변경분은 커밋해야 합니다: git add -A && git commit\n'
