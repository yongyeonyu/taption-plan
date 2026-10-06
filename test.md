# 검증 기록

## REL1007A01 · main 반영·iPhone 11/18 설치·생성 파일 정리 (2026-10-07 완료)

- main 반영: 시작 main9e1ad9d·원격 ahead/behind0/0에서 기존 GPS1006H01·PAW1006A01·DBP1006A01/B01/C01 변경을 보존해 코드 커밋3d547be186c2a3789ee158f51bbed2cf3c0a6094를 생성·push했고 실제 원격 main SHA 일치를 확인했다. 이 후속 문서/정리 기록도 별도 main 커밋·push 대상이다.
- 검증 재사용: C01 최종 앱156개·Core131개·Release 성능2개가 실패/건너뜀0이며 버전 변경 전 소스 manifest145/145/22개와 현재 바이트가 일치했다. GPS package45개의 필터/테스트 소스2개도 일치했다. PAW 이후 변경한 저장소/AppModel 경로는 C01의156개 회귀에 포함했고 GPS·발자국 UI 소스는 유지했다. 기존 결과를 현재 전체 앱의 새 전수검사로 표시하지 않는다.
- 새 빌드: 프로젝트 CURRENT_PROJECT_VERSION8곳·앱/Widget/독립 Watch 앱/위젯 Info.plist4곳을173으로 맞췄다. generic iOS Debug와 Release 모두 exit0. Release는 -O·whole-module 최적화 및 testability 제외를 확인했다. 앱·iPhone Widget 두 제품1.0(173)·strict 서명0·각 실행 파일/dSYM UUID 일치·두 설치 기기 provisioning·기존 App Group을 확인했다. iPhone 제품에 Watch 앱은 없다. 엔진 경계·diff check 통과. 기능 소스는 검증 후 변경하지 않았다.
- 실기기 설치: iPhone11 Pro(iPhone12,3)는1.0(167)→1.0(173), iPhone18 Pro Max(iPhone19,7)는1.0(172)→1.0(173). 두 devicectl install app JSON outcome success와 각 기기의 설치 후 앱 목록1.0(173)을 읽어 확인했다. development 서명 Release를 기존 앱 삭제 없이 업데이트했으며 앱 실행/사용자 입력은 수행하지 않았다.
- 정리: 명시 경로44개와 TaptionPlan만 설치된 검증용 iPhone18 Pro 시뮬레이터850D4C37-985B-4563-B4A6-6C2D35B706DD를 삭제했다. 대상 할당 사용량 합계9.042GiB(9,708,462,080바이트)이며 실제 전체 디스크 여유 공간 증가량 측정은 아니다. 저장소 build/ 전체(빌드·xcresult·임시 로그/스크립트/복사본), 두 package .build와 네 .swiftpm, 재생성 가능한 Package.resolved, 확인된 TaptionPlan OS 임시 파일·/tmp 스크립트·설치 복사본과 원래157 Xcode archive를 정리했다. 모든 지정 경로 부재 및 전용 시뮬레이터 삭제를 확인했다. 다른 프로젝트 시뮬레이터14개·공용 런타임·다른 프로젝트 DerivedData는 유지했다.
- 보존/근거: 사용자 DB·백업·원본 리소스와 ShotGuide 자료는 변경하지 않았다. 원래157/169/170/171/172 및 설치173의 실행 파일·가용 dSYM과 기존 보존된 Widget/Watch 심볼20개 항목을 artifacts/release-symbols/에 보존하고 SHA-256/UUID를 대조했다. 원래169 dSYM은 기존부터 없으며 다른 심볼로 대체하지 않았다. 기존 작은 검증 요약·소스 해시·실기기/배포 화면364개는 artifacts/local-validation-evidence/의 요청 ID 경로에 보존했고 두 기기 install/readback JSON도 추가했다. 이 로컬 자료는 Git 제외다. 과거 build/validation/ 경로는 정리 후 존재하지 않으며 보존된 파일 목록은 해당 manifest에서 확인한다. 현재 요청의 작은 검증·설치·정리 목록은 artifacts/validation/REL1007A01.json에 Git으로 보존한다.
- 제한: 직접 기기 설치이며 새 TestFlight 업로드/다운로드 결과가 아니다. 실제 사용자 DB 최초 이관·재시작/저장·지도 움직임·GPS 부산 재발 여부·분홍 발자국 탭·센서/Watch 데이터·기기 CPU/배터리 검증은 대표가 제공하는 화면/로그를 기다린다. 설치 성공만으로 기능/성능 통과를 처리하지 않는다. 요청된 설치·정리 기준 충족으로 REL1007A01을 temp에서 제거하고 기존 실기기 기능 대기는 유지한다.

## DBP1006C01 · SQLite 행 저장·시간 인덱스·앱 호출 경로 개편 (2026-10-07 로컬 검증 완료 / 실기기 대기)
- 요청/기준: 호환성 불필요·속도 우선 DB 재설계. main9e1ad9d의 미커밋 GPS1006H01·PAW1006A01·A01 변경을 보존하고 B01 활동 배열 분할 설계를 대체했다. 사용자 원본 DB/백업을 도구로 변환하거나 삭제하지 않았다.
- 구현: `actual_records`에 활동 필드를 별도 열로 저장하고 RTree+REAL 경계 재검사로 기간 교집합을 조회한다. 트리거가 외부 SQL 수정까지 활동 revision/시간 인덱스에 반영한다. UUID 중복 출현 키와 position으로 중복·순서를 보존하며 evidence만 현재 정본 codec을 사용한다. 처음 배포 배열을 읽을 때만 단일 트랜잭션으로 행에 이관하며 B01 manifest/분할 payload/원본 중복 테이블 API는 제거했다.
- 증분/앱: immutable 단건 변경 객체와 확정 배열 저장 공간이 일치하면 한 행만 UPSERT한다. 일반 수정은 변경 행을 비교하고 전체 가져오기는512행씩 바인딩하고 한 트랜잭션 안에서 행별 트리거 제거→정본 행 입력→SQL 한 번의 RTree 구성→트리거 복구→revision1회 증가를 수행한다. 오류·취소 시 DDL/행/인덱스/revision 모두 rollback한다. 빈 DB에 빈 이력을 다시 쓰면 인덱스 구성과 revision 갱신을 생략한다. 일자 생성·재계산은 현재 확정 배열과 revision이 맞을 때만 범위 SQL을 사용하고, 미저장 변경/외부 변경/메모리 압력 때는 캡처한 원본으로 돌아간다. 초기 정리 worker가 내용이 같은 배열을 새로 만드는 경로는 원래 저장 공간을 재사용하도록 고쳤다.
- 중간 실패: `app-tests-01`146개 중3개는 실제 저장 오류가 아니라 `encodedDomains`의 활동 영역 중복 집계 실패였다. 중복 집계를 제거했다. `app-tests-02`147개 중 앱 호출 검증1개에서 assertion2건이 실패해 초기 정리 이후 배열 저장 공간이 바뀌는 문제를 발견했다. 기대치를 낮추지 않고 실제 경로를 수정했다.
- 최종 회귀 통과: Core 전체131개·실패/건너뜀0(`core-final-03.log`); SQLite48·센서100·앱 시작/취소/수정/일자8개를 함께 실행한 앱156개·실패/건너뜀0(`app-tests-final-v3.xcresult`). 행 경계/진행 중/자정 교차·원문 UTF-8/embedded NUL·중복 ID·각 provenance 필드·부분 변경/추가/재정렬/축소/삭제·일관 WAL 읽기·실패/취소 rollback·외부 SQL 변경·부정확한 단건 hint의 fallback·앱 호출을 포함한다. EXPLAIN에서 RTree와 row_id PK 탐색을 확인했다.
- 중간 추가 수정: 최초 typed 구현의 Release 전체 저장6,488ms 회귀를 확인해 일괄 시간 인덱스로 변경했다. 변경 중 문자열 들여쓰기와 Swift6 Sendable 선언으로 컴파일이 실패한 뒤 수정했다(`core-native-02`, `core-final-02`, `app-tests-final`). `app-tests-final-v2`는 빈 이력 재저장 시 불필요한 revision 변경을 검출한1개 실패가 있어 이를 수정했고 v3에서156개 전체 통과했다. 앞서 통과한 실행/폐기한 구현의 수치를 최종 성능으로 혼용하지 않는다.
- 최종 빌드/정합: `performance-all-final.xcresult` Release(-O/WMO/ENABLE_TESTABILITY)2개·실패/건너뜀0; `device-debug-final.log` generic iOS Debug 성공(`ENABLE_DEBUG_DYLIB=NO`, 기존 개발용 dylib 서명 우회 CLI값이며 프로젝트 설정 변경 없음). 앱/Widget 산출물1.0(172), Watch 미포함, 두 번들 strict codesign exit0. 모든 최종 앱/성능/기기 빌드 및 Core 입력 파일 해시가 현재 소스와 일치한다(`final-verification.json`). 엔진 import 경계·`git diff --check` 통과. GPS/발자국 기존 변경의 소스 해시는 C01 전과 동일하다(`source-comparison.json`). 캐시된 일자 preview가 정본을 추가 조회하지 않는 것도 앱 호출 횟수로 확인했다.
- 최종 성능(12만 건, 동일 규격 Simulator Release fixture, 이전 B01→C01): 최초 전체 저장2,354.655→1,927.987ms; 최초 전체 조회748.395→188.980ms; 일반 배열 API의 한 건 변경 저장46.321→32.622ms; 설정 저장6.942→3.599ms; 외부 설정 변경 뒤 조회5.914→0.381ms. 새 명시 단건 API는 비교1건/쓰기1행·2.978ms, 하루 범위는1,441행·2.621ms. 설정용 부분 시작 조회0.265ms, 확정 snapshot 반복 조회3회 평균0.100ms. 최초 과정의 process peak는 B01 약108.97→113.67MiB로 소폭 증가했다. fixture1회 벽시계 측정이며 기기 성능·통계적 보장·UI 전체 지연으로 일반화하지 않는다. 실제 기존 DB 이관은 초기 codec decode가 추가되므로 신규 전체 저장1.93초와 같다고 보지 않는다.
- 센서 재검증(5천 건): 저장108.949ms·전체 조회3회 평균72.350ms. 같은 실행에서 좁은 범위 조회는 일자 전체4,440행/4.964ms와 인덱스2행/0.041ms. 센서 범위 SQL은 B01부터 적용된 것이며 C01의 신규 개선으로 중복 주장하지 않는다. 측정 간 환경 변화도 포함한다. 수치 원본은 `metrics.json`과 각 성능 로그이다.
- 제한: 전체 앱 초기 로드/portable 백업/일괄 분석은 전체 모델을 구성하고, 일반 배열 변경 비교·재정렬은 전체 건수에 비례한다. 단건 DB 측정은 배열 복사/화면 갱신을 포함한 전체 UI 지연이 아니다. 실제 사용자 DB 이관/기기 화면·CPU·배터리·체감은 미검증이며 commit/push/TestFlight/실기기 설치는 실행하지 않았다. 근거 `build/validation/DBP1006C01/`.


## DBP1006B01 · 대용량 활동 이력 부분 저장·센서 시각 범위 조회 · 2026-10-06
- 시작: main9e1ad9d의 GPS1006H01·PAW1006A01·DBP1006A01 미커밋 변경을 보존했다. A01의 최종 Release 결과를 비교 기준으로 재사용했다. 사용자 원본 DB·iCloud 백업·인증 자료는 열거나 변환하지 않았고 합성 fixture에서 검증했다.
- 구현: 활동 이력1,024건 이상을512건 이하 묶음으로 분할한다. `plan.actuals`는 버전1 manifest, `snapshot_parts`는 기존 canonical envelope로 압축된 배열을 보관한다. 배열 위치를 유지하므로 중복 UUID나 날짜 역순을 합치거나 정렬하지 않는다. 같은 묶음은 UTF-8/시각 비트까지 대조해 재인코딩을 생략하고, 변경 묶음만 UPSERT한다. append·축소·empty도 같은 트랜잭션으로 처리한다. metadata·manifest·묶음을 물리적으로 다시 읽어 검증하고 새 묶음의 decode 값이 입력과 일치한 뒤 commit한다. read는 별도 WAL 읽기 트랜잭션으로 묶어 외부 동시 쓰기 때도 root/묶음 세대가 섞이지 않는다.
- 변환/호환: 기존 inline 원본 행은 `snapshot_partition_sources`에 최초1회 보존하고, 최신 값 대신 자동 fallback하지 않는다. 저장 도중 강제 실패 시 manifest·묶음·보존 원본·metadata가 함께 rollback되고 재시도 가능함을 확인했다. 현재 facade·App Group 경로·portable snapshot·암호화 백업 포맷은 유지한다. 기존 배열 DB→분할 DB→파일 백업→새 DB 복원에서 원문·순서·중복·설정이 같다. 이전 앱 바이너리는 새 manifest를 배열로 해석할 수 없으므로 DB 파일 자체의 다운그레이드는 지원하지 않는다. 전체 사용자 데이터 삭제는 보존 원본/묶음도 삭제한다.
- 범위 조회: 센서의 `TimeSpan.contains` 계약대로 SQL에서 양 끝 시각을 포함한다. `events_domain_timestamp_index`는 동기 저장소 초기화 대신 actor의 첫 범위 조회에서 생성한다. 저장 당시 날짜 키의 시간대가 달라도 실제 timestamp가 범위 안이면 읽고, 기존 payload 시각 재확인·원본 복구·취소·generation 검사를 유지한다. 실제 query plan이 시간 범위 인덱스를 SEARCH하는지 Core 테스트로 확인했다.
- 최종 관련 검증: `app-tests-v2.xcresult`144개·`core-tests-final.log`127개·Release 성능2개 모두 실패/건너뜀0. 한 건 수정 시512건 이하 묶음1개만 encode/write하는 assertion, 전체 필드 변경·바이트가 다른 Unicode·중복 ID·삭제/추가·외부 동일 revision 손상·메모리 압력·변환 rollback·portable 복원·시간대/양 끝 시각·범위 밖 손상 원본 배제를 검증했다. 기존 센서 복구·삭제·일자 DB·취소 회귀도 포함한다. 첫 앱143개도 통과했다.
- 중간 실패 구분: 최초 Core127개에서 새 fixture의 `.now`가 SQLite REAL 왕복 때 미세하게 달라져 한 테스트의 equality assertion2개가 실패했다. 비교용 시각을 정확한 고정 시각으로 바꿨다. 두 번째 Core 검사에서는 기존 V3 동시 cold-open 테스트가 `database is locked`로1회 실패했다. 해당 테스트 단독 재검사와 최종 전체127개는 통과했으며, V3 초기화 코드를 바꾸거나 이 중간 실패를 통과로 처리하지 않았다.
- 성능: 같은 iPhone18 Pro/iOS27.0 Simulator의 Release(-O/whole-module, testability ON)·같은 규격의12만 건 fixture를 비교했다. 각 저장/콜드 조회는1회 측정이며, 반복 조회/센서 query는3회 평균이다. 통계적 유의성·기기 CPU/배터리·실제 사용자 DB의 지연 개선 근거가 아니다.

|12만 건 작업|A01 최종 ms|B01 최종 ms|
|---|---:|---:|
|기록 한 건 수정 저장|1140.100|46.321|
|최초 전체 이력 조회|1019.167|748.395|
|설정만 저장|9.475|6.942|
|저장 직후 조회|0.217|0.154|
|반복 조회 평균|0.115|0.080|
|외부 설정 변경 뒤 조회|6.023|5.914|
|최초 전체 저장|1733.994|2354.655|

- 센서5천 건 fixture에서 좁은 범위를 요청할 때, 같은 실행에서 이전 날짜 쿼리는4,440행/5.304ms, 새 시각 쿼리는2행/0.054ms였으며 반환 원문은 같다. 센서 전체5천 건 append198.889ms·조회92.942ms도 기록했으나 A01 대비 변화에는 실행 환경 차이도 포함될 수 있어 범위 쿼리의 구조적 개선과 구분한다. 최초 전체 저장의 프로세스 peak 표본은203.14→108.97MiB였으며 실기기 peak memory 개선을 입증한 값은 아니다.
- 비용/제한: 최초 전체 저장은 이번 측정에서0.62초 늘었다. 기존 배열의 첫 전환은 전체 인코딩/검증과 원본 보존 비용이 필요하며, 보존 원본만큼 DB 디스크 사용량도 추가된다. 전체 snapshot facade는 여전히 모든 이력을 메모리에 읽고, 배열 앞부분 삽입/전체 재정렬은 여러 묶음을 바꾼다. 다른 작은 영역/배열은 inline을 유지한다. 실제172 기기 적용·체감/지도·배터리 검증은 배포 후 확인해야 한다.
- 빌드/일치: generic iOS Debug exit0·BUILD SUCCEEDED. 기존 개발용 dylib 서명 회피 명령 옵션 ENABLE_DEBUG_DYLIB=NO를 사용했으며 프로젝트 설정은 바꾸지 않았다. 최종 앱/Widget1.0(172)·각 strict 서명 exit0·Watch 미포함을 확인했다. 최종 앱 Debug 테스트·Release2개·iOS Debug의 Swift/plist/project/header/modulemap 소스와 현재 파일이 모두 일치하고 Core 최종 소스도 일치한다. 두 번째 Release 성능 검사는 첫 Release의 동일 컴파일 산출물을 증분 재사용했다. import 경계·diff 검사가 통과했다. A01 최종 대비 변경 파일8개만 확인했고 GPS/분홍 발자국 구현은 보존했다.
- 근거/남음: `build/validation/DBP1006B01/`의 각 로그/xcresult/summary·metrics.json·final-verification.json·source-comparison.json. 현재 commit/push·TestFlight 업로드·실기기 설치 전이다. 실제 사용자 DB 전환과 기기 체감 검증 조건은 temp.md에 유지한다.

## DBP1006A01 · DB 반복 조회·저장 및 센서 codec 비용 개선 · 2026-10-06
- 시작: main9e1ad9d에서 GPS1006H01·PAW1006A01의 미커밋 변경을 보존했다. 현재 접근 가능한 최신 iCloud 진단 로그는170 자료이며 이번172 기기 DB 시간의 근거로 사용하지 않았다. 사용자 DB/원본/백업을 변환·삭제하지 않고 합성 fixture로 측정했다.
- 확인한 원인: snapshot은 영역별 큰 Codable 배열이며, 설정 저장에도 전체 영역 payload를 읽고 SHA-256 검증 후 저장 뒤 다시 읽었다. 외부 연결에서 설정만 바뀌어도 모든 이력을 다시 decode했다. 센서 codec은 각 레코드의 SHA-256 문자열을 만들 때 Foundation 포맷 호출32회를 반복했다. 큰 배열의 한 항목 변경이 전체 재인코딩을 요구하는 구조도 확인했다.
- 변경: 동일 SQLite 연결의 data_version·64bit total_changes와 삭제 generation이 같으면 검증된 snapshot을 재사용한다. 토큰은 SELECT 전에 캡처하고 연결 ID를 포함한다. 외부 변경이 있으면 실제 payload·revision·시각을 다시 검증하되 동일 영역의 decode는 재사용한다. 저장 전 확인·변환·쓰기·실제 행 재검증을 BEGIN IMMEDIATE 안에 묶고 중첩 저장은 savepoint로 rollback을 보존한다. 메모리 압력 후 오래된 읽기가 캐시를 다시 채우지 않는 조건을 유지했다. codec은 기존 소문자 SHA-256 문자열 바이트를 직접 생성하고 각 decode를 autorelease pool로 감쌌으며 plist/LZFSE/envelope/원본·백업 형식은 그대로다. repository_local_save의 읽기·변환·쓰기·검증 시간과 repository_local_load의 실제 읽은 바이트·decode 영역 수를 추가했다. 원본 내용은 새 로그에 넣지 않는다.
- 회귀: 최종 app-tests-final.xcresult138개·Core124개 통과, 실패/건너뜀0. 외부 동일 revision의 원문/Unicode 변경·손상, 외부 영역 삭제, 센서만 변경된 DB, 대기 중 메모리 압력, 트랜잭션/중첩 실패 rollback·별도 SQLite writer 차단, 기존 삭제·복원·센서 원본 계약을 확인했다. 첫 앱/패키지 시도는 CSQLite shim에 새 함수 선언2개가 없어 컴파일 실패했고 테스트는 실행되지 않았다(app-tests.log/core-tests.log). 선언을 보완한 Core123 중간 통과 후 codec 회귀를 추가해 최종124개를 통과했다. 이전 실패를 최종 통과 수에 합산하지 않는다.
- 측정 조건: iPhone18 Pro/iOS27.0 Simulator, Release -O/whole-module/ENABLE_TESTABILITY=YES. repository는 동일12만 건 fixture에서 비교했고 센서는 동일5천 건을 저장한 뒤3회 조회 평균이다. 각 성능 실행은1개 통과·실패/건너뜀0이며 최종 Release2개도 통과했다. 컴파일 대기는 앱 실행 시간에서 제외한다. 최종 repository 측정은 직전 sensor 실행과 동일한 소스/Release 산출물을 재사용했다(release-build-confirmation.json). 단일 실행 및3회 평균의 fixture 수치이며 기기 체감·CPU·배터리·통계적 유의성을 입증하지 않는다.

| 구간 | 수정 전 ms | 수정 후 ms |
| --- | ---: | ---: |
| 설정 저장 | 25.199 | 9.475 |
| 저장 직후 조회 | 6.119 | 0.217 |
| 반복 조회3회 평균 | 5.750 | 0.115 |
| 외부 연결의 설정 변경 뒤 조회 | 889.187 | 6.023 |
| 최초 전체 이력 조회 | 934.609 | 1019.167 |
| 최초 전체 저장 | 1593.857 | 1733.994 |
| 기록 한 건 수정 저장 | 1315.922 | 1140.100 |
| 센서5천 건 저장 | 539.058 | 345.725 |
| 센서5천 건 조회3회 평균 | 291.705 | 177.169 |

- 빌드/일치: generic iOS Debug exit0·BUILD SUCCEEDED. 기존 macOS 개발용 dylib 서명 문제에 사용했던 명령 옵션 ENABLE_DEBUG_DYLIB=NO를 적용했으며 프로젝트 설정은 변경하지 않았다. 앱/Widget1.0(172)·각 strict 서명 exit0·Watch 미포함을 확인했다. 최종 Debug 테스트·Release2개·iOS Debug의 Swift/plist/project/header/modulemap 소스 해시와 현재 파일이 모두 일치하며 Core 최종 소스도 일치한다. import 경계·diff 검사 통과. GPS/분홍 발자국 구현 소스는 이번 작업 시작과 동일하다.
- 남은 한계: 최초 전체 조회·최초 저장의 개선은 입증하지 못했고 이번 측정에서는 더 느렸다. 기록 한 건 수정도1.14초가 남으며 원본이 큰 배열 하나인 구조는 유지했다. 근본적인 날짜/레코드별 부분 저장은 기존 기록·백업의 마이그레이션/rollback 검증을 포함한 후속 범위다. 실제172 기기 DB 시간·화면 지연은 미확인이고 수정본은 commit/push·TestFlight 업로드·실기기 설치하지 않았다. 열린 조건은 temp.md에 유지한다. 근거 build/validation/DBP1006A01/의 metrics.json·각 xcresult/summary·core-tests-final.log·final-build-verification.json·source-comparison.json.

## GPS1006H01 · 오늘 부산 GPS 급이탈 경로 조사·수정 · 2026-10-06
- 시작: main9e1ad9d의 clean 상태에서 진행했다. 사용자가 발생 빌드를1.0(172)로 확인했으며 재생으로 발생 시각을 찾지 못해 원본 조회를 요청했다. iCloud 원본 백업의 헤더·암호문만 읽었고 위치/건강/일정 원문을 출력하거나 외부 전송하지 않았다.
- 확인한 코드 문제: 정지 표본을 생략할 때 마지막 정상 비교 시각도 오래 남아 실제 수집 공백으로 오인하고 새 좌표를 기준으로 잡을 수 있었다. 이상 좌표 뒤 비교 기준을 지워 연속된 도시 급이탈의 두 번째 표본이 새 경로에 들어갔다. 낮은 정확도의 경계 표본은 기존 거리 검사를 우회했다. 초기5개 회귀 중3개 실패·2개 통과(baseline-expanded.log)로 코드의 실패 경로를 재현했다. 이것은 오늘 부산 원본을 직접 확인한 결과가 아니다.
- 수정: 원본 normalized samples/저장 데이터를 유지하고 표시·판정 입력의 시간/거리 검사를 경계 표본에도 적용했다. 거른 표본 뒤에도 마지막 정상 위치를 비교 기준으로 유지하며 정상 GPS 공백 뒤 새 위치는 허용한다. 정지 수집 중 정상 시각을 갱신하고 경로의15분 이하 체크포인트와 마지막 시각을 기존 정지 위치에 남긴다. 정지 끝 시각 회귀의 초기 실패도 stationary-end-baseline.log에 기록했다. 현재 위치 마커는 일자 utility worker의 최신 정상/정지 표본을 사용하고 원본 최신 좌표로 우회하지 않는다. 날짜 projection은 버전1→2, 지도 문서 키는v7→v8로 바꿔 파생 캐시를 다시 만들며 SQLite raw 스키마3·codec·App Group·백업 형식은 유지했다.
- 검증: TaptionRouteEngine45개 통과(route-package-final.log), TaptionPlanCore119개 통과(core-package.log), 실패/건너뜀0. 관련 앱 최종351개 통과·실패/건너뜀0(PAW1006A01/app-tests-verified.xcresult 및 app-tests-verified-summary.json). 앱의 이전 stationary 시도는350개 통과·1개 실패였으며, 정지 끝 표본을 삭제한다는 옛 기대값3곳을 끝 시각 보존·좌표 고정·급이탈 뒤 경로 단절 검증으로 갱신했다. 그 실패를 통과로 처리하지 않았다. 앱/엔진 import 경계도 통과했다.
- 실제 원본 접근 제한: 최신으로 확인한2026-10 원본 백업은V4·1,749,967바이트이며 생성 시각은2026-10-06T19:58:56+09:00이다. 암호화 payload와 wrapped key가 있고 PIN salt/verifier는 백업 헤더에 없다. Mac의 해당 앱 PIN verifier/계정 복구 키와 iCloud 문서 복구 키가 없고 iPhone18은 unavailable였다(raw-access-summary.json). 제공된 PIN 값과 복구 키를 기록하거나 백업을 복호화/복원/변경하지 않았다. 오늘 부산 급이탈의 정확한 표본·시각·장시간 공백/첫 표본 여부와 실제 수정 효과는 직접 대조하지 못했다. 접근 가능한1532 진단 로그는 기존170 조사 자료이므로172 원본 근거로 사용하지 않았다.
- Debug/산출물: 첫 generic iOS Debug는 컴파일·링크 후 TaptionPlan.debug.dylib의 internal error in Code Signing subsystem으로 exit65였다(device-debug.log). 프로젝트 설정은 변경하지 않고 명령에 ENABLE_DEBUG_DYLIB=NO를 적용한 재시도는 exit0·BUILD SUCCEEDED였다(device-debug-no-dylib.log). 앱·Widget 산출물은1.0(172), 각각 codesign --verify --deep --strict exit0이며 Watch 앱은 포함하지 않았다. 최종 앱 테스트와 Debug의 Swift/plist/project 소스 해시는 일치한다(products-build-summary.json). 이 빌드는 설치·TestFlight 업로드 결과가 아니다.
- 현재 제한: 실기기 설치·GPS 위치·체류/재생 화면은 테스트 성공으로 통과 처리하지 않는다. 실제 원본/화면 조건 때문에 temp.md에 남기며, 수정본의 새 TestFlight 업로드·push는 아직 진행하지 않았다. 근거 build/validation/GPS1006H01/ 및 build/validation/PAW1006A01/.

## PAW1006A01 · 분홍 발자국의 기록 시각 선택 · 2026-10-06
- 구현: RouteTimelineSegment의 좌표마다 시각을 연결하고 지도 표시/캐시에도 함께 보존한다. 분홍 발자국은 해당 시각을 사용하며 회색 예상 발자국에는 실제 기록 시각을 부여하지 않는다. 지도 renderer의 단일 탭 시점에 마커를 현재 화면 좌표로 변환해 가까운 분홍 발자국을 고른다. 드래그·다중 탭 확대·길게 누르기와 구분하고 발자국 위에 드래그를 가리는 투명 버튼 영역을 추가하지 않았다.
- 선택 동작: 재생·현재 위치 추적·대기 중인 위치 요청을 멈춘 뒤 선택 날짜의 분/초 시각으로 이동한다. 정지 중에는 선택한 발자국의 정확한 경로 좌표를 표시하며 같은 분 안의 다른 발자국도 각 시각을 유지한다. 시간축 확대 범위 밖이면 선택 시간이 보이게 이동한다. 분홍 발자국에는 시간 접근성 동작을 연결하고 회색 발자국은 제외했다. 입력은 준비된 일자 경로/마커를 사용하며 전체 과거 이력 조회를 추가하지 않았다.
- 검증: 분홍 시작/중간/끝·초 단위 시각·날짜 경계·겹친 회색/분홍·현재 화면의 가까운 대상·잘못된 시각 입력·확대 시간축8개 통과. 전체 관련 앱351개는 XCTest305개(발자국8·RouteTimeline114·SensorDayStore7·TimeScale176)와 Swift Testing46개(경로 adapter19·활동 adapter27)이며 실패/건너뜀0이다. 최종 근거 app-tests-verified-summary.json. 첫 앱 테스트 시도는 helper의 default throwing closure 호출2곳 컴파일 오류로 실행되지 않았고 비투척 overload를 분리한 뒤 다시 검증했다(app-tests.log). 중간 실패/이전 결과와 최종 결과를 구분했다.
- Debug: generic iOS Debug 재시도와 앱·Widget strict 서명 검증이 성공했고 최종 앱 테스트의 소스 해시와 일치한다. 첫 개발용 dylib 서명 실패와 ENABLE_DEBUG_DYLIB=NO 재시도 결과는 위 GPS1006H01 및 products-build-summary.json에 구분했다.
- 현재 제한: iPhone18의 실제 탭/드래그·확대·겹친 발자국·VoiceOver 동작은 아직 검증하지 않았다. 사용자의 기존 실기기 확인 방식을 유지하고 temp.md에 해당 조건을 남긴다. 새 TestFlight 배포·실기기 설치는 진행하지 않았다. 근거 build/validation/PAW1006A01/.

## REL1006C01 · MAP1006G01 main 반영 및 TestFlight172 내부 배포 · 2026-10-06
- 시작: 원격 main과 로컬 HEAD가 4ab5cd3으로 일치하고 MAP1006G01의 검증된 변경 11개가 로컬에 있었다. 사용자의 다음 진행 요청에 따라 해당 변경을 보존해 다음 내부 배포를 진행했다. 실제 API 최신 빌드는171 VALID이고172는 없었다. Chrome 내부 그룹 화면의171 테스트 중·테스터1명·129개 빌드와 로그인 가능 상태를 확인했다.
- 버전/로컬 검증: 프로젝트 CURRENT_PROJECT_VERSION8곳과 앱·Widget·Watch·Watch Widget Info.plist4곳을172로 맞췄다. 원본 short version은 $(MARKETING_VERSION)을 프로젝트1.0으로 해석했다. MAP1006G01 Debug185개·Release3개(각 실패/건너뜀0)의 Swift 소스 해시 일치를 확인해 재사용했다. 새 generic iOS Debug exit0·앱/Widget1.0(172)·strict 서명·기존 HealthKit entitlement 범위·Watch 미포함을 확인했다. 엔진 import 경계와 diff check 통과, 변경 없는366개 집 이미지의 기존 검증을 재사용했다. 근거 build/validation/REL1006C01/prior-validation-reuse.json·prearchive-checks.json·debug-bundles.json.
- 실행 시도 구분: 첫 버전 확인 스크립트가 short version을 literal1.0으로 가정해 중단됐다. 일부 버전 변경 상태로 시작된 본인 Debug 빌드만 취소(exit75, BUILD INTERRUPTED)하고 기록을 보존했다. 프로젝트 변수를 해석하도록 고친 뒤 네 원본/새 Debug 제품의172 일치·exit0을 확인했다. 앱 코드 오류나 테스트 실패로 처리하지 않는다(validation-attempts.json).
- 코드/산출물:17097d473a7be8707c185f37a70d9b653bab7295를 main commit/push하고 실제 원격과 일치를 확인했다. Release archive/export exit0, 실제 -O/WMO·testability 제외 확인, 최종 앱+Widget1.0(172)·Watch 미포함·strict 서명 통과. 앱 binary/dSYM UUID A9FAE675-1C6D-30AC-8EB9-2A83174571F3, Widget797EE070-0F7B-3227-981D-C7BD0E0E940B 각 일치했다. IPA42,209,012bytes·SHA256 0f1b90025bbb754345ef92b71c20983639c08431a04a9fdcc4a4a3886c61e3b6. Debug/archive/export/upload 각 소스138개 해시 일치(final-scope-source-verification.json).
- 업로드/정리: 업로드 직전172 없음·remote main 일치·clean을 재확인하고1회만 업로드했다. altool exit0·UPLOAD SUCCEEDED with no errors·Delivery UUID386b6975-2586-48f1-98b2-92bd662b88d1. Apple BuildUpload는 processing-09.json에서COMPLETE·errors/warnings0, build는172 VALID·INTERNAL_ONLY를 확인했다. 본인 캐시 사용 빌드 프로세스가 없는 것을 확인해 재생성한 build/ArchiveDD1023.53MiB만 제거했다. 기존169~171의9개 배포 파일과 새172의IPA/앱·Widget binary/두dSYM5개, 총14개 크기·SHA256 전후 일치(cache-cleanup.json). archive/IPA/검증·사용자 자료는 보존했다.
- 내부 배포: TP Taption Plan 내부 테스트 그룹(b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd)에172를 연결하고 한국어 테스트 안내를 저장했다. API VALID·INTERNAL_ONLY·IN_BETA_TESTING·그룹 빌드 목록172·테스터1명·안내 원문 일치를 확인했다(deployment-api-summary.json). 실제 Chrome 그룹 화면에서 내부 그룹·테스터1명·130개 빌드·1.0(172) 테스트 중을 읽고 화면을 저장했다(web-group-build172.jpg). 실제 테스터 목록은 테스터(1)·설치됨1.0(171)로172 설치는 미확인이다(web-group-confirmation-final.json). 개인 연락처를 증거 파일에 저장하지 않았다.
- 완료 범위/제한: 배포 조건을 충족한 REL1006C01만 temp.md에서 제거하고 PER1006B01·CPU1006A01·LOG1006A01·PAN0930A01의172 배포 상태를 갱신했다. UNP1006A01의 물음표 수정도172에 유지했다. 새 실기기 설치·지도 드래그/편집·Watch 수신·CPU/최고 메모리 확인은 이번 빌드/배포 성공과 별개이며 계속 미확인으로 남겼다. 최종 기록 commit/push·실제 원격 HEAD 일치·clean은 build/validation/REL1006C01/final-git.json에 별도 저장한다. IAP·공개 App Store 제출은 진행하지 않았다.

## MAP1006G01 · 지도·저장·시작/센서 지연 구조 개선 · 2026-10-06
- 시작: main 4ab5cd3/origin/main 일치·clean에서 사용자가 MAP1006F01의 세 원인·개선책 구현을 요청했다. 기존 171 배포·원본·자료를 보존하고 로컬 코드만 변경했다. 데이터 경로·SQLite 스키마·정본 codec/체크섬·App Group·백업·HealthKit 읽기 범위는 변경하지 않았다.
- 지도: 날짜·source revision·활성 상태에 맞춘 일자 입력을 utility worker에서 준비하고 오래된 결과를 폐기한다. 날짜 데이터가 무효화됐다고 전체 과거 이력으로 돌아가지 않으며 UI 유효성 확인은 revision·날짜·projection version을 비교한다. 활동·재생·속도는 부모가 준비해 카메라 overlay에 전달한다. 경로·속도·요약·시간축의 전체 이력 fallback도 제거했다. 명시적 편집 직후 성장 보상과 지난 날짜 정산은 최신 전체 원본을 유지한다(map-presentation-boundary.json).
- 저장: 확정 snapshot과 실제 저장된 행의 generation·revision·시각·payload SHA-256 정보를 연결한다. 저장 후 조회도 DB 행을 읽고 검증한 뒤 동일 값만 재사용한다. 저장 시 변환 생략에도 실제 DB 행 검증을 적용하여 같은 revision의 외부 바이트 변경·Unicode 차이를 보존하며, 취소·삭제·메모리 압력·로드 실패 보호는 유지한다.
- 시작: pending 복원 journal·잠금·접근 상태를 확인하고 SQLite metadata/settings/categories만 먼저 읽어 지도 shell을 공개한다. 전체 로드 전 일자 preview는 읽기 전용이고 편집·저장을 막는다. legacy·journal·설정 읽기 실패는 기존 전체 로드로 돌아간다. 전체 로드 실패는 기존 덮어쓰기 차단을 유지하며, 늦은 설정이 이미 읽은 정상 이력을 덮어쓰지 않는다. 전체 원본 공개와 기록 정리·센서 준비의 대기를 구분했다.
- 센서: 같은 날짜의 source 변경은 projection만 취소하고 진행 중인 원본 읽기를 공유한다. raw 변경·메모리 압력·전체 무효화·삭제는 원본 읽기도 취소하며, 삭제는 이를 먼저 취소한 뒤 진행 중 작업 종료를 기다린다. 취소된 원본 결과는 완전한 값으로 캐시하지 않는다. Watch replay와 센서 결합/정렬을 utility worker로 옮겼고, 진단에는 source projection 변경·호출 취소·generation 변경·archive 실패를 구분하는 메타데이터만 남긴다. 실제 170 로그의 CancellationError 호출자가 확정됐다는 뜻은 아니다.
- 회귀: 최종 debug-tests-verified.xcresult 185개 통과·0실패·0건너뜀·exit0. 새 회귀 10개는 저장 직후 캐시, 같은 revision의 외부 원문 변경, 설정 읽기 뒤 이력 손상 확인, 전체 이력을 기다리지 않는 시작/부분 편집 차단, 늦은 설정/전체 로드 실패, 524,954건 중 일자 1건 준비, source 변경 중 원본 읽기 공유, 메모리 압력/전체 무효화 취소를 검증한다. 기존 삭제 generation·원본 digest·강제 읽기·동시 날짜·수면/활동·성장·복원/rollback·PIN·잠금·개별 버전 로그도 통과했다. 앞선 150개, 173개 및 계약 11개 실행은 중간 근거이고 최종 통과 수에 중복 합산하지 않는다. 공유 Core source/tests는 4ab5cd3과 같아 변경 없는 package를 다시 테스트하지 않았다(core-boundary-unchanged.json).
- Debug: 첫 generic iOS 빌드는 컴파일 후 debug.dylib의 Code Signing subsystem 내부 오류로 exit65였다(device-debug.log). 같은 서명 설정으로 최종 소스를 재빌드하여 BUILD SUCCEEDED/exit0, 앱·Widget strict 서명 검증 성공·1.0(171)·Watch 미포함을 확인했다(device-debug-final-products.json). 설치·기기 기능 검증은 하지 않았다.
- Release: 첫 실행은 ENABLE_TESTABILITY=YES 누락으로 앱 컴파일 뒤 테스트 모듈 dependency scan에서 exit65였고 테스트는 실행되지 않았다(release-performance.log). 기존 기준과 같은 -O/whole-module/ENABLE_TESTABILITY=YES 및 동일 iPhone18 Pro/iOS27.0 Simulator에서 다시 실행하여 3개 통과·0실패·0건너뜀·exit0을 확인했다(release-performance-testable-summary.json, release-compiler-options.json). Mac 동시 컴파일 부하로 빌드가 오래 걸렸으며 대기 시간은 앱 실행 비용이 아니다.
- 저장 측정: 기존 120,000건 fixture와 시간 측정 구간은 그대로다. 저장 후 첫 조회674.75→8.51ms, 반복3회 평균은 이번7.50ms/이전4.58ms다. 추가 DB 바이트 검증 때문에 settings 저장7.79→20.32ms로12.53ms 증가했고 초기 저장도1614.94ms/이전1259.84ms였다. 이 비용을 숨기거나 모든 저장·조회가 개선됐다고 처리하지 않는다. 개선된 것은 검증 후 저장 값을 즉시 재사용하여 전체 decode를 생략하는 readback이다(performance-baseline-comparability.json, release-metrics.json).
- 시작/지도 측정: 새 repository의 설정만 선조회0.508ms·전체 cold 조회1111.89ms이며 최초 전체 codec 비용의 감소는 입증하지 않았다. 전체 이력을 막은 시작 gate fixture30.57ms로 이력을 기다리지 않았고, construction·잠금/PIN·Pro 검사·실제 UI 렌더는 제외한다. 524,954건 중 날짜 입력1건 준비103.20ms·이후8회 판정1.572ms였다. 동일 Debug의 전용 진단은 전체 입력8회2008.59ms/날짜 입력0.016ms로 같은 활동을 판정한다. 이 진단은 실제 팬/줌 지연이나 fps가 아니다. 시뮬레이터 최고 footprint도 앞선 fixture·allocator·동시 작업의 영향을 받으므로 기기 memory/배터리 개선으로 처리하지 않는다.
- 최종 확인/정리: Debug185·generic Debug·최종 Release의 입력 소스 해시가 모두 현재와 일치하며 import 경계와 git diff --check를 통과했다(source-confirmation.json, core-boundary-unchanged.json). 현재 저장소/캐시를 사용하는 활성 빌드가 없음을 확인한 뒤 이번 재생성 build/ArchiveDD2008.50MiB만 삭제했다. 169·170·171 IPA와170·171 앱/Widget 바이너리·dSYM9개 파일은 정리 전후 바이트 수·SHA-256이 동일하다(cache-cleanup-preflight.json, cache-cleanup.json).
- 완료·제한: 로컬 구현·관련 회귀·Debug·Release fixture 검증이 완료되어 MAP1006G01만 temp에서 제거한다. 현재 TestFlight171에는 이번 변경이 없으며 commit/push·업로드·실기기 설치를 하지 않았다. PER1006B01·LOG1006A01·PAN0930A01·CPU1006A01의 기기 시작 체감·팬/줌·활동 편집·Watch 수신·CPU/최고 메모리 조건은 대표의 새 화면/로그로 판정할 미완료 항목으로 유지한다. 근거 build/validation/MAP1006G01/.

## REL1006B01 · 물음표 위치·개별 버전 로그 TestFlight171 · 2026-10-06
- 준비: 실제 원격 main a05a8fd와 로컬이 일치하고 ASC 최신 170 VALID·INTERNAL_ONLY / 171 미존재를 확인하여 171을 선택했다. project build 설정 8곳과 앱·Widget·보존된 독립 Watch·Watch Widget 원본 Info.plist 4개의 번호를 1.0(171)로 맞췄다. iPhone 제품에는 앱·Widget만 포함한다(source-build-versions.json).
- 검증 재사용: UNP1006A01의 TimeScale 176개, LOG1006D01의 Diagnostics 11개, MAP1006F01의 합성 진단 1개가 각각 실패·건너뜀 0이며 검증 대상 Swift 소스 해시가 현재와 일치하여 188개 통과 근거를 재사용했다. import 경계·git diff --check와 승인된 성장 366개 자산 원본 대조도 통과했다(prior-validation-summary.json, prior-validation-reuse.json, prearchive-checks.json).
- 포함 범위: 미확인 물음표의 겹침 회피 이동 제거·정확한 구간 중앙과 모든 새 진단 이벤트의 app_version/build 기록이다. MAP1006F01의 지도·저장 구조 개선은 분석·개선책과 진단 fixture만 추가했으며 성능 개선 구현을 이번 빌드에 포함한 것으로 처리하지 않는다.
- main 반영: 코드·기존 변경·빌드 171·요청 기록을 0705ceb로 main에 commit/push했다. 당시 HEAD·origin/main·실제 원격 main이 일치하고 워크트리 clean을 확인했다(code-commit.json, code-git-confirmation.json). 배포 기록 후속 commit은 별도다.
- 산출물: generic Debug·Release archive/export 모두 exit 0, 앱·Widget 두 제품 1.0(171)·Watch 미포함·deep strict 서명 통과. 각 archive 실행 파일과 dSYM UUID 일치/해시를 archive-symbols.json에 보존했다. IPA는 42,161,717바이트·SHA-256 4872c75d1b55e0aa358108592c40388639f0c481b8ad9049ef3ebcaeeb6bb13a이며 배포 서명의 get-task-allow=false와 필요한 HealthKit scope를 확인했다. archive 입력 138개 소스가 업로드 직전에도 일치한다(pre-upload-verification.json).
- 업로드·처리: ASC 171 미존재를 다시 확인한 뒤 altool 1회 exit 0 / UPLOAD SUCCEEDED with no errors. 전달 ID·build ID는 494e4f9b-e6dc-433b-b8a8-0d407bd50256. 최초 PROCESSING에서 COMPLETE로 처리됐으며 오류·경고 0, build 171 VALID·INTERNAL_ONLY다(upload-summary.json, processing-01~03.json).
- 내부 배포: TP Taption Plan 내부 테스트 그룹에 연결했고 최종 IN_BETA_TESTING·그룹 목록 171·테스터 1명·한국어 테스트 안내 저장 및 재조회 일치를 API로 확인했다(deployment-api-summary.json). 안내에는 물음표 위치·겹침 선택과 새 이벤트의 app_version 1.0 / build 171 확인을 요청했으며 추가 성능 구현이 포함되지 않았음을 명시했다.
- 실제 웹: Chrome의 해당 그룹에서 내부 그룹·테스터 1명·129개 빌드, 1.0(171) 내부 ‘테스트 중’ 행을 읽었다. 테스터 페이지도 테스터(1)와 설치됨 1.0(170) 표시를 확인했다. 이는 171 설치 확인이 아니며 연락처는 저장하지 않았다(web-group-confirmation-final.json, web-group-build171.jpg).
- 정리: 검증 뒤 이번에 재생성한 build/ArchiveDD 1043.35MiB를 삭제했다. 169·170·171 IPA, 170·171 앱 바이너리와 앱·Widget dSYM 총 9개 파일의 정리 전후 바이트 수·SHA-256이 일치한다. 검증 근거·배포 archive·사용자 원본은 보존했다(cache-cleanup.json).
- 완료·제한: 내부 배포 조건을 충족해 REL1006B01만 temp에서 제거했다. UNP1006A01의 실기기 화면·선택 확인과 기존 성능·Watch·HealthKit 등 미완료 검증은 유지하며 설치·기기 기능 통과로 추정하지 않는다. IAP·공개 심사 보류도 유지한다. 배포 기록 commit/push 뒤 최종 HEAD·원격 main 일치와 clean은 final-git.json에 남긴다. 문서 전용 후속 변경에는 테스트·빌드를 재실행하지 않는다. 근거 build/validation/REL1006B01/.

## UNP1006A01 · 미확인 물음표의 정확한 시간 위치 · 2026-10-06
- 시작: main a05a8fd/origin/main 일치. 기존 LOG1006D01 버전 기록·MAP1006F01 진단 테스트·temp/test 변경을 보존했다. 제공된 이미지는 읽어 확인했으며 원본을 복사·수정하지 않았다(placement-evidence.json의 경로/해시).
- 원인: unconfirmedReviewMarkerCenters의44pt 최소 간격을 만드는 전방/후방 이동과 half-hit-height 상하 clamp가 시간상 중앙과 다른 위치를 만들었다. 구간 중앙을 정수 분으로 나누던 방식도 확대 화면에서 반분 오차를 만들었다.
- 변경: 겹침 회피와 경계 이동을 제거했다. 표시 중인 구간의 start/end 위치 평균을 계산하는 segmentCenterPosition을 구간 막대·물음표 좌표에 함께 사용한다. 따라서 인접하거나 중앙이 같은 물음표도 원래 시간 위치에 유지한다. 미확인 표시 조건·sourceIDs/구간 전달·44pt 터치 영역·날씨 배치·편집/저장 동작은 유지한다.
- 검증: TimeScaleTests176개 통과·0실패·0건너뜀·exit0/xcresult Passed. 기존 간격 강제 테스트를 정확한 좌표 회귀로 바꾸고00:00/24:00 가까운1분 구간,60분 확대창의 경계 clipping과 반분 중앙, 같은 중앙의 겹침 및 입력 순서 독립성3개 회귀를 추가했다. 관련 기존 시간 선택·드래그·확대·실제 미확인 조건/연속 입력 회귀도 통과했다(time-scale-tests-summary.json).
- 빌드: generic iOS Debug BUILD SUCCEEDED/exit0. 검증 시점과 최종 제품/관련 테스트5개 소스 해시가 일치하며 git diff --check 통과. 이전 LOG1006D01 및 MAP1006F01의 소스가 그대로여서 유효한 검증을 재사용했다(source-confirmation.json, prior-validation-reuse.json).
- 정리: 이번 테스트/빌드에서 재생성한 build/ArchiveDD1294.2MiB를 검증 후 삭제했다. 검증 로그/xcresult와 기존169·170 배포 산출물은 보존했으며 배포 파일5개의 바이트 수/SHA-256이 정리 전후 일치했다(cache-cleanup.json).
- 완료/제한: 로컬 구현·단위 좌표/회귀·Debug 완료. 새 커밋/push·배포·설치 또는 실기기 화면 확인은 하지 않았다. 사용자 대표의 배포 후 화면 확인은 temp에 유지한다. 근거 build/validation/UNP1006A01/.
- 배포 후속: REL1006B01에서 1.0(171) 내부 배포·실제 그룹의 빌드/테스터 노출을 확인했다. 실기기 화면과 겹친 물음표 선택은 계속 미확인이다.

## CLN1006F01 · 이번 검증에서 재생성한 빌드 캐시 정리 · 2026-10-06
- LOG1006D01의11개 테스트/generic Debug 및 MAP1006F01의1개 측정이 완료된 뒤 이번에 생성한 build/ArchiveDD1283.87MiB를 정리했다. 글로벌 xcodebuild가 있어 첫 사전 확인에서는 삭제하지 않았으며, 프로세스 cwd/derivedDataPath 메타데이터로 현재 저장소/캐시를 쓰지 않는 것을 확인한 뒤 지정 캐시만 정리했다. 다른 실행의 파일·빌드·기기에는 작업하지 않았다.
- 결과: 지정 경로 없음,169 원본 IPA·170 IPA·170 archive 앱 바이너리와 앱/Widget dSYM5개 파일의 삭제 전후 바이트 수/SHA-256 일치. 새 테스트/Debug 로그·xcresult·진단 요약/측정·사용자 원본 및 배포 archive는 보존했다. 근거 build/validation/CLN1006F01/cleanup.json 및 targeted-build-preflight.json.

## MAP1006F01 · 170 최신 로그·지도 지연 근본 원인 분석 · 2026-10-06
- 시작 상태: main a05a8fd, origin/main과 일치, 워크트리 clean. 사용자도 사용 빌드를1.0(170)으로 확인했다. 지정된 iCloud.com.taption.plan/Documents/TaptionLogs의 최신 파일은 TaptionLogs-20261006-153239.txt(1,383,852바이트)이며 헤더는1.0(170)/iOS27.2다. 과거 이벤트가 섞인 전체 파일을170 실행으로 간주하지 않고 마지막 initial_launch_started인15:29:36부터15:32:39까지의 세션만 분석했다. 원문 로그는 복사하지 않고 비용·개수·오류 타입만 허용한 JSON을 보존했다(latest-log-analysis.json).
- 실기기 비용: 시작 시 actuals524,938건, 내보내기 시524,954건. 로컬 bootstrap2453ms, 첫 decode2358.78ms, initial_launch_ready4328ms. 해당 세션의 전체 DB 조회5회 모두 reused_snapshot=false, decode2166.09~2576.89ms·합계11661.38ms다. 활동 저장4회의 시작/완료 시각 차이는 각7/8/8/7초이고 각 완료와 전체 readback이 일치한다. 이 차이는 초 단위·비동기 logger 시각의 상관관계이며 별도 저장 signpost 측정은 아니다.
- 지도/센서 비용: map_date_load_finished15687ms, snapshot_wait13328ms. day snapshot은 sensor7657ms·전체8875ms이고 route_readings_load_failed의 타입은 CancellationError, 이후 incomplete projection/readings0이다. integration refresh21928ms도 기록됐다. viewport 보고14개 중8개의 최대 callback 간격이130~210ms이고 마커 투영 최고0.04ms, 마커4~7개/경로 좌표0~9개였다. callback 간격에는 종료·애니메이션·정지 구간이 섞이므로 GPU fps나 순수 터치 지연으로 바꾸어 해석하지 않는다. 센서 취소의 호출 원인·메인 actor와GPU 시간 분담·170 최고 메모리는 이 로그만으로 확정하지 않는다.
- 지도 구조 원인: MapHomeView:2463에서 dayProjectionRevision 변경 시 dayDataSnapshot/actualIndex를 비우지만 오늘 날짜 load task key의 raw revision은0이며 dayProjectionRevision을 포함하지 않는다. 추가 날짜 로드 없이 displayedStickmanAction:8064 등이 전체 snapshot으로 돌아간다. viewport overlay:3538/3790/3802는 위치 갱신마다 화랑이 동작 및 appleMapPlayback을 다시 계산한다. MapHomeStickmanActionResolver:332는 캐시 조회 전에 전체 actuals를 filter하고 hasAppleWatchConfirmedSleep:444도 별도 순회를 한다. MapHomeView/LocationPresentation/InteractionPolicy/AppModel/PlanRepository/PlanDayDatabase는 배포 main a05a8fd와 바이트 일치하므로 실제170 경로를 조사한 것이다(source-findings-and-plan.json).
- 저장 구조 원인: saveActivitySectionEdit:3152의 저장 후 전체 repository.load readback이 반복된다. SQLitePlanRepository:1173의 save 후 remember는 loadStamps=nil이며 load:1041의 재사용 조건을 충족하지 못한다. 따라서 기존 PER1006C01의 동일 DB 반복 조회 개선이 저장 뒤 조회에 적용되지 않은 사실을 코드와5회 miss 로그로 확인했다. checksum/세대/외부 저장 검사를 생략하는 수정은 제안하지 않는다.
- 합성 측정: 실제 개수와 같은524,954개(과거524,953개+현재1개)의 Debug Simulator fixture에서 수면 우선 확인+활동 판정8회를5번 반복했다. 같은 시각·동일 입력으로 캐시가 준비된 조건에서도 전체 이력 입력1782.91ms/8회, 필요한 날짜 입력1개는0.01389ms/8회였다. 결과는 모두 동일한.eating이다. 신규 진단 테스트1개 통과·0실패·0건너뜀(action-cost-debug.xcresult, summary/log/source-hashes). 이 값은 합성 CPU 경로의 비용이며 실제 지도 한 프레임·Release·기기 개선 수치가 아니다.
- 개선 순서: (1) 날짜 revision에 맞춘 불변 지도 문서를 비동기로 갱신하고 action/playback/heading/text를 한 번 계산하여 viewport에서는 좌표만 이동, 지도 제스처 중 파생 route 작업 합치기. (2) 저장 트랜잭션의 실제 row stamp/확정 snapshot을 재사용하거나 변경 ID/영역만 검증하여 전체 재decode 제거. (3) 잠금·복원 journal/삭제 generation을 보존하면서 settings/오늘 일자 우선 로드, 나머지 이력은 필요할 때 읽기. (4) 센서 분석을 메인 actor 밖에서 준비하고 batch별 한 번 공개하며 읽기 취소와 수집 재시작 수명 분리. 원본/provenance/SQLite·백업/Unicode·외부 writer/삭제/취소 보호를 유지한다. 카메라만 이동할 때 전체 이력 순회0회, 같은52만 건의 Release·실기기 시작/저장/드래그와 최고 메모리 재측정이 적용 후 기준이다.
- 완료/제한: 요청한 로그·구조 분석 및 구체적 개선책은 완료했다. 성능 개선 구현·새 배포는 하지 않았다. 제품 변경은 별도 LOG1006D01의 버전 기록뿐이다. 추가 성능 구현/실기기 확인은 기존 PER1006B01·LOG1006A01·PAN0930A01의 미완료 조건으로 유지한다. 근거 build/validation/MAP1006F01/.

## LOG1006D01 · 개별 진단 로그에 앱 버전·빌드 포함 · 2026-10-06
- 변경: TaptionPlanDiagnosticsLogger는 생성 시 Bundle.main의 CFBundleShortVersionString/CFBundleVersion을 읽어 보관하고 모든 JSONL 이벤트의 최상위 app_version/build에 기록한다. operation·error·fallback에도 같은 기록 경로가 적용된다. 기존 환경 헤더/개인정보 필터는 유지하며 버전 없는 과거 줄에 현재 버전을 덧씌우지 않는다.
- 검증: DiagnosticsLogSupportTests11개 통과·0실패·0건너뜀, 새 회귀는170→171 혼합 이력과 버전 없는 legacy 줄, 건강 원문 필터 후 버전 보존을 확인했다. generic iOS Debug BUILD SUCCEEDED/exit0. 두 변경 소스의 해시가 검증 당시와 현재 일치한다(diagnostics-tests-summary.json, device-debug.log, source-confirmation.json).
- 실행 확인: Simulator 테스트 호스트의 지정 App Group Diagnostics/iphone.jsonl에서 기본 logger가 app_version1.0/build170을 포함한34개 줄을 쓴 것을 확인했다. 첫 접근 보조 스크립트는 simctl 출력을=> 형식으로 잘못 해석해 경로0개를 읽었으며 tab 형식으로 수정한 최종 근거를 따로 남겼다(runtime-version-proof-final.json). 이는 실기기 결과가 아니다.
- 완료 범위: 로컬 코드·관련 테스트·Debug 및 기본 runtime 버전 기록 확인 완료. 이번 변경을 TestFlight에 배포하거나 실기기에 설치하지 않았다. 배포된170의 과거 로그에는 개별 버전 필드가 없다. 근거 build/validation/LOG1006D01/.
- 배포 후속: REL1006B01에서 1.0(171) 내부 배포를 확인했다. 새 로그의 앱 버전·빌드 기록이 포함되며, 실기기 내보내기 결과는 아직 확인하지 않았다.

## PER1006C01 · 전체 조회 확인·반복 변환 생략 · 2026-10-06
- 시작: main e0695bd 및 실제 원격main 일치. LOG1006A01·CPU1006A01·PER1006B01 로컬 수정과 승인된 정리를 보존했다.
- 변경: 전체 DB 행의 세대·영역명 UTF-8 바이트·revision·시각·payload SHA-256이 마지막 성공 조회와 모두 같을 때만 기존 snapshot 하나를 재사용한다. 최초 조회와 변경된 DB는 기존 정본 decoder로 읽는다. 캐시는 원본 배열을 공유하며 별도 payload 사본을 보관하지 않는다. 메모리 압력·삭제·실패 시 축출과 epoch 보호를 유지한다. repository_local_load는 읽기·해시 검증·decode 시간/개수/바이트 수/재사용 여부만 기록한다.
- Debug: 관련235개 통과·0실패·0건너뜀·xcodebuild exit0, xcresult Passed. 새 회귀는 동일 revision의 Unicode 원문 바이트 변경과 손상, 외부 저장·삭제 및 메모리 압력을 확인한다. 원본/백업/권한/시작 관련 기존 회귀도 포함한다(debug-regression-summary.json).
- 합성 측정: 120,000건 첫 조회1802.33ms·반복3회 평균41.28ms. 첫 조회 구간은 읽기3.70ms·해시4.29ms·decode1790.81ms이고 동일 7,964,883바이트의 반복3회 decode는0.01~0.03ms다. 최초 전체 조회가 빨라졌다는 결과가 아니며, OS 파일 캐시를 비운 콜드 시작/실기기 결과도 아니다. footprint는 Simulator 테스트 호스트 첫 조회187.27MiB·반복159.05MiB의 단일 실행 구간 최고치로 기기 최고 메모리 개선을 입증하지 않는다(debug-load-phase-profile.json).
- Release: 같은120,000건 fixture1개 통과·0실패·0건너뜀·exit0. 첫 조회674.75ms·반복3회 평균4.58ms, 첫 조회 읽기2.08ms·검증2.66ms·decode669.74ms. 반복 decode0.00~0.01ms이며 wire 해시 검증은 계속 수행한다. 첫/반복 구간 최고 footprint154.10/127.60MiB는 단일 Simulator 호스트 결과다. 과거 별도 프로세스 조회와 환경·warm allocator 조건이 같지 않아 최초 조회 개선율을 주장하지 않는다(release-storage-summary.json, release-load-phase-profile.json).
- 완료 범위: 현재 Swift 소스가 Debug235·Release1 통과 소스 해시와 같고 정본 codec은 변경 전과 동일하다. generic iOS Debug170 BUILD SUCCEEDED/exit0·deep strict 서명·앱/Widget1.0(170)·Watch 미포함·HealthKit 최소 scope를 확인했다. Core119 통과 근거의 관련 package3개 소스 해시가 현재와 같아 재사용한다. 이 요청의 구간 확인·동일 조회 반복 변환 생략과 자동 검증은 완료했다. 최초 전체 조회/기기 최고 메모리·시작 체감은 PER1006B01/CPU1006A01/LOG1006A01에 유지하고, 원본169 충돌 스택/dSYM은 CRH1006A01에 유지한다. 근거 build/validation/PER1006C01/source-confirmation.json 및 build/validation/REL1006A01/core-validation-reuse.json·debug-bundles.json.

## REL1006A01 · 시작·반복 계산 성능 수정 TestFlight170 · 2026-10-06
- 준비: ASC 최신169 VALID·INTERNAL_ONLY와 실제 원격main e0695bd를 확인하여170을 선택했다. project build 설정8곳과 앱/Widget/보존된 Watch/Watch Widget 원본 Info.plist4개가 모두1.0(170)이다. iPhone 배포는 Watch 앱 없이 앱/Widget 두 제품만 포함한다.
- 사전 검증: 관련 앱235개 통과, 관련 Core 소스 해시 일치에 따른 기존119개 통과 재사용. 승인된 성장366개 자산 원본 대조와 앱/엔진 import 경계 통과. 현재 Chrome의 실제 내부 그룹 화면169 테스트 중·테스터1명을 확인하여 로그인 접근 가능하다. 새170 빌드/업로드/그룹 연결은 진행 중이다.
- 충돌 확인: Apple 공식 beta feedback API를 다시 조회했고 전체3건은149/44/44이며 다음 페이지도 없다.169의 보고서는 없어 원인·원본 스택은 미확인이다. 연락처·코멘트·원문 건강/위치/일정은 저장하지 않았다(crash-feedback-current-summary.json). 공식 경로 https://developer.apple.com/documentation/appstoreconnectapi/beta-feedback-crash-submissions .
- 배포 산출물: generic Debug·Release archive/export 모두 exit0, 앱/Widget 두 제품1.0(170)·Watch 미포함·deep strict 서명 통과. archive의 앱/Widget dSYM UUID가 각각 실행 파일과 일치하며 archive-symbols.json에 DWARF 해시와 경로를 남겼다. 최종 IPA의 get-task-allow는false, HealthKit 임상 entitlement/목적 key는 없고 필요한 건강 읽기 목적 key는 있다. IPA42,162,135바이트·SHA2560babc09388218107c4f5662e1be1c0eb7be1bf9dab5bb1dbbe38c9e6fa0bd663.
- 검증 헬퍼 수정: 첫 archive 검증은 export 전 개발 서명의 get-task-allow를false로 요구하여 assertion이 실패했다. archive 빌드와 실제 signature 검증은 성공했으며 앱 코드를 바꾸지 않았다. 그 초기 근거는 archive-verification-initial-error.json·archive-preexport-entitlements.plist·archive-preexport-signature.log로 보존했다. 배포 서명 조건을 최종 export IPA에 적용한 수정 헬퍼의 archive/IPA 검증은 모두 통과했다.
- 업로드 전: 최종 소스 해시가 archive 입력과 일치하며, ASC170 미존재를 확인했다. 이후 코드 commit/push·altool 업로드/처리/그룹/API 및 웹 확인 결과를 별도로 추가한다. 실기기 설치·권한 승인·기능 통과는 아직 확인하지 않았다.
- 메인 반영: 코드·기존 승인된 정리·버전 변경을 deda1ba로 main에 commit/push했고 당시 HEAD·origin/main·실제 원격main 일치와 clean을 확인했다(code-commit.json, code-push.log, code-git-confirmation.json).
- 업로드/처리: altool1회 upload exit0·오류0, 전달ID/buildID fd5599b9-c05a-4854-8a36-dcbe0cf834c8. BuildUpload COMPLETE·오류0·경고0, build170 VALID·INTERNAL_ONLY 확인 후 기존 TP Taption Plan 내부 테스트 그룹에 연결했다. 최종 IN_BETA_TESTING·그룹 목록170·테스터1명·한국어 테스트 안내 저장 재조회 일치가 API로 확인됐다(upload-summary.json, processing-05.json, deployment-api-summary.json).
- 실제 웹: Chrome의 해당 그룹에서 내부 그룹·1명의 테스터·128개의 빌드, 1.0(170) 내부 ‘테스트 중’ 행을 확인했다. 테스터 페이지도 테스터(1)와 실제 설치됨1.0(169) 행을 읽었다. 이는170 설치 확인이 아니며 연락처는 저장하지 않았다(web-group-confirmation-final.json, web-group-build170-visible.jpg).
- 완료/제한: 내부 배포 조건을 모두 충족하여 REL1006A01만 temp에서 제거한다. LOG1006A01/CPU1006A01/PER1006B01·Watch/HealthKit·다른 실기기 검증 조건은 유지하며 이번 배포로 기능 통과를 추정하지 않는다. 원본169 크래시 스택/dSYM 미확보와 IAP/공개 심사 보류도 유지한다. 신규170 archive/dSYM은 정확한 UUID와 함께 보존했다. 배포 기록 commit/push 뒤 최종 HEAD/원격main·clean 결과는 final-git.json에 남긴다. 문서 전용 후속 변경에는 앱 테스트/빌드를 재실행하지 않는다.

## CLN1006E01 · 검증 완료 생성 캐시 정리 · 2026-10-06
- 결과: 이번 Debug Simulator7곳475.07MiB·Release Simulator7곳533.81MiB·검증 완료 후 남은 ArchiveDD1407.97MiB, 합계15개 경로/2416.85MiB(약2.36GiB)를 삭제했다. 진행 중인 Release 공용 모듈은 완료 전까지 유지했고 최종 archive의 외부 DD 의존 symlink가 없음을 확인한 뒤 DD 전체를 제거했다.
- 보존: 현재 Swift/plist/project 소스 해시, Debug235/Release1 xcresult·로그, 새170 archive·일치하는 두 dSYM·최종 IPA를 보존했다. 기존169 원본 IPA SHA256도 unchanged다. 다른 프로젝트·저장 원본·기존 보존 심볼은 삭제하지 않았다. 최종 export/서명도 완료됐고 ArchiveDD는 재생성되지 않았다. 앱 동작 코드는 이 정리로 바꾸지 않았으며 정리 후 새 빌드는 하지 않았다.
- 근거: build/validation/CLN1006E01/의 각 삭제 계획·결과 및 verification.json, REL1006A01/archive-symbols.json·final-scope-source-verification.json.

## CLN1006D01 · 남은 빌드 찌꺼기 추가 삭제 · 2026-10-06
- 결과: CLN1006C01 이후 남은 생성 경로45곳/사전 할당량382.23MiB를 추가로 삭제했다. 프로젝트 ArchiveDD·검증 DeviceDD/DerivedData 및 TaptionPlan 이름의 외부 DD 잔여 폴더 전체, 네 패키지 자동 .swiftpm, IDE 자동 xcuserdata, 검증 Python bytecode, 중복/미완성 xcresult를 제거했다. 소스 영역의 .build/.swiftpm/__pycache__/DerivedData 및 임시/객체/UI 상태 파일 잔여는0개다.
- 중복: REL1004A01의 export-unpacked 전체 파일2개와 CPU1006A01/TaptionPlan169-original 실행 파일을 원본 export/TaptionPlan.ipa의 해당 ZIP member와 SHA-256으로 대조한 뒤 삭제했다. 원본 IPA의 해시는 삭제 전후 동일하며 다음 분석에서 같은 바이트를 다시 추출할 수 있다. 원본 IPA가 없는 과거 ipa-readback/export-unpacked 자료는 유일한 원본으로 취급해 보존했다.
- 검증 기록: PER1006B01의 최신 Debug233·Release 저장/활동·저장 baseline·새 프로세스 조회6회 결과와 LOG1006A01 최신 회귀, CPU1006A01 baseline/회귀의 완성된 결과는 유지했다. 중간/미완성 xcresult는 별도 실행 로그/요약이 남아 있음을 확인하고 삭제했으며 미실행/실패/중단을 통과로 처리하지 않았다. 해당 과거 기록의 경로는 실행 당시 근거이며 지금 제거한 항목은 deleted.json에 명시했다.
- 보존/검증: 기존 Git 추적 파일 해시/존재 확인에서 작업 기록 temp/test 외에 변경·누락0, HEAD main e0695bd 유지. 제품/디자인/생성 원본, 원본 배포 IPA·유일 자료·기기 dSYM6개와 기존 수정은 유지했다. ShotGuide·다른 프로젝트 및 공유 전역 경로는 변경하지 않았다. 삭제 경로45곳 부재, git diff --check 통과. 동작 코드 변경이 없어 테스트/빌드를 재실행해 캐시를 만들지 않았다. 현재 전체 디스크 여유17GiB는 동시 작업/APFS 영향도 포함한다.
- 근거: build/validation/CLN1006D01/before.json, deletion-plan.json, archive-duplicate-verification.json, deleted.json, verification.json.

## CLN1006C01 · 재생성 파일·캐시·임시 파일 정리 · 2026-10-06
- 결과: TaptionPlan 소유가 확인된 생성 경로62곳을 삭제했다. Xcode Build/SDK/Module/Compilation 캐시·clean MapLibre checkout 복제본·Swift 패키지4개의 .build·합성 조회 fixture DB/WAL/SHM/lock·임시 xctestrun/미실행 runner·Python bytecode·.DS_Store·IDE UI 상태를 정리했다. 현재 동작 코드는 변경하지 않았다.
- 미리보기: 제품/생성 도구가 입력으로 참조하지 않는 .cat-visual-check 최상위 PNG15개를 삭제했다. 생성 도구가 실제 참조하는 legacy-atlases 원본7개와 집/화랑이 제품 이미지·디자인 원본은 유지했다. .gitignore에 최상위 미리보기 PNG만 추가했으며 legacy 원본이 ignore되지 않는 것을 확인했다.
- 보존: 최신 PER1006B01·CPU1006A01·LOG1006A01 등의 실제 로그/xcresult/요약/명령/소스 해시는 유지했다. 원본 배포 archive/IPA와 실제 사용자 자료·설정·기존 변경은 삭제 대상에서 제외했다. 기기 플랫폼의 기존 dSYM6개는 삭제 전 preserved-symbols로 이동하고 UUID/DWARF 해시 일치를 확인했다. ShotGuide 및 다른 프로젝트/공유 전역 캐시는 변경하지 않았다.
- 검증: 삭제 경로62곳의 부재와 의도한 미리보기15개 외의 기존 Git 추적 파일에 누락/해시 변경이 없음을 확인했다(작업 기록 temp/test와 .gitignore 제외). HEAD main e0695bd 유지, git diff --check 통과. 기존 source/test 변경은 보존했고 실제 미리보기 삭제15개가 Git diff에 남는다. 동작 코드 변경이 없는 파일 정리이므로 테스트/빌드를 다시 실행해 생성물을 만들지 않았다. 기존 검증은 해당 실행 시점의 근거로 유지한다.
- 공간: 삭제 후보의 사전 할당량4.981GiB이며 기기 심볼 이동 보존량을 뺀 추정 삭제량은 4.924GiB다. 현재 df 여유16GiB; 다른 동시 작업/APFS 영향을 포함하는 전체 디스크 차이를 전부 이번 삭제의 성과로 합치지 않는다.
- 근거: build/validation/CLN1006C01/before.json, deletion-plan.json, deleted.json, preserved-symbols.json, verification.json. 기존 캐시 경로·임시 fixture·제품 미리보기가 필요한 후속 작업은 보존된 소스/설정에서 새 요청 ID로 재생성한다.

## PER1006B01 · 남은 시작·저장·반복 갱신 병목 수정 · 2026-10-06
- 범위/보존: main e0695bd의 기존 LOG1006A01·CPU1006A01 수정과 사용자 자료를 유지했다. SQLite 경로·테이블/스키마·현재 binary PropertyList/LZFSE/SHA-256 envelope·백업 암호화/참조·원본 id/source/evidence를 보존했다. ShotGuide·빌드 번호·배포 상태는 변경하지 않았다.
- 저장: 저장 전 전 영역을 변환하던 경로를 항목별 DB revision 조회와 최근 확정 snapshot 하나의 배열 공유 확인으로 줄였다. 같은 revision과 같은 원본 배열일 때만 변환을 생략한다. 새 배열과 작은 settings는 codec의 실제 바이트로 비교하여 값은 같아도 Unicode 원문이 다른 경우를 보존한다. 다른 repository 쓰기·같은 ID/개수의 내용 변경·metadata 단조 증가·잠금 재시도/취소·삭제 generation을 유지한다. 메모리 압력·삭제·로드 실패 때 캐시를 비우며 epoch/revision이 뒤처진 결과로 캐시를 복원하지 않는다. header 조회는 UTF-8 표현이 다른 DB domain을 모두 반환하고 클라이언트는 최대 revision을 사용한다. codec 인코딩은 로컬 autoreleasepool 안에서 수행한다.
- 화면/권한: public refreshPermissions의 동시 요청을 합치고 async 조회 뒤 최신 settings에 변경만 반영한다. 같은 권한/Screen Time/센서 상태를 다시 공개하거나 저장하지 않는다. 조회 중 취소·삭제 generation을 확인한다. 지도 일자 revision이 같으면 fingerprint를 계산하지 않고, 현재 화랑이 활동의 fingerprint는 활성 기록/이동/체류·3분 내 이동 센서·확정 Watch 수면만 사용한다. 활성 원본의 필드 변경과 수동 override/Watch 우선순위를 유지한다.
- 백업: manifest 재시도의 복호화·본문/경로/raw 병합을 PlanManifestBodyPreparation actor로 옮기고 raw 암호문은 한 세대씩 전달한다. 최신 snapshot의 중복 복호화도 제거했다. 각 반환 및 최종 저장 전에 PIN/취소/삭제 fence를 확인하며 원래 세대를 보존한다. utility 우선순위의 기존 재시도/게시 Task에 명시적 self capture를 적용했다. 진단 backup_manifest_prepare는 시간/개수/메인 스레드 여부만 기록한다.
- 최종 Debug: debug-decoder xcresult Passed/exit0, 관련 앱233개 통과·0실패·0건너뜀. SQLite30·화랑이40·백업/복원136·센서6·일자2·캐시4·관련 모델15개다. 변경 없는 권한의 연속/동시 갱신은 snapshot revision과 저장 횟수를 늘리지 않았고, 백업 병합의 worker_main_thread:false와 양 기기 원본/재실행 결과를 확인했다. 공유 TaptionPlanCore119개 통과·0실패·0건너뜀/exit0(core-tests-decoder); 정본 변환/체크섬·취소 rollback과 UTF-8 표현이 다른 domain의 header 두 행 보존 포함. 최종 Swift source15개와 package3개의 해시가 실행 당시와 일치한다(validation-summary.json sourceConfirmation).
- 수정 전 Release: 같은 생성 규칙의 합성 실제 기록120,000개에서 최초 저장2155.67ms·설정만 저장2045.81ms·로드1465.77ms. 물리 footprint 10ms sampling의 구간 최고치는 각각193.10/161.86/152.50MiB다. 단일 case1통과·0실패·0건너뜀/exit0(storage-baseline). UUID는 프로세스별로 다시 생성하며 위치·건강·일정 원문을 사용하지 않았다.
- 중간 오류: 최초 Debug는 actor isolation과 async cache clear 컴파일 오류2건으로 exit65/테스트 미실행이었다. 이를 수정했다. 검증 runner의 이름 분기 오류로 Core 재검증에 xcodebuild가 잘못 선택되어 공유 build.db 잠금 오류가 났다. 해당 요청의 중복 xcodebuild만 SIGINT로 중단(exit75), runner를 고치고 Core와 앱을 올바른 명령으로 재실행했다. 실패/중단 결과를 통과에 합치지 않으며 기존 로그/결과를 유지한다(core-tests-final-dispatch-correction.txt, debug-delivery, debug-regression).
- 최종 Release: 합성 실제 기록120,000개의 최초 저장2125.23ms·설정 저장23.81ms·로드2663.11ms, 구간 최고 footprint173.19/79.89/162.72MiB다(release-storage-decoder, case1통과/0실패/0건너뜀/exit0). 설정만 저장은 수정 전2045.81→23.81ms로 약98.8% 줄었다. 전체 조회는1465.77→2663.11ms로 더 느리게 측정되어 개선 성과로 처리하지 않는다. 이 측정은 최초/설정 저장 뒤 같은 프로세스의 조회이며, 생략된 변환 때문에 allocator 준비 상태도 같지 않다. 조회 codec의 추가 autoreleasepool은 보수적으로 철회했고 원래 decoder를 유지했다. 중간 pool 적용 측정도 지우지 않았다(release-storage-accepted/repeat). 전체 콜드 조회의 원인/성능과 실기기 최고 메모리 개선은 미완료다. 물리 footprint는 Simulator 테스트 호스트를10ms 간격으로 읽은 단일 실행 최고치(MiB)로, 전체 앱/기기 peak·배터리 개선의 증거가 아니다.
- 별도 조회 비교: 같은 합성120,000건 DB를 검증 폴더에 보존한 뒤 새 테스트 호스트에서 정본 행을 원래 필드 순서로 decode하는 참조 경로3회와 현재 repository3회를 번갈아 실행했다. 준비1회·조회6회 모두 case1통과/0실패/0건너뜀/exit0(fresh2-read-prepare, fresh2-read-1~6). 참조1533.15/1493.09/1557.85ms(중앙1533.15), 현재1715.28/1567.79/1650.03ms(중앙1650.03)다. 새 프로세스에서는 앞의2663.11ms가 재현되지 않았지만 현재 경로가 참조보다 빠르지도 않아 전체 조회 개선으로 처리하지 않는다. repository 초기화 포함·OS 파일 캐시 미축출이며, 참조는 정본 decode 경로이고 수정 전 전체 앱의 불변 빌드와 동등한 비교가 아니다. 구간 최고 footprint 참조129.55~146.33/현재131.33~144.74MiB는 실기기 peak의 증거가 아니다. 측정용 helper와 환경 분기는 테스트 target에만 잠시 추가했으며 최종 테스트 소스는 원래 Debug233 통과 때의 해시로 복원했다. 현재 앱·공유 production 소스11개는 측정 빌드와 모두 일치한다(fresh2-read-results.json, validation-summary.json).
- 추가 측정 환경 오류: 첫 준비 DB를 Simulator 임시 폴더에 둔 경우 다음 호스트 실행에서 파일이 없어 assertion/SQLite14로 실패했다. 해당 요청의 비교 드라이버만 SIGINT 후 SIGTERM으로 종료(exit-15), 미완성 xcresult와 로그를 유지했으며 통과/성능 결과에 합치지 않았다(fresh-read-1-reference). 저장 위치를 검증 폴더로 변경한 재실행은 위6회 모두 통과했다. 도중 셸 here-document의 no space left on device와 여유101MiB를 확인했으며, 프로젝트/기존 자료 삭제 없이 이후 여유4.4GiB를 확인했다. 저장 공간 사용 주체나 회복 원인은 단정하지 않는다.
- 최종 화랑이 Release: 활성1개+과거120,000개를 포함한120,001개 입력20회에서 활동 판정 평균6.79ms, 비활성 이력과 같은 ID의 활성 필드 변경을 함께 검증했다(release-action, case1통과/0실패/0건너뜀/exit0). 과거와 같은 개수/ID만으로 캐시를 재사용하지 않는다. 수정 전 활동 캐시의 동등한 측정값은 없으므로 개선율을 주장하지 않는다.
- iOS 산출물: generic iOS Debug BUILD SUCCEEDED/exit0, deep/strict codesign0. 앱 com.taption.plan·iPhone Widget com.taption.plan.widget 모두1.0(169), Watch 임베딩 없음. 원본 네 Info.plist와 CURRENT_PROJECT_VERSION8곳도169다. import 경계·git diff --check 통과. final Debug/Core/Release/device Swift source 해시가 모두 현재와 일치한다. 이번 최종 로그의 자체 compiler warning은 없지만 SDK의 과거 경고가 해소됐다고 처리하지 않는다(device-debug, device-products.json, source-versions.json, import-boundary-final.log, validation-summary.json).
- 제한: 실기기169 보고서의 CPU 평균89%·최고1519.53MB, iPhone11/18 전체 시작/Watch 도착 속도/배터리 개선은 이 합성 측정으로 입증하지 않는다. 최초 저장·전체 변경·로드는 현재 codec을 계속 사용한다. 원본169 dSYM 부재와 전체 상위 스택의 미확정도 유지한다. 새 TestFlight 업로드·실기기 설치/기능 판정·commit/push는 수행하지 않았다. 기존 SecurityBackupCore self capture 경고2곳은 수정했으며 외부 SDK의 StoreKitTest 경고는 SDK 소스를 변경해 숨기지 않는다. autoreleasepool 근거: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html .

## CPU1006A01 · TestFlight169 CPU 보고서·날짜별 계산 범위 · 2026-10-06
- 기기 근거: 사용자가 제공한 incident6A46C99F-E8C1-4A14-AC67-B5A02D5F5514는1.0(169), iPhone19,7/iOS27.2(24B5089g), 10:09:14~10:10:55의 cpu usage 보고서다. CPU90초/101.13초·평균89%, footprint386.59→601.27MB·최고1519.53MB를 기록했다. Action taken:none이며 해당 보고서만으로 충돌/강제 종료를 확인하지 않는다. 계정/cohort와 원문 위치·건강·일정은 별도 저장/전송하지 않았다(report-summary.json).
- 원본 대조: 기존 REL1004A01 IPA의 앱 실행 파일 한 개만 새 요청 폴더로 추출했으며 UUID4E01A777-C424-333A-9F5E-DFF959E76386가 보고서와 일치한다. 현재 Debug UUID는 달라 대체 심볼로 사용하지 않았다. 배포 바이너리의 정의 함수명은 제거되어 atos는 주소만 반환했고, 저장소 범위의 UUID 메타데이터 조회에도 dSYM이 없다. App Store Connect 읽기 API는 includesSymbols:true·dSYMUrl:null을 반환했다. 원래 archive/dSYM 경로의 부재와 API 한계를 유지한다(original-nm.txt, asc-symbol-metadata.json).
- 확인한 호출: 보고서 offset11231508/11231568/11231628의 직전 원본 명령은0x100cce76c를 호출하며 import table의 Foundation.localizedCaseInsensitiveContains와 일치한다. 해당 세 검색의 상수는 수면/취침/sleep이다. 소스의 AutomaticRecordTimelineEngine.isSleep와 대조했고, 날짜와 무관한 제목부터 검사하던 DayPhaseEngine 및 MapHomeSleepLocationPolicy를 확인했다. 원본 dSYM이 없어 상위 caller 함수명/소스 줄과 모든 CPU·메모리 원인을 확정한 것은 아니다(sleep-search.asm, phase-caller.asm).
- 수정: 하루 앞뒤35분의 근거 범위에 걸친 actuals/travel/stays만 제목 분류·장소 그룹에 전달한다. 수면 위치는 날짜/cutoff 교집합을 먼저 계산한다. 제목/수면/운동 판정 규칙, 자정 경계·미종료 기록·출퇴근 근거, 원본 id/source/evidence와 SQLite/백업 포맷을 바꾸지 않았다. LOG1006A01의 시작 화면 분리 수정도 보존했다.
- Debug 합성 비교: 동일한120,004개 기록 fixture의 하루 요약691.94→38.80ms, 수면 위치479.27→33.14ms. 과거 기록을 뺀 기준 출력과 일치하고 원본은 유지됐다. 수정 전 비교1개 통과와 수정 후 관련31개 통과·0실패·0건너뜀, 각각 xcresult Passed/exit0. 기존 simulator를 사용했으며 실기기 시작 시간/CPU 평균/peak memory나 Release 성능 수치가 아니다(projection-baseline-summary.json, projection-regression-summary.json, debug-fixture-metrics.json).
- Debug 빌드: generic iOS BUILD SUCCEEDED/exit0, deep/strict codesign0. 앱·iPhone Widget은1.0(169), Watch 임베딩 없음. import 경계 검증 성공. 새 TestFlight 업로드·commit/push·실기기 설치는 수행하지 않았다(debug-build.log, debug-products.json).
- Release 합성 비교: 같은120,004개 fixture의 하루 요약507.68→12.50ms, 수면 위치394.52→4.01ms. 비교 전1개·수정 후17개 모두 통과·0실패·0건너뜀, xcresult Passed/exit0. 비교 전에는 이 요청의 두 core 파일만 검증된 HEAD 원문으로 잠시 교체하고 finally에서 수정본을 복원했으며, 기존 LOG 수정과 기타 사용자 자료는 유지했다. 최종 앱/UI/모델/테스트6개 파일의 해시는 Debug 회귀 당시와 모두 일치한다. Release 최적화 설정의 Simulator 계산1회이며 실제 기기/전체 시작/CPU 평균/peak memory 측정이 아니다(release-fixture-metrics.json, release-baseline-summary.json, release-regression-summary.json, release-source-restore.json, final-source-confirmation.json).
- 경고/제한: Release 재컴파일에서 기존 SecurityBackupCore의 self 캡처 경고2곳과 StoreKitTest SDK의 deprecated SKPaymentTransactionState 경고가 남았다. 수정본의 기기 CPU/메모리/시작 체감과 일치하는 원본 dSYM에 의한 전체 스택 대조는 미검증이므로 temp에 유지한다. 저장/JSON 경로 등 나머지 비용과 보고서의 메모리 최고치를 전부 해결했다고 판단하지 않는다. 근거 build/validation/CPU1006A01/.

## LOG1006A01 · 시작 화면 지연 분리 · 2026-10-06
- 확인 범위: main e0695bd에서 시작했으며 사용자가 지연을 Taption Plan 시작 로딩 화면으로 특정했다. Mac의 지정 iCloud TaptionLogs 폴더는 TaptionLogs-20260930-234421.txt(1,689,504bytes, 환경1.0/163)가 최신이다. 현재169의 새 로그로 취급하지 않았다. iPhone11의 앱/공유 그룹 Diagnostics 폴더를 각각 한 번 제한 조회했으나 CoreDevice.ActionError3으로 읽지 못했다. 원본 건강·위치·일정/PIN을 출력·복사·외부 전송하지 않았다(log-access-summary.json).
- 변경: 복원 journal 확인·로컬 로드·잠금 준비는 유지한다. sceneBecameActive는 로컬 데이터 준비까지만 기다리고 bootstrap은 기록 정리·저장 완료를 계속 기다린다. 정리 worker의 snapshot revision/취소/삭제 generation 확인을 유지하고 최신 결과만 반영하며 메인 actor에서 같은 보정을 반복하지 않는다. 지도 shell을 먼저 준비하고 정리가 끝난 뒤 첫 날짜 데이터를 조회한다. 권한/Live Activity와 진행률 완료 애니메이션 대기를 화면 진입에서 분리했다. initial_launch_ready 및 bootstrap_local_snapshot/bootstrap_preparation 시간 필드만 진단에 추가했다. SQLite 경로·스키마·백업·센서 provenance·HealthKit 범위와 집 자산을 변경하지 않았다.
- 수정 전 재현: 저장 첫 회를 continuation으로 막은 fixture에서 초기 scene이 반환되지 않아 1초 기대가 실패했고, 저장 release 전 준비false였다. 단일 case1실패·assertion2실패가 로그에 기록됐다. 그 뒤 Xcode가 결과 bundle을 수 분간 마무리하지 않아 해당 요청의 baseline 프로세스만 중단/종료했다(exit143). baseline xcresult는 Info.plist가 없는 미완성 상태이며 유효한 xcresult 결과로 주장하지 않는다(startup-baseline.log, baseline-run-status.json). 다른 실행과 자료는 종료/삭제하지 않았다.
- 수정 후: 기존 iOS27.0/iPhone18Pro Simulator로 관련 앱30개 통과·0실패·0건너뜀, xcodebuild exit0, xcresult Passed. 저장 지연 fixture에서 초기 scene 준비4ms·release 전 준비true이고, bootstrap은 release를 계속 기다렸다. 이 수치는 AppModel 생성·화면 렌더·실기기/네트워크를 제외한 sceneBecameActive 준비이며 전체 시작 시간/개선율을 뜻하지 않는다. 추가 회귀는 사용자 보정 및 원본 id/source/evidence·자동 분류 잠금·저장 일치, 로드 실패/복구, commerce/PIN 잠금, 복원 journal와 동시 편집 보존, 날짜 task, 진단 redaction/export를 확인했다(startup-regression-final-summary.json, final-test-source-hashes.json).
- 빌드: generic iOS Debug exit0 / BUILD SUCCEEDED, deep/strict codesign exit0. 앱·iPhone Widget 산출물은1.0(169), Watch 임베딩 없음. 엔진 import 경계 통과, 신규 compiler warning은 해당 incremental 검증 로그에 없었다. 코드 버전 변경·commit/push·TestFlight 업로드·실기기 설치는 수행하지 않았다(debug-build.log, debug-signature-confirmed.log, debug-products.json).
- 제한: 이후 사용자가 제공한 실제169 CPU 보고서는 CPU1006A01에서 별도로 대조·수정했다. 수정본의 iPhone11/18 시작 화면/기록 표시·Watch 도착 속도·기기 성능 개선은 미확인이다. 로컬 수정·자동 검증 결과를 실기기 통과로 처리하지 않고 LOG1006A01을 temp에 유지한다. 근거 build/validation/LOG1006A01/validation-summary.json. 기존30개 전 실행의27개 통과 결과와 baseline 로그도 덮어쓰지 않았다.

## CRH1006A01 · TestFlight169 충돌 상세 접근 · 2026-10-06
- 실제 관찰: TP 내부 그룹169 행에 세션1·충돌1이 표시됐다. App Store Connect 충돌 피드백 목록은149(9월20일)와44(8월8일) 두 건만 표시하며169 제출 보고서는 보이지 않았다. 연락처·개인 코멘트는 출력/기록하지 않고 날짜·빌드·기기 메타데이터만 확인했다. 충돌 집계 수치와 제출 피드백을 동일하게 취급하지 않는다.
- 로컬 심볼 확인 제한: 기록에 연결된169 archive 앱/dSYM 경로가 현재 존재하지 않아 dwarfdump 조회와 UUID 대조 시도가 실패했다. IPA는 존재하지만 export-unpacked 앱 경로도 없다. 제거/이동 원인과 주체는 미확인이다. 과거 서명/업로드 검증을 취소하거나 현재 심볼 준비가 됐다고 간주하지 않는다. 이번 작업에서 산출물을 삭제·이동하거나 대체 archive를 만들지 않았다(symbolication-artifact-check.json).
- 원본 진단 시도: Apple 공식 안내에 따라 Xcode Organizer의 TaptionPlan(com.taption.plan)→Crashes를 열었다. Error Downloading Crashes List / A developer account is required for downloading crashes list. 오류로 원본 보고서를 받지 못했다. Apple Accounts 설정의 Sign In… 화면을 준비했고 직접 로그인을 요청했다. 계정 추가/인증 입력은 수행하지 않았다.
- 제한:169 충돌 스택·발생 시각·원인·HealthKit 연관성은 미확인이다. 추측 수정이나 새 빌드·업로드·설치를 하지 않았으며 CRH1006A01을 temp에 유지한다. WHK1004A01/HKS1004A01 실기기 건강 권한·수신도 미검증이다.
- 근거: build/validation/CRH1006A01/web-crash-feedback-summary.json, xcode-access-status.json. 공식 진단 경로: https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs 와 https://help.apple.com/xcode/mac/current/en.lproj/dev861f46ea8.html .


## WEB1006A01 · TestFlight 실제 그룹 화면 확인 · 2026-10-06
- 결과: 로그인된 기존 Chrome 탭에서 Taption Plan의 TP Taption Plan 내부 테스트 그룹을 직접 확인했다. 그룹 헤더는 내부 그룹·테스터1명·127개 빌드, 빌드 탭은1.0(169) 내부·테스트 중을 표시하고 링크 ID90924a58-f2b2-42dc-a15a-62ea4adde888가 배포 근거와 일치했다. 같은 화면에서168과167도 테스트 중이다.
- 테스터: 실제 테스터 탭은 테스터(1), 설치됨1.0(169)·2026년10월4일을 표시했다. 이번 작업에서 새 설치를 실행한 결과가 아니며 건강 권한 승인/Watch 데이터 수신·기능/성능 통과로 처리하지 않는다. 테스터 연락처는 파일/문서에 기록하지 않았다.
- API: 169 VALID·INTERNAL_ONLY·IN_BETA_TESTING, 기존 그룹 목록169·테스터1명을 최신 조회로 다시 확인했다. 기존 재업로드/새 빌드/그룹 변경은 하지 않았다.
- 완료: WEB1006A01 및 REL1004A01의 실제 웹 그룹 조건을 충족했다. 이전 REL1003A01도 동일 그룹의168 테스트 중·테스터 노출을 확인하여 남은 웹 조건을 충족했다. 이 세 항목만 temp에서 제거하고 WHK1004A01/HKS1004A01과 다른 실제 기기 검증 대기는 유지한다. 문서만 변경하여 앱 테스트/빌드는 실행하지 않았다.
- 관찰: 그룹169 행의 세션1·충돌1 표시는 실제 화면 값이다. 원인이나 HealthKit 연관성은 이 화면만으로 판정할 수 없어 충돌 상세를 별도로 확인한다.
- 근거: build/validation/WEB1006A01/web-group-confirmation.json, api-summary.json, build-current.json, group-builds-current.json, testers-current.json. 시작 HEAD/원격main f6ea922 일치·clean이었다.


## REL1004A01 · HealthKit 최소 범위·Watch 앱 제외 TestFlight169 · 2026-10-04
- 시작: main HEAD/origin/main/실제 원격 a4d1910 일치. 기존 집 흰색50% 육각형 배경과 WHK1004A01·HKS1004A01 변경/기록을 보존하여 새 배포를 진행한다.
- 버전: ASC 최신168 VALID를 확인하여169 선택. project build 설정8개 및 앱·Widget·보존된 Watch·Watch Widget 원본 Info.plist4개 모두169. 현재 사용자의 Watch 앱 제외 지시에 따라 iPhone 최종 배포 산출물은 앱/Widget 두 개, Watch 디렉터리 없음으로 검증한다.
- 현재 검증: HKS1004A01 검증 대상8개 소스 hash 모두 동일하여 Core117통과/0실패/0건너뜀 재사용. 신규 iOS generic Debug169 성공, 앱/Widget1.0(169)·Watch 미포함 확인. 성장366자산 원본 대조·import 경계·diff 검사 통과. Simulator runtime/device0 유지, 앱 XCTest·건강 권한/실제 Watch 수신은 미검증이다. 이후 Release·업로드·처리·기존 그룹/웹 확인 결과를 추가한다.
- 코드: 1fe06ab89a8eef6d2631730c3a4fc491adf7437b main commit/push 성공. archive 시작 직전 clean, 저장한 소스/설정1,075개 hash는 archive 후에도 동일하다.
- Release: archive/export 성공, archive 및 IPA deep strict 서명 검증 성공. 앱/Widget 두 번들1.0(169), Watch 폴더 없음, 최종 임상 health-records entitlement 및 임상 목적 key 없음. 기존 SecurityBackupCore 캡처 경고2곳은 유지한다. IPA42,072,768바이트, SHA2564608fb21b882d6c61078606a9fbe25998c24714396d6df8e5d1be033a423e543.
- 업로드: 직전 ASC에169 미존재 확인 후 altool1회 업로드 성공·exit0. 전달ID90924a58-f2b2-42dc-a15a-62ea4adde888. 첫 BuildUpload 조회는 PROCESSING·오류0·경고0. 재업로드하지 않는다.
- 내부 배포: BuildUpload COMPLETE·오류0·경고0, build169 VALID·INTERNAL_ONLY 확인 후 기존 TP Taption Plan 내부 테스트 그룹에 연결했다. 최종 IN_BETA_TESTING, 그룹 목록169, 테스터1명, 한국어 안내 재조회 저장 일치 확인(deployment-api-summary.json, build-final.json, group-builds.json, testers-final-summary.json, beta-test-notes-final.json).
- 웹 제한: Chrome5331254에서 App Store Connect 실제 상세 URL은 Apple 계정 이메일/전화번호 로그인 화면으로 이동했다. 사용자 직접 인증을 요청했고 최종 재확인에서도 같은 화면이다. 실제 그룹의 빌드·테스터 노출은 아직 확인하지 못하여 REL1004A01은 temp에 유지한다. API 확인을 웹 화면 확인으로 대체하지 않는다(web-confirmation-pending.json).
- 실기기/범위: 이 배포에서는 새 기기 설치/건강 권한 승인/Watch 수신 속도를 확인하지 않았다. WHK1004A01·HKS1004A01 실제 기기 조건과 기존 미완료 항목, IAP/공개 심사 제출 보류를 유지한다. 기록 commit/push 후 HEAD·origin/main·실제 원격 main 일치와 clean은 final-git.json으로 확인한다.
- 근거: build/validation/REL1004A01/builds-before.json, validation-reuse.json, source-build-versions.json, ios-debug.log, debug-bundles.json, artwork-check.log, import-boundary.log.


## HKS1004A01 · HealthKit 최소 읽기·수집 범위 · 2026-10-04
- 결과: TaptionHealthReadScope를 운동·수면·심박·걸음·걷기/달리기 거리·자전거 거리·활동 에너지·운동 경로의8개로 제한했다. HealthKit 권한 요청·observer·전체/증분 원본 import가 같은 allowlist를 사용한다. 영양·투약·임상·시력·혈당·월경·특성·활동 요약 신규 수집/시력 별도 권한 요청과 마음챙김 직접 조회는 하지 않는다. 전체 타입 카탈로그와 기존 저장 원본은 삭제하지 않아 과거 기록/백업 해석은 유지한다.
- 목적: NSHealthShareUsageDescription에 운동/수면 시간표 표시 및 심박/걸음/거리/에너지/운동 경로로 활동 기록·이동 지도를 보완한다는 실제 목적을 적었다. toShare는 계속 빈 집합이다. NSHealthUpdateUsageDescription은 읽기 전용이며 건강 기록을 저장/수정하지 않는다는 문구로 변경했다. 임상 사용 목적 key와 Debug/Release health-records entitlement는 제거했고 최종 서명 entitlement에도 없음을 확인했다.
- 앱 열기: WHK1004A01의 immediate 조회에서15분 broad cache를 우회하여8개 허용 유형을 즉시 증분 조회한다. 별도 Watch 앱은 포함하지 않으며 실제 Watch→iPhone 동기화는 Apple 관리 범위다.
- 검증: 허용 범위·불필요한 민감 기록 배제 신규2개 포함 Core117통과/0실패/0건너뜀. scope-audit8종 모두 카탈로그와 일치, 임상/투약/문서/특성/활동 요약 import 호출 제거·시력 권한 함수 제거 확인. import 경계·plist lint·diff check 통과. 최종 generic iOS Debug 성공(debug-build-confirmed.log), 앱/Widget1.0(168), Watch 미포함, deep strict 서명 성공. 초기 debug-build.log은 새 Core 타입의 import 누락으로 컴파일 실패했고 명시적 import 추가 후 성공했다. 실패 기록은 유지한다.
- 제한: iOS 앱 XCTest는 Simulator runtime/device0으로 미실행이다. 실제 권한 화면·Watch 수신·속도·심사 통과는 검증하지 않았다. 기존 승인 범위는 iOS 건강 앱에 남을 수 있으나 앱의 신규 조회는8개 유형으로 제한된다. 심사 제출/건강 권한 초기화·기기 설치·commit/push/TestFlight 업로드는 수행하지 않았다. 현재 내부 TestFlight168은 이번 변경을 포함하지 않는다.
- 근거: build/validation/HKS1004A01/core-tests.log, scope-audit.json, debug-build-confirmed.log, import-boundary.log, bundle-verification.json, signed-entitlements.plist, signature-verification.log, source-hashes.json. 권한 목적 문구 기준: https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data .


## WHK1004A01 · Watch 앱 없이 iPhone HealthKit 수신 · 2026-10-04
- 결과: iPhone target에서 Watch 앱 embed phase와 target dependency를 해제했다. 기존 Watch 소스/독립 target, SQLite·App Group·센서 provenance와 legacy 수신 호환 코드는 보존했다. 새 배포 제품은 iPhone 앱과 iPhone Widget이며 Watch 앱 설치·메시지 응답은 건강 조회 조건이 아니다.
- 활성화: bootstrap 후 앱 foreground 진입과 잠금 해제에서 즉시 별도 HealthKit 조회 task를 시작한다. WCSession 활성화 후 페어링 상태만 초기 권한 요청 조건으로 사용한다. 건강 연결이 켜져 있으면 Watch 미페어링 상태에서도 이미 iPhone에 저장된 건강 데이터를 조회한다. task 중복/잠금 상태를 차단하고 기존 느린 통합 조회의 중복 건강 pass를 생략했다. 승인 후 즉시 조회하고 전체 이력 동기화·observer·기존 주기 갱신은 유지한다.
- UI/제어: 설정과 지도에서 Watch 앱 설치, 실시간 Watch 센서 수신, 1/5/15분 가져오기 간격·legacy receipt 표시를 제거했다. 수동 가져오기도 HealthKit을 조회한다. iPhone 운동 시작/종료에서 별도 Watch 운동 앱 기동 명령을 제거했다. 기존 집 marker 흰색 50% 육각형 배경 두 경로는 보존했다.
- 검증: 초기 페어링 권한 요청·명시적 건강 끄기 후 재요청 방지·미페어링 시 기존 건강 조회·미페어링 첫 실행 네 정책 테스트 통과. macOS TaptionPlanCore 전체115통과/0실패/0건너뜀(신규4 포함). package import 경계와 git diff --check, pbxproj lint 통과.
- 빌드: 최초 기존 build/ArchiveDD 실행은 이전 정리로 MapLibre XCFramework cache가 없어 실패했다(debug-build.log). 요청 전용 DeviceDD에서 고정 패키지를 정상 해석·다운로드하여 재실행했고 최종 debug-build-map-confirmed.log에서 generic iOS Debug 성공. 최종 앱/Widget1.0(168), app/Watch 디렉터리 없음, deep strict codesign 검증 성공. Watch 소스 변경이 없어 Watch 빌드는 실행하지 않았다. Simulator runtime/device를 설치·생성하지 않았다.
- 제한: iOS 앱 XCTest는 사용자의 Simulator 정리 이후 runtime/device0으로 실행하지 않았다. Core 테스트·Debug 성공은 실제 Watch 건강 읽기 승인을 받은 데이터 수신이나 소요시간 검증이 아니다. Watch→iPhone 건강 동기화는 Apple이 관리하며 HealthKit은 읽기 거절 여부를 앱에 공개하지 않는다. 권한 요청 완료를 모든 데이터 유형 읽기 승인으로 해석하지 않는다. 실제 페어링/권한/수신은 WHK1004A01 temp에 유지한다. WCH1003A01 기존 companion 경로 검증은 요구 변경으로 구분하고 기존 속도 미검증은 유지한다.
- 배포: commit/push/TestFlight 업로드·기기 설치 없음. 현재 배포168에는 이 변경이 아직 없고 로컬 Debug168만 새 소스를 포함한다. ShotGuide와 기존 Release/IPA/디자인 자료는 변경하지 않았다.
- 근거: build/validation/WHK1004A01/validation-summary.json, policy-tests.log, core-regression.log, import-boundary.log, debug-build-map-confirmed.log, bundle-verification.json, debug-signature.log, source-hashes.json, simulator-devices.json, simulator-runtimes.json. Apple 공식 문서: https://developer.apple.com/documentation/watchconnectivity/wcsession/ispaired 및 https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data .


## SIM1003D01 · TaptionPlan 시뮬레이터 파일 정리 (2026-10-03)

- 결과: 삭제 대상165개 경로·추정 할당 크기4,275,453,952바이트(3.982GiB)를 삭제했고 실행 오류0·대상 잔여0이다. 시뮬레이터 앱/Watch 제품·중간 산출물·module map/stat cache, simulator 전용 WDT0930Tests 출력, 시뮬레이터 빌드에 사용한 프로젝트 임시 컴파일/테스트 캐시, 결과 번들67개·시뮬레이터 실행 로그·XCTest 내보내기 그림, simulator 아키텍처가 포함된 다운로드 바이너리 의존성 캐시를 정리했다. APFS 공유 블록과 다른 작업의 정리가 있어 이 크기를 실제 디스크 여유 증가로 간주하지 않는다.
- 근거: `build/validation/SIM1003D01/`의 `deletion-manifest.json`, `deletion-results.json`, `additional-deletion-manifest-final.json`, `additional-deletion-results.json`, `cleanup-summary.json`. 삭제 범위는 기존 ShotGuide 보호 지시와 현재 저장소 문맥에 따라 TaptionPlan으로 한정했다. Mac 전체 포함 여부를 질문했으나 응답 없이 다른 프로젝트/공용 Xcode SDK 삭제로 확대하지 않았다.
- 검증 기록: 삭제 전67개 xcresult의 실제 요약을 모두 추출했다(추출 실패0). `retained-test-summaries/`와 원본 경로→요약 경로·통과/실패/건너뜀 값을 기록한 `test-summary-inventory.json`에 남겼다. 과거 실패/건너뜀도 그대로 보존했으며 이번 정리를 새 테스트 통과로 처리하지 않는다. 기존 test.md에 연결된 Simulator xcresult·해당 실행 로그·내보내기 그림은 사용자 삭제 요청으로 제거됐으므로 재확인은 보존된 요약과 매핑을 사용한다. 원본 첨부/전체 xcresult 재조회는 더 이상 가능하지 않다.
- 보존: 시작 시 미커밋 집 육각형 변경·앱 소스/자산·프로젝트/성장 manifest, 실기기 Debug 앱, Release168 archive/IPA·배포 증거, 의존성 소스 checkout을 보존했다. 보호 파일12개 SHA-256이 전후 같고 실기기 Debug 앱·Release archive 앱의 codesign deep/strict 검증도 전후 성공했다(`protected-file-hashes.json`, `debug-signature-before/after.log`, `archive-signature-before/after.log`). 의존성의 바이너리 캐시는 재빌드 때 필요에 따라 다시 내려받는다.
- 전역 상태: 처음 Mac 장치4대가 보였으나 소유 확인 재조회 전에 장치/런타임 목록이0개로 바뀌었다. 이 작업에서는 전역 장치/런타임 삭제 명령을 실행하지 않았고 변경 주체는 확인할 수 없다(`devices-before.json`, `external-state-observation.json`). 최종 조회도 장치0·런타임0이다(`devices-final.json`, `runtimes-final.json`). CoreSimulator 임시 BackgroundDelete 할당 크기는0으로 확인됐다.
- 최종 확인: 명시한 삭제 대상, 프로젝트의 이름으로 식별되는 Simulator 출력/패키지 출력, 직접 연결된 결과 번들과 Simulator 호출 로그의 잔여가 모두0이다. 파일을 재생성하는 앱/Simulator 빌드·테스트·설치를 실행하지 않았다. 앱 동작 코드 변경·추가 커밋·push·배포도 수행하지 않았다. 정리 기준 충족으로 SIM1003D01만 temp에서 제거하고 기존 기기/배포 확인 대기는 유지한다.

## HBG1003A01 · 집 아이콘 흰색 육각형 50% 배경 (2026-10-03)

- 결과: 지도 집 그림 뒤에 `hexagon.fill` 흰색·불투명도0.5·56×56pt 배경을 적용했다. 일반 집 표시와 화랑이가 집에 있는 표시 모두 같은 배경을 사용하며 배경은 터치/접근성 대상에서 제외했다. 집 그림 자체는48×48pt·기존 선명도이고 기존 화랑이/장식/윤일 별/탭 영역을 유지한다.
- 범위: MapHomePlacePin의 공통 배경10줄과 두 사용 위치만 추가했다. 이 추가를 제거하면 시작 HEAD a4d1910의 MapHomeView.swift와 정확히 같아지는 대조를 통과했다. 성장 상세 카드/시즌 보관 화면과 성장·저장 정책, 승인된366개 SVG 자산은 변경하지 않았고 원본 해시 검사를 통과했다. 근거는 `build/validation/HBG1003A01/implementation.json`, `source-scope-verification.json`, `artwork-check.log`이다.
- 관련 기존 회귀 **20통과·0실패·0건너뜀**: MapHomeGrowthPolicyTests18개(실제 번들366개/48pt 렌더 검증 포함)와 FeatureEngineTests의 집/화랑이 탭 분리·마커 탭 경계2개. 초기 보조 탭 선택자는 잘못된 클래스명으로 지정되어 실행되지 않았고 성장18개만 실제 통과했다. 클래스명을 바로잡아 별도 결과 번들에서2개가 실제 통과한 후 합산했다(`home-background-tests.xcresult`, `growth-test-summary.json`, `home-tap-tests.xcresult`, `tap-test-summary.json`, `test-selection-correction.json`).
- 최종 generic iOS Debug BUILD SUCCEEDED·exit0, 산출물 네 제품 번들 모두1.0(168), import 경계·diff 검사 통과(`ios-debug.log`, `debug-bundles.json`, `import-boundary.log`, `validation-summary.json`). 새 테스트 파일은 만들지 않았다. 기존 테스트는 성장/자산/탭 정책 검증이며 육각형의 실제 지도 화면이나 픽셀 불투명도 측정을 대신하지 않는다.
- 제한: 구현/관련 회귀/Debug 기준 충족으로 이 요청만 temp에서 제거한다. 실제 기기 지도 시각 확인·새 설치·커밋·push·TestFlight 배포는 이번 요청에서 수행하지 않았다. 이 수정이 포함된 로컬 Debug168과 앞서 배포한 TestFlight168(코드027464b)을 구분한다. REL1003A01의 웹 로그인/그룹 화면 대기와 다른 실기기 검증 조건은 유지한다.

## REL1003A01 · main 반영·내부 TestFlight168 (2026-10-03)

- 시작: main HEAD·fetch 후 origin/main·실제 원격 main은 모두 c441beaa0b72c31d590bb02157caf24a42d78f6d였다. 토요일 표시·Watch 수신 개선·세계 건축 366개 자산·관련 기록·디자인 자료와 기존 Kiro 파일3개 삭제 변경을 보존하여 사용자 요청 범위로 반영한다. 새 브랜치/초기화/파일 삭제는 수행하지 않았다.
- 버전: ASC 최신 빌드 목록의 최고167 VALID를 확인하고168을 선택했다. CURRENT_PROJECT_VERSION8개 설정과 앱·Widget·Watch·Watch Widget 원본 Info.plist4개를168로 맞췄다(`builds-before.json`, `source-build-versions.json`). 근거 경로는 `build/validation/REL1003A01/`이다.
- 검증 재사용: Watch 소스/테스트5개 hash와 성장 SVG366개 hash가 해당 최종 검증과 동일하고, 상단 날짜 수정 diff도 기존 토요일 우선 분기뿐임을 확인했다. Watch 관련58개·성장 관련18개·달력 정책1개 모두0실패·0건너뜀인 실제 요약을 대조해 재사용했다(`validation-reuse.json`). 새 전체 테스트나 실기기 기능 통과로 표시하지 않는다.
- 최종168 iOS·Watch generic Debug 모두 BUILD SUCCEEDED·exit0. iOS 앱에 포함된 네 제품 번들 모두1.0(168) 확인(`ios-debug.log`, `watch-debug.log`, `debug-bundles.json`). 성장 자산 대조·import 경계·staged diff 검사도 성공했다. 배포 기준 소스/설정1,071개 hash를 저장했다(`source-hashes.json`).
- 자료: 이전 시안과 승인본·배포 ZIP을 포함한 디자인2,907개 파일(98,899,733바이트)을 보존하여 함께 반영한다. Python 자동 캐시만 .gitignore에 제외하며 지우지 않았다. 디자인 CSV의 의도된 CRLF를 .gitattributes의 cr-at-eol로 선언하여 내용/바이트를 그대로 보존하고 다른 공백 검사는 유지했다. 최초 CSV 진단은 `staged-diff.log`, 최종 무진단은 `staged-diff-final.log`이다.
- 코드 커밋027464b를 origin/main에 push했다. HEAD·origin/main·실제 원격 main의 동일 hash와 워크트리 clean을 확인한 뒤 해당 소스로 Release archive/export를 수행했다(`code-commit.log`, `code-push.log`, `pre-archive-git.json`).
- Release archive/export 모두 성공·exit0이며 archive/IPA 각각 codesign deep·strict 검증에 성공했다. archive와 최종 IPA의 네 제품 번들 모두1.0(168), IPA56,659,328바이트·CRC 정상·내부 테스트 전용 옵션을 확인했다(`archive.log`, `export.log`, `archive-signature.log`, `ipa-signature.log`, `archive-bundles.json`, `ipa-bundles.json`, `ipa-metadata.json`). Release 성장 자산은366개 고유 이름/1,464개 rendition·9,538,015바이트이며 소스/설정1,071개 hash도 일치했다(`release-asset-summary.json`). 기존 SecurityBackupCore 캡처 경고2곳은 남아 있다.
- 업로드 직전 ASC에168이 없는 것을 재확인하고 altool로1회 업로드했다. UPLOAD SUCCEEDED·exit0, 전달ID ee3ce0a4-5f3b-4131-b74a-6bf7a2b5cbf7(`pre-upload-builds.json`, `upload.log`, `upload-summary.json`). 최초 BuildUpload API 결과는 PROCESSING·오류0·경고0이다(`processing-01.json`).
- 최종 API: BuildUpload COMPLETE·오류0·경고0, 빌드1.0(168) VALID·INTERNAL_ONLY를 확인했다(`processing-03.json`). 한국어 테스트 안내 저장 후 기존 `TP Taption Plan 내부 테스트` 그룹에 연결했고 최종 빌드는 IN_BETA_TESTING이다. 그룹 빌드 목록의168·테스터1명·한국어 안내 재조회도 확인했다(`build-final.json`, `group-attach.json`, `group-builds.json`, `testers-final-summary.json`, `beta-test-notes-final.json`, `deployment-api-summary.json`). 코드027464b의 토요일 표시·Watch 수정·세계 건축366개 자산이 이 빌드에 포함된다.
- API 조회 제한/재시도: 처리 직후 테스트 안내의 첫 GET은 HTTP409로 실패했다. 변경 요청 전 단계였으며 같은 조회 재시도는 정상 종료했다. 이후 안내 저장/그룹 연결과 최종 재조회 모두 성공했다(`initial-beta-notes-read-retry.json`). 실패를 앱 테스트 통과로 합치거나 업로드를 다시 실행하지 않았다.
- 남은 조건: 웹 앱 목록은 기존 세션 화면을 보였으나 실제 TestFlight 상세 접근/갱신에서 Apple 계정 로그인으로 이동했고 인증 만료가 확인됐다. 사용자 지시인 "PIN과 필요한 인증 입력은 사용자가 직접 합니다"에 따라 열려 있는 Chrome 탭에서 직접 로그인을 요청했으며 최종 관찰도 이메일/전화번호 로그인 화면이다(`web-confirmation-pending.json`). 내부 업로드/처리/그룹 배포는 API로 확인했으나 실제 그룹의 빌드/테스터 노출 조건은 미충족이므로 REL1003A01을 temp에 유지한다.
- 실기기/범위: 이번168의 iPhone11/18·Watch 새 설치/다운로드·화면/Watch 실제 수신 시간·기능/성능 검증은 수행하지 않았다. 기존 기기 기능 대기와 IAP/공개 제출 보류를 유지한다. 배포 기록까지 main에 반영한 뒤 HEAD·origin/main·실제 원격 main 일치·워크트리 clean을 확인하는 최종 근거는 `final-git.json`이다.

## WCH1003A01 · Apple Watch 데이터 수신 지연 개선 (2026-10-03)

- 코드에서 확인한 지연 경로: Watch ambient outbox는 reachable 상태에서도 transferUserInfo만 예약했고, 이미 백그라운드 전송 중인 항목을 건너뛰었다. iPhone의 저장 확정 ACK도 transferUserInfo만 사용하며 Watch live-message delegate에는 ACK 소비가 없었다. 수동 syncNow는 전체 ambient drain 완료 후에야 독립적인 HealthKit 조회를 시작했다. 이 세 경로와 시작 소스 hash는 `build/validation/WCH1003A01/investigation.json`에 기록했다. 사용자 기기의 지연 시간이나 모든 지연의 단일 원인을 실측한 결과는 아니다.
- 변경: durable outbox·기존 reliable 전송을 유지하고 reachable 때 ambient 요약/가속도 원본의 즉시 전송을 추가했다. 이미 reliable 큐에 있는 항목도 즉시 경로를 사용할 수 있다. 공유 gate는 ACK 대기4개, payload32KiB, 재시도10초를 적용하며 ACK 유실·기기 uptime 역전·purge reset을 처리한다. 큰 항목/연결 끊김/즉시 전송 실패는 기존 reliable 큐에 남는다. iPhone 저장 성공 후 ACK 호출 위치는 유지하고 ACK의 즉시 전달·Watch 수신 처리를 추가했다. ACK 소비와 outbox 삭제 성공 후에 다음 항목을 보낸다.
- 수동 건강 조회는 ambient drain과 함께 시작한다. 기존 삭제/설정 generation을 전달하여 대기 중 시작되는 오래된 건강 조회를 차단하고, 전체 동기화 종료는 두 경로의 완료를 모두 기다린다. 기존 HealthKit 원본·출처, SQLite/payload 스키마, App Group 경로, 삭제 fence와 재전송/중복 저장 계약을 유지한다. CMSensorRecorder의 기존 조회 가용성 대기180초는 변경하지 않았다.
- 관련 회귀 **58통과·0실패·0건너뜀**: WatchSensorQueryPlanTests 전체(신규4개 포함)와 실제 저장/ACK·같은 버전 재수신·fallback·재시작 high-water·revision 역전·가속도 중복/순서 역전 테스트6개. 신규 fixture는 12개 backlog를 ACK 라운드3회/라운드당4개로 전달하며 중복 예약·ACK 유실 재시도·크기/연결 경계·reset을 검증했다. xcresult의 실제 요약은 `watch-sync-tests.xcresult`, `test-summary.json`, 실행 로그는 `tests.log`이다. fixture 전달 수는 실제 기기 전송 시간 측정이 아니다.
- 최종 iOS generic Debug와 Watch generic Debug 모두 BUILD SUCCEEDED·exit0(`ios-debug.log`, `watch-debug.log`). iOS 산출물의 앱·Widget·Watch·Watch Widget 네 번들1.0(167) 확인(`ios-bundles.json`), import 경계·diff 검사 통과. 기존 SecurityBackupCore weak 캡처 경고2곳은 그대로다. 최종 소스 hash는 `source-hashes-after.json`, 검증 요약은 `validation-summary.json`에 저장한다.
- 제한: 변경된 iPhone·Watch 수정본의 설치 및 실제 수신 시간/백그라운드 체감/배터리는 미검증이므로 temp에 실기기 조건을 유지한다. 로컬 Debug167은 이번 변경을 포함하며 기존 TestFlight167 배포 소스와 구분한다. 재업로드·커밋·push는 수행하지 않았다. 시작 시 있던 상단 토요일 수정·문서 변경·Kiro 파일3개 삭제 상태를 보존했다.

## SAT1003A01 · 상단 토요일 파란색 표시 (2026-10-03)

- 상단 날짜/요일의 dateColor가 공휴일을 우선하여 개천절과 겹친 2026-10-03 토요일에 빨간색을 반환했다. 토요일 분기를 공휴일 분기 앞에 두어 상단 날짜와 요일에 기존 파란색 tpSaturday를 적용한다. 일요일/다른 공휴일/평일 규칙은 유지한다.
- 기존 TimeScaleTests/testMapHomeCalendarDayStyleUsesHolidayAndWeekendColors 1통과·0실패·0건너뜀(xcresult 요약 확인). 앱 generic iOS Debug BUILD SUCCEEDED·exit0, diff 검사 통과. 근거: `build/validation/SAT1003A01/`의 `tests.log`, `date-colors.xcresult`, `test-summary.json`, `debug.log`.
- 제한: 이 회귀는 기존 달력 주말/공휴일 정책 검증이며 상단 화면의 시각 검증은 아니다. 이번 수정본은 실기기에 재설치하지 않았다. 시작 시 존재한 문서 변경과 Kiro 파일3개의 삭제 상태를 보존했으며 커밋/push는 수행하지 않았다. 구현/회귀/Debug 기준 충족으로 temp 항목을 제거했다.

## INS1002A01 · iPhone11·18 최신167 설치 (2026-10-02)

- 사용자 요청에 따라 iPhone11 Pro와 iPhone18 Pro Max에 기존 앱 삭제 없이 직접 Debug1.0(167)을 업데이트 설치했다. 시작 main c441bea·기존 문서2개 변경을 보존했다. 배포 검증 소스/설정119개 hash 변화0, 기존 최종 Debug 산출물 앱·Widget·Watch·Watch Widget 네 번들1.0(167), codesign deep/strict 검증 성공으로 기존 빌드/테스트 근거를 재사용했다.
- 설치 전 devicectl 조회: iPhone11 1.0(163), iPhone18 1.0(167). 두 기기 install app 명령 exit0 및 JSON outcome success·com.taption.plan을 확인했고, 설치 후 각각 다시 조회하여 두 기기 모두1.0(167)을 확인했다.
- 근거: `build/validation/INS1002A01/artifact-check.json`, `signature.log`, 각 `iphone11/iphone18-before.json`, `-install.json`, `-install.log`, `-after.json`. 새 실행 폴더를 사용해 기존 결과를 덮어쓰지 않았다. 완료 기준을 충족해 temp 항목을 제거했다.
- 제한: 직접 설치한 Debug 빌드이며 TestFlight 다운로드 실행 결과가 아니다. 앱 실행·실제 화면/센서/저장/기능/성능 검증은 이번 요청에서 수행하지 않았다. 기존 실기기 기능 검증 대기는 유지한다. 앱 코드 변경·새 빌드·커밋·push는 수행하지 않았다.

## REL1002A02 · main 반영·내부 TestFlight167 (2026-10-02)

- 시작 main9c525b2, fetch 후 origin/main과 일치했다. 미커밋 변경29개 파일은 DYN1001A01/B01·DYN1002C01·MAP1002D01·OPT1002A01·LCK1002B01 및 이전166 배포 기록에 연결되어 보존한다. 삭제/초기화/새 브랜치를 수행하지 않는다.
- ASC 최신 목록의 최고166 VALID를 읽고167을 선택했다(`build/validation/REL1002A02/builds-before.json`). `CURRENT_PROJECT_VERSION`8개 설정과 앱·Widget·Watch·Watch Widget의 원본 Info.plist4개를167로 맞췄다. 사용자 요청에 따라 main 커밋·push와 내부 배포를 진행한다.
- 기존 유효한 전체 앱1,472통과/0실패/1건너뜀, 최종 관련268통과, package184통과, 화랑이 회귀3통과를 재사용했다. 시작 시 OPT runtime10개 및 LCK3개 파일의 SHA256은 검증 후 같았다. staged diff 검사에서 새 파일2개의 끝 빈 줄을 발견해 정리했으며 내용 동일성과 전후 hash를 `whitespace-adjustments.json`에 기록했다. 새167 최종 iOS Debug BUILD SUCCEEDED(`debug-final.log`) 및 산출물 네 번들1.0(167) 확인(`debug-bundles.json`). import 경계·staged diff 검사 성공. Release 기준 소스/설정119개 파일 hash를 저장했다(`source-hashes.json`).
- 코드 커밋a9c23dd를 origin/main에 push한 뒤 main/origin/main 동일·워크트리 clean을 확인했다(`pre-archive-git.json`). 이 소스로 Release archive와 내부 전용 export가 성공했고 archive 서명 검증 및 archive/IPA 네 번들1.0(167) 확인을 마쳤다(`archive.log`, `export.log`, `archive-signature.log`, `archive-bundles.json`, `ipa-bundles.json`). 소스/설정119개 hash도 일치했다.
- 19:42 KST에 업로드 성공을 확인했다(`upload.log`, Delivery UUID `c009e32e-0647-4a2a-bf6f-912befc443d0`). 첫 ASC 조회에서는167이 아직 목록에 등록되지 않아 처리 완료·그룹 연결/화면 확인은 대기다(`processing-01.json`). App Store Connect 웹 세션은 로그인 요청 중이다. 실제 기능·실기기 성능 검증 대기는 별도다.
- 목록 등록 지연을 조사해 공식 BuildUpload API에서1.0(167) `PROCESSING`·오류0·경고0을 확인했다(`delivery-api-01.json`). 19:52 KST 후속 조회는 `COMPLETE`·빌드`VALID`·`INTERNAL_ONLY`를 반환했다(`delivery-api-02.json`). altool 조회도 exit0으로 정상 종료되어 `VALID`를 반환했다(`delivery-status-01.log`); 중지하려던 시점에는 이미 종료되어 실제 중지한 프로세스가 없었다(`delivery-status-01-stop.json`). 업로드 취소/재업로드는 하지 않았다.
- 최종 API에서1.0(167) **VALID·IN_BETA_TESTING·INTERNAL_ONLY**를 확인했다. `TP Taption Plan 내부 테스트` 연결, 그룹 빌드 목록의167 포함, 테스터1명, 한국어 테스트 안내 저장도 확인했다(`build-final.json`, `group-attach.json`, `group-builds.json`, `testers-final.json`, `beta-test-notes.json`, `deployment-api-summary.json`). 빌드ID는 `c009e32e-0647-4a2a-bf6f-912befc443d0`이다. LCK1002B01·OPT1002A01·MAP1002D01·DYN1002C01 구현은 이제167에 포함되어 있다.
- 당시 제한: App Store Connect 웹 세션은 Apple 계정 로그인 화면이고 사용자 로그인 응답이 없어 실제 그룹 화면의 빌드/테스터 노출은 확인하지 못했다. 내부 업로드/처리/배포는 완료했지만 프로젝트의 전체 배포 기준은 미충족이므로 REL1002A02를 temp에 유지했다. 실제 기능·실기기 성능 대기도 유지했다. 배포 기록 반영 후 main/origin/main·실제 원격 hash 일치와 clean의 근거는 `build/validation/REL1002A02/final-git.json`이다.
- 2026-10-02 23:37 KST 후속 확인: 시작 시 main HEAD·origin/main·`git ls-remote origin refs/heads/main`이 모두 `c441beaa0b72c31d590bb02157caf24a42d78f6d`이고 워크트리는 clean이었다. 현재 App Store Connect 웹 로그인이 유효하여 Taption Plan(6797370230)의 `TP Taption Plan 내부 테스트` 그룹을 직접 읽었다. 그룹 헤더는 테스터1명, 빌드 탭의 1.0(167) 내부 행은 **테스트 중**, 해당 행 링크의 빌드ID는 `c009e32e-0647-4a2a-bf6f-912befc443d0`이었다. 테스터 탭도 1명과 **설치됨 1.0(167)**·2026년10월2일을 표시했다.
- 화면 근거는 `build/validation/REL1002A02/group-screen-2026-10-02T14-37-34-811Z/`의 `testers.jpg`, `builds.jpg`, `summary.json`에 새로 저장했다. 기존 근거를 덮어쓰지 않았다. 남은 그룹 화면 검증 조건을 충족하여 REL1002A02를 temp에서 제거했다. 웹의 설치 상태는 관찰 결과이며 이번 작업에서 새 업로드·실기기 설치·기능/성능 검증은 수행하지 않았다. LCK1002B01·DYN1002C01·MAP1002D01·OPT1002A01의 실기기 대기와 IAP/공개 제출 보류를 유지한다.
- 이번 후속 변경은 temp.md·test.md의 로컬 검증 기록뿐이다. 앱 코드 변경이 없어 기존 테스트/빌드 근거를 재사용하며 앱 테스트·빌드를 다시 실행하지 않았다. 새 커밋·push는 수행하지 않았다. 문서 diff 및 최종 Git 상태는 같은 화면 근거 폴더의 `record-validation.json`에 기록한다.

## LCK1002B01 · 잠금 화면 하단 현재 활동 화랑이 (2026-10-02)

- 첨부의 센서 카드 왼쪽은 `SensorCollectionLockScreenView`에서 고정 `SensorCollectionAppIcon`을 사용했다. 이를 Island와 같은 `TaptionLiveActivityCat`으로 바꿔 현재 활동 분류·스타일·프레임을 전달하고52×40pt 영역에서 원본 비율을 유지한다. 앱 아이콘의 회색 표시 자체는 기기 로그로 확정하지 않았으며 해당 고정 이미지 경로를 대체했다.
- 계획 Live Activity 잠금 카드도 이전 사람 그림 대신 같은 화랑이 뷰와 현재 활동명으로 연결했다. 센서 카드의 수집 문구·센서 종류·최근 저장, 계획 카드의 계획 제목·시간·종료 기능은 보존했다. VoiceOver에도 현재 활동명을 포함한다. Reduce Motion/화면 어두움에서 정지 프레임을 쓰는 기존 정책을 재사용하며 지속 애니메이션을 새로 요구하지 않는다.
- 기존 bitmap 생성/프레임 차이·활동별 동작 정책·optional 상태 호환 회귀3개 통과·0실패·0건너뜀(`build/validation/LCK1002B01/activity.xcresult`, `activity-summary.json`). 위젯 포함 iOS Debug/Release BUILD SUCCEEDED(`debug.log`, `release.log`). 프레임 크기를 그대로 반복하는 새 테스트는 만들지 않았다.
- 실제 iPhone 잠금 화면의 화랑이·활동 전환·가독성/잘림은 미검증이며 temp에 남긴다. 설치/업로드를 수행하지 않았고 기존 TestFlight166에는 이 변경이 없다.

## OPT1002A01 · 코드 검토·DB/캐시/터치 비용 개선 (2026-10-02)

- 전체 제품 소스의 구조/import·반복 연산/입력/SQLite 위치 지도를 만들고 일자 DB, AppModel projection, 원본 캐시, 지도·시간축 입력을 직접 검토했다. 검토 범위/판단은 `build/validation/OPT1002A01/code-review.md`, 파일 지도는 `code-inventory-final.json`이다. 모든148k줄의 의미 검토 또는 모든 잠재 결함 해결을 주장하지 않는다.
- 서로 다른 source에서 동일 materialized 일자를 두 번 읽던 경로를1회로 합쳤다. 검증된 complete raw를 재사용하고 source fingerprint의 동일 revision 캐시·취소 가능한 계산을 사용한다. 원본 정렬의 기존 UUID 순서를 바이트 비교로 보존하며 이미 정렬된 원본은 복제/재정렬을 생략한다. 삭제 generation·원본 digest·취소·강제 갱신·다른 DB 연결 무효화와 중복 ID 마지막 값 보존 회귀를 확인했다.
- 공통 bounded cache·UUID 순서·60Hz 입력 projection을 기존 TaptionPlanCore 라이브러리에 넣었다. 일자/원본 digest/월 캐시 제한42/64/2를 유지하고 조회 때마다 recency 배열을 훑던 작업을 제거했다. 동일 값/지도 좌표는 다음 입력의 갱신 예산을 소비하지 않으며240Hz 입력의 최종값을 종료 시 즉시 반영한다. 지도 경로 갱신 비교에서 문자열 조합을 값 key로 바꿨다.
- 일자 값 모델은 `PlanDayDataSnapshot.swift`, 지도 입력/카메라 정책은 `MapHomeInteractionPolicy.swift`로 분리했다. UIKit/MapKit/ActivityKit은 앱에 두고 기존 facade·SQLite 스키마/payload·App Group 경로·백업 읽기 계약을 유지했다. DEVELOPMENT에 탐색 위치와 비용 판단/검증 명령을 추가했다.
- 같은 Simulator fixture의 일자 콜드 조회 p95: baseline41.897875ms → 최종 관련 회귀21.375583ms, warm0.089292ms →0.060958ms. 전체 테스트 실행 중 콜드19.861625ms도 관측했다. Release host 캐시10만 hit microbenchmark는3.89625ms →1.246042ms. `performance-comparison.json`에 원자료 경로별 값을 보존했다. 단일 실행·fixture 측정이며 실기기 앱 시작/배터리·peak memory 개선 수치로 해석하지 않는다.
- 전체 앱1,472통과·0실패·1건너뜀(`app-full.xcresult`, `app-summary.json`); StoreKitTest의SKInternalErrorDomain Code3인 구매/복원1건은 통과가 아니다. 최종 파일 분리/추가 회귀를 포함한 관련 앱268통과·0실패·0건너뜀(`app-refactor-complete.xcresult`). Core111·Activity33·Route39·facade1 통과(`core-complete.log`, `activity.log`, `route.log`, `engine.log`). iOS Debug/Release BUILD SUCCEEDED(`debug-complete.log`, `release-complete.log`), import 경계·diff 성공. 최종 검증 시점의 runtime10개 파일 SHA256이 동일함을 확인했다.
- 최초 Release 캐시 측정은 패키지 제네릭 호출 비용으로 느려져 작은 함수의 특수화를 적용하고 재측정했다. 최초 파일 분리 실행은 PBX 소스 등록 누락으로 실패했으며 등록 후 별도268개 회귀/빌드로 해결했다. 이전 실패 로그는 덮어쓰지 않았다. 기존 SecurityBackupCore의 캡처 경고2곳은 남아 있다.
- 실기기 체감·배터리/peak memory는 증거가 없어 temp에 검증 대기로 남긴다. 기존 미완료 복원/Watch/계정 항목을 완료 처리하지 않는다. 새 유료 서비스/외부 dependency·설치·commit/push·TestFlight 업로드는 수행하지 않았으며 기존 TestFlight166에는 이 최적화가 없다.

## MAP1002D01 · 시작 카메라·중앙·RPG 스타일 제한 (2026-10-02)

- 시작 화면은 route fit/캐시 카메라 복원에 따라 축척이 달랐다. 최초 화랑이 표시 좌표(없으면 현재 좌표)를 중심으로3000m 카메라를 적용하고, 초기 위치 요청 결과도 같은 경로를 사용한다. 캐시는 파생 경로를 읽되 카메라를 덮어쓰지 않는다. 사용자 드래그/재생 중 자동 초점 변경은 차단한다. 사용자가 직접 선택하는 전체 경로 맞춤 기능은 유지한다.
- 현재 위치 목표점은 화면 중앙, 지도 엔진 contentInset도0으로 통일했다. RPG 렌더러를 사용하고 메뉴의 다른 스타일은 disabled로 남겼다. 이전 스타일 데이터/enum/에셋을 삭제하거나 저장값을 일괄 변경하지 않았다. 설정 안내도 현재 제공되는 RPG에 맞췄다.
- TimeScaleTests170통과·0실패·0건너뜀(`build/validation/MAP1002D01/tests.xcresult`, `tests.log`), 마지막 여백 조정 포함 iOS Debug BUILD SUCCEEDED(`debug-centered.log`), diff 검사 성공. 크기 상수를 그대로 반복하는 테스트는 추가하지 않았다.
- 첨부 이미지에는 거리/카메라 메타데이터가 없으므로3000m는 근사값이다. 실제 시작 화면의 비율·화랑이 중앙과 기기별 잘림은 확인 대기. 새 설치/업로드/commit/push는 수행하지 않았으며 TestFlight166에는 미포함이다.

## DYN1002C01 · Island 화랑이 아이콘 확대 (2026-10-02)

- 첨부 화면에서 고양이 아이콘 실제 표시를 확인했다. 이전 회색 사각형 증상은 이 화면에는 없으나 활동 전환 정확도/전체 상태는 이 이미지로 통과 처리하지 않는다.
- sensor와 plan의 compact leading을20×20에서32×26pt로 확대했다.52:32 이미지 비율을 유지하므로 표시 이미지 폭은60% 커진다. minimal은18×18에서26×26pt로 확대했다. 큰 atlas 대신 작은 bitmap 경로를 유지하고 clipping/scaleEffect는 추가하지 않았다.
- 관련 bitmap 회귀1통과·0실패·0건너뜀(`build/validation/DYN1002C01/tests.xcresult`, `tests.log`), iOS Debug BUILD SUCCEEDED(`debug.log`), git diff --check 성공. 프레임 크기 변경을 그대로 반복하는 테스트는 추가하지 않았다.
- 실제 기기 확대 후 가독성/잘림 확인은 대기다. 이 변경은 이미 업로드된TestFlight166에 포함되지 않는다. 새 업로드/설치/commit/push는 수행하지 않았다.

## TFL1002A01 · Island 수정 내부 TestFlight166 (2026-10-02)

- 시작 main9c525b2, origin/main과 일치. 기존 DYN1001A01/B01 미커밋 변경을 보존하여 포함했다. ASC 최고165 VALID 확인 후166을 선택했다. 코드/문서 변경은 아직 미커밋이며 push하지 않았다.
- Release 첫 archive에서 Debug 전용 진단 함수의 무조건 호출로 컴파일 실패. 호출을 DEBUG 조건으로 제한한 뒤 archive-final 성공. 회귀 재실행 **645통과·0실패·1건너뜀(총646)**, Debug 성공. 건너뜀과 실제 Island 기능은 통과로 처리하지 않는다.
- 내부 전용 export 성공. archive/IPA/Debug의 앱·Widget·Watch·Watch Widget 네 번들1.0(166) 확인. source hash 일치와 diff 검사 성공. 증거 `build/validation/TFL1002A01/`.
- 14:20 KST 업로드 성공. Delivery UUID/빌드ID `8c075df3-a864-4e0b-9df1-ae01e835a537`. 최종 API **VALID·IN_BETA_TESTING**, `TP Taption Plan 내부 테스트` 연결 및166 그룹 목록 포함, 테스터1명을 확인했다(`processing-03.json`, `build-final.json`, `group-attach.json`, `group-builds.json`, `testers-final.json`). 한국어 테스트 안내도 저장했다.
- 제한: 실제 그룹 화면은 App Store Connect 웹 세션 만료로 로그인 대기다. 업로드/처리/내부 배포는 완료했지만 프로젝트의 전체 배포 완료 기준은 미충족이므로 TFL1002A01을 temp에 유지한다. DYN1001A01/B01 실제 화면 검증 대기도 유지한다.

## DYN1001B01 · 이동 잔류·Island 회색 아이콘 수정 (2026-10-01)

- 사용자 화면에서 이전 DYN1001A01의 이동 잔류·회색 사각형 문제가 확인됐다. 자동 이동을 최신 저장된 고신뢰 정지 관측으로만 활동 상태로 보완한다. 사용자 확정/수동 기록, 빠른 속도, 낮은 신뢰도, 오래된/미저장 관측은 변경하지 않는다. 원본 기록은 수정하지 않는다.
- Island 이미지 경로를 큰 atlas의 GeometryReader/offset/clip 조합에서 52×32pt 단일 프레임 bitmap으로 변경했다. 프레임 캐시를 제한하고 누락 시 고양이 symbol을 사용한다. 실제 bitmap 생성·걷기 프레임 차이·수면 이미지 차이와 상태 판정 경계를 회귀 테스트했다.
- 최종 FeatureEngineTests **645통과·0실패·1건너뜀(총646)**, generic iOS Debug **BUILD SUCCEEDED**. StoreKit 건너뜀은 통과가 아니다. 증거 `build/validation/DYN1001B01/tests-final.xcresult`, `tests-final.log`, `debug-final.log`.
- iPhone18에 Debug1.0(165) 수정본 설치·실행 성공(`install.json`, `launch.json`). 읽기 진단에서 샘플 나이0.035초, motion unknown/high, 앱 projection과 ActivityKit published 모두 unconfirmed로 일치, 앱 bitmap 생성52×32 확인(`iphone18-report.json`). 진단에는 위치/건강/일정 원문을 기록하지 않았다.
- 제한: 이 기기 진단은 실행 직후 미확인 상태의 전달 일치만 입증한다. 정지 전환 실상황과 위젯 프로세스의 실제 아이콘 렌더링은 사용자 화면 확인 대기다. 기존 TestFlight165에는 미포함이며 commit/push/재배포하지 않았다. DYN1001A01/B01을 완료 처리하지 않는다.

## INS1001B01 · iPhone18 DYN1001A01 수정본 설치 (2026-10-01)

- 현재 DYN1001A01 소스 hash 일치 및 Debug 빌드 성공을 재사용했다. iPhone18 Pro Max `00008160-000E195A1140000A`에 `com.taption.plan` Debug1.0(165) 설치·실행 모두 성공했다. 증거 `build/validation/INS1001B01/install.json`, `install.log`, `launch.json`, `launch.log`.
- 앱 삭제/기록 초기화/백업 복원은 호출하지 않았다. 이는 DYN 수정이 포함된 직접 개발 설치본이며 기존 TestFlight165와 버전 번호만 같고 코드가 다르다. TestFlight 재배포는 수행하지 않았다. 실제 Island 화면·상태 전환·프레임 움직임은 DYN1001A01의 사용자 확인 대기로 유지한다.

## DYN1001A01 · 현재 활동과 Dynamic Island 화랑이 동기화 (2026-10-01)

- 원인: Live Activity의 별도 policy는 사용자 확정/수동 기록을 제외하고 자동 기록의 원시 category만 읽었다. 종료 시각이 마지막 저장 샘플인 자동 구간은 wall-clock 현재 시각과 비교해 선택하지 못했다. compact/minimal/expanded가 서로 다른 상태를 읽고 사람 그림 또는 항상 걷는 고양이를 사용했다. 센서 저장 이외 상태 변경의 즉시 갱신 경로도 빠져 있었다.
- 수정: 현재 구간의 사용자 확정을 우선하고 `RecordAnalysisCategoryPolicy`와 같은 분류를 사용한다. 최근90초 이내 저장 샘플이 속한 자동 구간을 현재 후보에 포함해 더 오래된 열린 자동 구간보다 최신 관측을 선택한다. 종료된 수동 구간·미래 샘플·오래된 센서 관측은 이 보완 경로로 연장하지 않는다. raw/사용자 기록 자체를 수정하지 않는다.
- 갱신: 저장 확정 직후 및 snapshot timestamp 변경, 전경30초 시간 경계 확인 시 동기화한다. UI body에서 전체 actuals 분류를 반복하는 computed category onChange는 사용하지 않는다. 기존 센서/백그라운드 갱신을 유지하며 plan compact와 sensor state에 호환 optional 프레임을 전달한다. 프레임은 실제 센서 저장 갱신에 맞춰 진행하고 수집 없는 새 샘플을 꾸며내지 않는다.
- 화면: Island compact/minimal/expanded는 같은 현재 category/title의 공유 화랑이 atlas를 사용한다. 수면/식사/이동/운동/취미/업무/수업/미확인 동작, 선택한 고양이 style, 업무 모니터/수업 책 표시를 연결했다. 수업은 grooming 대신 앞발 kneading 프레임+책을 사용한다. 고정52×32 atlas를 영역 크기에 맞춰 축소해20×20 표시가 잘리지 않게 한다. 확대 영역의 별도 항상 걷는 고양이는 제거했다.
- 검증: FeatureEngineTests 전체 **643통과·0실패·1건너뜀(총644)** (`tests-complete.xcresult`, `test-summary.json`). 추가 회귀3개는 수동 확정과 공통 분류/순서·시간 경계, 새 센서 구간/90초 만료·종료 수동/미래 관측, 동작 매핑·optional 필드 이전 JSON 호환을 확인한다. StoreKit 시뮬레이터 건너뜀은 통과가 아니다. generic iOS Debug **BUILD SUCCEEDED** (`debug-complete.log`), diff 검사 성공, 최종 source hash 보존. 앞선 중간 검증 결과도 덮어쓰지 않았다. 증거는 `build/validation/DYN1001A01/`.
- 제한: 실제 iPhone Island 화면/위젯 프로세스의 상태 전환·프레임 움직임은 아직 미검증이다. Live Activity는 앱/ActivityKit 상태 갱신을 사용하며 시스템 애니메이션은 최대2초 제한이 있어12fps 무한 TimelineView에 의존하지 않는다. Apple 문서: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities , https://developer.apple.com/design/human-interface-guidelines/live-activities . 이 수정은 기존 TestFlight165에 미포함이며 새 배포·기기 설치·commit/push는 이번 요청에서 수행하지 않았다.

## TFL1001B01 · main 후속 내부 TestFlight165 (2026-10-01)

- 시작: main `ba33080`, origin/main과 같고 워크트리 clean. ASC 최고 번호164 VALID를 확인해165를 선택했다. 빌드 설정8곳/네 Info.plist 번호를165로 변경하고 main 커밋 `baf26ea501467120b3c6d080d91fedd7f4c9c69e` 생성·push 후 해당 소스로 archive했다.
- 기능 소스 hash가164의 검증된 코드와 같으므로 STR1001A01의 전체 앱 xcresult1,462통과/0실패/1건너뜀, Core103통과와 마지막 관련869통과/1건너뜀을 재사용했다. 새 기능 수정이나 StoreKit/실기기 기능 통과 판정을 하지 않았다.
- Release archive/internal-only export/generic iOS Debug 성공. archive·IPA·Debug의 앱/iPhone Widget/Watch/Watch Widget 네 번들 모두1.0(165)을 readback했다. IPA는 Production 서명/get-task-allow=false. Release CloudKit manifest 자동 생성은 계속 비활성이다. 증거 `build/validation/TFL1001B01/`의 `archive.log`, `export.log`, `debug.log`, `*-bundles.json`, `ipa-entitlements.plist`, `source-hashes.json`.
- 16:11 KST 업로드 성공, Delivery UUID `e19df96b-637c-4106-ab47-a1657d218b28` (`upload.log`). 최초 ASC readback에는165가 없었으나 최종 API에서 **VALID, IN_BETA_TESTING, 내부 그룹 연결=true, 테스터1명**을 확인했다 (`processing-final.json`, `build-final.json`, `testflight-readback.json`).
- 실제 `TP Taption Plan 내부 테스트` 그룹 화면에서 **1.0(165) 내부·테스트 중·1명의 테스터**를 읽고 캡처했다 (`group-165.jpg`). 기존164의 화면 검증도 완료했다 (`group-164.jpg`). 한국어 테스트 안내는 기존 locale이 있어 생성409 후 기존 항목을 PATCH해 성공했다 (`beta-test-notes.json`).
- diff 검사 성공, 기능 코드 hash는 archive 생성 이후에도 일치. 배포 완료 기준을 충족해 TFL1001B01을 temp에서 제거한다. 실제 회사 기능·특정 기기 다운로드·백업 PIN/복원 검증은 이 배포 결과로 통과 처리하지 않는다. 기존 원본과 열린 요청을 보존한다. 최종 문서 커밋을 main에 push하고 원격 일치/clean을 확인한다.

## GIT1001A01 · TestFlight164 수정 main 커밋·push (2026-10-01)

- 현재 변경29개 파일의 앱·package·회귀 테스트·빌드164 설정과 검증 문서를 기존 작업 그대로 반영한다. TestFlight164 archive 생성 시 소스 hash와 현재 동작 코드가 일치한다. 기존 테스트·Debug·Release 검증은 TFL1001A01/STR1001A01 근거를 재사용했고 문서/커밋 작업으로 앱 테스트를 반복하지 않았다.
- 커밋 전 `git diff --check` 성공. origin/main을 fetch한 뒤 HEAD와 차이0/0 확인. 구현 커밋 `dbbeed60088b2a67e1f0ab3f897f02ede7267463`을 main에 생성·push했다. `git ls-remote`의 원격 main과 local/origin HEAD가 같고 `git status --porcelain=v1` 출력이 비어 tracked/untracked clean을 확인했다. 실기기 기능·백업 PIN·그룹 화면 확인 대기 항목은 그대로 유지한다.

## TFL1001A01 · 회사 검증용 내부 TestFlight164 배포 (2026-10-01)

- 후속 화면 검증: TFL1001B01 실행 중 로그인 연결 후 실제 내부 그룹 화면에서 **1명의 테스터, 1.0(164) 내부, 테스트 중**을 읽었다. 테스터 목록에는164 설치됨도 노출됐으나 특정 iPhone의 설치로 단정하지 않는다. 화면 `build/validation/TFL1001B01/group-164.jpg`. 배포의 그룹 화면 대기 기준을 충족해 TFL1001A01만 temp에서 제거했다. 기존 실기기 기능 검증은 별도다.

- 시작: main `48b8efd`, origin/main과 같으며 기존 미커밋 변경29개 파일을 보존했다. ASC 최신 빌드163 VALID, 다음 번호164, 내부 그룹 `TP Taption Plan 내부 테스트`와 테스터1명을 readback했다 (`build/validation/TFL1001A01/builds-before.json`, `groups-before.json`, `testers-before.json`).
- 기존 유효 검증 재사용: STR1001A01 전체 앱 xcresult1,462통과/0실패/1건너뜀(XCTest1,420+Swift Testing42), Core103통과, 마지막 관련869통과/1건너뜀과 Debug 성공. StoreKit 건너뜀은 통과가 아니다. 실기기 백업 PIN 요구/복원·서버 경합 검증 대기는 남긴다.
- 빌드 설정8곳과 네 Info.plist를164로 맞췄다. internal-only export를 사용한다. TestFlight 서명은 Production entitlement를 사용하지만 Release의 CloudKit manifest 동기화 자동 생성은 계속 비활성이다. 기존 iCloud Drive 파일 백업은 유지한다.
- Release archive·internal-only export·generic iOS Debug 성공 (`archive.log`, `export.log`, `debug.log`). archive/IPA/Debug 네 번들 모두1.0(164)을 확인했다 (`archive-bundles.json`, `ipa-bundles.json`, `debug-bundles.json`). IPA 서명은 Production/get-task-allow=false이며 Release manifest 자동 동기화는 비활성이다.
- 10:33 KST 업로드 성공, Delivery UUID `ad5807cb-b9dd-4eca-9767-adf588adbe07` (`upload.log`). 최초 ASC readback에는164가 없었으나 후속 조회에서 VALID/READY_FOR_BETA_TESTING을 확인했다 (`processing-04.json`).
- 내부 그룹 연결 후 최종 ASC readback은 **1.0(164), VALID, IN_BETA_TESTING**, `TP Taption Plan 내부 테스트` 내부 그룹 **buildAttached=true, 테스터1명**이다 (`testflight-readback.json`, `build-final.json`, `group-builds.json`). 한국어 테스트 안내를164에 등록했다 (`beta-test-notes.json`).
- 제한: API 처리·그룹/테스터 노출은 확인했지만 App Store Connect 브라우저는 로그인 화면이므로 **그룹 화면 검증은 대기**다. 실제 TestFlight 다운로드와 회사 기능 검증은 사용자 확인 전이다. 소스 hash를 보존했고 실제 실행과 diff 검사에 오류가 없었다. 기존 미커밋 변경을 보존했으며 이번 요청에서는 commit/push를 수행하지 않았다.

## STR1001A01 · 저장·백업 staging·복구·migration·CAS 구현 (2026-10-01)

- 구현: V4 raw ciphertext를 보호 파일에서 페이지 단위로 읽고 SQLite staging에 중복 검증하며 저장한다. 앱은 streamRaw 경로로 최대256행/기본1MiB 페이지를 처리한다(단일행 상한4MiB). 기존 facade·저장 경로·원본 백업을 보존했다.
- 복구: 보호 restore journal과 SQLite 삽입 영수증을 같은 트랜잭션으로 기록하고 재시작 시 commit/rollback을 판정한다. rollback은 이번 복원에서 삽입했고 이후 바뀌지 않은 행만 제거한다. 삭제/PIN 변경 generation fence로 오래된 준비 작업의 재저장을 차단한다.
- migration/CAS: snapshot에 연결된 V1–V3 월 백업을 새 immutable V4 generation으로 한 번 변환하며 원본과 재시도 journal을 보존한다. Development manifest 경합은 참조 body를 검증·병합·재봉인한 뒤 CAS 재시도한다. 오프라인/미확인 snapshot 참조를 보수적으로 보존하며 Production은 비활성이다.
- 최종 검증: 전체 앱 xcresult 집계 **1,462통과·0실패·1건너뜀** (`app-validated.xcresult`, `app-summary.json`; XCTest 로그는1,420통과/1건너뜀이고 Swift Testing 추가42개 포함), Core **103통과·0실패** (`core-validated.log`). 마지막 generation fence 추가 후 관련 suite **869통과·0실패·1건너뜀** (`fence-final.xcresult`, `fence-final.log`), generic iOS Debug 성공 (`debug-fence-final.log`). StoreKit 구매 테스트의 시뮬레이터 SKInternalErrorDomain Code3 건너뜀은 통과가 아니다. 모든 경로는 `build/validation/STR1001A01/` 아래에 있다.
- 회귀: staging 재개/중복 충돌/취소 rollback, journal 재개, historical V1–V3 1회 변환 및 원본 보존, fork manifest body 재병합·멱등성, V4 파일 페이지1500건, 오프라인 참조 보존·삭제 실패 재시도, SQLite receipt 재시작·사용자 수정/초기화 보호를 검증했다. 초기 fixture·임시 snapshot commit·schema cold-open 경쟁·migration timestamp·컴파일 실패 로그도 보존하고 수정 후 재검증했다.
- iPhone11 10:13 KST: Debug1.0(163) 설치·실행 성공 (`iphone11-install.json`, `iphone11-launch.json`). 읽기 전용 `--verify-streamed-backup` 결과는 **pinRequiredForCloudBackup / verified=false** (`iphone11-report.json`). PIN 등록/입력 전 백업 복호화·페이지 읽기·복원 준비는 미검증이다. 원본 기록 복원/교체/백업 재봉인은 실행하지 않았다. iPhone18의 앞선 설치는 개발 연결 오류4016으로 실패했고 성공으로 계산하지 않는다.
- 남은 기준: raw만 있는 legacy 월 변환, legacy 단일 GCM의 엄격한 incremental 메모리 상한, 실제 대용량 peak memory, 실제 Development 서버 두 기기 CAS/오프라인 연동, App Group Widget/Watch readback, 단계별 강제 종료와 실기기 복원. SQLite를 사용하지 않는 legacy Watch fallback의 rollback은 아직 메모리 경로다. 미확인 snapshot orphan은 보존하므로 완전한 정리 완료를 주장하지 않는다. STR/RST/MIG/BKC/BRT/PKG 관련 열린 항목은 유지한다. push·TestFlight는 이번 실행에서 하지 않았다.

## CUT1001A01 / SLP1001A01 · 자정 회색 발바닥·확정 수면 표시 수정 (2026-10-01)

- 원인: 보행 GPS 공백 발바닥이 하루 전체 표본을 사용해 재생 cutoff 이후의 공백도 표시했다. 전날에서 이어지는 확정 철도 좌표도 당일 시작으로 잘리지 않았다. 분류 정책은 사용자 확정 category보다 기존 sensor behavior를 먼저 적용했고, 캐시 키에는 수동 교정 여부/소스가 없었다. 미리보기 day snapshot은 revision/fingerprint 검증을 우회했다.
- 수정: GPS 공백은 표시 시각 이하 표본으로 생성하고 자정 철도 overlay는 비운다. 전날 철도 prefix는 당일 시작 좌표부터 표시한다. 지도 캐시 v7 갱신. 수동/사용자 교정 대분류를 우선하고 해당 상태를 분류 캐시 키에 넣는다. 미리보기에도 현재 source 검증과 rebase를 적용해 새 수면을 오래된 활동으로 대체하지 않는다. 원본·사용자 기록·백업은 삭제/복원하지 않았다.
- 새 회귀 4개: 자정/중간/완료 GPS cutoff, 전날→당일 철도 경계, 같은 ID 수면 교정 후 캐시/JSON 재독해/사이드바, 오래된 day preview와 새 확정 수면·raw 보존. 모두 통과.
- 최종 검증: RouteTimelineDataTests114 + TimeScaleTests170 + FeatureEngineTests639 = **922 통과·0 실패·1 건너뜀**. StoreKit 구매 테스트는 iOS26.5 시뮬레이터 SKInternalErrorDomain Code3으로 건너뛰었으며 통과로 계산하지 않는다. `build/validation/CUT1001A01/recheck-tests.xcresult`, `test-summary.json`. generic iOS Debug 성공(`debug-final.log`), diff 검사 성공.
- 중간 결과 보존: 첫 테스트는 923실행/1건너뜀/한 테스트의 assertion2개 실패. 이동 중복 제거 fixture에서 수동 확정 category가 activity인데 센서 walking으로 movement를 기대했다. 새 사용자 확정 우선 계약에 맞춰 해당 fixture를 movement로 확정하도록 바꾼 후 전체 관련 suite를 재검증했다. 진단 집계 추가 빌드의 ActualRecord.span 참조 컴파일 오류도 수정했으며 `debug-evidence.log`를 보존했다.
- iPhone18 09:13 KST: 최종 Debug1.0(163) 설치·실행 success(`install.json`, `launch.json`). 기기 내부에서 기존 9/30 위치 백업 원본1,426개로 같은 함수를 실행했다. 전체 날짜 공백 발바닥5개였던 입력에서 **00:00 공백 발바닥0개·철도 overlay0개**; 완료 시 철도 발바닥96개는 유지. 현재 기기의 확정 수면1건은 category mismatch0건. 백업에는 확정 수면0건이므로 백업 수면 결과를 기기 저장 검증으로 주장하지 않는다. 집계는 `iphone18-report.json`; 좌표·PIN·키·건강/일정 원문은 내보내지 않았다.
- 제한: 저장된 수면의 분류 함수와 사이드바 회귀는 확인했으나 현재 기기의 화면 픽셀/터치·재진입 화면은 사용자 확인 전이다. temp 항목은 화면 확인 대기로 유지한다. 이전 전체 앱 테스트 실패/건너뜀을 이 검증으로 완료 처리하지 않았다. commit/push/TestFlight는 수행하지 않았다.

## COP1001A01 · 실제 9/30 회사 업무 읽기 전용 검증 (2026-10-01)

- 같은 최종 기기 집계에서 등록 회사1개·반경120m·반경 내 표본235개·체류2개/563분·업무 후보2개를 확인했다. 기기 업무1개가 두 후보 모두 50% 이상 덮어 새 업무 중복 생성을 막았으며, 수동/다른 분류 blocker0개·억제false였다. 반복 병합 후 업무1개·ID 동일true. 백업은 업무2개로 생성되고 반복2개·ID 동일true. 후보2→기기 업무1은 업무 누락이 아니라 기존 업무에 대한 중복 제거였다.
- 과거 날짜/현재 날짜를 동시 읽은 결과 complete가 둘 다true(각1,433/109개). 근거 `build/validation/CUT1001A01/iphone18-report.json`; 이전 회사 기초 검증은 `build/validation/COP1001A01/`에 보존. 진단 자체로 기록 복원/편집/백업 재봉인은 하지 않았다. 앱 정상 실행 중 snapshot은 갱신될 수 있으므로 예전 travel 수치와 같은 입력의 전후 비교로 주장하지 않는다.
- 코드·집계 검증 완료, 회사 현장 체류와 실제 지도/사이드바 화면은 별도 확인 대기.

## SUB1001A01 · 지하철 탑승 확정 후 회색 노선 발바닥 (2026-10-01)

- 최종 검증: RouteTimelineDataTests·TimeScaleTests 전체 및 관련 FeatureEngineTests 51개를 함께 실행하여 **331 통과·0 실패·0 건너뜀** (`route-tests-balanced.xcresult`, `test-summary-final.json`). generic iOS Debug 성공(`debug-balanced.log`), diff 검사 성공. 최종 소스 hash는 `source-hashes-final.txt`에 보존했다.
- 최종 iPhone18 검증(10/1 01:55 KST): 설치·실행 success(`install-balanced.json`, `launch-balanced.json`). `iphone18-final-report.json`에서 실제 9/30 위치 원본1,426개로 기기 경로5개/고유 지오메트리5개/회색 발바닥96개, 백업 경로4개/고유4개/96개를 재현했다. 5개 경로를 균등 배분해 뒤쪽 노선도 입력에 유지되는 것은 회귀로 함께 확인했다. 이는 기기 안의 동일 노선/발바닥 함수 실행 근거이며 화면 픽셀·터치 검증을 의미하지 않는다.
- 확정 노선이 비어 있던 짧은 조각4개 중2개는 경로 입력에 연결됐고2개는 개별 구간 근거가 부족해 임의 복구하지 않았다. 전체 관측 철도 노선을 짧은 조각 때문에 제외하는 조건은 제거했으므로, 개별 조각의 미복구와 전체 추정 경로 생성 결과를 구분한다. 원본·확정 활동·iCloud 파일을 교체하지 않았고 push/TestFlight 배포는 수행하지 않았다.
- 시작: main `48b8efd`, origin/main과 동일하나 기존 미커밋 수정이 있었다. 기존 수정·자료·브랜치를 보존했다.
- 결함: 회색 발바닥이 estimated overlay만 사용해 확정 노선을 제외했다. 저장 노선이 없는 확정 subway에는 역 근거 재계산이 없었고, 짧은 확정 조각이 겹치면 더 긴 추정 철도 노선도 숨겼다. train 조각마다 같은 노선을 복제해 표시 한도를 낭비했다.
- 수정: 관측 역·정밀 GPS와 유효한 카탈로그 노선으로 확정 구간을 표시용 복구한다. 확정 모드는 보존하고 추정 좌표는 회색으로 표시한다. 전체 철도 노선의 부분 확정 제외를 제거하고 동일 노선을 중복 생성하지 않는다. 96개 철도 발바닥 자리를 노선별 배분하여 뒤쪽 경로가 앞쪽 경로 때문에 사라지지 않게 한다. 지도 파생 캐시는 v6로 갱신했다.
- 시간·안전 경계: cutoff 이후 표본을 사용하지 않고, 수집 종료·다른 수집 세션·Watch 소스·30분 초과 미관측 공백을 넘어 확정 경로를 복구하지 않는다. 출발·도착 근거가 부족한 단일 역 체류에는 임의의 노선을 만들지 않는다. 추정은 화면 파생값이며 사용자 확정/센서 원본을 수정하지 않는다.
- 중간 검증에서 비시간순 입력의 종료 marker를 놓치는 결함을 발견해 정렬로 수정했다. 이후 조각 중복 및 세션 경계 회귀를 보강했다. 첫 컴파일 실패(진단 dictionary 타입 추론)와 중간 실패 기록은 그대로 보존한다. 중간 성공은 330 통과·0 실패·0 건너뜀(`route-tests-complete.xcresult`); 표시 자리 배분 변경 후 최종 재검증을 별도로 기록한다.
- 실제 원본: Debug 전용 `--verify-subway-routes`로 정상 앱 잠금 해제 후 기존 기기 자격 증명을 내부에서 사용했다. `loadLatestBackupPackage(rewrapRecoveredArchive:false)`의 9/30 위치 원본 1,426개와 기기/백업 snapshot으로 같은 노선·발바닥 함수를 읽기 전용 재현했다. 진단 파일에는 개수·시간 범위·판정 여부만 있고 좌표·역 이름·키·PIN·건강/일정 원문은 없다. 기록 복원/수동 활동 변경/백업 재봉인은 호출하지 않았다.
- 실제 조사(`iphone18-probe-report.json`, `iphone18-diagnosis-report.json`, `iphone18-verified-report.json`): 백업의 기존 조각별 추정은 overlay18개이나 지오메트리는4개였다. 중복 제거 후 4개로 줄었다. 기기 상태는 재현 중 여행36→37/확정 지하철2→5로 갱신되어 시점 간 숫자를 동일 입력의 전후 비교로 주장하지 않는다. 최종 배분 전 기기 경로5개에서 발바닥 후보120개를 확인해, 전체 경로에 배분하는 보정을 추가했다. 남은 미복구 조각은 전체 추정 노선과 별개이며 근거 없는 단일 조각을 확정 경로로 둔갑시키지 않는다.
- 검증 산출물은 `build/validation/SUB1001A01/`. 실제 화면 표시/터치는 자동 원본 재현·빌드·설치와 구분하며 사용자 화면 확인 전 temp.md에 유지한다.

## BVD1001A01 · 실제 백업 기기 복호·엄격 페이지 검증 (2026-10-01)

- 최종 실기기 읽기 전용 복원 준비(10/1 01:11 KST): 기기 잠금 때문에 첫 launch가 거부됐으나 이후 재시도 success를 확인했다. `iphone18-preflight-final-verification.json`에서 9·10월 모두 strict verified, 8월 PIN/계정 key unwrap false, 전체 `restore_preflight_verified=true`, 활동50건/raw5104건/envelope232개/제외 snapshot1개를 읽었다. 실제 사용자 자료로 BKR의 과거 월 실패 분리까지 검증한 결과다. `rewrapRecoveredArchive=false`로 archive 재봉인을 수행하지 않았고 applyCloudBackup/현재 기록 교체는 호출하지 않았다. 최신 iCloud snapshot/raw 경로·생성 시각은 그대로였다.
- 사용자 디버깅 요청에 따라 기존 기기 자격 증명을 내부에서만 사용하는 읽기 전용 검증을 추가했다. snapshot checksum·키 열기·AEAD·압축/내용 decode와 raw generation 참조·checksum·모든 페이지 AEAD/내용 decode를 검증한다. raw `allowsPartialRecovery=false`로 손상 페이지를 성공에서 제외하지 않는다. 기존 실제 복원의 부분 복구 기본값은 유지했다.
- Debug 전용 `--verify-cloud-backups` 실행은 앱 잠금이 해제된 상태에서만 1회 수행한다. tmp 보고서에는 월/시각/참조 ID/단계/개수/키 일치 여부만 기록한다. PIN·키·좌표·건강·일정 원문을 외부로 꺼내지 않는다. 실제 기록 교체는 호출하지 않는다.
- iPhone18 첫 실기기 검증 00:52, 키 단계 재검증 00:58: 9월 최신 snapshot 활동50건/raw5094건/envelope231개와 10/1 00:33 신규 snapshot 활동50건/raw10건/envelope1개 모두 `verified=true`. 현재 PIN으로 payload key를 열었고 raw는 손상 페이지 건너뜀 없는 전체 검증을 통과했다. 두 보고서 `build/validation/BVD1001A01/device-verification.json`, `iphone18-key-verification.json`.
- 8월 snapshot은 `snapshot_key_unwrap`, `invalidArchive`, `pinKeyMatches=false`, `accountKeyMatches=false`였다. 현재 iPhone18의 두 키로 보관된 payload key를 열 수 없는 상태를 확인했다. 이 사실만으로 payload 파일 자체의 손상이라고 단정하지 않는다. BKR1001A01에서 수정한 이전 월 실패와 최신 정상 월 복원 분리 경로에 해당한다. 원본은 보존한다.
- iPhone11 설치·검증 실행은 성공했으나 PIN 미등록 `pinRequiredForCloudBackup`로 월별 검증과 전체 preflight 모두 진행하지 못했다 (`iphone11-preflight-verification.json`). 새 PIN을 임의로 등록하거나 기존 자격 증명을 초기화하지 않았다. 이전 파일 복호 가능 기기로 판정하지 않는다.
- SecurityBackupCoreTests 전체 128 passed / 0 failed / 0 skipped (`backup-verification-fixed.xcresult`, `test-summary.json`). 키 구분 추가 후 관련3개 통과 (`key-stage-tests.xcresult`), 읽기 전용 복원 준비 플래그 추가 후 관련4개 통과 (`readonly-preflight-tests.xcresult`, `preflight-summary.json`). 초기 빌드/테스트는 파일 전용 JSONEncoder 접근 보호 오류로 컴파일 실패했고 로컬 보고서 encoder로 수정했다. 실패 로그도 보존했다.
- 최종 generic iOS Debug 성공 (`debug-preflight.log`), diff 검사 통과. 두 기기에 Debug 1.0(163) 설치 성공. 공개 UI의 기본 복원 동작을 유지하고 `rewrapRecoveredArchive=false`일 때만 준비 과정의 archive 재봉인을 끄도록 했다. 해당 회귀에서 과거/현재 archive 사전 전체가 변하지 않음을 확인했다.
- 처음 전체 preflight launch는 기기 Locked로 실패했고 사용자에게 잠금 해제를 요청했다. 이후 `iphone18-preflight-resume-launch.json` success와 위 최종 보고서를 확보했다. 실제 데이터 교체나 8월 복호는 수행/성공한 것으로 보고하지 않는다. 본 디버깅·읽기 전용 검증 요청은 완료이며 실제 DB 복원 관련 다른 ID를 완료로 확대하지 않는다. push/TestFlight 업로드는 수행하지 않았다.

## BKR1001A01 · 월별 백업 키 혼합·이전 archive 실패 분리 (2026-10-01)

- 실제 복원 준비 추가 검증은 BVD1001A01 참조: 현재 키로 8월 snapshot key를 열 수 없지만 9·10월은 strict decode 성공. 수정된 전체 준비도 활동50/raw5104/envelope232·제외 snapshot1로 성공했다. 실제 기록을 교체하는 적용 단계는 이번 디버깅에서 실행하지 않았다.
- 실제 저장 추가 확인(10/1 00:33:31 KST): 사용자가 백업 완료를 보고했고 iCloud에 신규 10월 snapshot `2A6324EF-A8E1-4C76-B634-CEAB7FAD7963`와 raw generation `985AEBD5-19F5-459D-8A38-54157DF735E9` 파일 두 개가 도착했다. 둘 다 version4이며 encrypted payload SHA256/digest, month/account scope, snapshot→raw generation 참조가 모두 일치한다. 이전 00:08 snapshot/raw도 보존됐다. BKR 설치·실행(00:21~00:22) 이후 신규 저장 성공 근거다. 메타데이터·검증만 `build/validation/BKR1001A01/icloud-backup-003331-confirmed.json`에 보존했다. 사용자 PIN/키를 읽지 않았으며 AEAD 복호/실제 복원/과거 월 병합 성공까지 확인한 것은 아니다.
- 사용자 무결성 오류 재발 보고를 받았다. iCloud latest는 여전히 9/30 23:44 로그이며 신규 snapshot/raw의 encrypted payload SHA256은 저장된 digest와 일치한다(DAY0930A01 추가 업로드 검증 참조). 이 사실은 AEAD 복호·페이지 내용 검증 성공을 의미하지 않는다. 기기 fallback 진단 로그 복사도 파일 부재 오류였고, 실제 이번 오류가 저장/복원/자동 처리 중 어느 단계인지는 새 근거 대기다.
- 코드에서 재현한 결함: restore가 선택된 전체 월 snapshot을 throwing map으로 읽어 과거 월의 키 불일치 하나가 정상 최신 파일도 막았다. PIN 실패 후 account-only 재시도는 현재 PIN으로만 읽히는 최신 파일과 계정 키로 읽히는 과거 파일의 혼합도 실패시켰다.
- 수정: 최신 snapshot을 먼저 검증하며 최신 실패는 계속 오류로 처리한다. 이전 archive는 PIN·계정 키를 파일별로 함께 시도하고 둘 다 실패한 파일만 제외한다. 계정 불일치·취소는 제외하지 않는다. package에 제외한 snapshot 수를 담고 기존 복원 확인 화면에서 이전 파일 제외/원본 보존을 안내한다. 기존 archive는 삭제하거나 덮어쓰지 않는다. raw의 기존 부분 복원 정책과 generation/deletion fence는 유지했다.
- 저장에도 `icloud_backup_generation_stage`의 recovery_key → previous_snapshot → raw_archive → snapshot_archive → committed 단계를 추가했다. PIN/키/좌표/건강/일정 원문은 기록하지 않는다. 기존 `invalidArchive` 문구만 바꿔 성공처럼 표시하지 않았다.
- 최종 SecurityBackupCoreTests 전체 **126 passed / 0 failed / 0 skipped**, `build/validation/BKR1001A01/backup-complete.xcresult`, `backup-complete-summary.json`. 새 회귀는 이전 월 키 불일치와 원본 불변, PIN/계정 혼합 월 복원, 최신 손상 파일 복원 거부를 확인한다. 초기 검증은 fixture에서 private API 인자를 사용한 컴파일 오류, 이어 최신 손상본을 다른 경로/동일 시각으로 넣어 정상 파일이 선택된 기대값 오류(125 통과/1 실패)가 있었다. fixture를 실제 최신 시각·generation으로 보정했으며 실패 산출물은 보존했다.
- iOS Debug 최종 `BUILD SUCCEEDED` (`debug-final.log`), diff 검사 통과. iPhone18 Debug 1.0(163) 설치·실행 각각 success (`install.json`, `launch.json`). 빌드 번호 변경·push·TestFlight 업로드·실제 기기 기록 복원은 수행하지 않았다.
- 남음: 실제 새 iCloud 저장은 위 추가 확인으로 완료. 과거 월 키 혼합 복원 및 실패 당시 정확한 단계는 실제 복원/진단 로그 근거 전까지 대기한다. temp.md 유지.

## DAY0930A01 · 9/30 경로 소실·회사 업무 재계산 수정 (2026-10-01)

- 업로드 후 추가 확인(10/1): iCloud latest.json은 `TaptionLogs-20260930-234421.txt`(9/30 23:44 KST)를 가리킨다. 이전 업로드 이후 23:39:48 및 23:41:02에도 `CancellationError` → incomplete_projection → raw0/travel0/places0 → 재생 경로0이 재현됐다. 수정본 설치 완료는 10/1 00:03:04, 실행은 00:03:25이므로 이번 파일은 수정 전 증거다. 수정 후 재발/해결 판정으로 사용하지 않는다. 신규 snapshot/raw backup encrypted payload checksum은 둘 다 일치하나, 평문 센서 원본이나 회사 체류 근거를 확보한 것으로 처리하지 않는다. 메타데이터·필요 이벤트만 `build/validation/DAY0930A01/icloud-upload-234421-review.json`에 보존했다.
- 9/30 iCloud 진단 로그 `TaptionLogs-20260930-233407.txt`의 관련 이벤트를 확인했다. 21:58 KST 완전 snapshot(raw1396/travel17), 이후 읽기 취소와 빈 불완전 projection, 23:12경 정상 재생성(raw1414/travel18), 23:31경 `CancellationError` 이후 raw0/travel0/places0 및 지도 경로0으로 전환됐다. 원본 삭제 증거가 아니라 취소/불완전 읽기가 화면을 덮는 경로다.
- day coordinator는 다른 날짜의 읽기를 취소하지 않고, 같은 키의 진행 중 강제 읽기를 공유한다. 취소/불완전 읽기 때 지도는 마지막 완전 snapshot을 preview로 유지하며 현재 source revision으로 재투영해 사용자 수정도 보존한다. 삭제 generation fence와 취소 검사는 유지했다. `map_incomplete_reload_kept_preview`는 개수만 기록한다.
- 회사 업무의 별도 코드 결함: 이전 `place-activity-v1` 자동 기록이 새 후보를 overlap blocker로 막고, 뒤이어 이전 기록을 제거했다. 갱신 엔진에서 자기 이전 자동 결과와 자동 미확인은 blocker에서 제외했다. 사용자 수정·suppressed ID·다른 확정 자동 활동은 보존한다. 회사 반경/최소 체류 조건은 변경하지 않았다.
- `SensorDayStoreTests` + `RouteTimelineDataTests`: 196 passed / 0 failed / 0 skipped. 새 회귀는 독립 날짜 동시 읽기, 강제 읽기 합치기, 회사 업무 반복 갱신/미확인 overlap, 사용자 수정·억제 보존을 확인한다. 기존 취소·삭제 fence·캐시 관련 검증도 포함한다. `build/validation/DAY0930A01/regression.xcresult`, `test-summary.json`.
- 최종 iOS Debug `BUILD SUCCEEDED` (`debug-final.log`), `git diff --check` 통과. iPhone18 Debug 1.0(163) 설치·실행 성공 (`install.json`, `launch.json`). 기존 자료 보존, push/TestFlight 배포는 수행하지 않았다.
- 제한: 9/30 실제 센서 원본 export를 아직 확보하지 못했고 기기 tmp export 목록 읽기도 실패했다. 실제 회사 체류 및 수정 후 9/30 화면의 경로/업무 표시를 확인한 것으로 처리하지 않는다. 이 기준은 temp.md에 유지한다. 과거 전체 앱 테스트 실패 해결로 확대 해석하지 않는다.

## CRAS0930A1 · iPhone 18 Pro Max 1.0(163) 충돌 보고서 분석 (2026-09-30)

- 기기에서 `systemCrashLogs` 도메인을 읽어 `Retired/TaptionPlan-2026-09-30-141604.ips`를 새로 복사했다. 보고서 메타데이터는 `com.taption.plan`, TestFlight 1.0(163), iPhone 18 Pro Max (`iPhone19,7`), iOS 27.2 (24B5089g), 2026-09-30 14:16:04 KST와 일치한다. 설치 앱 목록도 1.0(163)으로 확인했다. 파일 및 기기 readback: `build/validation/CRAS0930A1/`.
- 종료는 `EXC_CRASH (SIGKILL)`, `FRONTBOARD` code `0x8BADF00D`, `scene-update watchdog transgression`이다. 앱은 `ProcessVisibility: Background`, `ProcessState: Running`이었고 scene update의 실제 시간 allowance 10초를 소진했다. 보고서상 application CPU 10.201초, thermal state nominal. 따라서 기존 iPhone 11 파일 잠금 `0xDEAD10CC`나 메모리 jetsam과는 다른 종류의 종료다. Apple은 `0x8badf00d`를 watchdog 종료로, `scene-update`를 메인 스레드 UI 업데이트 제한 초과로 설명한다: [watchdog termination codes](https://developer.apple.com/documentation/xcode/sigkill?language=objc), [addressing watchdog terminations](https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations?changes=_1).
- Triggered thread 0은 `com.apple.main-thread`; 앞부분이 `Hasher.combine(bytes:)` → `UUID.hash(into:)` → TaptionPlan 이미지 프레임 8개 → SwiftUI `AG::Graph::UpdateStack::update()` / `AG::Subgraph::update()`로 이어진다. 이 시점에 메인 스레드가 SwiftUI AttributeGraph 갱신 중이었던 것은 확정이다. 지도/시간축 갱신은 코드상 후보지만, UUID hashing은 그 스냅샷의 호출 위치일 뿐 과도한 UUID 수나 특정 SwiftUI view가 원인이라는 증거는 아니다.
- 앱 이미지 UUID `227B98A5-DE75-3F63-9FEA-D1797BA72491`. App Store Connect API에서 build 163의 `includesSymbols=true`와 `dSYMUrl=null`을 readback했다(`asc-build-dsyms.json`). 현재 source로 Release dSYM build는 성공했지만 로컬 앱 UUID `8623F483-F0B9-3D16-9A9A-26A397EBA448`로 달라 crash report의 앱 프레임 offset을 심볼화할 수 없었다(`symbol-build.log`). 정확한 앱 함수명은 일치하는 dSYM/archive를 얻기 전까지 미확정이다.
- 앱 소스 수정이나 기능 테스트는 하지 않았다. 분석 중 생성한 현재 Release symbol build는 `BUILD SUCCEEDED`이며 단지 심볼 일치 시도를 위한 산출물이다.

## TFL0928C01 · main 반영 및 TestFlight 163 (2026-09-28)

- 배포 전 App Store Connect API readback에서 최근 빌드 162 `VALID`, 최고 번호 162를 확인했다. 기록 `build/validation/TFL0928C01/asc-builds-before.json`.
- 앱 전체 테스트: **1,427 통과, 1 건너뜀, 0 실패 (총 1,428)**. 건너뜀은 `FeatureEngineTests.testStoreKitProductPurchaseEntitlementAndRestore`이며 iOS 26.5 StoreKitTest 환경 보호 항목이다. 구매/IAP를 검증하지 않았다. `build/validation/TFL0928C01/app-tests.xcresult`, `app-tests.log`.
- 366개 `HomeEvolution` SVG 모두 고유, 인접 레벨 365쌍 차이 확인. `CURRENT_PROJECT_VERSION` 8개 설정 및 앱·iPhone Widget·Watch·Watch Widget `CFBundleVersion`을 163으로 맞췄다.
- 커밋 `a4cdab4030b8f9dd6e6f1d804ccb71a83527f22f` (`Polish map activity visuals and daily home evolution`)을 `main`에 만들고 `origin/main`에 push했다. 직후 워크트리는 clean이고 local/remote HEAD가 같다.
- 해당 커밋에서 Release archive와 App Store Connect internal-only Production export에 성공했다. archive와 IPA의 앱·iPhone 위젯·Watch 앱·Watch 위젯 네 번들 모두 1.0(163), IPA 서명 entitlement `iCloudContainerEnvironment=Production`. archive/export 로그와 IPA는 `build/validation/TFL0928C01/`에 있다.
- iOS generic Debug 빌드 `BUILD SUCCEEDED`: `build/validation/TFL0928C01/ios-debug.log`.
- `altool --upload-app` 업로드 성공, Delivery UUID `bd7a8004-7df6-478c-a63e-d606ed4be1ad`. `altool --build-status`와 App Store Connect API에서 build 163 `VALID`, `INTERNAL_ONLY`를 확인하고 `TP Taption Plan 내부 테스트` 그룹에 연결했다. 최종 그룹 API readback에서 build attached와 테스터 1명을 확인했다: `build/validation/TFL0928C01/testflight-readback.json`. App Store Connect 웹 페이지는 `authResult=FAILED` 로그인 화면을 반환해 화면 캡처는 불가했다.
- 최종 검증 기록을 포함한 문서 커밋은 후속 main 커밋으로 push한다. 공개 제출/IAP는 수행하지 않았다.

## UNCF0928A1 · 미확인 입력 대분류 확정 유지 (2026-09-28)

- 앱 부팅 전 레일을 `.wholeDayUnconfirmed`로 임시 채우던 부모 상태와 빈 `MapHomeTimeSidebarRailSnapshot`의 fallback을 제거했다. `model.isBootstrapped` 전에는 레일·현재 활동 표시를 비우고 시간 편집 및 미확인 입력 콜백을 막는다. 데이터 로드 완료 후 실제 미확인 구간은 이전 정책대로 표시한다.
- 미확인 공백에서 업무 대분류를 저장한 뒤 같은 repository로 `AppModel`을 새로 만들고 다시 부팅하는 테스트에서 업무 분류가 유지됐다. 이후 같은 시간에 겹치는 HealthKit 자동 활동을 추가해도 수동 확정 분류가 우선하며 확인 대상에서 빠진다.
- 요청 회귀 6종 통과: `FeatureEngineTests.testConfirmedUnconfirmedCategorySurvivesReloadAndLateAutomaticRecord`, `testActivitySectionSaveOverridesTravelAndSupportsImmediateReedit`, `testPartialUnconfirmedEditPreservesSourceOutsideSelectedSpan`, `TimeScaleTests.testMapHomeSidebarRailSnapshotIndexesOnlyVisibleIntervals`, `testQuestionMarkMarkersOnlyExistForActualVisibleUnconfirmedActivity`, `testQuickConfirmedIntervalDisappearsFromUnconfirmedReview`. 결과 `build/validation/UNCF0928A1/app-tests.xcresult`, `app-regressions.xcresult`, `unconfirmed-review.xcresult`; 모든 실행 `TEST SUCCEEDED`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/UNCF0928A1/ios-debug.log`. `git diff --check` 통과.
- iPhone 11 Pro에 Debug 1.0(162)을 설치하고 실행했다. 첫 화면 캡처 `build/validation/UNCF0928A1/iphone11-startup.png`에서는 로딩용 가짜 `?`가 보이지 않았다. 재실행 명령의 첫 두 캡처는 검은 화면이었고, 프로세스를 종료한 뒤 새로 실행하자 지도가 표시됐다(`iphone11-relaunch-fresh.png`). 이 캡처에는 13:50 선택 시각 옆에 실제 미확인 마커가 하나 나타났지만, 그 구간이 사용자가 이전에 확정한 바로 그 구간인지는 화면 자료만으로 식별할 수 없다. 따라서 해당 구간의 실기기 저장·재진입 확인은 미완료다.

## LOC0928A01 · 등록 장소 마커 지도 팔레트 통일 (2026-09-28)

- 집·회사·학교·학원·운동·취미·식당·사용자 장소의 색을 저채도 어스톤으로 바꿨다. 지도 랜드마크 기호는 모두 크림 표면·지도 라인 테두리·갈색 계열 그림자가 있는 같은 크기의 배지로 표시한다. 집 그림에도 은은한 크림 배경과 지도 테두리를 적용했다. 라벨과 위치 목록 썸네일은 같은 장소 강조색을 쓴다.
- `FeatureEngineTests.testRegisteredLocationTintsUseDistinctParchmentMapColors`, `testMapHomeLocationHierarchyKeepsConfiguredAndUserDestinationsDistinct`, `testRegisteredPlaceIconCenterMatchesStoredCoordinate`, `testCatTapRoutingAcceptsOnlyTapsInsideMarkerBounds` 통과(4/4). 결과 `build/validation/LOC0928A01/app-tests.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/LOC0928A01/ios-debug.log`; `git diff --check` 통과. 실기기 지도 화면은 미확인이다.

## BAK0928A01 · 수동 백업을 자동 설정과 분리 (2026-09-28)

- `FeatureEngineTests.testManualCloudBackupWorksWhenAutomaticBackupIsDisabled` 및 `testManualCloudBackupRejectsIncompleteSensorArchiveBeforeReplacingGeneration` 통과(2/2): 월별 자동 백업 off + PIN 상태에서 수동 저장은 성공하고, 센서 raw archive가 불완전하면 이전 세대와 raw 자료를 보존한다. `build/validation/BAK0928A01/app-tests-retry.xcresult`.
- `SecurityBackupCoreTests.testCloudBackupAndAppLockRequirePIN` 통과(1/1). 수동 generation 저장도 PIN이 없으면 `.pinRequiredForCloudBackup`로 거부한다. `build/validation/BAK0928A01/pin-guard-tests.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/TRN0928A01/build.log`; `git diff --check` 통과. 실제 iCloud 계정으로의 백업과 기기 설정 화면은 미검증이다.

## TRN0928A01 · 기차 이동에서 지하철 카탈로그 경로 생성 (2026-09-28)

- `.train` 이동 시간 안의 센서 표본에서 지하철 카탈로그 경로가 유효하게 복원될 때 지도에 추정 스타일 경로를 표시한다. 현재 재생 시점 이후 표본은 사용하지 않고, 역 순서/노선 증거가 부족하면 경로를 만들지 않는다. 경로 복원 엔진은 유효한 카탈로그 노선이 붙은 `.train` 추론도 지하철 세그먼트로 정규화한다. 복원된 지도 캐시는 첫 렌더에서 최신 센서 기반 추정 경로를 다시 계산한다.
- `FeatureEngineTests.testTrainMovementDrawsEstimatedSubwayCatalogRouteOnlyWithRailEvidence`, `testSparseRailEndpointsRestoreSubwayWithoutRoadFalsePositive`, `testMapHomeSubwayOverlayDoesNotDrawUnconfirmedWholeRoute`, `testRailEndpointsBridgeThirtyMinuteGPSGapOnlyOnCatalogRoute` 통과(4/4). 결과 `build/validation/TRN0928A01/app-tests.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/TRN0928A01/build.log`; `git diff --check` 통과. 실기기 지도 표시는 아직 미확인이다.

## CBG0928A01 · 화랑이 장면 배경·크기 통일 (2026-09-28)

- 지도 고양이 20개 동작마다 배경 아이콘과 의미 색상을 연결했다. 회사·학교·수면·식사·운동·취미·이동·교통 등 각 상황의 심볼을 낮은 대비로 장면 뒤에 배치하고 장면 캔버스 안에서 원형 클립한다.
- 동작별 개별 스케일(운동·수면 포함)을 없애고 캔버스 폭의 86%로 공통 크기 비율을 사용한다. 30·36·42pt 크기 및 0/무한 입력 경계 검사 포함.
- `MapHomeStickmanTests.testCatSceneBackgroundCoversEveryActionWithConsistentSpriteScale` 통과. 최종 `focused-verified.xcresult`, 로그 `build/validation/CBG0928A01/focused-verified.log`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/CBG0928A01/ios-debug-final.log`; `git diff --check` 통과. 전체 동작의 실제 지도 화면은 아직 기기에서 확인하지 않아 `temp.md`에 대기로 남긴다.

## WPL0928A01 · 현재·예보 날씨 알약 배경 (2026-09-28)

- 현재 관측 배경은 순백색, 미래 예보 배경은 불투명 `tpSurface`로 지정하고 두 배경 모두 alpha 1로 렌더한다. 예보 아이콘·온도 텍스트만 기존 비활성 표시 opacity 0.58을 유지한다.
- `TimeScaleTests.testWeatherTimelineDimsForecastsAndScalesWidgetsToEightyPercent` 통과. 같은 결과 번들에서 배경 스타일·불투명도 assertion 확인. generic iOS Debug와 `git diff --check` 통과.

## TF0928B162 · `?` 조건부 표시 TestFlight 162 (2026-09-28)

- QMRK0928A1 포함 main 커밋 `25322bb` 푸시 완료. 빌드 162로 앱·Widget·Watch·Watch Widget 버전을 맞췄다. IPA 내부 네 번들의 `CFBundleVersion` 모두 162.
- iOS Debug 및 Watch Debug 빌드 통과. Release archive 및 Production CloudKit entitlement 포함 IPA export 통과.
- App Store Connect 업로드 성공, Delivery UUID `46a8ee1e-cded-4fcf-aef7-4b06c89a3cd3`; 처리 상태 `VALID`. `TP Taption Plan 내부 테스트` 그룹 연결 후 API readback에서 빌드 노출과 테스터 1명을 확인했다. 근거 `build/validation/TF0928B162/testflight-readback.json`; archive/export/upload 로그는 같은 경로.
- iPhone 11 Pro에 build 162 설치 및 실행 성공. 기기의 앱 목록에서 버전 1.0 (162), 실행 프로세스 PID 2688을 확인했다. 요약 `build/validation/TF0928B162/iphone-device-readback.json`; 원본 devicectl 결과는 같은 폴더. iPhone 18 Pro Max는 현재 `unavailable`.
- App Store Connect 웹 그룹 화면과 기기 화면에서 실제 `?` 표시/숨김 동작은 아직 확인하지 않았다. iPhone 11은 실행까지만 확인했으며 QMRK0928A1 및 TF0928B162는 해당 확인이 끝날 때까지 열린 상태로 둔다.

## QMRK0928A1 · 미확인 `?` 마커 조건부 표시 (2026-09-28)

- `MapHomeTimeSidebarRailSnapshot`은 표시용 입력이 비면 하루 전체 `.wholeDayUnconfirmed` 구간을 합성한다. 이전 `?` 계산은 이 표시 snapshot에서 시작해 원본 구간이 없는 날에도 마커를 만들 수 있었다.
- 마커는 이제 실제 입력 `segments`에서 날짜 정책과 현재 보이는 시간 범위를 적용해 만든다. 빈 원본, 확정 구간만 있는 날, 현재 날짜의 미래 구간, 화면에 보이지 않는 구간은 마커 대상이 아니다. 시간 레일의 표시용 합성 구간은 기존 동작대로 유지한다.
- `TimeScaleTests.testQuestionMarkMarkersOnlyExistForActualVisibleUnconfirmedActivity` 통과(1/1): 빈 입력·확정만·미래·화면 밖에서 0개, 실제 보이는 미확인 구간만 반환. 결과 `build/validation/QMRK0928A1/questionmark-focused.xcresult`, 로그 `questionmark-focused.log`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/QMRK0928A1/ios-debug.log`; `git diff --check` 통과. 실기기에서 두 상태 화면을 보기 전까지 기기 검증은 대기한다.

## ALLT0927A1 · iPhone 11 Pro current Debug 160 실행 확인 (2026-09-28)

- 현재 소스에서 빌드한 signed Debug 앱을 연결된 iPhone 11 Pro (`iPhone12,3`, iOS 26.7/23H24)에 update-in-place 설치했다. 기존 앱 데이터를 초기화하지 않았다. `devicectl` 설치 성공 로그/JSON: `build/validation/ALLT0927A1/iphone11-session-20260928/install-debug-160.log/json`; 앱 목록 readback은 `com.taption.plan`, version 1.0, build 160.
- 앱 실행 명령 성공 후 settled screenshot에서 지도 홈, 날짜 헤더, 오른쪽 시간 레일/날씨, 집·불·고양이 마커 및 왼쪽 Undo/Redo가 보인다: `build/validation/ALLT0927A1/iphone11-session-20260928/debug-settled.png`. 기기 프로세스 목록에서 `TaptionPlan` 프로세스가 확인됐다. 첫 실행 직후의 전환 애니메이션 캡처는 `debug-after-launch.png`이며 판정에는 사용하지 않았다.
- 실행 전후 시스템 crash-log 목록에 새 Taption Plan 항목이 없고 기존 9/27 보고서 3건만 보였다. 이는 짧은 시작·화면 확인에서 새 충돌이 관찰되지 않았다는 근거이며, 장시간 백그라운드 복귀 안정성이나 0xDEAD10CC 재발 부재를 입증하지 않는다.
- 화면상 Undo/Redo 컨트롤 존재는 확인했지만 조작/기록 변경/복구는 하지 않았다. HealthKit 온보딩, 터치, 빠른 입력 저장, GPS 이동·회색 예측 경로, 회사·학교 고양이, 집 탭, 날씨 상태, 백업/계정/캘린더/Watch/수면은 미검증이다. 따라서 연결된 요청은 열린 상태다.

- 같은 current Debug 1.0(160)을 iPad Pro 12.9-inch (6th gen, iPad14,6)에 update-in-place 설치하고 앱 실행 및 화면 캡처를 완료했다 (`build/validation/ALLT0927A1/ipad-session-20260928/`). 화면은 온보딩 1/4의 위치·이동 단계다. 앱 설치 당시 권한 상태를 관찰했을 뿐, 버튼을 누르거나 권한을 변경하지 않았다. iPad readback은 시작·온보딩 표시까지만 확인한다.
- iPhone 18 Pro Max는 현재 연결 목록에서 `unavailable`이므로 current Debug 설치/로그 수집을 하지 못했다. 대표님 제공 영상·로그 분석을 기다린다.

## ALLT0927A1 · 최신 자동 검증 요약 (2026-09-28)

- 현재 작업 트리에서 앱 전체 테스트 **1,421 통과, 1 건너뜀, 0 실패 (총 1,422)**. 유일한 skip은 `FeatureEngineTests.testStoreKitProductPurchaseEntitlementAndRestore`; iOS 26.5 StoreKitTest가 `SKInternalErrorDomain Code 3`으로 시작되지 않았다. 원본 `build/validation/ALLT0927A1/app-tests-current-20260928.log` 및 `.xcresult`.
- Swift package 테스트: TaptionPlanCore 101/101, TaptionRouteEngine 39건 통과, TaptionActivityEngine 33/33, TaptionPlanEngine 1/1. 로그는 `package-core-20260928.log`, `package-route-20260928.log`, `package-activity-20260928.log`, `package-plan-20260928.log`.
- generic iOS Debug 및 Watch Debug 빌드 모두 성공. 로그 `ios-debug-current-20260928.log`, `watch-debug-current-20260928.log`. 전체 앱 테스트에는 GPS gap 보간·2행 카테고리 회귀가 포함됐다.

## ALLT0927A1 · 전체 앱 회귀·현재 Debug 기기 실행 (2026-09-28)

- 현재 수정 작업 트리 전체 앱 테스트 **1,427 통과, 1 건너뜀, 0 실패 (총 1,428)**. StoreKit 상품 구매/복원 테스트 1건은 iOS 26.5의 기존 시뮬레이터 환경 보호 skip이며, 별도 판매 검증으로 계산하지 않았다. 과거 실패 13건은 이번 전체 실행에서 재현되지 않았다. 결과 `build/validation/ALLT0927A1/current/app-tests.xcresult`, 로그 `app-tests.log`.
- TaptionPlanCore 101/101, TaptionRouteEngine 39/39, TaptionActivityEngine 33/33, TaptionPlanEngine 1/1 통과. 출력 로그는 `build/validation/ALLT0927A1/current/*-package.log`.
- generic iOS Debug 및 Watch·Watch Widget Debug 빌드 모두 `BUILD SUCCEEDED`: `build/validation/ALLT0927A1/current/ios-debug.log`, `watch-debug.log`. 앱·iPhone Widget·Watch 앱·Watch Widget 산출물의 bundle ID와 build 162를 각각 확인했다.
- 현재 소스 Debug 1.0(162)을 iPhone 11 Pro에 update-in-place 설치·실행했다. 캡처 `build/validation/ALLT0927A1/current/iphone11-after-launch.png`에는 지도 홈, 집·화랑이, 시간축, 날씨 및 Undo/Redo 컨트롤이 보인다. 터치/저장·실제 이동은 검증하지 않았다.
- 같은 Debug 1.0(162)을 iPad Pro에 설치·실행했다. 캡처 `build/validation/ALLT0927A1/current/ipad-after-load.png`는 온보딩 1/4 위치 단계다. 권한 버튼을 누르지 않았으므로 온보딩 진행 검증은 미완료다. iPhone 18 Pro Max는 연결할 수 없어 실기기 검증을 못 했다.
- `git diff --check` 통과. 4개 Swift package 테스트를 동시에 별도 빌드하려던 후속 실행은 디스크 부족으로 실패했다. 이 재실행 실패를 테스트 실패나 통과로 계산하지 않으며, 앞서 완료된 package 결과는 별도 출력으로 통과 확인했다. 임시 package scratch 폴더만 제거해 여유 공간을 회복했다.
- 실기기 캡처 `build/validation/ALLT0927A1/current/iphone11-after-relaunches.png`에서 오른쪽 시간축이 헤더 아래부터 하단 콘텐츠 영역까지 확장되고 00–24 시간 라벨 및 활동 구간이 서로 겹치지 않는 것을 확인했다. MARG270927 실기기 화면 기준을 통과했다. 짧은 레일의 조작 간격은 회귀 테스트 기준으로 확인했다.

## TF0928B161 · TestFlight/CloudKit 환경 제약 확인 (2026-09-28)

- App Store Connect API build 목록에서 최고 번호 1.0(160), 상태 `VALID`를 확인했다. `altool --build-status`에서도 delivery UUID `a40c7d53-56ae-429f-9ec8-14afdb85f529`의 160 `VALID`를 재확인했다. API 응답은 `build-status-160-recheck.json`에 보관했다.
- 161 archive를 생성하고 archive 내 앱 `com.taption.plan`, iPhone 위젯, Watch 앱 번들이 모두 build 161인지 확인했다. `archive-161.log`, `TaptionPlan161.xcarchive`.
- 기존 export options의 `iCloudContainerEnvironment=Production`은 현재 승인된 Development-only 조건에 맞지 않았다. 이를 `Development`로 변경해 `app-store-connect` export를 시도했으나 Xcode가 `value "Development" is not allowed`로 거부했다. `export-161.log`, `export-161/ExportOptions.plist`.
- Apple 설명에 따르면 TestFlight로 배포하는 앱은 CloudKit Development 환경을 사용할 수 없으며 Production만 사용한다: [Apple Testing Your CloudKit App](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/TestingYourApp/TestingYourApp.html), [CKContainer](https://developer.apple.com/documentation/cloudkit/ckcontainer?language=_3). 사용자가 이후 Production 사용을 명시 허용했다. `Development` export는 실패했지만 `Production` export는 성공했고 exported app entitlement readback이 Production이다. Internal-only option을 적용했고, 업로드·처리·그룹 검증은 후속 상태다.

## SK0928B001 · StoreKitTest 건너뜀 단독 재검증 (2026-09-28)

- `FeatureEngineTests.testStoreKitProductPurchaseEntitlementAndRestore`의 iOS 26.5 simulator skip을 단독 검증 목적으로 일시 우회해 실제 테스트를 시작했다. `SKTestSession` 초기화·상품 identifier 설정부터 `SKInternalErrorDomain Code 3`이 재발했고, 이후 `StoreProductPresentation`이 nil이라 `XCTUnwrap` 실패했다. 1개 실행·1개 실패. 로그 `build/validation/SK0928B001-storekit-test-rerun-20260928.log`; xctest stdout/stderr는 result bundle staging 안에 저장된다.
- 실패 원인은 앱 구매 entitlement assertion 전에 StoreKitTest session이 configuration/transaction override를 설정하지 못한 테스트 런타임 오류다. SKTestSession 정리 호출도 같은 Code 3을 반환했다. 실제 상품 로드가 없어 구매/복원 로직 결과는 검증하지 못했다.
- 이전의 iOS 26.5 환경 보호 skip을 테스트 소스에 복구했다. 판매/IAP 동작을 바꾸지 않았고 실제 구매도 하지 않았다. 다른 iOS 런타임이나 physical-device StoreKit configuration으로 실행하기 전까지 skip은 유지한다.

## TF0928B161 · TestFlight 1.0(161) Production 내부 빌드 생성 (2026-09-28)

- 최신 앱 소스의 Release archive 성공: `build/validation/ALLT0927A1/archive-161.log`, `TaptionPlan161.xcarchive`. archive 앱/위젯/Watch 앱 번들의 `CFBundleVersion`은 모두 161.
- Development CloudKit export를 Xcode가 거부한 뒤 사용자가 Production을 허용했다. `testFlightInternalTestingOnly=true`, `iCloudContainerEnvironment=Production`으로 export 성공. IPA `build/validation/ALLT0927A1/export-161-production/TaptionPlan.ipa` (47 MB); 앱·iPhone widget·Watch app·Watch widget 네 번들 1.0(161), 앱 서명 entitlement Production을 확인했다. export 로그 `export-161-production.log`.
- 업로드 전까지 TestFlight Processing/그룹 연결 여부는 미확인이다. 공개 App Store 제출은 하지 않는다.
- iOS Debug 1.0(161) `BUILD SUCCEEDED`: `build/validation/ALLT0927A1/ios-debug-161-final.log`; Watch Debug 1.0(161) `BUILD SUCCEEDED`: `watch-debug-161-final.log`. Debug 앱·iPhone widget·Watch app 번들의 `CFBundleVersion`도 모두 161.
- `altool --upload-app` 성공, Delivery UUID `84e88d1b-9cb6-4545-9939-c68ee91ef642`; 로그 `upload-161.log`. 최초 `altool --build-status` 조회가 응답하지 않아 중단했다. 즉시 App Store Connect API 목록 readback에는 161이 아직 나타나지 않았고, 그룹 연결/테스터 노출도 미확인이다. 공개 App Store 제출은 하지 않았다.
- 후속 App Store Connect API readback에서 빌드 161 `VALID`, `TP Taption Plan 내부 테스트` 내부 그룹 `buildAttached=true`, 테스터 수 1을 확인했다. 검증 결과 `build/validation/ALLT0927A1/testflight-161-readback.json`. App Store Connect 웹 UI는 `authResult=FAILED` 로그인 화면을 반환해 그룹 화면 캡처는 확보하지 못했다.
- 커밋 `3709724` (`Implement timeline, GPS, and location presentation updates`)를 `main`에 push했다. 빌드 161은 해당 커밋의 1.0(161) Release archive에서 업로드됐다.

## ALLT0927A1 · iPhone 11 Pro build 160 기기 확인 시도 (2026-09-28)

- 대상 기기 정보: iPhone 11 Pro (`iPhone12,3`), iOS 26.7 (23H24), paired·wired, Developer Mode enabled. readback: `build/validation/ALLT0927A1/iphone11-details-current.json`.
- 최신 소스의 Release archive 앱(`com.taption.plan`, 1.0/160)을 CoreDevice가 저장소 경로에서 열지 못해 첫 설치 시도는 sandbox bookmark 오류로 실패했다. archive 제품을 `/tmp/taption-iphone11-160/TaptionPlan.app`로 복사한 뒤 재설치했고, `devicectl`이 `App installed` 및 성공 JSON (`outcome=success`, database sequence 2984)을 반환했다. 근거: `iphone11-install-160-success.log/json`.
- 앱 프로세스 실행, 실행 프로세스 목록, 앱 번들 목록 readback은 각각 15–20초 후 CoreDevice timeout이었다. 새 `0xDEAD10CC` 로그 확인용 system crash-log 복사도 CoreDevice에서 응답이 오지 않아 중단했다. 설치는 반복 확인(성공 readback DB sequence 2984)했지만 실행 여부·앱 목록은 원격 readback 불가다. 관련 근거는 `iphone11-install-160-success.log/json`, `iphone11-launch-160-retry.log/json`, `iphone11-processes-after-launch.log/json`, `iphone11-apps-readback-160-final.log/json`, `iphone11-apps-readback-160.log/json`, `iphone11-launch-160.log`, `iphone11-launch-start-stopped.log`.
- 따라서 성공 판정은 1.0/160 앱 설치까지만이다. 앱 시작·백그라운드 복귀·Crash 재발·HealthKit 온보딩·지도/시간 레일·미확인 구간 저장·Undo/Redo·집 카드·실기기 GPS·날씨 표시 등 UI와 센서 결과는 확인하지 못했다. 사용자가 조작/증거를 주지 않은 기능은 통과 처리하지 않는다.
- 요청 ID의 자동 테스트·Debug/Release 빌드 근거는 기존 각 섹션에 유지한다. 설치 이후 UI/센서 실증은 ALLT0927A1 및 연결된 항목에서 계속 대기한다.


## ALLT0927A1 · main push·TestFlight 160 제출 및 2대 기기 확인 시도 (2026-09-28)

- `main` 커밋 `d85addc1ac71aa2cc85c4169d75a3d338177b976` (`Complete map, onboarding, and backup improvements`)을 push했고 원격 `origin/main`과 HEAD가 일치하며 워크트리는 clean이었다.
- App Store Connect 전체 빌드 135개를 확인했다. 최고 빌드는 159 (`VALID`), 160은 없었고, `TP Taption Plan 내부 테스트` 그룹은 내부 그룹이며 테스터 1명이 등록돼 있었다.
- 최신 `main`에서 iOS Release archive 성공: `build/validation/ALLT0927A1/archive-160.log`, `TaptionPlan160.xcarchive`; 앱 번들 `com.taption.plan`, 버전 `1.0(160)` 확인. App Store Connect export 성공, IPA 47 MB: `build/validation/ALLT0927A1/export-160.log`, `export-160/TaptionPlan.ipa`.
- `altool --upload-app`는 오류 없이 업로드 성공, Delivery UUID `a40c7d53-56ae-429f-9ec8-14afdb85f529`; 증거 `build/validation/ALLT0927A1/upload-160.log`.
- 확인 제한: 업로드 후 여러 차례 ASC REST 조회에서 160이 인덱스되지 않았고 내부 그룹 빌드 목록에는 기존 159가 최신으로 남아 있었다. `altool --build-status`는 응답을 끝내지 못했다. 따라서 처리 완료·그룹 연결·테스터 노출은 미확인이다.
- iPhone 11 Pro (`00008030-001628201AD2802E`) 및 iPhone 18 Pro Max (`00008160-000E195A1140000A`)는 USB 연결 상태이나 TestFlight에서 160을 내려받을 수 있는 단계가 아니었다. `devicectl` 앱 인벤토리 조회도 응답 지연으로 중단되어 두 기기의 설치/버전은 확인하지 못했다. TestFlight 설치 완료로 처리하지 않는다.
- 이전 검증 로그나 기기에 남아 있을 수 있는 160의 직접 개발 설치 결과를 TestFlight 다운로드 증거와 혼동하지 않는다. 전체 ALLT0927A1과 배포/기기 단계는 계속 열린 상태다.


현재 실행 근거만 간결하게 유지합니다. 이전 상세 개발·검증 기록은 Git 이력에 보존했습니다. `build/validation/`은 로컬 증거이며 Git에 포함되지 않습니다.

## BKM0928A01 · raw 구버전 전환·불변 파일 공개·manifest 참조 (2026-09-28)

- `saveMonthlyGeneration`이 snapshot-only 백업에도 존재하지 않는 raw generation을 발행하던 결함을 수정했다. manifest는 실제 저장된 raw 세대만 참조하며, raw 입력 없이 이전 raw를 보존하는 경우도 회귀로 확인했다.
- `FilePlanCloudRawSensorBackupStore.save`의 generation 덮어쓰기를 막고 snapshot/raw가 같은 불변 파일 writer를 사용하게 했다. complete-protection staging에 기록·fsync한 뒤 같은 디렉터리의 최종 경로에 덮어쓰기 없이 원자적으로 공개한다. 동일 바이트 재시도는 성공, 다른 내용·경로/세대 불일치는 거부한다. protection 실패 시 최종 파일이 생기지 않고 staging이 정리됨을 확인했다.
- V1·V2·V3 snapshot/raw 파일을 실제 file store에 시드해 다음 백업의 V4 전환, legacy 원본 바이트 보존, 서비스 재생성 후 복원, 다음 V4 저장을 각각 확인했다. 현재 월의 다음 백업 경로 검증이며 과거 월 일괄 migration/복원 recovery journal의 완료 근거는 아니다.
- 백업 회귀 **122/122 통과, 실패 0, 건너뜀 0**. 결과 `build/validation/BKM0928A01/backup-tests-03.xcresult`, 로그 `backup-tests-03.log`, summary `backup-tests-03-summary.json`. 최초 실행은 기존 손상 fixture가 저장 API로 불변 세대를 덮어쓰려다 1건 실패해 직접 디스크 손상 주입으로 고쳤다. 두 번째 실행은 새 fixture의 현재 시각 JSON 왕복 정밀도 비교 1건 실패로 고정 시각을 사용했다. 두 실패 로그도 보존했다.
- generic iOS Debug 빌드 성공: `build/validation/BKM0928A01/ios-debug-01.log`. `git diff --check` 통과. 동작 변경은 백업 앱 코드로 한정돼 기존 Core/package 결과를 재사용했다. 선행 전체 앱 1,412 통과/1 건너뜀은 ALLT0927A1의 이전 실행이며 이번 테스트 수와 합산하지 않는다.
- 제한: 이번 후속 빌드는 기기에 재설치하지 않았다. 실기기/iCloud Drive/CloudKit Development 동작, DB/file bounded streaming, 보호된 SQLite 복원 staging/recovery journal, 강제 종료로 남은 staging 정리는 미확인·미완료다. push·TestFlight 업로드를 실행하지 않았으며 전체 ALLT0927A1은 계속 열린 상태다.

## ALLT0927A1 · 저장소 잠금·HealthKit 온보딩 1차 수정 (2026-09-27)

- `SQLitePlanRepository`의 load/save/delete는 `TaptionPlanDayStore` actor의 동기 격리 클로저에서 flock과 SQLite 작업을 마치고 결과 row만 반환한다. 잠금 경합 시에는 잠금을 잡지 않은 채 비동기 재시도하며, snapshot Codable 디코딩도 잠금 해제 후 수행한다. deletion marker와 generation 갱신은 여전히 SQLite 삭제와 같은 잠금 임계 구역에 있다. 파일 snapshot 저장 경로도 동기 임계 구역으로 바꿨다.
- `testSQLiteRepositoryRetriesFileLockWithoutHoldingItAcrossSuspension`: 외부 잠금 점유 중 load 취소 응답, 잠금 해제 후 저장소 재접근을 검사해 통과했다. `testExclusiveFileAccessIsNonblockingAndReleasesOnThrow` 포함 TaptionPlanCore 101/101 통과. 로그: `build/validation/ALLT0927A1/core-tests-final.log`, `focused-app-tests.log`.
- HealthKit·캘린더·알림·위치 등 권한 요청 전용 상태를 통합 데이터 refresh 상태에서 분리했다. 온보딩 진행 모델은 요청 완료 시에만 다음 단계로 이동하며 실패한 “모두 허용”은 해당 단계에서 멈춘다. `testPermissionOnboardingDoesNotAdvanceWhenRequestDidNotComplete` 통과.
- iOS Simulator 앱 테스트 2/2 통과 (`** TEST SUCCEEDED **`), test 빌드 완료. 로그에 SDK StoreKit 헤더의 기존 deprecated 경고 1건이 있으나 앱 소스 오류는 없다. `git diff --check` 통과.
- 기존 전체 앱 테스트에서 실패한 16개를 개별 재실행해 16/16 통과했다. 실제 수정은 스틱맨 action cache가 destination/sleep input을 키에 누락한 문제였고, 나머지는 최신 RPG 지도·시간 레일·영어 카탈로그 동작에 맞춰 회귀 기대를 갱신했다. `build/validation/ALLT0927A1/failure-regressions-01.log`, `failure-regressions-01.xcresult`.
- V4 snapshot 파일은 timestamped immutable generation으로 저장하고 raw generation ID와 snapshot ID를 분리해 CloudKit Development manifest에 각각 기록한다. 같은 월의 snapshot은 parent ID를 보존해 같은 parent에서 갈라진 generation을 복원 시 병합한다. 순차 snapshot은 최신 내용이 조상보다 우선해 설정이 되돌아가지 않는다. 저장 후 readback과 삭제 generation 검사도 유지한다.
- 새 manifest·immutable 경로·동일 월 동시 세대 병합 3/3, 그 뒤 SecurityBackupCore 전체 113/113 통과. 로그: `snapshot-generation-tests-01.log`, `security-backup-suite-02.log`; 결과 `snapshot-generation-tests-01.xcresult`, `security-backup-suite-02.xcresult`. 기존 manifest JSON decode 호환과 snapshot 덮어쓰기 거부도 포함한다.
- 전체 앱 테스트를 새 iPhone 17 Pro 시뮬레이터(iOS 26.5)에서 직렬 실행해 **1,412 통과·1 건너뜀·실패 0(총 1,413)**을 확인했다. 과거 전체 테스트 실패 16건도 이 결과에 포함되어 통과했다. 유일한 건너뜀은 `testStoreKitProductPurchaseEntitlementAndRestore`; iOS 26.5 StoreKitTest의 `SKInternalErrorDomain Code 3`로 실행되지 않았다. IAP 판매 작업은 계속 보류한다. 기존 검증 시뮬레이터에서는 테스트 번들 설치 경로가 사라져 케이스 시작 전 실패했으므로, 그 결과는 테스트 실패로 세지 않고 새 시뮬레이터에서 재실행했다. 최종 결과 `build/validation/ALLT0927A1/app-tests-full-final2.xcresult`, 로그 `app-tests-full-final2.log`.
- V1·V2·V3 snapshot archive를 다음 저장 시 V4 immutable generation으로 전환하면서 구버전 원본을 남기는 회귀 3/3 통과. 로그 `legacy-migration-final.log`, 결과 `legacy-migration-final.xcresult`. V4 snapshot paging은 source payload 전체와 암호화 frame을 여전히 메모리에 둔다.
- V3 raw archive 복호 뒤 같은 payload를 V4로 재봉인하고 기존 generation 파일을 남기는 집중 회귀 1/1 통과. 로그 `legacy-raw-v3-reseal.log`, 결과 `legacy-raw-v3-reseal.xcresult`. 이 테스트는 다음 저장 경로와 원본 보존을 확인하지만 DB cursor streaming·복원 staging을 검증하지 않는다.
- App Store Connect API readback에서 기존 1.0(159)이 `VALID`임을 확인했다. 다음 번호 160으로 앱·위젯·Watch·Watch 위젯의 Debug/Release `CURRENT_PROJECT_VERSION` 8곳과 네 개 Info.plist의 `CFBundleVersion`을 맞췄다. 최종 iOS 및 Watch generic Debug 빌드가 모두 성공했고, 산출물의 네 번들 ID에서 1.0(160)을 각각 읽었다. 로그 `ios-debug-final.log`, `watch-debug-final.log`.
- 서명된 Debug 1.0(160)을 iPhone 11 Pro·iPhone 18 Pro Max·iPad Pro에 설치했다. iPhone 18과 iPad `devicectl` 앱 목록 readback은 160이다. iPhone 11 설치 명령은 성공했으나 이후 앱 목록 조회가 timeout 내 응답하지 않아 기기 버전 readback은 대기한다. Watch 직접 설치는 연결 터널 생성 timeout으로 실패했다. 설치본을 실행하거나 화면을 조작하지 않아 실기기 기능 검증은 아니다. 설치 로그 `install-iphone11.log`, `install-iphone18.log`, `install-ipad.log`, `install-watch.log`.
- TestFlight 160 업로드는 아직 하지 않았다. 앱 실행 후 권한 화면·GPS·UI·백업·Watch 계정 연동을 사용자가 확인할 수 있도록 실기기 검증을 대기한다.
- 한 번의 사용자 실기기 세션에서 확인할 체크리스트를 `build/validation/ALLT0927A1/device-session-checklist.md`에 준비하고 Codex 패널에 열었다. 체크 결과는 아직 입력되지 않았으며 어느 기능도 설치만으로 통과 처리하지 않는다.
- README, AGENTS, DEVELOPMENT, 활성 인계 진입점과 지원·개인정보 문서를 대조했다. AGENTS/DEVELOPMENT에 네 번들 `CFBundleVersion` 산출물 readback과 Watch Debug 명령을 명시해 번호 불일치 재작업을 막고, README·지원 문서는 이미 짧은 진입점 구조라 유지했다. 날짜가 붙은 보관 인계문은 역사 자료로 남겼다. 최종 문서·소스 `git diff --check` 통과.
- iPhone 11 실기기 재설치·시작·백그라운드 복귀와 새 충돌 로그, HealthKit 권한 화면 전환은 아직 확인하지 않아 CRAS270927/HK270927A1은 열린 상태다.

## CRAS270927 · iPhone 11 Pro 충돌 보고서 분석 (2026-09-27)

- iPhone 11 Pro (iPhone12,3, iOS 26.7/23H24)에서 iOS의 “Taption Plan 앱이 충돌함” 안내와 현재 화면을 확인했다: `build/validation/CRAS270927/iphone11-current-screen.png`. 공유 버튼은 누르지 않고 기기의 시스템 충돌 로그를 로컬로 복사했다.
- 기기에서 가져온 세 보고서 모두 `EXC_CRASH(SIGKILL)`, `RUNNINGBOARD` 종료 코드 `3735883980` (`0xDEAD10CC`)다. 21:27:31과 21:28:20 보고서는 1.0(158), 21:29:19 보고서는 1.0(159)에서 났다. 원본: `build/validation/CRAS270927/TaptionPlan-2026-09-27-212731.ips`, `TaptionPlan-2026-09-27-212820.ips`, `TaptionPlan-2026-09-27-212919.ips`. 같은 종료가 158에서 이미 발생해 159 설치 시간 초과가 최초 원인은 아니다.
- 159 보고서의 동시 실행 cooperative 스레드는 `AppModel.bootstrap()` → `MigratingPlanRepository.load()` → `SQLitePlanRepository.load()` → `loadFromStore()` / snapshot decode → `PlaceStay.init(from:)` → `TimeSpan.init(from:)`에 있었다. `TaptionPlan/Core/PlanRepository.swift`의 `load()`는 `.lock` 파일 flock을 잡은 뒤 `defer`로 해제하며, 그 사이 `await loadFromStore()`와 Codable 디코딩이 실행된다. 시작 호출은 `TaptionPlan/UX/AppModel.swift`의 `bootstrap()`에서 확인했다.
- Apple은 `0xDEAD10CC`를 앱이 정지 중 파일 또는 SQLite 데이터베이스 잠금을 보유해 OS가 종료한 경우로 설명한다: [Apple EXC_CRASH (SIGKILL) 문서](https://developer.apple.com/documentation/xcode/sigkill?language=objc). 보고서의 `RUNNINGBOARD` 종료와 시작 로드 스택, 코드의 flock 범위가 서로 일치하므로 시작 로드 잠금 유지가 강하게 의심되는 원인이다. 정확히 어느 잠금이 종료 조건을 유발했는지는 보고서만으로 확정할 수 없어 수정·재현이 남아 있다.
- 진단 범위에는 코드 수정, 테스트, 빌드가 포함되지 않았다. `temp.md`의 CRAS270927은 잠금 범위 수정과 동시 읽기/쓰기 회귀 테스트, iPhone 11 시작·백그라운드 복귀 후 새 보고서 확인 전까지 열린 상태다.

## INST270927 · iPhone 11/18 Debug 앱 설치 (2026-09-27)

- 현재 서명된 로컬 Debug 앱 `com.taption.plan` 1.0(159)을 iPhone 11 Pro (iPhone12,3, iOS 26.7)와 iPhone 18 Pro Max (iPhone19,7, iOS 27.2)에 설치했다. TestFlight 업로드·배포는 하지 않았다.
- iPhone 11 Pro는 시작 전 1.0(158)이었다. 설치 명령은 120초 시간 제한을 반환했지만 설치 후 기기 앱 목록에서 1.0(159)을 읽어 확인했다. 로그: `build/validation/INST270927/iphone11-install.log`.
- iPhone 18 Pro Max 설치 명령은 성공했다. 설치 후 두 기기의 앱 목록에서 `com.taption.plan` 1.0(159)을 확인했다. 로그: `build/validation/INST270927/iphone18-install.log` 및 `iphone11-install.log`.
- 제한: 앱을 실행하거나 화면·기능 동작을 확인하지 않았다. 설치 및 버전 readback은 기능 검증을 뜻하지 않는다.

## MARG270927 · 오른쪽 시간 레일 화면 높이·내부 여백 (2026-09-27)

- 오른쪽 시간 레일의 720pt 최대 높이 제한을 없애 상단 날짜 헤더 아래 20pt부터 하단 32pt 여백까지 화면 가용 높이를 사용한다. 활동 구간·시간 라벨의 공통 트랙 위아래 여백은 10pt에서 20pt로 늘렸다.
- 짧은 화면에서는 시간 라벨 행 간격이 최소 24pt가 되도록 전체 보기의 시각 라벨 일부를 생략한다. 충분히 긴 레일에서는 00–24시 라벨을 모두 표시한다.
- 시뮬레이터 회귀 7개 통과: `testTimeSidebarUsesItsOwnExpandedTopAndBottomMargins`, `testMapHomeTimeSidebarTapMapsAndClampsToVisibleRail`, `testFullDayTimelineSpacesHourLabelsOnCompactRail`, `testTimeSidebarHourLabelsKeepAnInnerTrailingMargin`, `testExpandedSidebarRulerSeparatesHourAndMinuteLabels`, `testWeatherTimelineCapsulesAttachFlushToSidebarPanel`, `testWeatherTimelineKeepsItsCenterWhenPlayheadOverlaps`. 최종 근거: `build/validation/MARG270927/layout-tests-final2.log` 및 `layout-tests-final2.xcresult` (`** TEST SUCCEEDED **`).
- 첫 테스트 실행에서는 중앙 탭 좌표가 기존 10pt inset 기준(160pt)이라 새 20pt inset에서 720분 대신 672분으로 매핑됐다. 중앙 좌표를 170pt로 갱신한 뒤 최종 선택 테스트 전부 통과했다. 초기 결과는 `build/validation/MARG270927/layout-tests.log`에 보존했다.
- generic iOS Debug 빌드 통과: `build/validation/MARG270927/debug-build-final.log` (`** BUILD SUCCEEDED **`). 최종 `git diff --check` 통과.
- 제한: 시뮬레이터 수학·레이아웃 테스트로 실제 iPhone별 화면 캡처나 터치 체감까지 확인하지 않았다.

## UN270927B1 · 미확인 세그먼트별 빠른 입력 (2026-09-27)

- 오른쪽 시간 레일의 공용 `?` 버튼을 없애고, 현재 표시 영역에 있는 입력 가능한 각 미확인 세그먼트 옆에 버튼을 배치했다. 가까운 버튼은 시간순을 유지하며 44pt 터치 영역이 가능한 범위에서 겹치지 않도록 조정한다. 오늘의 미래 구간은 표시 대상에서 제외한다.
- 각 버튼은 해당 구간 하나만 시트에 전달한다. 날짜 선택을 숨기고 해당 구간만 입력·저장하며, 빠른 저장 성공 시 시트를 닫는다.
- 시뮬레이터 회귀 7개 통과: `testUnconfirmedReviewTargetShowsAndSelectsOnlyItsSegment`, `testUnconfirmedReviewMarkersStayInRailAndSeparateNearbySegments`, `testUnconfirmedReviewIncludesOnlySortedUnconfirmedIntervals`, `testUnconfirmedReviewClipsTodayAtCurrentMinute`, `testUnconfirmedReviewAvailabilityIgnoresFutureAndConfirmedIntervals`, `testQuickConfirmedIntervalDisappearsFromUnconfirmedReview`, `testPartialUnconfirmedEditPreservesSourceOutsideSelectedSpan`. 근거: `build/validation/UN270927B1/final/focused-tests.log` 및 `focused-tests.xcresult` (`** TEST SUCCEEDED **`).
- generic iOS Debug 빌드 통과: `build/validation/UN270927B1/final/debug-build.log` (`** BUILD SUCCEEDED **`). `git diff --check` 통과.
- 제한: 실기기 화면에서 모든 구간 버튼의 위치·개별 터치·저장 결과는 확인하지 않았다. 빌드와 시뮬레이터 테스트만으로 실기기 기능을 판정하지 않는다.

## RST0920A01 · V4 snapshot/raw pages·CloudKit manifest CAS 부분 구현 (2026-09-27)

- 월 snapshot과 raw archive 쓰기를 V4 페이지 frame으로 전환했다. 기본 한도는 256행/1MiB, 하드 상한은 1,024행/4MiB이며 페이지별 압축·GCM 인증과 metadata/page-index AAD를 적용했다. V1–V3 decoder 호환은 보존했다.
- V4는 페이지별 GCM tag를 각각 검증한다. 한 페이지 인증이 실패하면 해당 페이지를 건너뛰고 남은 페이지의 정상 기록을 복원하며, 유효 페이지가 없으면 archive 오류를 반환한다. 회귀 `testRawSensorV4RestoreSkipsOneCorruptPage`가 300개 중 손상되지 않은 256개 복원을 확인한다.
- Snapshot V4는 각 자료형과 route point를 별도 256행/1MiB 페이지로 분리한다. `testSnapshotV4PagesRoundTripAcrossRoutePointBoundary`에서 300개 route point 페이지 경계 왕복 및 페이지 변조 거부를 확인했다. 저장 원본 모델과 전체 암호화 frame은 메모리에 남으므로 end-to-end memory bound는 아직 보장되지 않는다.
- 개발 빌드에서만 CloudKit manifest actor를 사용한다. device/month generation 참조를 merge하고 change-tag 충돌은 최대 3회 재시도한다. 오프라인 pending 참조는 로컬 보호 파일에 보존한다. retention은 manifest 및 snapshot 참조를 보호하고 미참조 raw generation을 월별 10개 유지한다. Production CloudKit 경로는 비활성이다.
- SecurityBackupCore 111/111 통과, 실패 0: `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_06-10-31-+0900.xcresult` (`** TEST SUCCEEDED **`). 손상 페이지 집중 테스트와 snapshot V4 targeted tests도 통과: `build/validation/RST0920A01/raw-partial-restore-test.log`, `v4-page-and-generation-tests.log`, `v4-page-targeted-final.log`. 앱 iOS Debug 빌드 통과: `build/validation/RST0920A01/app-debug-v4-pages-final.log` (`** BUILD SUCCEEDED **`). `git diff --check` 통과.
- 미완료: DB cursor/file 기반 bounded streaming, V1–V3 자동 1회 migration, 보호된 SQLite staging/recovery journal, snapshot immutable generation 및 기기 간 payload 재병합, 실제 CloudKit Development 기기 경합. 시뮬레이터 테스트는 CloudKit 실서비스 검증을 뜻하지 않는다.

## CAT0926T01 · UIV0926A01 실기기 녹화 판독 (2026-09-27)

- 사용자가 제공한 카메라롤 저장 원본 `/Users/u_mo_c/Downloads/ScreenRecording_09-27-2026 03-59-48_1.MP4`를 판독했다(19.606초, 1126×2436, 60fps). 판독 프레임은 `build/validation/RST0927A01/video-frames/half/`에 보관했다.
- 화랑이·모닥불 마커가 화면에 있는 상태에서 지도가 여러 차례 이동하고, 상세 도로 수준에서 인천·김포권까지 줌 아웃되는 화면 변화를 확인했다. 이 영상 범위에서 마커 주변 지도 팬·핀치줌 통과는 확인됐다.
- 시간축의 00–24 시간 라벨과 활동 색상 스트립, 날씨 아이콘·기온 캡슐을 확인했다. 왼쪽 메뉴와 줌 컨트롤의 하단은 오른쪽 시간 레일 하단과 거의 같은 선에 놓였다.
- 집 상태 콜아웃과 Lv.1 캠프파이어·화랑이 마커는 표시됐다. 화랑이 정지 탭으로 `.cat` 상세 시트가 열리는 장면, 레벨 캡슐 탭으로 하루 요약이 열리는 장면은 영상에서 확인되지 않았다. 따라서 CAT0926T01의 직접 탭과 DYS0927A01의 요약 탭은 미완료로 유지한다.
- FMAP0926R06 경로 재생·진단 로그, PAW0926T05 발자국, 성장 보상 선택 반영도 이 영상만으로 판정하지 않았다.

## MAP0927F01 · Map Home 터치·카메라 반응 개선 (2026-09-27)

- 원인: MapKit 카메라 시작 delegate가 지도 내부 전체 뷰·제스처를 재귀 순회했고, 가시 영역 프레임마다 화랑이 오버레이의 z 위치를 재설정하고 맨 앞으로 재배치했다. MapKit 네이티브 pan/pinch와 메인 스레드 작업이 경쟁했다.
- 수정: 카메라 시작 시 재귀 검색을 제거하고 제스처 연결 스캔은 최대 초당 1회로 제한했다. 화랑이 오버레이의 레이어 승격은 처음 붙을 때만 수행하고, 이동 중에는 좌표 추적만 유지한다.
- 회귀 2개 통과: `testWalkerViewportUpdatesDoNotRestackMapSubviews`, `testWalkerOverlayStaysOutsideAnnotationOrderingAndKeepsFootCoordinate`. 결과 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_04-16-13-+0900.xcresult` (`** TEST SUCCEEDED **`).
- iOS Debug 빌드 통과: `build/validation/MAP0927F01/build.log` (`** BUILD SUCCEEDED **`). `git diff --check` 통과.
- 서명된 Debug 빌드를 iPhone 11 Pro `00008030-001628201AD2802E`에 설치·실행했다. `devicectl` 앱 목록에서 `com.taption.plan` 1.0/157 readback 완료: `build/validation/MAP0927F01/iphone11-readback.txt`.
- 제한: 설치·실행만으로 손가락 입력 체감은 검증되지 않았다. 실제 드래그·핀치 반응은 카메라롤 저장 영상으로 재확인해야 하며, 그 전에는 기능 통과로 처리하지 않는다.

## HOF0926A01 · Kiro → Codex UI 인계 확인 (2026-09-26)

- `AGENTS.md`, 최신 `temp.md`, 관련 `test.md`, `CODEX_HANDOFF.md` 및 Git 이력을 대조했다. 기존 CODEX_HANDOFF.md의 35커밋·빌드 156·push 지시는 과거 스냅샷이며 이번 실행 지시로 사용하지 않았다.
- 시작 당시 main HEAD는 `1e283ec08e6d9d3588fe75272511f060e2330f42`, origin/main과 서버 main은 `07e848f24c1d103037666d72a2ab8cd5b93771d6`이었다. `git rev-list --left-right --count origin/main...HEAD` 결과 `0 58`로 전체 미push 58개를 확인했다. 전달된 UI 커밋 목록은 그 일부였다.
- 인계 확인 중 다른 작업에서 `520075e`·`c5e9dbb` 커밋이 추가됐다. 이후 HEAD·origin/main·`git ls-remote --exit-code origin refs/heads/main`의 서버 main이 모두 `c5e9dbbe39f8f5e43ee2a47a8cf43971d911d57b`로 일치했고 비교 결과는 `0 0`이었다. 따라서 최종 확인 기준 미push 커밋은 0개다. 이 세션에서 커밋·push를 실행한 것은 아니다.
- 시작 당시 앱·위젯의 `Localizable.xcstrings`, temp.md·test.md가 수정됐고 `.kiro/`, CODEX_HANDOFF.md가 미추적이었다. 기존 작업은 되돌리지 않았다. 다른 작업에서 해당 변경을 커밋했고, 이번 세션의 후속 변경 범위는 temp.md·test.md 인계 기록이다.
- `TaptionPlan.xcodeproj/project.pbxproj`의 `CURRENT_PROJECT_VERSION` 8곳은 모두 157이다. 이는 소스 설정 확인이며 기기 설치본이나 TestFlight 상태 확인은 아니다. `git diff 1e283ec..HEAD -- TaptionPlan/UI/MapHomeView.swift TaptionPlan.xcodeproj/project.pbxproj`는 비어 있어 동시 커밋에서 두 파일이 바뀌지 않았음을 확인했다.
- `MapHomeView.swift` 소스 대조: historical=`timelineRouteOverlays.dropLast()`, active=`last`, 발자국 입력은 전체 overlays다. `makeTimelineRouteOverlays`는 확정 지하철과 유효좌표 2개 미만을 제외한다. `fmap_route_projection`의 `dropped_short`는 유효성 검사 전 좌표 수를 세므로 필터 후 부족한 경우를 전부 집계하지 못한다. FMAP 원인은 아직 확정하지 않았다.
- FMAP0926R06·PAW0926T05 실기기 확인, HUD0926M08 통합 방식·지표 결정은 열린 상태다. 전달된 시간 카드 높이·화랑이 직접 탭·최신 UI 실기기 확인을 각각 TIM0926C01·CAT0926T01·UIV0926A01로 temp.md에 기록했다. 기존 완료 표시 항목의 구현은 반복하지 않았다.
- 문서 변경의 `git diff --check -- temp.md test.md`를 통과했다. 확인을 마친 HOF0926A01만 temp.md에서 제거하고 실기기·설계 대기 항목은 유지했다.
- 제한: 이 세션에서 앱 소스 변경·새 빌드·테스트·설치·실기기 영상 판독·ASC 조회는 수행하지 않았다. 기능 검증을 완료했다고 보고하지 않는다.

## SEP0926A01 · TaptionPlan 인계 프로토콜 및 main 정리 (2026-09-26)

- 대상 변경은 `temp.md`, `test.md`, 신규 `CODEX_HANDOFF_20260926.md` 세 파일이다. ShotGuide 및 앱 소스는 수정하지 않았다.
- `git diff --check` 통과. 앱·위젯 `Localizable.xcstrings` JSON 파싱 통과. 시작 시 `HEAD`/`origin/main`/서버 main은 `c5e9dbb`, ahead/behind `0/0`이었다.
- 기존 인계가 지목한 `build/validation/GIT0926P01/build-final.log`는 존재하지 않았다. 대신 고정 DerivedData `build/ArchiveDD`로 Debug 빌드를 실행해 `build/validation/GIT0926P01/build-sep0926a01.log`에서 `** BUILD SUCCEEDED **`, 종료 코드 0을 확인했다. 매크로 검증 스킵 및 `-Xfrontend -disable-sandbox` 플래그를 사용했다.
- 앱 소스 변경이 없는 문서 정리이므로 단위 테스트와 실기기 검증은 실행하지 않았다. 기존 UI·센서·백업의 실기기 대기 상태는 temp.md에서 유지한다.
- 커밋 `3cf1717` push 성공: `c5e9dbb..3cf1717 main -> main`. `git ls-remote origin refs/heads/main`의 readback은 `3cf1717ea03ebc2f453759ca1fb38847e3899bb2`다.
- push 뒤에 이 검증 기록을 정리하면서 생긴 후속 기록 커밋도 별도 push하고, 최종 HEAD·원격 main·워크트리 상태를 다시 확인한다.

## BAK0922I01 · 백업 복호 실패 시 새 아카이브 재봉인 (2026-09-23, A안)

- 로그 확정(9/22): `icloud_backup_automatic` 반복 실패 — error_code 4(invalidArchive)/6(accountUnavailable), 동시각 `cloud_account_status`는 전부 authorized. 계정은 정상, 기기 이전 키 불일치가 원인.
- 원인: `PlanMonthlyArchivePreparation.prepare`가 같은 달 기존 아카이브를 병합하려 PIN키→계정키로 복호 시도, 둘 다 실패(iPhone 14 키로 봉인) 시 invalidArchive throw → 매 백업 실패.
- 수정(A안): 두 키 모두 복호 실패 시 병합을 건너뛰고 이번 기기 데이터를 이번 기기 키로 새로 봉인해 저장(inheritedGenerationID=nil). accountMismatch는 그대로 throw, load 시 tamper/무결성 검증 불변. 스키마 변경 없음. 옛 아카이브는 이번 기기에서 어차피 복호 불가라 복구 가능 데이터 손실 없음. 스냅샷·raw 두 경로 공통(prepare 3675·3940).
- 검증: `TaptionPlanTests/SecurityBackupCoreTests` 103/103 PASS(신규 `testUndecodablePreviousArchiveResavesFreshInsteadOfFailing` 포함 — 다른 키로 봉인된 이전 아카이브가 있어도 새 백업 성공+새 키로 재복호 확인). tamper 테스트(invalidArchive 기대) 불변. 증거: `build/validation/BAK0922I01/backup-tests-r2.xcresult`.
- 한계: 시뮬 검증. 실기기에서 대표님이 PIN 입력 후 iCloud 백업 성공 전환·그룹 노출 확인 필요.

## GPS0922J01 · sparse-connection 불가능속도 차단 (2026-09-23)

- 로그 확정(9/22): 점프는 forecast가 아니라 actual leg 열(projection_actual_movement_count=890, forecast_same_endpoint_pairs=0). actual leg 생성은 연속 reading쌍을 `RouteSparseConnectionPolicy.breaksConnection`으로만 걸러왔다.
- 원인: `breaksConnection`이 gap>5분 AND 거리>1km 일 때만 끊어, **gap이 5분 이하이면 아무리 멀어도(회사↔집) 연결**돼 재생 시 직선 점프가 생겼다.
- 수정: `RouteSparseConnectionPolicy.breaksConnection`에 불가능속도 규칙 추가 — 거리/gap > 55m/s(≈198km/h, 라우트 필터 unknown-mode 상한과 동일)이면 gap 길이와 무관하게 끊는다. 기존 두-임계 규칙은 유지. 원본 raw는 보존, 파생 재생 leg만 영향.
- 검증: 패키지 `TaptionRouteEngine` 39/39 PASS(+1 신규 `sparseConnectionBreaksOnImpossibleSpeedWithinShortGap`, 기존 `sparseConnectionBreaksOnlyPastBothThresholds` 불변). 증거: swift test 로그.
- 한계: 시뮬/유닛 검증. 실기기에서 9/22 같은 날 재생 시 점프가 사라지는지 확인 필요.

## SLP0922S01 · 워치리스 수면 게이트 완화 (2026-09-23)

- 로그 확정: iPhone 18 진단 패키지 TaptionLogs-20260923-014921(9/20~9/22)에서 `sleep_inference_completed` 61회 전부 `reason=conditions_or_continuity_not_met` — 워치리스 경로가 매 윈도 실행됐으나 보조조건 게이트에서 전량 탈락.
- 수정(2파일, `TaptionActivityEngineAdapter.strictSleepActuals`만): (1) homePoint 있을 때 `minimumSupportingConditions`를 3→2로. (2) `ambientIsDark`가 밝기 nil(화면 꺼짐)이면 화면 꺼짐 자체를 어두움 근거로 인정(`?? (screenIsOn==false ? true : nil)`). 공유 `SleepInferenceEngine` 게이트·기본 config는 미변경(기존 동작 보존).
- 검증: 패키지 `TaptionActivityEngine` 33/33 PASS(`testSleepDoesNotInferWithOnlyTwoSupportingConditions`·`testSleepRequiresCoreAndAllSupportingConditionsForFiveMinutes` 포함 — 엔진 기본 동작 불변 확인). 앱 `TaptionPlanTests/TaptionActivityEngineAdapterTests` 26/26 PASS, 신규 회귀 2건 포함: `watchlessSleepFiresWhenScreenOffAtHomeWithoutCharger`(무충전·화면꺼짐·집=수면 생성), `watchlessSleepStaysEmptyWhenPhoneIsUsedAndMoving`(이동·화면켜짐=수면 아님, 과확정 방지). Xcode 27 매크로 플러그인 오류는 `-skipPackagePluginValidation -Xfrontend -disable-sandbox`로 회피. 증거: `build/validation/SLP0922S01/adapter-tests-r2.xcresult`.
- 한계: `CODE_SIGNING_ALLOWED=NO` 시뮬 빌드라 실기기 설치·실제 취침 데이터 표시는 별도 검증 필요. 실기기 재현(무충전 야간 취침 후 수면 표시)으로 최종 확인해야 함.

## KIR0923A01 · 2026-09-23 Kiro 인수인계 준비

- 환경: Apple Silicon arm64, macOS 26.6.2 (25G83), Xcode 27.0 (27A266a), Swift 6.4. 프로젝트 언어 모드 6.0, iOS 18/watchOS 11 이상, 네 번들 버전 1.0(149).
- 기존 구현·회귀·개발 기록을 `a8e3d5c` 커밋으로 보존하고 `KIRO_HANDOFF.md`에 환경·명령·아키텍처·다음 개발 범위를 통합했다.
- 삭제: `DEVELOPMENT.md`, `NEXT_CHAT_PROMPT.md`, `plan.md`, `design-qa.md`, `STICKMAN_ANIMATION_GUIDE.md`, `SENSOR_FUSION_SOURCES.md`, `ui-draft-iphone.html`.
- 유지: `AGENTS.md`, README, 지원·개인정보 문서, 미완료 요청과 이번 검증 기록. 기존 로컬 전용 `temp.md`는 미완료 항목을 압축해 인수인계 자료로 함께 추적한다. `.codex/`·`.workbuddy-ai/`는 로컬에 보존하고 Git에서 제외했다. 사용자 데이터·기존 빌드 증거·다른 프로젝트 작업은 삭제하지 않았다.
- 기준 파일 281개 중 276개는 SHA-256이 동일하다. 검증에서 발견한 아래 비일자 snapshot 호환 회귀의 최소 수정 5개 파일만 변경했다. 문서·`.gitignore`는 정리 대상이라 이 비교에서 제외했다. 증거: `build/validation/KIR0923A01/preservation-check.json`.
- README/인수인계의 로컬 링크, 문서 내 shell 예제 구문, 앱 엔진 import 경계와 `git diff --check` 통과. 원격 fetch 시 기존 main은 origin/main과 일치했으며 새 브랜치는 만들지 않았다.
- 최종 검증: 패키지 Core 99/99·Activity 33/33·Route 38/38·facade 1/1 PASS(총 171), 앱 전체 1,344 PASS·기존 StoreKit 1 SKIP·0 FAIL·runtime warning 0. StoreKit 스킵은 iOS 26.5 Simulator의 SKInternalErrorDomain Code 3 제한이다.
- 최종 iOS·watchOS generic device Debug 빌드 모두 PASS, error/warning/analyzer warning 0. `CODE_SIGNING_ALLOWED=NO` 빌드이므로 서명·실기기 설치 검증을 뜻하지 않는다.
- 실행 증거: `build/validation/KIR0923A01/TaptionPlanCore-final.log`, `TaptionActivityEngine.log`, `TaptionRouteEngine.log`, `TaptionPlanEngine-final.log`, `app-tests-r3.xcresult`, `ios-debug-r3.xcresult`, `watch-debug-r3.xcresult` 및 각 summary JSON.
- 소스·인수인계 정리 커밋 `881d433b111e8e411e6cd8535e195c8dc79e2dc2`를 main에 푸시한 뒤 HEAD·origin/main·서버 refs/heads/main 일치와 빈 `git status --porcelain=v1`을 확인했다. 이 완료 증거에 따라 `KIR0923A01`을 요청 큐에서 제거했다.

## HKD0923A01 · HealthKit·계획 저장소의 비일자 snapshot 호환

- 최초 전체 실행에서 `HealthKitImportStore`가 기존 `0000-00-00` snapshot을 조회할 때 Core의 강화된 날짜 검증이 `invalidDay`를 반환했다. 동기화 gate 진입 전 실패해 후속 테스트도 대기했다. 최초 결과는 673 PASS·1 SKIP·4 FAIL(직접 오류·시간초과·후속 오류·중단 포함), exit 75이며 통과 결과로 사용하지 않는다: `build/validation/KIR0923A01/app-tests.xcresult`.
- `TaptionPlanDayStore`에 기본 false인 비일자 snapshot 허용 옵션을 추가하고 HealthKit 저장소와 SQLite 계획 저장소만 명시적으로 사용한다. 기존 SQLite 키·payload·anchor·revision·원자적 event/checkpoint 갱신은 유지하며 스키마 migration은 하지 않는다. event·map·V3 및 일반 저장소 날짜 검증은 유지한다.
- 새 회귀는 기존 SQLite row의 읽기, event/checkpoint 갱신 후 재열기, 일반 저장소 기본 거부, 비일자 event/map·부분 무효 날짜 거부를 검사한다.
- HealthKit 집중 35/35 PASS. 중간 전체 실행은 계획 저장소의 같은 키 호환 누락으로 1,331 PASS·1 SKIP·13 FAIL이었다. 소비자와 직접 readback하는 테스트를 수정한 뒤 최종 전체 1,344 PASS·1 SKIP·0 FAIL 및 iOS/Watch Debug 빌드로 저장·재열기·revision·Watch summary ACK 경로까지 통과했다. 완료 항목을 요청 큐에서 제거했다.

## 선행 실기기 증거와 아직 남은 검증

- 2026-09-22 iPhone의 날짜·지도 재생 입력, 9/9 항공 경로 readback 및 일부 실제 저장 재열기는 기존 기록에서 확인됐다. 같은 날 iPad Debug 설치·실행은 첫 권한 화면까지 확인했고 후속 UX는 미완료다. 이전 전체 테스트 통과 수를 이번 최종 소스의 전체 검증으로 재사용하지 않는다.
- 2026-09-23 iPhone 18 Pro Max 대상 profile을 포함한 Debug 149 설치·foreground 실행과 약 1분 app/widget 생존, 새 OS crash report 없음이 기록됐다. 이는 TestFlight 설치나 정확한 9/9 장시간 CPU workload 완료가 아니다: `build/validation/HAR0922A01/device-targeted-build.xcresult`, `device-targeted-install.json`, `device-targeted-processes.json`.
- Watch는 paired/developer mode enabled 상태에서도 tunnel disconnected/timeout이었다. 실제 강제 종료 후 재전송·ACK/receipt 전환·HealthKit 삭제는 미검증이다.
- WeatherKit capability·entitlement와 대상 기기 profile은 확인했으나 실제 provider/401 해소 로그는 없었다. iCloud 실제 PIN 복원·다중 기기 경합, 장시간 CPU/file-lock workload도 별도 남아 있다.
- 마지막 배포 기록은 2026-09-13 TestFlight 149의 처리·`TP Taption Plan 내부 테스트` 그룹 빌드·테스터 노출 확인이다. 그 이후 코드와 이번 정리는 새 TestFlight 업로드가 아니다. 이번에는 ASC live 조회·실기기 설치·실제 판매 작업을 수행하지 않았다.

## GIT0926P01 — 워크트리 정리 및 main push (2026-09-26)
- 사용자 승인: 두 프로젝트 기존 변경 보존 후 main 커밋·push.
- 사전 확인: `git fetch origin`, `git status --short`, `git rev-list --left-right --count origin/main...HEAD`; 원격 전용 커밋 0개. JSON 문자열 카탈로그·Kiro 설정, plist, scheme XML 파싱 통과.
- 실행 명령: `xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlan -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/ArchiveDD -skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'`.
- 최초 빌드는 디스크 부족으로 실패. `xcodebuild clean`도 공간 부족으로 실패하여 알려진 로컬 DerivedData의 재생성 가능한 중간파일·모듈캐시·인덱스만 정리. 소스, Logs, xcresult, SourcePackages, 배포 archive/export는 보존.
- 런타임 `.kiro/settings/.kirocrew-cli-settings.lock`은 파일 유지 후 `.git/info/exclude`로 로컬 제외. 그 외 기존 변경 파일은 커밋 대상으로 보존.
- 산출물: `/Users/u_mo_c/Documents/taption plan/build/validation/GIT0926P01/`; 실기기 기능 검증은 수행하지 않음.
- 최종 앱타깃 빌드: `build/validation/GIT0926P01/build-final.log`의 BUILD SUCCEEDED, 종료 0 확인. push 및 원격 HEAD/clean readback은 같은 폴더 `git-readback.txt`에 기록.

## HME0926A01 · 집 성장·HUD·시간축 부분 구현 검증 (2026-09-26)

- `TaptionPlan/UI/MapHomeView.swift`: 로컬 날짜별 실제 기록/미확인 조건, 하루 +1 성장·연속일/주간 보상 데이터, 연도 archive, 집 레벨 핀과 2월 29일 표시, 하루요약 시트 걸음 수 반영. 앱 활성 복귀 시 오늘 상태를 재평가하고, 현재 시각 이후의 미완성 시간축 구간은 달성 대상에서 제외한다.
- `TaptionPlan/UI/MapHomeTimeSidebar.swift`: 선택 시각 ±1시간만 감싸는 라운드 카드 프레임 및 경계 클리핑.
- `TaptionPlan/Assets.xcassets/HomeEvolution001.imageset`…`HomeEvolution366.imageset`: 366개 기본 SVG 성장 그림. Contents.json 참조 및 SVG 파싱 366/366 통과. 이는 국가별 랜드마크 변형의 완성이 아니다.
- `TaptionPlanTests/FeatureEngineTests.swift`: `MapHomeTimeRailCardTests`, `MapHomeGrowthPolicyTests` 실행 성공. 로그: `build/validation/HME0926A01/feature-tests-final.log` (`** TEST SUCCEEDED **`).
- 앱 Debug 빌드 성공: `build/validation/HME0926A01/app-debug-build-final.log` (`** BUILD SUCCEEDED **`), 고정 `build/ArchiveDD`, `-skipPackagePluginValidation`, `-disable-sandbox` 사용. `git diff --check` 통과.
- 미완료: 주간 보상 선택·땅 직접 연결 배치·화랑이 액세서리 보관함 UI, 실사용 가능한 세계 랜드마크 카탈로그/아트, 전년도 집 열람. 이 기능은 현재 데이터 정책/기본 그림 단계에 머물러 있다. iPhone 실기기 UI/일자 경계 검증도 하지 않았다.
- 첫 검증 기록 시점에는 커밋·push·설치 전이었다. 이후 `f90a7d4` (`HME0926A01: add daily home growth foundation`)를 `main`에 push했고, 서버 `refs/heads/main` readback도 `f90a7d4c13323724c3fb2f20e699283b10a1d10e`였다.
- 서명된 Debug 앱(build 157, bundle `com.taption.plan`)을 iPhone 11 Pro `00008030-001628201AD2802E`, iPhone 18 Pro Max `00008160-000E195A1140000A`, iPad Pro 12.9-inch 6세대 `00008112-000964980E45401E`에 설치했다. 각 기기 `devicectl device info apps` readback에서 앱과 build 157 노출을 확인했다. 이 확인은 설치만 입증하며 실행·UI 기능 검증은 아니다. TestFlight 배포는 하지 않았다.

## SBR0926A01 · 좌우 사이드바 및 홈 성장 콜아웃 (2026-09-26)

- 선택 시안의 하단 탐험 HUD를 제거했다. 홈 마커에 레벨·오늘 성장 상태 콜아웃을 표시하고, 마커 탭으로 하루 요약 시트를 연다.
- 지도 왼쪽 조작 독과 오른쪽 시간축을 공통 뷰포트 프레임에 배치해 시작·끝 높이를 맞췄다. 왼쪽 버튼과 줌을 한 레일 안에서 위·아래로 나누고, 오른쪽 시간축과 크림 종이 표면·테두리·라운드를 통일했다.
- `TaptionPlanTests/MapHomeTimeRailCardTests` 통과: `build/validation/SBR0926A01/rail-tests.log` (`** TEST SUCCEEDED **`). 화면 높이 812·1024pt에서 공통 시작/끝선과 680pt 최대 높이를 검사했다.
- iOS generic Debug 빌드 통과: `build/validation/SBR0926A01/app-debug-build.log` (`** BUILD SUCCEEDED **`). `git diff --check` 통과.
- 시뮬레이터 미리보기: `build/validation/SBR0926A01/simulator-preview.png`. 좌우 사이드바 상·하단 정렬 및 하단 HUD 제거를 확인했다. 시뮬레이터에는 저장된 집 위치가 없어 집 성장 콜아웃은 화면에서 직접 확인하지 못했다. 실기기 저장 영상과 제스처 확인은 남아 있다.
- 변경은 커밋·push·실기기 설치하지 않았다.

## RST0920A01 · 손상 raw 월 건너뛰기 (2026-09-26)

- `PlanRawSensorRestoreAccumulator`는 계정 키로 복호 시도한 raw archive의 decode 실패를 월 단위로 격리한다. 해당 월은 건너뛰며 정상 월 payload를 유지하고, 모든 raw가 손상된 경우에는 `.invalidArchive`를 보고한다.
- 서로 다른 월에 정상 raw와 손상 raw가 있을 때 정상 센서 ID만 복원되는 테스트를 추가했다. 단일 손상 raw는 `.invalidArchive`, 월간 중복 ID 충돌은 기존처럼 전체 raw 복원을 거부한다.
- 대상 테스트 3개 통과: `testRawRestoreSkipsOneCorruptMonthAndKeepsValidMonths`, `testRawRestoreRejectsAValidArchiveSetWithCorruptMonth`, `testRawRestoreRejectsConflictingIDsAcrossMonths`.
- 실행: `xcodebuild test -project TaptionPlan.xcodeproj -scheme TaptionPlan -destination 'platform=iOS Simulator,id=5484EA8D-B979-498B-9BA8-6A4AEFFC9B8B' -derivedDataPath build/ArchiveDD -skipPackagePluginValidation COMPILER_INDEX_STORE_ENABLE=NO OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'`와 위 세 `-only-testing` 필터. 결과 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.26_23-00-10-+0900.xcresult`, `** TEST SUCCEEDED **`.
- V4 청크 포맷·마이그레이션·CloudKit CAS·세대 보존은 아직 구현/검증 전이다.

## HME0926A01 · 주간 집 성장 UI·랜드마크 카탈로그 (2026-09-26)

- 하루 요약에서 집 성장 화면으로 진입하는 버튼을 연결했다. 화면에는 연간 단계 그림/레벨/연속일, 보상 후보 3개 선택, 보상 땅 연결 배치, 화랑이 액세서리 보관·착용, 전년도 집 보관 내역이 표시된다.
- 한국·일본·미국·영국·프랑스·이탈리아·중국·스페인·태국·호주 각 5개씩 총 50개 후보를 구성했다. 땅 배치 저장은 optional 필드로 추가해 기존 저장 JSON과 호환되게 했다.
- `MapHomeGrowthPolicyTests` 통과(11개): 기존 성장/366개 리소스 검증에 더해 10개국×5 후보, 주간 후보 3개, 연결 땅 중복 방지/인접성을 확인했다. 로그 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.26_23-07-47-+0900.xcresult`.
- 화랑이 액세서리는 인벤토리에서 착용/해제하고 지도 마커에도 표시되도록 연결했다. 저장 호환 테스트에서 새 땅 배치 필드 없이 저장된 구버전 시즌 JSON을 정상 decode하는 것을 확인했다.
- 최종 관련 회귀 재실행: `MapHomeGrowthPolicyTests` 12개와 raw 복원 3개 통과. 로그 `build/validation/HME0926A01/combined-regressions-final.log`, 결과 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.26_23-20-08-+0900.xcresult`.
- generic iOS Debug 빌드 통과: `build/validation/HME0926A01/app-debug-final.log` (`** BUILD SUCCEEDED **`). 이 빌드와 App Group 주입 반영본을 iPhone 11 Pro·iPhone 18 Pro Max·iPad Pro에 설치했고 각 기기에서 `com.taption.plan` 버전 1.0 / 빌드 157을 readback했다. 설치는 UI 기능 검증이 아니다.
- 아직 남음: 실기기 레이아웃/보상 경험 확인. 과거 집은 연도·레벨·진화/땅 요약으로 열람 가능하며 별도 집 화면은 없다.
- 2026-09-27 에셋 재검증: 랜드마크 후보 50개 모두 고유 image set과 파일 참조를 가지며, 50개 SVG XML 파싱 오류가 없었다. 기존 366단계 집 그림은 보존되어 있다.

## PKG0920A01 · App Group host 주입

- Core에 `TaptionPlanAppGroupProviding`, 고정 provider, 동기화된 주입 API를 추가했다. 앱·Watch·iPhone 위젯·Watch 위젯의 초기화에서 기존 `group.com.taption.plan`을 host가 주입하며, Core는 기본값 fallback을 유지한다. `TaptionPlanDeviceLocalStorage`도 공통 주입 식별자로 컨테이너를 찾는다.
- package contract 테스트에서 provider 변경, 빈 식별자 무시, reset 후 기존 기본 ID 회귀를 통과했다. 명령 `swift test --package-path Packages/TaptionPlanCore --scratch-path build/validation/PKG0920A01/core-tests --filter CoreEngineContractsTests/testSharedContainerUsesHostProviderAndPreservesDefaultIdentifier`.
- 전체 Core package 100/100 통과: `build/validation/PKG0920A01/core-tests-final.log`. 앱 generic Debug 빌드 통과. 최종 설치본은 위 HME 기록의 세 기기 readback에 포함.
- 아직 남음: Watch/Widget 실제 프로세스별 App Group 데이터 연속성과 기존 컨테이너 파일 readback 실기기 검증.

## BRT0920A01 · generation 정리의 참조 안전성 (2026-09-26)

- 코드 검토에서 File raw store가 같은 달 generation 파일을 수정 시각 기준 최근 10개로 pruning하면서 snapshot의 committed ID나 다른 기기의 offline 참조를 조회하지 않는 점을 확인했다. 삭제 오류도 `try?`로 무시했다.
- 참조를 확인할 CloudKit manifest가 아직 없으므로 자동 pruning을 제거해 저장된 generation을 보존한다. 정리 정책은 참조 목록을 제공하는 CAS manifest 구현 뒤 다시 연결해야 한다.
- 12개 raw generation을 저장한 뒤 모두 남는 것, committed generation 보존, 손상 월 일부 복원 회귀 통과. 로그 `build/validation/HME0926A01/backup-safety-regressions-final.log`, 결과 `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.26_23-27-19-+0900.xcresult`.
- 최근 10개 제한·offline 참조 확인·삭제 실패 재시도는 미완료다.

## OVL0926U01 · 집 성장 콜아웃과 화랑이 마커 겹침 (2026-09-26)

- 제공된 실기기 캡처(`/Users/u_mo_c/Downloads/스크린샷, 2026-09-26 오후 11.25.49.png`)에서 집 성장 카드의 오늘 상태가 화랑이 마커에 가려지는 것을 확인했다. `MapHomePlacePin`에서 카드만 위로 42pt 이동했다. 마커, 지도 제스처, 레일 프레임은 바꾸지 않았다.
- `git diff --check` 통과. 앱 Debug 빌드 `build/validation/OVL0926U01/app-debug.log`: `** BUILD SUCCEEDED **`.
- 해당 빌드를 iPhone 11 Pro `00008030-001628201AD2802E`, iPhone 18 Pro Max `00008160-000E195A1140000A`, iPad Pro 12.9-inch 6세대 `00008112-000964980E45401E`에 설치했다. `devicectl device info apps`에서 세 기기 모두 `com.taption.plan` 버전 1.0 / 빌드 157을 readback했다.
- 제공 캡처는 수정 전 화면이며, 수정 후 화랑이·상태 문구 가시성과 지도 제스처는 실제 기기 화면/저장 영상으로 재확인해야 한다. 설치 성공만으로 UI 검증을 통과 처리하지 않는다.

## MUI0926D01 · 지도 홈 좌우 메뉴·통합 집 마커 디자인 시안 (2026-09-26)

- 제공된 실기기 지도 캡처를 참조해 별도 이미지 시안 5개를 생성했다. 왼쪽 독은 짧은 세로형, 하단 가로형, 2×2 압축형 등으로 나누고, 우측 시간 레일과 일체형 집·화랑이 이미지를 각 시안에 반영했다.
- 생성 파일: `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-22014dda-1366-4bd0-8e5e-4fe4b9287477.png`, `exec-4b86347d-336c-4d6c-9176-10f0295247af.png`, `exec-ddcea126-843b-45b4-b74e-f68ab709cf8b.png`, `exec-21e25b2e-34aa-480f-9398-ad7436eaa53e.png`, `exec-ff79150a-f068-4596-8ac4-82d9511cc3b3.png`.
- 시안 이미지 자체는 코드 반영이나 실기기 검증이 아니다. 사용자가 선택한 조합의 구현·검증 내역은 아래 기록한다.

## MUI0926D01 · 선택 시안 구현 및 검증 (2026-09-27)

- 사용자가 시안 2의 우측 레일과 시안 4의 왼쪽 메뉴·집/화랑이 구성 조합을 선택했고, 추가로 좌우 레일 높이를 맞추고 아래로 이동하도록 요청했다. 통합 검토 이미지: `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-55ee3e14-ac51-47e7-8370-383ee257c2df.png`; 높이 맞춤 보정 시안: `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-86bf3272-951e-41f3-a02b-3b1916f66030.png`.
- 공통 레일을 28pt 아래로 이동하되 높이는 유지했다. 우측 레일의 바깥 여백을 줄여 화면 오른쪽에 붙이고, 배경 숫자 트랙을 둥근 실루엣으로 클립했다. 선택 시간 표시는 좁은 캡슐 형태로 바꿨다.
- 집 위치의 사용자 설정 반경 안에 표시 위치가 들어오면 집 안에 작은 흰 고양이를 합성하고, 별도 고양이 마커와 플레이어 방향 화살표를 숨긴다. 집 밖에서는 기존 성장 아트와 별도 화랑이를 유지한다. 기존 액세서리·윤달 표시는 통합 마커에서도 보존한다.
- 신규 `MapHomePresencePolicyTests` 2개와 `MapHomeTimeRailCardTests` 4개, 기존 `MapHomeGrowthPolicyTests`를 실행해 통과했다. 로그 `build/validation/MUI0926D01/ui-tests.log`; xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_00-17-41-+0900.xcresult`.
- Generic iOS Debug 빌드 통과: `build/validation/MUI0926D01/app-debug.log` (`** BUILD SUCCEEDED **`). 동일 빌드를 iPhone 11 Pro `00008030-001628201AD2802E`, iPhone 18 Pro Max `00008160-000E195A1140000A`, iPad Pro 12.9-inch 6세대 `00008112-000964980E45401E`에 설치했다. 세 기기 모두 `com.taption.plan` 버전 1.0 / 빌드 157 readback.
- 아직 실제 실행 화면·지도 팬/핀치·집 반경 합성 상태를 카메라롤 저장 영상으로 확인하지 않았다. 설치만으로 기능 검증을 완료 처리하지 않는다.

## MUI0927A02 · 선택 시안과 실 UI 일치 보정 (2026-09-27)

- 선택 시안의 왼쪽 압축 메뉴와 분리 줌을 지도 하단에 배치하고, 집 안 화랑이 통합 마커를 기존 `MapHomeHouseMarker` 그림으로 구성하도록 수정했다.
- `MapHomeTimeRailCardTests`, `MapHomePresencePolicyTests`, `MapHomeGrowthPolicyTests` 통과. 로그 `build/validation/MUI0927A02/ui-tests.log`; xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_00-37-56-+0900.xcresult`.
- Generic iOS Debug 빌드 통과: `build/validation/MUI0927A02/app-debug.log`. 해당 산출물을 iPhone 11 Pro `00008030-001628201AD2802E`에 설치·실행했고 `devicectl`에서 `com.taption.plan` 버전 1.0/빌드 157을 readback했다.
- 실기기 화면과 지도 제스처는 별도 증거 대기이며, 빌드·설치만으로 완료 처리하지 않는다.

## MAP0927T03 · 집 성장 그림 정합 및 지도 드래그 (2026-09-27)

- 집 안 마커 배경을 고정 집 이미지에서 `MapHomeGrowthPolicy.artworkName(level:)`이 반환하는 동일 연도 단계 그림으로 바꾸고 화랑이를 합성했다. 집 위치 마커의 hit-testing을 꺼 UIKit 지도가 집/고양이 영역에서 직접 드래그를 받을 수 있게 했다.
- `MapHomeGrowthPolicyTests`, `MapHomeTimeRailCardTests`, `MapHomePresencePolicyTests` 통과(총 18개). 로그 `build/validation/MAP0927T03/ui-tests.log`; xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_00-47-52-+0900.xcresult`.
- 앱 Debug 빌드 통과: `build/validation/MAP0927T03/app-debug.log`. 산출물을 iPhone 11 Pro `00008030-001628201AD2802E`에 설치·실행했고 `com.taption.plan` 버전 1.0/빌드 157을 readback했다.
- 수정 화면·팬/핀치 동작은 아직 실제 기기 카메라롤 저장 증거로 확인하지 않았다. 사이드바 시안은 선택 전이므로 코드 반영하지 않았다.
- 사이드바 이미지 시안(최근 캡처를 참조): `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-1a505b1a-8c2e-40fe-a219-26c034d99860.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-7a2aaf6a-8278-44be-84e3-4d38d0cd4efb.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-e67e30f5-51de-4424-992d-3942c1f73116.png`.
- 사용자가 2안을 고르며 활동 카테고리 색상 세그먼트가 보여야 한다고 보정 요청했다. 지속 시간에 비례한 연속 색상 구간이 있는 수정 시안 `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-3679919c-2b7b-42eb-bf32-114a6d2f6615.png` 생성. 최종 시안 확인 후 구현한다.
- 후속으로 왼쪽 메뉴의 4개 조작(메뉴·검색·현재 위치·방향)과 아래 분리형 확대/축소 전체를 유지하도록 요청해 최종 검토 시안 `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-70032c3e-37d8-4364-b2c9-357c4ed8822d.png`를 생성했다. 구현 전 최종 확인 대기.
- 좌우 사이드바 하단 위치와 화면 아래 여백을 동일하게 하고 오른쪽 시간축을 아래로 연장하도록 추가 요청받아 시안 `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-f6b3f2d7-b50e-4eba-9e06-6743ab3098c6.png`로 보정했다. 구현 전 최종 확인 대기.

## WTH0927A05 · 시간축 왼쪽 날씨 시안 5개 (2026-09-27)

- 매시간 00–24 표시, 활동 색상 세그먼트, 전체 좌측 조작 버튼, 좌우 같은 하단 여백을 유지하며 날씨 레이아웃 다섯 안을 생성했다. 최종 선택 전 코드는 변경하지 않았다.
- 시안 순서: `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-d20af15e-a2e2-469e-a231-af615941d298.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-0775b59d-fca1-4b6d-ba64-c325e04bc308.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-af7d62a2-06e3-4601-bb9f-eeff12be9445.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-f8da4268-2ce0-4861-a18d-c26fbe66b7ed.png`, `/Users/u_mo_c/.codex/generated_images/01a0dd4c-fef3-72b2-b39e-e5c1f14ab959/exec-6b9a9ece-7d54-4956-9914-f0eecc3d844e.png`.
- 사용자가 3안을 선택해 날씨 셀을 카드 없는 세로형 기호·기온으로 바꾸고 날씨 항목 사이 최소 간격을 확보했다. 전체 하루 보기 시간 눈금은 00–24 매시간 모두 표시한다. 활동 색상 띠, 전체 왼쪽 조작 메뉴, 좌우 레일 정렬은 유지했다.
- 자동 테스트 22개 통과: `build/validation/WTH0927A05/tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_01-39-16-+0900.xcresult`. iOS Debug 빌드 성공: `build/validation/WTH0927A05/build.log`.
- iPhone 11 Pro `00008030-001628201AD2802E` 설치·실행 완료, `com.taption.plan` 버전 1.0/빌드 157 readback: `build/validation/WTH0927A05/install.log`. 기기 화면 캡처·카메라롤 영상은 아직 판독하지 않아 시각 기능 검증은 대기한다.

## WTH0927A06 · 날씨 전용 레일 / HSM0927A06 · 집 성장 요약 펼침 (2026-09-27)

- 3안 적용: 지도 위 작은 날씨 텍스트 대신 시간 레일에 붙는 크림색 세로 레일에 예보 시각·아이콘·기온을 정렬했다. 예보가 비어 있으면 선택 시간 위치에 `날씨 없음`을 표시한다. 레일 행은 최소 44pt 간격을 확보하고, 기존 활동 색 띠·매시간 눈금은 유지했다.
- 집 요약은 화랑이가 집에 있을 때도 집 그림 위에 표시한다. 기본 캡슐은 레벨·오늘 상태·진행을 보여주며, 캡슐을 누르면 연속일과 대기 주간 보상이 펼쳐진다. 지도 드래그를 위해 집 그림과 화랑이 이미지 자체의 hit-testing은 끈다.
- 관련 테스트 20개 통과: `build/validation/WTH0927A06-tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_02-10-01-+0900.xcresult`. 앱 iOS Debug 빌드 성공: `build/validation/WTH0927A06-build.log`.
- iPhone 11 Pro `00008030-001628201AD2802E`에 설치·실행했고 앱 `com.taption.plan` 1.0/157 readback: `build/validation/WTH0927A06-install.log`. 실제 화면 가독성, 요약 펼침, 지도 드래그는 카메라롤 저장 화면/영상 판독 전까지 미검증이다.

## DYS0927A01 · 레벨 버튼이 하루 요약을 하단에서 열기 (2026-09-27)

- 집 성장 캡슐의 집 아이콘·레벨 영역을 누르면 기존 `MapHomeDaySummarySheet`를 표시하도록 연결했다. 펼침 화살표는 연속일·주간 보상 요약을 열고 닫는다.
- 관련 회귀 테스트 18개 통과: `build/validation/DYS0927A01/tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_02-14-27-+0900.xcresult`. 앱 iOS Debug 빌드 성공: `build/validation/DYS0927A01/build.log`.
- iPhone 11 Pro `00008030-001628201AD2802E` 설치·실행, `com.taption.plan` 1.0/157 readback: `build/validation/DYS0927A01/install.log`. 실제 레벨 탭 후 하단 시트 표시 여부는 카메라롤 증거로 확인 대기.

## SBW0927A01 · 시간 사이드바·날씨 배치 참고 시안 적용 (2026-09-27)

- 긴 날씨 패널을 제거하고 시간 레일 왼쪽에 아이콘·기온 가로 캡슐을 예보 시각 높이로 표시했다. 캡슐 폭은 60pt, 시간 레일은 44pt로 줄였다. 기존 활동 색상 띠, 매시간 00–24 눈금, 선택 시간 표시는 보존했고 왼쪽 메뉴·좌우 하단 정렬은 변경하지 않았다.
- 회귀 테스트 5개 통과: `build/validation/SBW0927A01/targeted-tests.log` (`testWeatherTimelineCapsulesAttachFlushToSidebarPanel`, `testWeatherTimelineKeepsItsCenterWhenPlayheadOverlaps`, `testWeatherRailKeepsTheSelectedValueWithoutStackingLabels`, `testSidebarSelectionTimeBlockFitsTheExistingRailWidth`, `testSidebarHandleLaneContainsExpandedHitAreaWithoutRailOverlap`). xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_02-39-38-+0900.xcresult`.
- 앱 generic iOS Debug 빌드 성공: `build/validation/SBW0927A01/build.log`. 빌드 후 수정된 미사용 좌표 계산도 제거했으며 재빌드에서 경고 없이 통과했다.
- 전체 `TimeScaleTests` 실행에서 sidebar 스타일 상수, ruler 폭/선택 시간 폭, 지도 스타일 및 기존 하단 정렬 등 이 요청 바깥 실패가 발생해 실행을 중단했다. 변경에 직접 대응하는 세 테스트는 별도 실행해 모두 통과했다. 중단 로그: `build/validation/SBW0927A01/test.log`.
- 실기기 설치·실행은 완료했으나 실제 화면을 카메라롤 저장 파일로 판독하지 않았다. 캡슐 판독성과 겹침은 해당 증거 확인 전까지 대기한다.
- 요청된 iPhone 11 Pro `00008030-001628201AD2802E`에 위 빌드를 설치·실행했고, `devicectl`에서 `com.taption.plan` 버전 1.0 / 빌드 157 readback을 확인했다. 기록 `build/validation/SBW0927A01/install.log`.
- 설치본 화면을 캡처해 `build/validation/SBW0927A01/device-screen.png`에서 가로 날씨 캡슐, 활동 색상 띠, 매시간 눈금, 선택 시간 캡슐 간 간격 및 좌우 하단 정렬을 확인했다. 이는 직접 기기 screenshot이며, 프로젝트 기준의 카메라롤 저장 영상 판독과는 구분한다.

## 전체 temp 실행 · 2026-09-27 진행 기록

- 화랑이 지도 탭은 `SpatialTapGesture` 좌표를 현재 화랑이 중심점과 비교해 반경 36pt 안 정지 탭에서 기존 `.cat` 상세를 연다. 드래그/핀치 핸들러는 변경하지 않았다. 기하 경계 회귀 테스트 `testCatTapRoutingAcceptsOnlyTapsInsideMarkerBounds` 통과: `build/validation/RST0927A01/test-cat-tap.log`.
- 집 성장 주간 후보 50개에 각기 별도 SVG 에셋을 생성하고 후보 카드에 연결했다. 366단계 SVG는 수정하지 않았다. SVG XML parse 통과, asset 포함 앱 Debug 빌드 성공: `build/validation/RST0927A01/build-landmark-assets.log`.
- 백업 V4/CloudKit CAS는 아직 구현하지 않았다. 현 구조는 월 archive 전체 payload 단일 AES-GCM, iCloud 파일 저장이며 raw 조회 page cursor만 256행·1MiB 기본 제한을 제공한다. staging/recovery journal 및 offline/referenced-generation-aware CloudKit manifest가 없어 기존 복원·혼합 버전 계약을 더 설계 중이다. 기존 Core 테스트 baseline 100/100은 `build/validation/RST0927A01/core-tests.log`에 있다.
- 최종 변경 화랑이 집/이동 좌표 경계 테스트 통과: `build/validation/RST0927A01/test-growth-cat-assets-final.log`. 후보 50개/국가당 5개 및 에셋 이름 회귀 테스트 통과: `build/validation/RST0927A01/test-landmark-catalog.log`. 최신 generic iOS Debug 빌드 성공: `build/validation/RST0927A01/build-final.log`.
- 전체 진행 중 재실행한 지도 오버레이 카메라 갱신 회귀와 화랑이 좌표 탭 회귀가 통과했다. `build/validation/RST0927A01/open-items-regression.log`; 랜드마크 국가·후보 회귀도 개별 재실행 통과했다. `build/validation/RST0927A01/test-landmark-catalog-final.log`.
- build 157을 iPhone 11 Pro·iPhone 18 Pro Max·iPad Pro에 설치하고 `com.taption.plan` 1.0/157을 readback했다. 로그: `build/validation/RST0927A01/install-iphone11.log`, `install-iphone18.log`, `install-ipad.log` 및 해당 `readback-*.txt`. 설치본 화면·제스처는 카메라롤 영상 검증 전이라 미판정이다.
- 실기기 기능, 카메라롤 영상, Watch/App Group 연속성, GPS·수면·백업·캘린더·장시간 사용은 판정하지 않았다.
# TF0927A001 · main push 및 TestFlight 빌드 (2026-09-27)

- App Store Connect API readback에서 앱 `com.taption.plan`의 최신 처리 완료 빌드는 157이었다. 새 TestFlight 빌드 중복을 피하려고 앱·Widget·Watch 타깃 `CURRENT_PROJECT_VERSION`을 158로 올렸다.
- `swift test --package-path Packages/TaptionPlanCore`: 100/100 통과. 기존 백업 회귀 111개 통과 근거는 `build/validation/RST0920A01/security-backup-regressions-final.log`에 보존돼 있다.
- 이번 전체 앱 시뮬레이터 테스트 시도에서 13개 테스트 실패가 기록됐고, 시뮬레이터가 앱을 다시 시작하지 못한 뒤 진단 수집이 정지해 결과 번들이 완성되지 않았다. 로그: `build/validation/TF0927A001/app-tests.log`. 실패: `MapHomeStickmanTests.testDestinationActionsUseCompanySchoolAndRestaurantSemantics`, `MapHomeStickmanTests.testIPhoneOnlySleepDoesNotClaimAppleWatchPriority`, `TimeScaleTests.testExpandedSidebarRulerLabelsStartAfterTickColumn`, `TimeScaleTests.testLegacyMapStylesRemainDecodableButRuntimeIsWBSApple`, `TimeScaleTests.testMapDisplayStyleIncludesSimplifiedAndUnknownValuesFallback`, `TimeScaleTests.testMapDisplayStyleNormalizesPersistedAndMissingValuesToWBSApple`, `TimeScaleTests.testMapHomeOverlayUsesSharedBottomMarginAndUniformControlSpacing`, `TimeScaleTests.testMapHomeVectorStylesKeepOnlyStyledRoadMapLayers`, `TimeScaleTests.testSidebarRulerFontStaysFixedAcrossAllZoomSteps`, `TimeScaleTests.testSidebarSelectionHandleUsesApprovedWhiteAndDeepPinkStyle`, `LocalizationCatalogTests.testEveryCatalogKeyHasAnEnglishValue`, `FeatureEngineTests.testMapHomePastelPaletteKeepsCategoriesVisuallySeparated`, `FeatureEngineTests.testMapHomeSidebarUsesDistinctMajorCategoryVisuals`. 이 실패들은 통과로 처리하지 않는다.
- 랜드마크 에셋 검증 스크립트에서 10개국 50개 asset catalog와 SVG XML 50개가 모두 유효했다. `git diff --check`도 통과했다.
- main 변경 커밋 `94859b9`를 `origin/main`에 push하고 `git ls-remote`로 동일 SHA를 확인했다. archive `build/ArchiveDD/Archives/TaptionPlan-158.xcarchive`는 `** ARCHIVE SUCCEEDED **`; export/upload 로그 `build/validation/TF0927A001/export.log`에 `Upload succeeded`, `Uploaded TaptionPlan`, `** EXPORT SUCCEEDED **`가 기록됐다.
- App Store Connect 빌드 ID `dba98e5e-61e0-4997-8639-5217b656f8ab`, 버전 1.0(158), `processingState=VALID`를 API로 확인했다. `TP Taption Plan 내부 테스트` 그룹 ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`에 연결하고 그룹 `/builds` 목록에서 158을 readback했다. App Store Connect 그룹 화면에도 `빌드 1.0 (158) 내부`가 표시되고 상태 `테스트 중`, 그룹 테스터 1명으로 확인했다.
- 배포 프로파일이 없어 App Store Connect API로 App/Widget/Watch/Watch Widget의 App Store 프로파일을 만들고 수동 배포 서명에 사용했다. API key 인증을 Xcode export에 전달해야 했으며 인증 정보는 저장소에 기록하지 않았다.
- Xcode archive 경고: MapLibre.framework의 dSYM UUID `19E85E5A-837A-3278-87A6-FA63D4B799E5`가 포함되지 않아 해당 프레임워크 crash symbolication은 제한될 수 있다. 업로드와 Apple 처리에는 영향이 없었다.
- 전체 앱 테스트는 위 13개 실패 및 시뮬레이터 재실행/진단 수집 오류로 완주하지 못했다. 이 실패들은 해결·통과 처리하지 않았고 별도 재검토가 필요하다. Core 100/100과 보존된 SecurityBackupCore 111/111 결과만 통과 근거로 남긴다.

## UNQ0927A001 · 미확인 활동 빠른 입력 및 시간 눈금 inset (2026-09-27)

- 오른쪽 시간 사이드바의 `?` 버튼을 추가해 미확인 시간 구간만 시간순으로 확인한다. 구간을 누르면 목록 시트를 닫고 기존 활동 구간 편집기로 연결한다. 확인할 구간이 없으면 완료 안내를 표시한다.
- 시간 레일의 숫자 눈금에 6pt 안쪽 여백을 적용했다. 분 단위 눈금 위치와 활동 색상 레일은 유지했다.
- 회귀 테스트 2개 통과: 미확인 구간 필터/정렬 및 중앙 분 선택, 사이드바 숫자 inset. 실행 로그 `build/validation/UNQ0927A001/targeted-tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_15-20-08-+0900.xcresult`.
- generic iOS Debug 빌드 성공: `build/validation/UNQ0927A001/debug-build.log`. `git diff --check` 통과.
- 실기기 시각 판독은 하지 않았다. `?` 버튼 위치와 시트 전환 체감은 기기 화면으로 별도 확인이 필요하다.

## UNQ0927B01 · HME0927B02 · CAT0927B03–CAT0927B08 (2026-09-27)

- 미확인 목록에서 최근 7일 전부터 오늘까지 날짜를 바로 이동하고, 각 구간의 활동 칩을 눌러 기존 `ActivitySectionEditRequest` 저장 경로로 즉시 입력한다. 오늘의 미래 구간은 목록에 내지 않으며, 저장 실패는 행 안에 표시한다. 시간 행을 누르면 기존 상세 편집기로 이동한다.
- 최근 7일의 미완료일은 전체 구간을 확인한 직후 날짜당 한 번만 해당 연도의 집 레벨을 올린다. 소급 보상은 연속 달성·주간 후보·땅·화랑이 액세서리를 지급하지 않는다. 연말 완료는 이전 연도 집 archive에 적용한다. 정상 일일 달성과 소급 달성의 중복 지급을 막는다.
- 화랑이 재생 간격을 기존의 약 4배로 늘렸다. 미확인은 갸웃·물음표, 업무는 모니터 앞 왕복, 공부는 책 앞 왕복, 취미는 순환 음표, 수면은 호흡·Zzz, 운동은 회전하는 캣휠과 달리기 포즈를 표시한다. 지도 마커와 작은 글리프에 같은 표현을 사용한다.
- 관련 23개 테스트 통과: `build/validation/MULT0927B01/targeted-tests-final.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_15-43-54-+0900.xcresult`. 날짜 경계, 중복 보상, 액세서리 미지급, 구형 성장 데이터 디코딩, 미확인 구간 입력 후 목록 제외, 카테고리 동작·속도를 확인했다.
- 지난 날짜 보상 시 미정산 날짜의 실제 기록을 다시 판정하도록 마무리한 뒤 집 성장 정책 17개를 재실행해 통과했다: `build/validation/MULT0927B01/growth-final.log`.
- 앱 generic iOS Debug 빌드 성공: `build/validation/MULT0927B01/debug-build.log`. `git diff --check` 통과. 시뮬레이터 실행 화면 `build/validation/MULT0927B01/simulator-home.png`에서 오른쪽 `?` 진입점과 시간 눈금의 배치를 확인했다.
- 실제 기기에서 빠른 입력 저장·집 레벨 보상 readback·화랑이 동작 속도 및 표현은 아직 판독하지 않았다. 시뮬레이터 홈 화면 캡처는 이 검증을 대체하지 않는다.
## REV0927C01 · 빠른 입력 원본 보존·자정 정산·버튼 터치 영역 (2026-09-27)

- 부분 편집에서 선택 범위 바깥의 수동 기록을 별도 조각으로 남기고, 저장소 재조회 시 해당 조각까지 확인하도록 수정했다. 소급 보상이 거절돼도 먼저 수행한 미정산 날짜의 정산 결과를 저장한다. `?` 버튼의 표시 원형은 26pt로 유지하고 실제 터치 영역은 44pt로 확대했다.
- 회귀 테스트 2개 통과: 원본 미확인 기록의 편집 범위 밖 보존과 보상 거절 시 자정 정산. 로그 `build/validation/REV0927C01/targeted-tests.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.27_16-35-37-+0900.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/REV0927C01/debug-build.log`. `git diff --check` 통과.
- 실기기에서 빠른 입력 저장 결과와 버튼 터치감은 확인하지 않았으므로 `temp.md`의 검증 대기로 유지한다.

## TFL0927C01 · main push 및 TestFlight 159 (2026-09-27)

- 지도 UI·빠른 입력·성장 보상 변경을 `0e1977e`로, 앱·Widget·Watch·Watch Widget의 Info.plist 빌드 번호 159 정정을 `6cb630e`로 main에 커밋·push했다. 첫 archive는 프로젝트 설정만 159이고 Info.plist가 158이라 업로드가 중복 번호로 거절됐다. 네 Info.plist를 수정한 최종 archive의 앱·Widget·Watch 번들 번호가 159임을 확인했다.
- 최종 archive `build/ArchiveDD/Archives/TaptionPlan-159-final.xcarchive`가 `ARCHIVE SUCCEEDED`, `build/validation/TFL0927C01/export-final.log`에 `Upload succeeded`, `Uploaded TaptionPlan`, `EXPORT SUCCEEDED`가 기록됐다. 첫 실패와 수정 근거는 같은 폴더의 `export.log`, `archive-final.log`에 보존했다.
- App Store Connect API에서 빌드 ID `d5a86231-c08b-4dc2-859f-5d00211b1020`, 버전 159, `processingState=VALID`를 확인한 뒤 `TP Taption Plan 내부 테스트` 그룹에 연결했다. 그룹 빌드 화면에서 `1.0 (159) 내부`가 `테스트 중`으로 표시되고, 그룹에 테스터 1명·빌드 118개가 표시됨을 확인했다.
- 이번 배포는 설치·실기기 기능 검증을 대신하지 않는다. 앞선 전체 앱 테스트의 미해결 실패 13개도 통과로 처리하지 않았다.

## D270927A01 · 개발 문서 정합성·작업 문맥 절약 (2026-09-27)

- `README.md`를 짧은 시작점으로 바꾸고, 개발 규칙은 `AGENTS.md`, 구조·명령은 새 `DEVELOPMENT.md`, 상태·근거는 기존 `temp.md`·`test.md`의 요청 ID 구간에서 읽도록 나눴다.
- Codex/Kiro의 활성 인계문은 각각 5줄로 줄였다. 과거 Codex 9/25 push 문서와 Kiro 9/23 상세 인계문은 원문 본문을 날짜가 명시된 보관본으로 옮기고, 보관 안내를 덧붙였다. Codex 9/26 인계에도 오래된 상태를 따르지 말라는 표시를 추가했다. `PRIVACY.md`, `SUPPORT.md`, 기존 미완료 요청과 검증 기록은 변경하지 않았다.
- 12개 Markdown 문서의 로컬 링크·끝 공백·충돌 표시를 확인해 통과했다. `git diff --check`도 통과했다. `xcodebuild -list`에서 `TaptionPlan` scheme과 대상 프로젝트를 확인하고 개발 안내의 소스 경로를 현재 저장소와 대조했다.
- 이 변경은 문서 전용이므로 앱 테스트·빌드는 실행하지 않았다. 문서 명령은 예시이며 실제 동작 변경 시 관련 테스트와 Debug 빌드를 별도로 실행한다.

## HK270927A1 · 첫 실행 HealthKit 허용 후 온보딩 정체 확인 (2026-09-27)

- `AppShellView`에서 현재 단계의 `허용하기`·`건너뛰기` 두 버튼은 `model.isRefreshingIntegrations`에 함께 비활성화되지만, 하단 `모두 허용`은 `isRequesting`만 검사한다.
- 첫 활성화는 지연 foreground refresh를 예약한다. `refreshEnabledData`도 같은 `isRefreshingIntegrations`를 켠다. 그 사이 `requestHealth`는 무표시로 반환할 수 있고, 온보딩 `request(_:)`는 요청이 실제 수행됐는지와 무관하게 `advance()`를 호출한다. 따라서 첨부 화면처럼 개별 버튼이 비활성화되고 하단 전체 허용만 동작하는 경로가 코드상 가능하며, 전체 허용 경로는 권한 요청을 건너뛴 채 넘어갈 수도 있다.
- 기존 `FeatureEngineTests`에는 온보딩 표시 조건 테스트는 있지만 이 화면의 버튼 잠금·요청 진행 중 전환 테스트는 없다. 스크린샷의 희미한 버튼과 코드의 비활성화 조건이 일치한다. 단, 기기 로그나 실행 중 상태를 받지 않아 해당 캡처 순간 어떤 refresh가 잠금을 잡았는지까지는 확인하지 못했다.
- 소스는 수정하지 않았고 앱 테스트·빌드는 실행하지 않았다. 수정과 동적 검증은 `temp.md` HK270927A1에 열린 항목으로 남겼다.
- 사용자가 로그 업로드를 알린 뒤 현재 대화 첨부와 `~/Downloads` 최상위 파일을 재확인했다. 확인된 것은 이미지와 화면 녹화뿐이며 `.log`, `.ips`, `.crash` 진단 파일은 없어 로그 기반 재현 원인은 여전히 확인하지 못했다.

## UI270927A1 · 오른쪽 시간축 여백·미확인 입력 버튼 (2026-09-27)

- 시간축만 상단 20pt·하단 32pt 여백으로 확장하고 눈금 안쪽 여백을 10pt로 줄였다. 지도 조작 버튼 레일은 기존 위치를 유지한다. `?` 버튼은 시간축 하단으로 옮겼으며, 선택 날짜에서 현재까지 입력할 미확인 구간이 있을 때만 활성화된다.
- 신규 테스트 2개 통과: `testTimeSidebarUsesItsOwnExpandedTopAndBottomMargins`, `testUnconfirmedReviewAvailabilityIgnoresFutureAndConfirmedIntervals`. 기존 회귀 테스트 5개 통과: 미확인 구간 정렬, 오늘 현재 시각 자르기, 빠른 확정 후 목록 제거, 시간축 탭 매핑, 고주사율 드래그 결과 일치. 7개 선택 테스트 결과는 `build/validation/UI270927A1/final-tests.log`에 있다.
- iOS generic Debug 빌드 `BUILD SUCCEEDED`; `git diff --check` 통과. 최종 빌드 로그는 `build/validation/UI270927A1/debug-build-final.log`다.
- 시뮬레이터 단위 테스트는 통과했지만 실기기에서 간격·터치와 저장 동작은 확인하지 않았다. 해당 확인은 `temp.md` UI270927A1에 열린 상태로 둔다.

## GPS270927A · 포그라운드 실시간 현재 위치·이동 경로 (2026-09-27)

- 원인은 기본 위치 수집이 선택된 GPS 간격마다 짧은 표본 창을 열고 닫아, 앱을 켜 두어도 지속적인 `didUpdateLocations` 흐름이 없던 점이다. 지도는 이미 저장된 현재 위치와 `liveRouteState`를 그리므로 수집 간격이 화면 갱신을 제한했다.
- 위치 기록이 켜져 있고 위치 권한이 허용된 동안 앱이 active이면 Core Location을 정밀도 우선, 5m 이동 간격으로 유지한다. 중복 fix는 건너뛰고 0.5초보다 자주 저장하지 않는다. 새 위치를 SQLite 보관소에 즉시 기록한 뒤 기존 persisted-reading 콜백으로 현재 핀과 경로를 갱신한다. 앱이 background로 가면 포그라운드 모드를 끄고 기존 듀티사이클/Always 권한 기반 수집 정책을 사용한다. 새 Always 권한 요청은 추가하지 않았다.
- 새 회귀 테스트 3개 통과: 활성 화면·설정·권한 게이트, 5분 표본 간격 중 연속 위치 fix 출력, 포그라운드 경로점 즉시 저장. 기존 collector stream 교체 테스트 1개와 `testLiveRouteRequiresPreciseAvailableGPS` 1개도 통과했다. 총 5개 선택 테스트 실패·건너뜀 0건이며 로그·xcresult는 `build/validation/GPS270927A/` 아래에 있다.
- generic iOS Debug 빌드 성공: `build/validation/GPS270927A/debug-build.log`; `git diff --check` 통과. 시뮬레이터에서 자동 검증했으며 실제 기기 GPS·화면 경로·백그라운드 전환은 확인하지 않았다. 이동 경로 선은 기존 정책상 정밀 GPS fix를 요구한다. 실기기 확인은 `temp.md` GPS270927A에 남겼다.

## HOM270927A · 집 마커 탭으로 레벨 플로팅 카드 열기 (2026-09-27)

- 집 레벨·오늘 상태 카드를 기본 숨김 처리하고 집 그림 중앙 탭으로 열고 닫게 했다. 숨겨진 카드가 공간을 계속 차지해 집 핀의 좌표가 열릴 때 이동하지 않는다. 화랑이가 집에 있을 때는 집 아이콘 탭과 화랑이 탭 영역을 분리해 기존 화랑이 상세 진입을 보존했다. VoiceOver에는 성장 정보 표시/숨김 동작을 제공한다.
- 회귀 테스트 2개 통과: `testCatTapRoutingAcceptsOnlyTapsInsideMarkerBounds`, `testHomeIconTapRoutingSeparatesHouseFromHomeCat`. 로그 `build/validation/HOM270927A/tap-routing-final.log`, 결과 `build/validation/HOM270927A/tap-routing-final.xcresult`.
- generic iOS Debug 빌드 `BUILD SUCCEEDED`: `build/validation/HOM270927A/debug-build-final.log`. `git diff --check` 통과.
- 시뮬레이터에서 탭 라우팅 단위 테스트만 실행했다. 기본 카드 가시성·열기/닫기·지도 팬/핀치와 화랑이 상세 탭의 실제 화면 동작은 실기기에서 추가 확인 전이며 `temp.md`에 대기로 남겼다.

## WTH270927B · 현재 날씨 강조·미래 예보 흐리게·위젯 20% 축소 (2026-09-27)

- 관측 날씨(`isForecast != true`)는 불투명도 100%, 미래 예보(`isForecast == true`)는 58%로 표시하고 예보의 접근성 값을 비활성 상태로 알린다. 날씨 캡슐은 기존 60×28pt에서 48×22.4pt로, 내부 아이콘·기온·간격·테두리·그림자도 80%로 줄였다. 축소 후에도 캡슐 우측과 시간 레일 간격은 기존 4pt 정렬을 유지한다.
- 회귀 테스트 5개 통과: `testWeatherTimelineDimsForecastsAndScalesWidgetsToEightyPercent`, `testWeatherTimelineCapsulesAttachFlushToSidebarPanel`, `testWeatherTimelineKeepsItsCenterWhenPlayheadOverlaps`, `testMapHomeWeatherCollapsesConcurrentLocationStreamsForDisplay`, `testMapHomeWeatherPrefersObservedOverSameSignatureForecast`. 로그 `build/validation/WTH270927B/final-tests.log`, 결과 `build/validation/WTH270927B/final-tests.xcresult`.
- generic iOS Debug 빌드 `BUILD SUCCEEDED`: `build/validation/WTH270927B/debug-build.log`. `git diff --check` 통과.
- 시뮬레이터에서 정책·정렬 단위 테스트만 실행했다. 실제 화면에서 축소된 글자 가독성과 현재/미래 대비는 별도 화면 확인 전이라 `temp.md`에 대기 중이다.

## UR270927A1 · 왼쪽 하단 실행취소/다시실행 (2026-09-27)

- 지도 왼쪽 조작 레일의 줌 버튼 아래에 실행취소·다시실행을 세로로 추가했다. 가능한 이력이 없으면 흐리게 표시하고 누를 수 없게 한다. 실행 중 최대 40개의 사용자 일정·수동 활동 편집 이력을 유지하며, 자동 센서 원본은 되돌리지 않는다. 새 편집은 다시실행 이력을 지운다.
- 선택 테스트 3개 통과, 실패·건너뜀 0건: `testActivityEditUndoRedoPreservesAutomaticRecordsAndClearsRedo`(활동 변경 왕복, HealthKit 기록 보존, 새 편집 뒤 다시실행 무효화), `testUserPlanUndoRedo`(사용자 계획 추가 왕복), 기존 `testActivitySectionSaveOverridesTravelAndSupportsImmediateReedit`. 로그·xcresult는 `build/validation/UR270927A1/final-tests.log`, `final-tests.xcresult`에 있다. 첫 컴파일 시 테스트의 `XCTUnwrap`에 `try` 누락이 확인되어 수정한 뒤 최종 테스트를 재실행해 통과했다.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/UR270927A1/final-debug-build.log`. `git diff --check` 통과.
- 테스트는 시뮬레이터에서 실행했다. 이번 빌드는 iPhone에 설치하지 않았고, 실제 화면에서 왼쪽 하단 위치·터치감은 확인하지 않았다. 이 화면 확인은 `temp.md`에 대기로 남긴다.

## IN270927A1 · iPhone 18 Pro Max 현재 작업본 설치 (2026-09-27)

- 현재 연결된 실기기는 iPhone 18 Pro Max(`iPhone19,7`, UDID `00008160-000E195A1140000A`), iOS 27.2로 확인했다. 기기 정보 readback은 `build/validation/IN270927A1/device-details.txt` 및 `.json`에 있다.
- 최신 generic iOS Debug 산출물 `com.taption.plan` 1.0/159를 기기에 설치했다. `devicectl` 설치 성공 로그·JSON은 `build/validation/IN270927A1/install.log`, `install.json`; 앱 목록 readback에서 `Taption Plan · com.taption.plan · 1.0 · 159`를 확인했다: `readback.txt`, `readback.json`.
- 사용 요청은 설치였으므로 앱을 실행하거나 화면 기능을 판정하지 않았다. 설치와 readback은 날씨/UI 기기 검증을 의미하지 않는다.

## CAT0928A01 · 회사 넥타이 업무 포즈·학교 안경 학습 포즈 (2026-09-28)

- `MapHomeStickmanAction`에 실제 등록 장소 전용 `.company`/`.school` 표현 상태를 추가했다. resolver는 회사 체류를 회사 업무, 학교 체류를 학교 학습으로 구분하고, 앱 사이드바의 work/study 라벨에서도 회사/학교가 명시될 때만 전용 표현을 선택한다. 일반 업무·수업 카테고리, 독서, 학원은 기존 표현을 유지한다.
- 전용 회사/학교 화랑이는 각각 앉은 포즈로 모니터/책 앞 좌우 움직임을 유지하고, 지도 마커에서만 넥타이/안경 overlay를 표시한다. 다른 고양이 마커와 실제 활동 분류·저장 데이터는 변경하지 않았다.
- `MapHomeStickmanTests` 집중 회귀 3개 통과(실패 0, 건너뜀 0): `testCatActivityScenesUseRequestedActionsAndQuarterSpeed`, `testDestinationActionsUseCompanySchoolAndRestaurantSemantics`, `testMapStickmanResolvesMajorCategoryBeforeActivityDetail`. 최종 결과 `build/validation/CAT0928A01/cat-focused-tests-final4.xcresult` 3/3 통과(실패·건너뜀 0), 로그 `cat-focused-tests-final4.log`. 중간 실행에서 발견된 일반 업무 포즈 회귀와 resolver category alias 문제를 수정한 뒤 이 결과로 확인했다. 첫 실행에서 드러난 상태 수·일반 걷기 기대값 차이는 전용 회사/학교로 수정 후 재검증했다.
- 최종 generic iOS Debug `BUILD SUCCEEDED`: `build/validation/CAT0928A01/ios-debug-build-final.log`. `git diff --check` 통과.
- 실기기 화면 캡처는 하지 않았다. 실제 회사/학교 체류 데이터에서 넥타이·안경 및 모니터·책 포즈가 보이는지는 기기 확인 전까지 `temp.md`에 대기한다.

## UIX0928A01 · 미확인 활동 대분류 2행 전체 표시 (2026-09-28)

- 빠른 입력 대분류 8개를 기존 순서대로 4열×2행으로 배치했다. 버튼별 즉시 저장 동작·색상은 유지했다.
- `TimeScaleTests.testUnconfirmedQuickCategoriesFitInTwoOrderedRows` 통과(1/1): `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.28_10-38-38-+0900.xcresult`; 같은 실행에 GPS 집중 테스트가 포함됐다.
- generic iOS Debug 빌드는 `build/validation/GPSX0928A1/ios-debug-build-final.log`에서 성공했다. `git diff --check` 통과.
- 실기기 화면은 아직 확인하지 않아 좁은 화면에서의 시각적 겹침/터치감은 `temp.md`에 대기한다.

## GPSX0928A1 · GPS 공백의 회색 예상 발자국 (2026-09-28)

- 지도에만 제한된 GPS 공백 보간을 추가했다. 정규화된 시간순 route readings에서 서로 이웃한 두 기록이 모두 정밀 iPhone GPS fix일 때만 같은 날 45초~5분, 25~600m, 정확도 각 50m 이하, 평균 이동속도 3m/s 이하 구간을 선형 보간한다. 최대 24개 보간 좌표를 약 25m 간격으로 만든다.
- 보간 좌표는 `SensorReading`이나 저장소에 기록하지 않는다. 기존 실측 발자국은 청록색으로 유지하고 예측 발자국만 회색으로 렌더링한다. GPS 외 기록을 건너뛰어 앞뒤를 잇지 않고, Watch·종료 세션·장시간/장거리/부정확 구간은 생략한다.
- `RouteTimelineDataTests.testGPSGapPredictionAddsOnlyBoundedDisplayCoordinates`와 `testGPSGapPredictionRejectsLongInaccurateAndWatchGaps`, `TimeScaleTests.testUnconfirmedQuickCategoriesFitInTwoOrderedRows`가 모두 통과(3/3, 실패/건너뜀 0). 실행 로그 `build/validation/GPSX0928A1/focused-tests-final2.log`, xcresult `build/ArchiveDD/Logs/Test/Test-TaptionPlan-2026.09.28_10-38-38-+0900.xcresult`.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/GPSX0928A1/ios-debug-build-final.log`; `git diff --check` 통과.
- 실기기에서 실제 GPS 공백 구간을 재현한 화면은 아직 확인하지 않았다. 예측은 지도 표시용 직선 보간이며 실제 도로·실제 이동 경로를 보장하지 않으므로 화면 확인 전에는 기능의 기기 검증을 완료 처리하지 않는다.

## DINA0928A1 · Dynamic Island 현재 대분류 화랑이·활동명 표시 (2026-09-28)

- 현재 구현이 요청을 이미 충족한다. 센서 수집 Live Activity와 활동 타이머 Live Activity 모두 compactLeading에서 현재 대분류 ID/이름으로 화랑이 동작을 선택하고, compactTrailing에서 같은 현재 활동명을 표시한다. 예를 들어 `movement` 상태에서는 왼쪽이 이동 동작으로 애니메이션되고 오른쪽은 `이동`이다. 실제 현재 활동 projection은 시작 상태에 전달되며 센서 수집 reconciliation 때 갱신된다. 따라서 소스 변경은 하지 않았다.
- `FeatureEngineTests.testLiveActivityContentStateOptionalFieldsDecodeAndRoundTrip` 1/1 통과, `MapHomeStickmanTests.testLiveActivityStickmanResolvesEveryMajorCategory` 1/1 통과. 각각의 xcresult/log는 `build/validation/DINA0928A1/compact-tests.xcresult`, `compact-tests.log`, `category-action-test-verified.xcresult`, `category-action-test-verified.log`에 있다. 첫 resolver 실행은 잘못 지정한 test class로 인해 0건이었으며 성공 근거에 포함하지 않는다.
- 위젯 extension을 포함한 generic iOS Debug `BUILD SUCCEEDED`: `build/validation/DINA0928A1/ios-debug-build.log`. `git diff --check` 통과.
- 실기기 Dynamic Island 캡처는 이번에 확인하지 않았다. 자동 테스트·빌드는 통과했으나 실제 기기의 표시 결과까지 검증한 것은 아니다.

## RPL0928A01 · 9월 24일 기록 재생에서 화랑이·이동 경로 누락 조사 (2026-09-28)

- iCloud 앱 컨테이너의 최신 로그 `TaptionLogs-20260928-123536.txt`에서 9월 24일의 날짜 snapshot 3건을 집계했다. 완료된 snapshot은 `readings=0`, `readings_with_point=0`, `travel=0`, `subway_segment_count=0`, `subway_route_count=0`이었다. 같은 시점 `fmap_route_projection`도 `segment_count=0`, `overlay_count=0`, `overlay_coordinate_total=0`, `dropped_short=0`, `dropped_subway_confirmed=0`으로 끝났고 날짜 로드는 완료됐다.
- 진단은 저장된 활동 항목의 존재와 별개로, 해당 날짜 지도 재생에 공급된 GPS/이동 원본이 없어서 화랑이 좌표와 이동 경로가 생성되지 않았음을 보여준다. 렌더러가 생성된 경로를 누락한 증거는 없다. 이 로그만으로 사용자가 말한 활동 기록 자체의 원본/건수까지 확인할 수는 없다. 원본 위치·건강 데이터는 출력하지 않았다.
- 판정: 현재 증거 기준 데이터 부재로 설명되므로 코드 결함으로 오판하지 않고 조사 요청을 닫는다. GPS가 저장된 9월 24일 기록이 있다고 확인되는 별도 증거가 생기면 새 조사로 연다. 9월 24일 화면을 직접 조작해 캡처한 것은 아니므로 실기기 UI 확인을 완료로 주장하지 않는다.

## HGR0928A01 · 집 성장 초반 단계·투명 마커 크기 (2026-09-28)

- Lv.1 모닥불은 그대로 두고 Lv.2 야영 흔적, Lv.3 천막, Lv.4 개방형 비가림막, Lv.5 목재 골조, Lv.6 지붕을 얹는 오두막, Lv.7 첫 완성 집으로 SVG를 교체했다. 하루 한 단계 성장, 기존 `HomeEvolution001...366` 이름과 연도별 365/366 단계는 보존했다.
- 지도 집 아이콘의 흰색 광륜·크림색 원판·테두리를 제거했다. 투명 여백이 있는 SVG 캔버스는 48pt로 유지해 실제 집 그림이 약 34pt로 보이며 `MapHomeStickmanMarker.size` 36pt에 가깝게 맞춘다. 집 안 화랑이 합성 그림도 같은 48pt 집 크기를 쓰고, 집 상세 탭의 18pt 반경과 48pt 터치 프레임은 유지했다.
- 성장 정책 테스트 18/18 통과(`testAll366EvolutionIllustrationsArePackaged` 포함). 집 아이콘·화랑이 탭 분리 회귀 1/1 통과. 결과 `build/validation/HGR0928A01/growth-policy-tests.xcresult`, `growth-tests.xcresult`; 최초 잘못된 테스트 클래스 경로로 실행해 0건 나온 결과는 성공 근거에 포함하지 않는다.
- generic iOS Debug `BUILD SUCCEEDED`: `build/validation/HGR0928A01/ios-debug.log`. 첫 7개 SVG와 366개 전체 SVG·이미지 세트 존재 및 XML 파싱을 검사했고, `git diff --check` 통과했다. 별도 에셋 미리보기로 Lv.2/3/4/5/6/7 그림을 육안 확인했다.
- 이번 Debug 변경본은 iPhone에 설치하지 않았다. 지도 화면에서 흰색 배경 제거, 화랑이 대비 크기 및 실제 보이는 크기는 기기 캡처 전이라 `temp.md`에 확인 대기로 남긴다.

## HGV0928A01 · 연간 집 성장 경로와 에셋 구조 조사 (2026-09-28)

- 구현을 읽어보면 집 그림은 분기하지 않는다. `artworkName(level:)`가 현재 시즌 레벨과 `HomeEvolutionNNN`을 직접 연결하고, 실제 일 기록이 있고 미확인 구간이 0인 날짜를 닫을 때 하루 최대 +1, 현지 연도의 365/366에서 상한을 둔다. 해가 바뀌면 이전 시즌을 archive하고 Lv.1부터 새로 시작한다.
- 별도 분기는 7일 연속마다 생기는 주간 보상이다. 50개 랜드마크 후보(10개국×5개) 중 3개를 보여 주고 하나를 고르면 진화 후보 ID·연결 배치용 땅 조각·액세서리 ID를 보관한다. 땅 배치와 액세서리 착용은 각각 별도 동작이며, 이 선택은 `HomeEvolution` 그림의 레벨/경로를 변경하지 않는다.
- 자산 검사는 366개 SVG와 카탈로그가 전부 존재하고 파싱됨을 확인했다. SVG의 `Lv.숫자` 텍스트만 정규화해 본문을 문자열 비교하면 총 178개 패턴이며, Lv.8–366은 359개 레벨에 171개 패턴이다. 일부 본문이 반복되며 최장 반복 그룹은 14레벨이다. 이는 SVG 문자열의 정확한 본문 중복 측정이지, 사람 눈에 비슷해 보이는 모양을 합산한 수는 아니다. 별도 랜드마크 에셋은 50개다.
- 레벨 1–7을 한 줄 성장, 매주 보상 선택을 옆 분기로 나타낸 경로도 SVG/PNG를 생성하고 화면으로 확인했다: `build/validation/HGV0928A01/home-growth-path.svg`, `home-growth-path-preview.svg.png`. 원본 코드 파일을 바꾸지 않는 조사·시각화 작업이다.
- SVG 파싱/카탈로그 수와 카운트 검사 통과, `git diff --check` 통과.
- 후속 화면 요청: Lv.8–14의 실제 SVG 7개를 동일한 96×96 viewBox로 나란히 배치한 연락 시트를 생성·육안 확인했다. 파일은 `build/validation/HGV0928A01/levels-8-14-contact.svg`와 `levels-8-14-contact.svg.png`에 있다. 이 구간은 모두 완성된 집이며, 화단·관목·나무·높이 등의 작은 장식 차이가 주 변화다.

## M1280928A1 · Lv.1–28 첫 달 성장 에셋 재구성 (2026-09-28)

- `scripts/generate_home_evolution_artwork.py`의 층수 규칙을 조정했다. 기존 Lv.1–7 도입 그림은 유지하고, Lv.8–14는 1층, Lv.15–21은 2층, Lv.22–28은 3층으로 구성한다. 이후에는 12주 단위로 층이 추가되어 기존 최대 8층 상한을 유지한다. 각 레벨에는 7일 팔레트 순환과 날짜별 주변 소품/강조 요소가 적용된다.
- 48pt 마커 비율 연락 시트를 렌더링해 Lv.1–14와 Lv.15–28의 단계별 실루엣 및 일별 팔레트·장식 변화를 육안 확인했다: `build/validation/M1280928A1/lv1-14.svg.png`, `lv15-28.svg.png` (편집 가능한 SVG 원본도 같은 폴더).
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_home_evolution_artwork.py --check`: 366개 SVG 본문 모두 고유, 365개 연속 레벨 쌍 모두 다름, 카탈로그 검증 통과.
- `MapHomeGrowthPolicyTests` 18/18 통과, 실패·건너뜀 0: `build/validation/M1280928A1/growth-tests.xcresult`, 로그 `growth-tests.log` (iPhone 17 Pro, iOS 26.5 시뮬레이터).
- iOS generic Debug 빌드 성공: `build/validation/M1280928A1/ios-debug.log`. `git diff --check` 통과.
- 테스트는 성장 정책과 번들 에셋을 검증한다. 실제 iPhone 지도에서 업데이트된 집 그림이 표시되는 장면은 아직 촬영하지 않았다.

## DLY0928A01 · 매일 눈에 띄는 집 성장 변화 (2026-09-28)

- `scripts/generate_home_evolution_artwork.py`를 추가해 기존 Lv.1–7 소개 그림을 보존하고 Lv.8–366을 결정론적으로 생성한다. 일별 7색 지붕/벽 팔레트와 큰 주변 장식을 바꾸며 건물 층과 실루엣을 키운다. 층 간격은 M1280928A1에서 첫 4주 주 1층, 이후 12주 1층으로 조정했다. 기존 `HomeEvolutionNNN` 파일명·96×96 투명 SVG viewBox·레벨 직접 매핑은 유지했다.
- `python3 scripts/generate_home_evolution_artwork.py --check`: 366/366 SVG XML 유효, `Lv.N` 레벨 문구를 제외한 그림 본문 고유 366/366, 인접 레벨 차이 365/365. `--write`로 결과를 재생성하고 다시 `--check`를 통과했다.
- `MapHomeGrowthPolicyTests` 18/18 통과(366개 에셋 bundle 포함): `build/validation/DLY0928A01/growth-tests.xcresult`, 로그 `growth-tests.log`. iOS generic Debug `BUILD SUCCEEDED`: `build/validation/DLY0928A01/ios-debug.log`. `git diff --check` 통과.
- Lv.8–21 연락 시트를 48pt 지도 마커 비율로 렌더링해 색·장식 변화와 15레벨부터의 주간 건축 변화가 읽히는지 육안 확인했다: `build/validation/DLY0928A01/daily-evolution-contact.svg.png`; 편집 가능한 원본은 `daily-evolution-contact.svg`.
- 시각화 수치는 SVG 본문 구조 고유성 검사와 연락 시트 육안 확인 기준이다. 실제 iPhone 지도에 업데이트 에셋이 표시되는 장면은 촬영하지 않았다. HGV0928A01의 178 패턴 수치는 DLY 변경 전의 과거 스냅샷이다.


## WDT0930A01 · iPhone 18 watchdog 방어 수정 · 2026-09-30
- CRAS0930A1의 `scene-update / 0x8BADF00D` 종료를 기준으로 방어 수정했다. 당시 앱 UUID와 일치하는 dSYM이 없어 특정 함수 원인이 확정됐다고 보고하지 않는다.
- `MapHomeView`의 지도·레일·마커 콘텐츠는 background에서 생성하지 않는다. 성장·시간축·탑승 후보 갱신은 active에서만 실행한다. 센서 수집/저장 모델은 변경하지 않았다.
- 실제 기록/이동/장소 배열을 SwiftUI `onChange`로 각각 비교하던 경로를 기존 `dayProjectionRevision` 변경 하나로 합쳤다. 모델의 해당 revision은 actuals/places/travel 변경 때 증가하는 것을 확인했다. 복귀 시 성장·시간축·탑승 후보·예상 경로를 다시 갱신하며 기존 날짜 로드 task는 활성 상태를 키로 최신 원본을 다시 읽는다.
- iOS generic Debug 최종 빌드 성공: `build/validation/WDT0930A01/debug-final.log`. 관련 RouteTimelineDataTests/TimeScaleTests 첫 실행 267 통과·0 실패·0 건너뜀: `map-tests.xcresult`. 최종 소스 재검증도 `map-final.xcresult`에서 267 통과·0 실패·0 건너뜀이다. `map-final-summary.json`에 실제 결과를 보존했다. `git diff --check`도 통과했다.
- 제한: iPhone 18 실기기 장시간 실행/백그라운드 복귀·메모리/충돌 재발 검증은 아직 하지 않았다. 단위 테스트와 빌드만으로 watchdog 해소를 확정하지 않으며 temp.md 항목을 열린 상태로 유지한다. 설치·배포·push는 이번 수정 요청에서 실행하지 않았다.

## INS0930A01 · iPhone 18 수정본 설치 · 2026-09-30
- WDT0930A01 최종 Debug 빌드 산출물을 연결된 iPhone 18 Pro Max에 설치했다. 설치 결과 success, `com.taption.plan` readback은 1.0(163), builtByDeveloper=true이다. TestFlight 새 배포가 아닌 로컬 Debug 설치본이다.
- 앱 실행 결과 success, PID 3505. 삭제/데이터 초기화는 실행하지 않았다. 근거: `build/validation/INS0930A01/install.json`, `apps.json`, `launch.json`.
- 설치/실행만 검증했으며 장시간 background/복귀 시 watchdog 재발 여부와 실제 데이터 동작은 WDT0930A01에서 열린 상태로 유지한다.

## SEQ0930A01 · 미확인 활동 연속 입력 · 2026-09-30
- 대분류 빠른 저장 성공 후 `dismiss()`하던 처리를 제거했다. 다음 시간순 미확인 구간 한 건으로 이동하며 뒤쪽이 없으면 앞쪽 남은 구간부터 이어간다. 확인한 ID는 세션에서 제외하고 마지막 구간 뒤에는 완료 화면을 유지한다. 날짜를 바꾸면 연속 입력 상태를 초기화한다.
- 저장 실패는 현재 구간/오류 메시지를 유지한다. 저장 중에는 버튼/닫기를 잠그고, 아래로 스와이프해서 닫기는 막았다. 기존 시간 상세 편집 전환은 유지한다.
- 다음 구간·시간순 정렬·앞쪽 순환·확정 활동 제외·마지막/빈 목록 테스트를 추가했다. TimeScaleTests 170 통과·0 실패·0 건너뜀: `build/validation/SEQ0930A01/review-tests.xcresult`, `review-summary.json`.
- generic iOS Debug 빌드 성공: `build/validation/SEQ0930A01/debug-build.log`. `git diff --check` 통과.
- 제한: 실제 iPhone에서 연속 탭/저장/마지막 완료 화면은 아직 확인하지 않았다. 이번 변경을 기기에 설치하거나 배포하지 않았다.

## PAN0930A01 · 벡터 지도 드래그 지연 개선 · 2026-09-30
- 코드 경로에서 확인한 부하: MapLibre viewport 60Hz 갱신 → 부모 readback 15Hz → MapHomeView 경로/마커 재구성. unchanged content에서도 viewport를 재발행하여 반복 갱신이 가능했다. 안개는 최대 220개의 개별 Circle+blur+destinationOut 노드였고 발바닥 경로도 overlay body에서 재계산했다. 실기기 지연량/단일 최악 원인은 아직 측정하지 않았다.
- 지도/마커 위치 전달은 기존 60Hz 제한을 유지하고 부모 중심/줌 readback은 이동 종료 시에만 수행한다. 발바닥·장소 입력은 부모 렌더 시 캡처하여 viewport 변경에서 원본 경로를 재샘플링하지 않는다. 안개는 offscreen 포인트를 제외하는 단일 Canvas의 radialGradient+destinationOut으로 변경했다. 가장자리 부드러움은 기존 개별 blur와 정확히 같은 픽셀이 아니므로 기기 화면 확인이 필요하다.
- unchanged route/marker/bounds는 viewport를 재발행하지 않는다. 마커 좌표/ID 및 뷰 크기가 바뀌면 재투영하여 신규 센서/마커 표시가 누락되지 않게 했다. 위치 추적을 멈춘 뒤 compass heading이 카메라를 재중앙화하지 않도록 vector followsHeading을 추적 상태와 함께 검사한다.
- `map_viewport_performance` 로그를 이동 종료 시 집계한다: renderer, sample_count, marker_count, max_projection_ms, max_frame_gap_ms. 좌표·장소 이름·센서 원문은 포함하지 않는다. max_projection_ms는 마커 투영 비용이고 max_frame_gap_ms는 viewport callback 간격이며 전체 터치 지연/실제 GPU fps 측정값은 아니다.
- 240Hz 입력 480회 동안 부모 중간 readback 없음·최종 readback 및 최종 화랑이 위치 즉시 반영 회귀를 검증했다. 첫 관련 테스트 268 통과·0 실패·0 건너뜀 (`map-tests.xcresult`); 최종 마커 보완 소스도 `map-final.xcresult`에서 268 통과·0 실패·0 건너뜀이고 실제 요약은 `map-final-summary.json`에 보존했다. 최종 generic iOS Debug 빌드 성공 (`debug-final.log`), diff 검사 통과.
- 제한: 수정 범위는 기본 벡터 지도 렌더러이며 Apple 지도 UIKit 카메라 readback은 변경하지 않았다. iPhone 18 실제 드래그 체감/안개 대비/장시간 로그는 확인 전이다. 설치·push·배포는 하지 않았다.

## RAIL0930A1 · 지하철 GPS 단절 예상 발자국 · 2026-09-30
- iPhone18 appDataContainer와 App Group 파일 목록에서 앱 센서 DB를 확인하지 못했다. appDataContainer의 sqlite는 HTTP 저장소뿐이고 group 루트에는 Library만 노출됐다. 앱 실행 후 재조회도 동일했다. 파일 조회 증거는 `build/validation/RAIL0930A1/device-sqlite-list.log`, `source-launch.log`. 이 결과만으로 원본이 삭제/없다고 판단하지 않는다.
- iCloud Taption Plan Raw Sensors/2026-09.rawsensorbackup 파일의 수정 시각은 2026-09-05이며 오늘 원본 근거로 사용하지 않았다. 오늘 로우 데이터는 아직 가져오지 못했고 실제 탑승 재현 검증은 미완료다.
- 확인한 소스 결함: 보행 GPS 보간 제한(5분/600m/3m/s)은 철도 구간을 제외하며 GPS 없음 중간 표본이 정상 GPS 양 끝점의 인접 쌍을 끊는다. 지하철 estimated overlay와 이미 생성한 철도 예상 경로는 발바닥 입력에 연결하지 않았다.
- 수정: 보행 제한은 유지하고 신뢰 가능한 양 끝점을 연결하되 Watch/세션 종료 경계는 건너지 않는다. 지하철 estimated overlay 및 cutoff까지 보이는 기존 예상 train/subway 경로를 경로 길이 기준으로 샘플링해 회색 발바닥으로 연결했다. 미래 전체 경로는 사용하지 않는다. 전체 발바닥 220개 상한 내에서 예상 경로에 최대96개의 표시 예산을 예약한다. 저장소/자동 판정/사용자 확정 기록은 변경하지 않는다.
- 신규 회귀: GPS 없음 중간 표본 연결과 종료 경계 차단, 600m를 넘는 굽은 철도 경로가 직선 대신 원래 polyline을 따라 샘플링됨, 유효하지 않은 좌표 거절/빈 경로/샘플 상한. 관련 RouteTimelineDataTests 100 통과·0 실패·0 건너뜀 (`rail-tests.xcresult`, `rail-summary.json`). generic iOS Debug 성공 (`debug-build.log`), diff 검사 통과.
- 제한: 합성 회귀와 빌드 검증이며 오늘 실제 raw/지하철 탑승/기기 화면의 회색 발바닥 표시를 통과 처리하지 않는다. 기기 잠금 해제·앱 실행 상태 확인을 사용자에게 요청했으며 원본 확보 후 해당 구간으로 재검증해야 한다. 이번 변경의 설치/배포는 하지 않았다.

## REXP0930A1 · 오늘 원본 로컬 내보내기와 iPhone18 설치 · 2026-09-30
- 잠금 해제 후 재조회 및 직접 지정한 DB 복사에서 CoreDevice error 11007: App Group 루트 DB가 허용 디렉터리 Library/Documents/tmp 밖이라 접근 제한됨을 확인했다 (`RAIL0930A1/unlocked-db-copy.log`). 원본 부재로 판단하지 않으며 직접 DB 접근을 더 시도하지 않았다.
- 앱의 정상 day snapshot 읽기로 오늘 원본 센서 readings·travel·day·isComplete를 별도 JSON으로 내보내는 `오늘 센서 원본 내보내기` 설정 버튼을 추가했다. temp/TaptionPlanRawExport에 고유 이름·complete file protection으로 기록하고 공유 메뉴를 표시한다. 원본/기존 파일을 삭제하지 않으며 일반 로그·자동 외부 전송에는 포함하지 않는다. JSON 생성은 utility detached 작업에서 수행한다.
- 날짜 경계 필터·원본 유지 테스트를 추가했다. RouteTimelineDataTests 101 통과·0 실패·0 건너뜀 (`build/validation/REXP0930A1/export-tests.xcresult`, `export-summary.json`), generic iOS Debug 성공 (`debug-build.log`), diff 검사 통과.
- 수정본을 iPhone18에 설치하고 앱 실행 success를 확인했다 (`install.json`, `launch.json`). 이 설치본은 WDT0930A01/SEQ0930A01/PAN0930A01/RAIL0930A1/REXP0930A1 변경을 포함한다. App Store/TestFlight 새 배포나 데이터 초기화는 하지 않았다.
- 남음: 사용자가 설정에서 오늘 원본 내보내기를 실행해야 실제 파일을 확보할 수 있다. 확보 후 오늘 지하철 구간 재현·예상 발바닥 결과를 RAIL0930A1에 기록한다. 설치/실행/합성 테스트만으로 실제 raw 검증을 완료 처리하지 않는다.

## BFX0930A01 · iCloud 신규 백업 무결성 오류 방어 · 2026-09-30
- 실제 iCloud 9월 legacy snapshot(version3, hasRawSensorArchive=true)와 raw(version1)의 encryptedPayload SHA256을 payloadDigest와 대조해 둘 모두 일치함을 확인했다. snapshot의 계정 scope도 현재 private scope와 일치했다. 파일을 변경/삭제하지 않았다. PIN/계정 복호키는 읽지 않았으므로 사용자 실패의 정확한 복호 단계는 실제 재시도 로그 전까지 미확정이다. 최신 23:14 로그에는 해당 수동 백업 실행 이벤트가 없었다.
- 재현된 결함: 새 기기의 PIN/계정 키로 기존 raw를 열 수 없으면 monthly generation 저장이 중단된다. snapshot 준비 경로는 이미 별도 새 백업을 허용하는데 raw 경로는 그대로 실패하는 비대칭이다.
- 수정: nonempty 신규 raw가 있는 immutable generation 저장만 이전 복호 불가 raw를 미병합 상태로 보존하고 새 데이터로 별도 암호화 generation을 만든다. legacy 동일 파일 덮어쓰기 경로는 여전히 실패한다. 신규 raw가 없고 기존 committed raw가 있으면 재암호화 실패 시 기존 raw 참조를 유지한다. 계정 불일치/파일 부재/취소/ID 충돌은 계속 오류로 처리한다.
- 재사용한 기존 raw는 새 snapshot commit 실패/삭제 fence 처리에서 삭제하지 않는다. 화면은 현재 데이터 저장 성공과 이전 원본 미병합·원본 보존을 구분해 안내한다. `raw_backup_previous_preserved_unmerged` / `raw_backup_previous_reference_preserved` 단계 로그를 추가했으며 키·PIN·좌표·센서 원문은 기록하지 않는다.
- 회귀: 서로 다른 PIN/복구키에서 snapshot-only 기존 raw 참조 보존 → 새 raw generation 저장 → 새키 복구 성공 및 이전 archive/원본 데이터 불변을 검증했다. 첫 실행은 기존 122 통과·신규1 실패였고, 새 테스트의 GPS 없는 샘플이 raw 아카이브에서 제외돼 원본 archive가 nil인 fixture 오류였다. 유효한 GPS 입력으로 보정했다. 최종 전체 SecurityBackupCoreTests 123 통과·0 실패·0 건너뜀 (`build/validation/BFX0930A01/backup-complete.xcresult`, `backup-complete-summary.json`). 이전 실패 결과는 별도 backup-tests.xcresult에 보존했다.
- 최종 generic iOS Debug 빌드 성공 (`debug-final.log`), diff 검사 통과. iPhone18 설치·실행 success (`install.json`, `launch.json`). 다른 미커밋 변경을 보존하고 push/TestFlight 배포는 하지 않았다.
- 남음: 사용자 실제 계정에서 지금 백업을 다시 실행해 새 generation/iCloud 저장 결과 및 단계 로그를 확인한다. 설치·합성 테스트만으로 실제 iCloud 기능을 완료 처리하지 않는다. 오늘 지하철 raw 검증(RAIL0930A1)은 별도로 계속 대기한다.

## BUI0930A01 · 백업 진행/완료 피드백 · 2026-09-30
- 백업 클릭 즉시 isBackingUp=true, 이전 피드백 제거, 진행 spinner와 버튼 문구 `백업 중입니다` 표시. 백업/복원 중복 입력은 비활성화한다. 저장 성공은 `백업완료`이며 이전 raw 미병합 안내는 아래 별도 문단으로 보존한다. 실패는 실제 오류를 표시하고 defer로 진행 상태를 해제한다.
- 백업 핵심 동작은 변경하지 않았다. 이전 BFX0930A01 전체 123건 통과 근거를 재사용하고 관련 새기기/기존 raw 보존 회귀 1건을 실행해 1 통과·0 실패·0 건너뜀 (`build/validation/BUI0930A01/backup-test.xcresult`, `backup-summary.json`). 최종 generic iOS Debug 성공 (`debug-final.log`), diff 검사 통과.
- 사용자 실제 재시도는 `현재 데이터는 백업했습니다` 성공 안내를 확인했다고 보고했다. iCloud에서 생성 시각 2026-09-30 23:34의 신규 snapshot/raw version4 파일 두 개를 확인했다. encryptedPayload SHA256이 두 payloadDigest와 각각 일치하고 snapshot generationID와 raw generationID가 일치한다. 원본 9월 legacy snapshot/raw 파일도 남아 있다. 이는 BFX0930A01의 실제 신규 iCloud 저장 성공 근거이며 이전 raw를 복호/병합했다고 주장하지 않는다.
- BUI 진행/완료 표시 자체의 실제 화면은 사용자 확인 전이므로 열린 상태로 유지한다. 오늘 raw 재현/회색 발바닥 검증도 별도 대기한다.
- BUI0930A01 수정본 iPhone18 설치·실행 success (`install.json`, `launch.json`). TestFlight 업로드/초기화는 하지 않았다.


## H53A1003B1 · 집 성장 주간 이미지53장 · 건축 양식 v2 (2026-10-03)
- 요청: 주간 이미지53장을 먼저 제작. 최신 지시의 나무→초가집→기와집→주택→정원 주택→빌라→아파트→고층 순서를 반영하고 씨앗 시작·롯데월드타워 끝을 유지했다.
- 산출물: `design/home-seed-to-lotte/H53A1003B1/v2/`. SVG53개·투명 PNG512×512 53개, 전체/48px 검토 시트, manifest/CSV, ZIP. 기존 SVG 시스템을 확장해 편집 가능한 벡터로 제작했으며 앱 자산은 변경하지 않았다. 첫 시안도 보존했다.
- 검증: SVG XML53개 정상, 본문 해시53개 고유, PNG53개 RGBA·512×512·투명 모서리/알파0–255 확인. 48px 인접52쌍 모두 차이 있음(채널차35 초과 픽셀 최소54). 전체 시트와48px 시트를 시각 확인했고 초가/기와 지붕·층수·정원·동 배치 및 타워 형상을 확인했다. 수치 차이는 사용자 체감 검증을 대신하지 않는다.
- 근거: `build/validation/H53A1003B1/v2-assets-validation.json`. 최초 시안 검증 파일은 보존했다.
- 제한: 일별 세부 변화는 manifest의 제작 계획만 있다. 실제365/366개 일별 이미지, 앱 적용, 실기기 화면 검증은 수행하지 않았다. 앱 밖 디자인 산출물만 변경하여 추가 앱 테스트/Debug 빌드는 실행하지 않았다.


## H53C1003A1 · 모닥불·해먹·움막 및 다양한 주거 양식53장 (2026-10-03)
- 결과: 연간53주 틀을 유지하며 자연5단계, 모닥불/해먹/움막/텐트8단계, 초가·한옥6단계, 다양한 단독/정원/연립주택18단계, 빌라·아파트6단계, 고층5단계, 롯데 타워5단계로 재구성했다. A프레임·샬레·수상가옥·고상식·풍차·지중해·튜더·중정·타운하우스 실루엣을 추가했다.
- 산출물: `design/home-seed-to-lotte/H53C1003A1/weekly-53-v3.zip`, SVG53개·투명PNG53개(512×512), 전체/48px 시트, manifest/CSV. 이전 시안과 기존 앱 자산은 보존했다.
- 검증: 전체 시트 시각 확인. SVG XML53개 정상·본문53개 고유, PNG53개 RGBA/512×512/투명 모서리 확인.48px 인접52쌍 모두 렌더 차이 있음(채널 차35 초과 최소54픽셀). 근거 `build/validation/H53C1003A1/assets-validation.json`. 픽셀 차이는 사용자 체감 통과를 의미하지 않는다.
- 제한: 일별 변화는 제작 계획만 존재하며 실제365/366개 일별 자산·앱 적용·실기기 확인은 미수행. 앱 밖 디자인 변경이므로 앱 테스트/Debug 빌드는 추가 실행하지 않았다.


## H53D1003A1 · 추가 건축 양식 v4 (2026-10-03)
- 결과:53주 구성 중 반복 변형20개를 동굴·이글루·흙집·유르트·원형 돌집·마차·마치야·트리하우스·하우스보트·돔·컨테이너·바우하우스·온실·고딕·아르누보·아르데코·브루탈리즘·나선형·계단식 양식 등으로 교체했다. 건축 특징을 단순화한 창작 SVG 아이콘이다.
- 산출물: `design/home-seed-to-lotte/H53D1003A1/weekly-53-v4.zip`. SVG53개·투명PNG512×512 53개, 전체/48px 미리보기, 단계CSV/manifest. 기존 시안·앱 자산 보존.
- 검증: 전체 시트 및 최종48px 시각 확인. SVG XML53개 정상·본문53개 고유, PNG53개 RGBA/512×512/투명 모서리 확인. 인접48px52쌍 모두 차이(채널차35 초과 최소85픽셀). 근거 `build/validation/H53D1003A1/assets-validation.json`. 픽셀 수치는 사용자 체감 검증과 구분한다. git diff --check 성공.
- 제한: 일별 이미지는 계획만 있고365/366개 실제 일별 자산·앱 연결·실기기 확인은 미수행. 앱 밖 디자인 산출물 변경으로 앱 테스트/Debug 빌드 추가 실행 없음.


## H53E1003A1 · 세계 건축 대표 시기순53단계 (2026-10-03)
- 결과:1–7주는 자연·야영 비연대 도입,8–53주는 신석기→고대→중세→근대→현대의 대표 시기순으로 재구성.46개 건축 단계의 sortYear 비감소 확인. 지역·대표시기·날짜 기준을 manifest/chronology/README에 기록했다. 양식 최초 발생순 또는 모든 정확한 연대의 학술 검증을 주장하지 않는다.
- 마지막 롯데타워 반복5단계를 제거하고 빌바오·타이베이101·부르즈 칼리파·상하이타워·롯데월드타워로 교체. 신전·궁전·성곽·박물관 포함 창작 아이콘이며 정밀 역사 재현은 아니다. 비잔틴 도입에 후대 미나레트를 넣지 않고 반돔으로 수정, 일본 목탑/성곽과 고대 신전/신고전주의도 전체 비율·벽체를 구분했다.
- 근거:UNESCO/Met/NPS 및 건축가·운영기관 자료로 주요 대표 양식·시기 확인. 링크와 선택 기준은 산출물README/chronology.csv. 일부 대표 세기는 디자인 편집 기준이다.
- 산출물:`design/home-seed-to-lotte/H53E1003A1/weekly-53-v5.zip`,SVG53·투명PNG512×512 53개, 지역/시기가 붙은 전체/48px 시트,CSV/JSON. 이전시안·기존앱자산 보존.
- 검증:SVG XML53개 정상,SVG53개·디코딩PNG53개·이름53개 모두 고유, 투명 모서리·RGBA/크기 정상.53개 전체1,378쌍을48px에서 비교하여 동일 이미지0쌍,채널차35초과 최소219픽셀. 최종48px 시각 확인. 같은 바닥/화풍과 실제 공통 건축 요소는 유지하며 픽셀 비교가 체감 평가를 대체하지 않는다.근거`build/validation/H53E1003A1/assets-validation.json`.git diff --check 성공.
- 제한:실제365/366개 일별이미지·앱적용·실기기 확인 미수행. 앱밖 디자인 수정으로 앱테스트/Debug빌드 추가실행 없음.


## D3561003A1 · 세계 건축 일별 세부 이미지356장 (2026-10-03)
- 결과: 최신 요청 총356장으로 제작. 이전365/366일과 수량 차이를 선택 질문으로 안내했으며 별도 답변이 없어 최신 명시 수량을 적용했다. 확정53종을 모두 유지해38단계7일+15단계6일로 배분했다. 따라서 모든 단계를7일로 고정하거나365일 전체를 덮는 자산이라고 주장하지 않는다.
- 실제 이미지: `design/home-seed-to-lotte/D3561003A1/daily/`의SVG356개·투명PNG512×512 356개. 씨앗 균열/뿌리, 새싹/수관 성장, 모닥불/해먹/움막 구조, 지역 양식에 맞춘 기단/계단·별채·문루·입면/회랑·마당·현관/차양을 그렸다. 날짜/이름/색만 바꾼 복제나 crossfade를 사용하지 않는다. 건축 원형의 지역/대표시기 순서는H53E1003A1을 재사용하며 세부 증축은 창작 표현이다.
- 배포 파일:PNG전용`daily-356-png.zip`(실제PNG 정확히356개;CSV/JSON/README/오프라인 날짜별index.html 포함), 별도SVG원본`daily-356-svg.zip`(SVG 정확히356개). 전체 단계 비교 시트·48px 시트·7개분할 검토 페이지·표본 시트 제공. 이전 주간 시안 및앱카탈로그 보존.
- 검증:SVG XML356개 정상,SVG356개·디코딩PNG356개·48px이미지356개 각각 고유.1–356일 누락/중복0,단계53개 커버. 전PNG RGBA512×512·투명모서리/알파0–255·캔버스 경계 잘림없음 확인. 인접355쌍을48px premultipliedRGBA로 비교하여 채널차35초과 최소53픽셀(모든쌍50픽셀이상).7개 분할페이지에서 전체53종 일별 변형 시각 확인, 최종 회랑/곡면/캡슐 수정 표본 추가 확인. 숫자 차이는 실제 기기 체감 판정을 대신하지 않는다.
- 제작 중 검수: 초기 가림/작은 변화 및RGBA계산int16범위 문제를 수정했다. first/second/third-pass 기록은 중간 실패/비최종이며 판정 근거는`build/validation/D3561003A1/daily-assets-delivery.json`, `packaging-validation.json`, `delivery-summary.json`이다. 기본Python의PIL미설치로 추가검수1회실패 후 제공된Python런타임에서 재실행 성공. 최종ZIP무결성/포맷수량 확인,뷰어JS구문확인,git diff --check 성공.
- 제한: 현재 산출물 제작 완료이며 앱 연결·기기 설치·실기기화면 기능판정은 수행하지 않았다. 앱밖 디자인/제작도구 변경으로 앱테스트/Debug빌드는 추가실행하지 않았다. 기록된 대표시기/양식은 정밀역사복원 또는 모든기원의연대검증이 아니다.


## D3661003A1 · 366개 수량 정정/날짜 매핑 확인 (2026-10-03)
- 정정: 직전D3561003A1은356개였음을 사용자에게 명확히 알렸고366개 세트를별도생성했다.356개기존세트보존.신규산출물`design/home-seed-to-lotte/D3661003A1/`.
- 날짜:1–52단계각7일(총364일),53단계는365·366일2장.1–366일 연속/누락/중복0,53단계순서유지.마지막2일은롯데타워기준형/현관·마당확장형으로다르다.
- 결과:실제SVG366개·투명PNG512×512 366개.각형식ZIP(`daily-366-png.zip`, `daily-366-svg.zip`)에도해당포맷정확히366개/무결성정상.오프라인뷰어/CSV/JSON도366개로수정했다.
- 검증:SVG XML·디코딩PNG·48px이미지각366개고유,RGBA/크기/투명모서리정상,캔버스경계잘림0.연속365쌍48px premultipliedRGBA차이각50픽셀이상(채널차35초과최소53픽셀).7일로복원된씨앗초기단계2쌍의미세차이를뿌리/새가지/잎으로보강한뒤재검수성공.초기실패는`daily-assets-validation.json`,최종근거는`daily-assets-final.json`·`delivery-summary.json`.첫8단계/마지막5단계시각확인.뷰어JS구문확인·git diff --check 성공.
- 앱현재상태확인:MapHomeGrowthPolicy.artworkName(level:)이기존HomeEvolutionNNN을선택하고기록확인/일마감조건에서season.level을증가한다(`MapHomeView.swift`1558/1687/1769/16684부근).현재새366개이미지연결이나달력날짜자동교체는수행하지않았으며매일앱화면이바뀐다고판정하지않는다.
- 범위/제한:산출물수량·매핑정정및현재동작확인만수행.앱코드/카탈로그미변경으로앱테스트/Debug빌드추가없음.기기설치/실기기검증없음.365개자료를사용하는평년은D001–D365의자산목록이며실제달력선택정책은아직앱미구현이다.


## D3X61003A1 · 3일마다 세계 건축이 바뀌는 366장 (2026-10-03)
- 결과: 366장을 122단계 × 정확히 3일로 다시 구성했다. 자연·야영 10종 뒤 세계 건축 112종을 선택한 대표 시기순으로 배치했다. 피라미드·카르나크·히타이트 성문·페르세폴리스·야흐찰·원형극장·산치·페트라·콜로세움·보로부두르·프람바난·계단우물·스타브 교회·사헬 모스크·알람브라·천단·잉카·트룰리·카스바·포탈라·바람탑·팔레·루마가당·에펠탑·카사 바트요·아인슈타인탑·크라이슬러·낙수장·롱샹·구겐하임·아비타67·퐁피두·루브르·페트로나스·온실·국가체육장·마리나베이·CCTV·샤드·헤이다르·보스코·빈하이 등의 다른 본체를 추가했다. 마지막 D364–D366은 롯데월드타워다.
- 제작: 저장소의 기존 RPG SVG 시스템을 확장했다. 76개 새 주제(자연/야영 포함)와 기존 승인 46개 건축 형태를 사용하고, 본체 성장에 건물별 지붕·첨탑·열주·성문·건물 동·테라스·캡슐·외피·정원을 다르게 그렸다. 색·날짜만 바꾼 복제와 crossfade는 사용하지 않았다. 이전 53단계와 D3561003A1/D3661003A1 시안 및 기존 앱 자산은 보존했다.
- 산출물: `design/home-seed-to-lotte/D3X61003A1/`의 SVG 366개·투명 RGBA PNG 512×512 366개, 122종 전체 128px/48px 미리보기, 전체 일별 11개 분할 페이지를 각각 128px/48px로 제공했다. CSV/manifest는 D001–D366 연속, 단계마다 3개 파일과 실제 일별 변화 설명을 담는다. PNG ZIP에 날짜 슬라이더·단계 선택·3일 비교·전체 미리보기의 오프라인 `index.html`을 포함했다.
- 최종 자산 검증: SVG XML 366개 정상, SVG·디코딩 PNG·48px 이미지 각각 366개 고유. 전 이미지 RGBA/크기/투명 배경 정상, 캔버스 경계 잘림 0. 122개 고유 단계명·각 3일·날짜 누락/중복 0·112개 대표 연도 비감소 확인. 48px premultiplied RGBA(int32), 최대 채널차 35 초과 기준으로 인접 365쌍 모두 최소 54픽셀 차이. 이 중 건물 전환 121쌍은 최소 327픽셀 차이 및 알파 윤곽 최소 158픽셀 차이. 완성형 122종 전체 7,381쌍에 동일 이미지 0쌍. 근거 `build/validation/D3X61003A1/final-assets.json`.
- 시각 검수: 전체 122종 시트와 128px 분할 페이지 11개에서 모든 366장을 확인했고, 최종 48px 페이지 03/05/07/10에서 보강·보정된 원형극장·보로부두르·성문·풍차·온실·현대 건축을 추가 확인했다. 최초 약한 일별 2쌍(41/31픽셀)은 카스바 돌출 성문과 풍차 작업실로 보강했다. 보로부두르의 기단/스투파 연결과 온실·상하이타워 외피 선이 경계를 벗어나는 부분도 보정했다. 최초 `first-pass.json`은 실패한 중간 결과이며 최종 통과 근거와 구분한다. 수치는 실제 기기의 체감 평가를 대신하지 않는다.
- 패키징 검증: `daily-366-three-day-png.zip`(7,326,125바이트)은 PNG 파일 총 366개, `daily-366-three-day-svg.zip`(420,741바이트)은 SVG 파일 총 366개다. 전체 미리보기를 HTML에 포함하여 ZIP의 PNG 수량을 늘리지 않았다. 두 ZIP의 CRC·각 파일 원본 일치·manifest 일치 확인. CSV/HTML 366개 매핑, 모든 이미지 참조, 포함된 전체 SVG 미리보기 정상. 제작 Python 6개 구문 파싱, 뷰어 JS 및 렌더러 JS의 Node 구문 확인, `git diff --check` 성공. 근거 `packaging-final.json`과 `delivery-summary.json`. 이전 `packaging-validation.json`은 미리보기 PNG가 별도 포함된 중간 패키지 결과로 최종 ZIP 해시와 구분한다.
- 연대 자료: UNESCO·CTBUH·건축가/운영기관의 주요 자료와 선택 기준을 `references.md`/README에 남겼다. 크라이슬러는 1930년, 헤이다르는 2012년 개장, 마리나베이는 설계사 자료의 2011년으로 확인·정정했다. 전통 양식은 선정한 대표 시기이며 모든 기원/연대의 학술 검증 또는 정밀 복원이 아니다. 일별 확장은 게임용 창작 표현이고 같은 해의 월·일 순서는 주장하지 않는다.
- 범위/제한: 이번 요청은 이미지 제작과 매핑이며 이 세트를 앱 코드/Assets.xcassets에 연결하거나 기기 설치하지 않았다. 실제 달력 자동 교체·기기 화면 검증은 미수행이다. 앱 동작 코드를 바꾸지 않아 추가 앱 테스트/Debug 빌드는 실행하지 않았다. Watch 실기기 확인 등 다른 미완료 요청은 그대로 남긴다.


## LV3661003A · 새 세계 건축 366장을 앱 레벨에 연결 (2026-10-03)
- 결과: D3X61003A1의 승인된 366개 SVG를 `HomeEvolution001...366`에 정확히 매핑했다. Lv.1–3 씨앗, 4–6 새싹처럼 매 레벨 다른 세부 이미지이고 3레벨마다 주제가 바뀐다. 자연/야영 10종과 세계 건축 112종, 마지막 Lv.364–366 롯데월드타워다. 지도 집·성장 상세·지난 시즌의 기존 `MapHomeGrowthPolicy.artworkName(level:)` 경로가 같은 새 자산을 사용한다.
- 보존: 저장된 레벨·성장 자격/중복 보상 방지·주간 보상·평년 365/윤년 366 상한·연말 보관 정책과 데이터 스키마는 바꾸지 않았다. 자동 달력 일차로 레벨을 덮어쓰지 않는다. 기존 SVG 366개·Contents.json 366개·이전 생성 스크립트는 `build/validation/LV3661003A/original-home-evolution.zip`에 보관했고 CRC 확인했다. 사용자/다른 요청의 기존 변경도 보존했다.
- 구현/매핑: `scripts/home_evolution_artwork_manifest.json`에 레벨/3단계 매핑·원본/앱 자산 SHA-256을 기록했다. 이전 반복형 생성 스크립트의 `--write`/`--check`를 승인된 세트 설치/해시 대조로 갱신하여 과거 그림으로 재생성되지 않게 했다. 전체 366개 자산/고유 본문·122개 주제·연속 레벨 및 Contents 참조/vector representation을 확인했다. 초기 512px 원본 그대로 적용 결과는 `source-mapping.json`, 최종은 `source-mapping-native128.json`이다.
- 자산 크기: 512px 기본 크기는 기기 산출물에서 512/1024/1536px 래스터를 생성해 성장 자산에 49,804,748바이트를 사용했다. 내부 도형/viewBox/벡터 표현을 유지하며 앱 기준 크기를 128pt로 맞췄다. 최종 128/256/384px 래스터와 벡터, 366개 고유 이름/1,464개 rendition이 포함됐다. 성장 자산 SizeOnDisk 합은 9,538,015바이트로 80.85% 감소, 전체 앱 Assets.car는 18,085,720바이트. 설치/전송 압축 크기·실기기 메모리/배터리/시작 속도 개선을 측정한 결과는 아니다.
- 최종 회귀/렌더: MapHomeGrowthPolicyTests 18개 통과·0실패·0건너뜀. 기존 패키징 테스트를 실제 번들 UIImage 366개·128pt 크기·48pt 렌더·중복 검사와 전체 검토 이미지 첨부로 보강했다. 366개 렌더 그림을 시각 확인했고, 최종 렌더 검토 PNG가 512px 초기 적용본과 바이트 단위로 동일함을 확인했다. 흰 배경에서 각 아이콘 영역만 따로 비교해 366개 고유·연속 365쌍 모두 차이(채널차 35 초과 최소 29픽셀), 건물 전환 121쌍 최소 320픽셀. 제작 원본의 투명 RGBA 차이 기준/54픽셀 결과와 다른 배경·렌더 조건으로 구분한다. 실제 지도/기기 체감 판정을 대신하지 않는다.
- 최종 빌드/근거: generic iOS Debug 성공, `assetutil`로 최종 기기용 Assets.car에 HomeEvolution001–366 모두 포함됨을 확인했다. `growth-native128-tests.xcresult`, `growth-native128-tests-summary.json`, `ios-native128-debug-build.log`, `device-native128-asset-info.json`, `integration-native128-summary.json`, `bundled-home-levels-native128-48pt.png`가 최종 근거다. 512px 초기 적용의 테스트 18개/Debug 성공 및 `integration-summary.json`도 중간 기록으로 보존했다. 최종 자산 `--check`, `git diff --check` 성공.
- 범위/제한: 레벨 이미지 반영·관련 검증 완료로 이 요청만 temp에서 제거했다. 이번 수정본의 iPhone11/18 설치·실기기 지도/성장 상세 확인·TestFlight 업로드는 수행하지 않았다. 이전 설치/167 배포 상태와 이번 검증을 합쳐서 완료 처리하지 않는다. 다른 미완료 요청은 남긴다.
