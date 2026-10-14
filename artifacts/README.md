# 검증·진단 자료

`validation/REL1007A01.json`은 2026-10-07 main 반영·기기 설치·생성 파일 정리의 작은 검증 기록입니다. DB 개편 테스트 결과와 소스 SHA-256, 합성 성능 측정, 설치·정리 결과를 보존합니다.

`release-symbols/`는 원래 배포된 실행 파일과 일치하는 dSYM을 로컬에 보존하는 위치이며 Git에 포함하지 않습니다. 이 자료는 같은 소스를 다시 빌드해도 원본 UUID가 재현되지 않으므로 임시 빌드 캐시와 구분합니다. 실행 파일·심볼의 출처, UUID와 SHA-256은 각 버전의 manifest에 기록합니다. 사용자 DB·위치/건강/일정 원문·인증정보는 이 폴더에 저장하지 않습니다.

`release-symbols/175/manifest.json`은 REL1013A01의 원래 archive/export 실행 파일, 두 dSYM, 업로드한 IPA와 소스 해시를 기록합니다. 앱/Widget만 포함한 iPhone 내부 TestFlight 산출물이며 독립 Watch 검증 제품은 포함하지 않습니다.

`validation/CLN1014A01.json`은 2026-10-14 재생성 가능한 출력물·캐시·전용 시뮬레이터 정리 결과입니다. 이번에는 대표의 원본 검증 자료 보존 선택에 따라 실제 xcresult·로그도 보존했습니다. 정리 직전 `build/validation/<ID>/`의 실제 결과는 `local-validation-evidence/CLN1014A01/validation/<ID>/`로 이동했으며, 별도 build-records와 distribution 로그도 같은 CLN1014A01 폴더 아래에 있습니다.

`validation/PAW1014A01.json`과 `BAK1014A01.json`은 발자국 경로 선택/확정/삭제와 수동 백업의 로컬 센서 읽기 실패 개선 근거입니다. 실제 테스트/Debug 로그와 xcresult는 `local-validation-evidence/PAW1014A01/`, `BAK1014A01/`에 보존했습니다. `validation/CLN1014B01.json`은 이 검증으로 재생성된 출력물/캐시/전용 Simulator만 다시 정리한 기록입니다. 배포/실기기 판정은 코드·자동 검증과 구분합니다.

`validation/PAW1014B01.json`은 경로 앞부분이 발자국 한도를 소진해 이후 시각을 누락시키는 표시 개선 근거입니다. 실제158개 테스트 결과·Debug 로그·소스 해시·좌표 없는 오늘 로그 요약은 `local-validation-evidence/PAW1014B01/`에 보존했습니다. `validation/CLN1014C01.json`은 이번 검증의 재생성 출력물과 전용 Simulator를 정리한 결과이며 배포/실기기 확인을 뜻하지 않습니다.

테스트·빌드·설치 결과는 실제 기기 기능·데이터 이관·성능 결과와 구분합니다. 상세 판정과 남은 조건은 `test.md`와 `temp.md`의 요청 ID를 따릅니다.

`local-validation-evidence/`는 기존의 작은 검증 요약·소스 해시·기기/배포 화면 근거만 로컬에 보존합니다(Git 제외). 과거 `test.md`의 `build/validation/<ID>/` 경로 중 보존 대상 파일은 이 위치의 같은 `<ID>/` 아래로 옮기며 manifest가 목록을 기록합니다. 재생성 가능한 빌드·xcresult·원시 빌드 로그·임시 스크립트는 정리합니다.
