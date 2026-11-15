# 성능 측정·개선 계획 (PRF1116A01)

대표 지시(2026-11-16): 「성능관점에서 최적화 진행하자. 아이폰 11로 성능 테스트 및 벤치마킹 진행.」

앱이 느린 곳을 아이폰 11 Pro에서 수치로 재고, 영향이 큰 것부터 고치고, 전후를 같은 방법으로 다시 잰다. 동작·화면 모습·저장 형식·백업 형식은 바꾸지 않는다. 구조 쪽 이전 수치는 `docs/STRUCTURE_PERFORMANCE.md`, 저장소 쪽은 `docs/DATA_PIPELINE.md`에 있다.

## 측정 조건

| 항목 | 값 |
| --- | --- |
| 기기 | 아이폰 11 Pro(60Hz 화면), USB 연결, 대표의 실제 기록이 들어 있는 상태 그대로 |
| 판 | Release(최적화 켬, whole-module) + `-D BENCH`(측정 훅만 켬), 개발 서명, `xcrun devicectl`로 설치·실행 |
| 실행 | `devicectl device process launch --console --terminate-existing com.taption.plan -- <인자>` — 앱이 찍는 `PRFBENCH` 줄(숫자만)을 받는다 |
| 횟수 | 항목마다 3회 이상. 가운데 값과 범위(최소~최대)를 적는다 |
| 개인 정보 | 기록 내용·좌표·장소 이름은 로그·문서에 남기지 않는다. 행 수와 시간만 남긴다 |
| 섞지 않는 것 | 시뮬레이터·Debug 수치는 기기·Release 수치와 같은 표에 넣지 않는다 |

측정 도구: `MapHomePerfBench`(`TaptionPlan/UI/MapHomeInteractionMonitor.swift`, `#if DEBUG || BENCH`). 화면 틱 간격은 기존 `MapHomeInteractionMonitor`(표시 링크, 측정 중에만 돎)로, CPU는 스레드·프로세스 CPU 시계로, 메모리는 `task_vm_info`의 `phys_footprint`와 최고치로 잰다. 받는 스크립트는 `scripts/perf-bench.sh`.

XCTest 성능 지표(`XCTApplicationLaunchMetric` 등)와 `xctrace`는 쓰지 않았다. 앱에 이미 손짓별 틱 계측과 자동 실행 훅이 있어 같은 수단으로 이전 기록(`LGS1115A01`, `PRF1030A02`)과 이어 볼 수 있고, 화면 시험 실행기를 기기에 따로 올리지 않아도 되기 때문이다. 함수별 원인을 볼 때만 `xctrace`(Time Profiler)를 쓴다.

## 잴 항목과 합격선

60Hz 화면이라 한 프레임은 16.7ms다. 「끊긴 프레임」은 틱 간격이 20ms를 넘은 것(한 프레임 이상 놓침), 「크게 끊긴 프레임」은 40ms를 넘은 것이다.

| # | 항목 | 방법 (`PRFBENCH` 이름) | 합격선(가운데 값) |
| --- | --- | --- | --- |
| 1 | 콜드 실행 → 홈 첫 화면 | 프로세스 시작 시각(`sysctl`)부터 홈이 「준비됨」을 알릴 때까지(`launch ready_ms`), 오늘 하루 자료가 다 읽힐 때까지(`launch day_loaded_ms`). 실행마다 앱을 끝내고 다시 띄운다 | 준비 3,000ms 이하 |
| 2 | 대기 상태 CPU | 첫 화면 뒤 25초 기다린 다음 10초씩 3번, 손대지 않고 프로세스 전체·메인 스레드 CPU 시간(`idle`) | 전체 CPU 10초에 1,500ms(15%) 이하 |
| 3 | 날짜 바꾸기 | 어제·그제·그끄제를 차례로 고르고(처음), 같은 세 날을 다시 고른다(다시). 고른 순간부터 그날 자료가 「읽음」이 될 때까지(`date_cold`·`date_warm`의 `loaded_ms`), 4초 동안 메인 CPU, 3초 동안 틱 간격(`bench_date_*`) | 처음 1,000ms, 다시 300ms 이하. 크게 끊긴 프레임 3 이하 |
| 4 | 시간 끌기 | 어제를 고른 채 화면 틱마다 고른 분을 옮긴다(3초에 하루 왕복, 6초씩 3번, `bench_scrub`). 사이드바의 손짓 판정은 거치지 않고 그 뒤 화면 갱신만 잰다 | 6초에 342프레임(95%) 이상, 크게 끊긴 프레임 0 |
| 5 | 지도 끌기 | 기존 `-autoBenchMapPan`(프레임마다 지도를 좌우로 밀기, 12초씩 3번, `bench_pan`). 기기에 저장된 지도 스타일 그대로 | 12초에 648프레임(90%) 이상, 크게 끊긴 프레임 2 이하 |
| 6 | 가계부·여행 화면 열기 | 화면을 4번씩 여닫는다. 연 순간부터 첫 틱까지(`first_ms`), 1.5초 동안 최대 틱 간격·메인 CPU(`bench_open_ledger_*`, `bench_open_travel_*`). 처음(cold)과 다시(warm)를 나눈다 | 다시 열기: 최대 간격 50ms 이하, 끊긴 프레임 3 이하 |
| 7 | 하루 재생 | 기존 `-autoStartDayPlayback -autoPlaybackYesterday`(`playback_frame_stats`: 틱 수, 20ms 넘는 틱, 최대) | 20ms 넘는 틱 5% 이하 |
| 8 | 메모리 | 위 순서를 다 돈 뒤 `phys_footprint`와 최고치(`memory`) | 최고치 500MB 이하 |
| 9 | 기록이 많은 날의 시간표 계산 | 3번의 날짜별 행 수(`rows`)와 `main_cpu_4s_ms`. 행 수가 가장 많은 날을 본다 | 4초 동안 메인 CPU 1,200ms 이하 |

못 재는 것: 손가락 핀치 줌(자동 줌 훅이 Apple 지도 집 근처 단계 축소뿐이라 일반 줌은 재지 않음), 사이드바 손짓 판정 자체, 120Hz 동작(이 기기는 60Hz), 이동 중 GPS가 들어오는 상태.

## 순서

1. 기준값: 지금 HEAD + 측정 훅만 넣은 판을 설치해 3회 이상 잰다(`build/validation/PRF1116A01/baseline/`).
2. 분석: 합격선을 넘은 항목마다 원인을 코드와 표본(Time Profiler)으로 찾는다. 추측은 추측이라고 적는다.
3. 고치기: 영향이 큰 것부터 하나씩. 고칠 때마다 관련 단위 시험·Debug 빌드·그 항목 재측정. 좋아지지 않으면 되돌린다. 한 변경 = 한 커밋.
4. 보고: 아래 표와 `test.md`.

## 기준값 (아이폰 11 Pro, Release + BENCH)

(측정 뒤 채움)

## 분석

(측정 뒤 채움)

## 전후

(고친 뒤 채움)

## 되돌린 시도 · 남은 느린 곳

(끝에 채움)
