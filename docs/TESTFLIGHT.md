# TestFlight 자동 배포

"테스트플라이트 연결해서 빌드업해" 요청 한 줄로 빌드 번호 증가부터 내부 테스터 노출 확인까지 수행한다.

## 트리거

| 사용자 요청 | 실행 |
| --- | --- |
| 테스트플라이트 연결해서 빌드업해 | `bash scripts/testflight/release.sh --yes` |
| 사전 점검만 | `bash scripts/testflight/release.sh --preflight` |
| 업로드 없이 산출물까지만 | `bash scripts/testflight/release.sh --no-upload` |
| 이미 올린 빌드 재확인 | `bash scripts/testflight/verify.sh --build <번호>` |

`release.sh`는 확인 질문에서 Enter를 기다린다. 무인 실행이면 `--yes`를 붙인다.

## 설정과 인증 정보

`scripts/testflight/config.json`에 비밀이 아닌 값만 둔다. 개인키는 저장소 밖에만 존재한다.

| 항목 | 값 | 위치 |
| --- | --- | --- |
| Issuer ID | `229c124e-7477-462c-b3f0-3180eb81ff25` | `config.json` |
| 키 ID | `AGB82JKGT3` | `config.json` |
| 개인키 | `AuthKey_AGB82JKGT3.p8` | `~/.appstoreconnect/private_keys/` |
| 팀 ID | `4FWG8XXYM7` | `config.json` / `project.pbxproj` |
| 앱 | `com.taption.plan` → `6797370230` | App Store Connect |
| 내부 그룹 | `TP Taption Plan 내부 테스트` | `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd` |

환경변수로 덮어쓸 수 있다: `ASC_API_ISSUER`, `ASC_API_KEY`, `ASC_API_KEY_PATH`, `TESTFLIGHT_GROUP_ID`. CI에서는 키를 파일로 떨어뜨린 뒤 `ASC_API_KEY_PATH`로 지정한다.

## 파일 구성

| 파일 | 역할 |
| --- | --- |
| `scripts/testflight/config.json` | Issuer ID·키 ID·번들·그룹 등 비밀이 아닌 설정 |
| `scripts/testflight/asc.py` | App Store Connect API 클라이언트(의존성 없음). `preflight`/`builds`/`latest-build`/`wait`/`attach`/`verify`/`groups` |
| `scripts/testflight/release.sh` | 9단계 오케스트레이터 |
| `scripts/testflight/verify.sh` | 업로드된 빌드 재검증 |

`asc.py`는 PyJWT 없이 `openssl dgst -sha256 -sign`으로 ES256 JWT를 만든다. openssl이 주는 DER 서명을 JWT가 요구하는 64바이트 R‖S로 변환한다.

## 실행 흐름 (release.sh)

| 단계 | 내용 | 실패 시 |
| --- | --- | --- |
| 1/9 사전 점검 | Issuer ID·키 ID·개인키·JWT 서명·**JWT 클레임 재확인**·도구·앱 조회·빌드 조회·내부 그룹 + 네 `Info.plist` `CFBundleVersion` 일치 + `project.pbxproj` `CURRENT_PROJECT_VERSION` 일치 + 작업 트리 clean | 즉시 중단, 무엇이 다른지 출력 |
| 2/9 빌드 번호 | 현재+1(또는 `--build-number N`)로 4개 plist + pbxproj 갱신 후 재확인. 숫자·현재보다 큼·ASC에 미존재 검사 | 갱신값을 되읽어 불일치 시 중단 |
| 3/9 테스트 | `--with-tests`일 때 `TaptionPlanTests` 실행 | 테스트 실패 로그 경로 출력 |
| 4/9 아카이브 | `xcodebuild archive` (Release, generic/platform=iOS). 기존 `.xcarchive`가 있으면 덮어쓰지 않고 중단 | `archive.log` |
| 5/9 익스포트 | `-exportArchive` + `ExportOptions.plist`(`app-store-connect`, automatic) | `export.log` |
| 6/9 산출물 검증 | 아카이브 안 `com.taption.plan*` 번들을 모두 읽어 목표 빌드 번호와 비교. 앱 번들(`com.taption.plan`)은 필수 | 번들 없음·앱 번들 없음·버전 불일치 시 중단 |
| 7/9 업로드 | `xcrun altool --upload-app --apiKey --apiIssuer` | `No errors uploading`/`UPLOAD SUCCEEDED` 미확인 시 중단 |
| 8/9 처리 대기·그룹 연결 | `VALID`까지 폴링(기본 30분, 20초 간격) 후 내부 그룹에 POST | `FAILED`/`INVALID`/시간 초과 시 중단 |
| 9/9 검증 | `VALID` + 그룹 연결 + 테스터 수 > 0을 모두 읽어야 통과 | `verify.log` |

`--no-upload`는 6/9에서 끝나고, `--preflight`는 1/9에서 끝난다. `--reuse-archive <경로>`를 주면 2/9(번호 증가)와 4/9(아카이브)를 건너뛰고 기존 `.xcarchive`로 익스포트·업로드만 다시 한다(업로드 실패 재시도용).

### 산출물에 Watch 앱이 없는 이유

이 프로젝트의 iOS 앱은 Watch 앱을 **embed하지 않는다**. `project.pbxproj`에 `Embed Watch Content` 단계가 없고 `TaptionPlanWatch.app` 참조도 없으며, Watch는 `TaptionPlanWatch.xcscheme`으로 따로 빌드되는 별도 target이다. 따라서 아카이브 산출물은 앱·위젯 2개 번들이고, 6/9는 이 2개가 모두 목표 번호인지 확인한 뒤 나머지 제품을 "산출물에 없는 제품(별도 target)"으로 알린다. 네 plist의 버전 일치는 1/9이 소스에서 확인한다.

## 검증 기준

요청이 요구한 다섯 가지와 대응 근거는 다음과 같다.

1. **설정·인증 참조 정확성** — `release.sh --preflight`의 `issuer_id`·`key_id`·`private_key`·`jwt_signed`·`app_lookup`·`internal_group` 검사.
2. **Issuer ID가 실제로 쓰이는지** — `jwt_claims` 검사가 서명된 토큰을 되읽어 `iss`가 `config.json` 값과 같은지, `kid`·`alg`·`aud`가 맞는지 대조한다.
3. **빌드 성공** — `--no-upload`로 아카이브·익스포트·산출물 번들 버전까지 확인. 네 plist와 `project.pbxproj`의 일치는 1/9이 따로 본다.
4. **TestFlight 반영** — `verify.sh --build N` 또는 9/9 단계가 `processingState == VALID`, `buildAttached == true`, `testerCount > 0`을 확인. 보고서는 `build/validation/<요청 ID>/testflight-report.json`.
5. **개인키 비노출** — `asc.py`는 키를 읽기만 하고 경로·크기만 출력한다. 로그에 `PRIVATE KEY` 블록이 없어야 한다(`grep -c 'PRIVATE KEY' build/validation/<ID>/*.log` → 0).

## 실패 대응

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| `HTTP 400 ... sort can not be used` | `/v1/apps/{id}/builds`는 sort·filter 미지원 | `asc.py`가 최상위 `/v1/builds`에 `filter[app]`·`sort=-version`을 쓴다(수정됨) |
| `빌드 N을 찾지 못했습니다` | 빌드가 200개를 넘으면 앱 하위 경로 첫 페이지에 최신 빌드가 없다 | 같은 원인. `find_build`가 `filter[version]`으로 정확히 찾고 60초까지 재시도한다(수정됨) |
| `앱을 찾지 못했습니다` | Issuer ID·키가 다른 팀 것 | `config.json`의 `issuerId`/`keyId` 확인 |
| `개인키가 없습니다` | 키 파일 부재 | `~/.appstoreconnect/private_keys/AuthKey_<키 ID>.p8` 배치 |
| `번들 버전이 서로 다릅니다` | 4개 plist 중 일부만 수정됨 | `--build-number N`으로 다시 실행(전부 덮어씀) |
| `이미 App Store Connect에 있습니다` | 같은 빌드 번호 재사용 | 다른 번호 사용. 번호는 되돌리지 않는다 |
| `아카이브가 이미 있습니다` | 같은 요청 ID 재실행 | 새 요청 ID(`--request-id`) |
| 처리 `FAILED`/`INVALID` | 서명·entitlement·심사 정보 문제 | `upload.log`와 App Store Connect 알림 확인 |
| `testerCount == 0` | 그룹에 테스터 없음 | App Store Connect에서 내부 테스터 추가 |

## 로그와 산출물

모든 실행은 `build/validation/<요청 ID>/`에 남는다(`build/`는 gitignore). 요청 ID는 자동으로 `TFB<MMDD>A<일련번호>`가 붙고 `--request-id`로 고정할 수 있다.

```
build/validation/TFB1024A04/
├── release.log              # 전체 실행 로그
├── preflight.json           # 사전 점검 결과
├── archive.log
├── export.log
├── upload.log
├── processing.log
├── attach.log
├── verify.log
├── testflight-report.json   # 검증 보고서
├── TaptionPlan234.xcarchive/
└── export/TaptionPlan.ipa
```

## 빌드 번호 규칙

`AGENTS.md` 규칙대로 `CURRENT_PROJECT_VERSION`과 앱·위젯·Watch·Watch 위젯 `Info.plist`의 `CFBundleVersion`을 모두 같은 값으로 유지한다. `release.sh` 1/9가 소스에서, 6/9가 최종 산출물에서 각각 확인한다. 자동 증가분은 커밋해야 한다.
