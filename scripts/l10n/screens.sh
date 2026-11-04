#!/bin/bash
# 언어별 화면 스크린샷과 글자를 남긴다. 사용: screens.sh <시뮬레이터 UDID> <출력 폴더> <언어...>
set -u
udid="$1"; out="$2"; shift 2
dd=build/DerivedData-LNGSim
scripts/with-device-lock.sh xcodebuild build-for-testing -project TaptionPlan.xcodeproj -scheme TaptionPlan \
  -configuration Debug -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$dd" >"$out/build-for-testing.log" 2>&1 || { echo "build failed"; exit 1; }
for code in "$@"; do
  xcrun simctl terminate "$udid" com.taption.plan 2>/dev/null
  TEST_RUNNER_LANGUAGE_PACK_OUT="$out" TEST_RUNNER_LANGUAGE_PACK_CODE="$code" scripts/with-device-lock.sh xcodebuild test-without-building \
    -project TaptionPlan.xcodeproj -scheme TaptionPlan -configuration Debug -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$dd" -parallel-testing-enabled NO -only-testing:TaptionPlanUITests/TaptionPlanLanguagePackUITests \
    >"$out/test-$code.log" 2>&1
  echo "$code exit $? $(ls "$out/$code" 2>/dev/null | wc -l)"
done
