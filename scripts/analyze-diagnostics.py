#!/usr/bin/env python3
"""Taption Plan 진단 로그(TaptionLogs-*.txt.gz 또는 .txt)를 표로 요약한다.

사용:
  python3 scripts/analyze-diagnostics.py <로그 파일>            # 요약 보고서
  python3 scripts/analyze-diagnostics.py <로그 파일> --csv out.csv   # 이벤트 전체를 CSV로
  python3 scripts/analyze-diagnostics.py <로그 파일> --event largest_jump_m  # 필드 값이 있는 이벤트만

로그 스키마 2: 한 줄에 JSON 객체 하나(schema, session_id, seq, timestamp, build, level, event, fields, metrics).
"""
import argparse
import collections
import csv
import gzip
import json
import sys
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))


def read_log(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as handle:
        text = handle.read()
    header, events = {}, []
    section = None
    for line in text.splitlines():
        if line.startswith("## "):
            section = line[3:].strip()
            continue
        if section == "environment" and ": " in line:
            key, value = line.split(": ", 1)
            header[key] = value
        elif section == "iphone_log" and line.startswith("{"):
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
    return header, events


def local(timestamp):
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone(KST)


def print_launch(events):
    """마지막 실행의 시작 단계별 시간과, 그때 저장소를 몇 행 읽었는지 보여준다.

    "시작이 느리다"는 말은 어느 단계가 마지막까지 남는지를 봐야 고칠 수 있다.
    `launch_gate`는 단계가 열린 순서대로 남으므로 마지막 줄이 곧 병목이다.
    """
    starts = [i for i, e in enumerate(events) if e["event"] == "initial_launch_started"]
    if not starts:
        print("  (없음)")
        return
    gates = []
    total = None
    for event in events[starts[-1]:]:
        if event["event"] == "launch_gate":
            gates.append((event.get("fields", {}).get("gate", "?"),
                          int(event.get("fields", {}).get("elapsed_ms", 0))))
        elif event["event"] == "initial_launch_ready":
            total = int(event.get("fields", {}).get("duration_ms", 0))
            break
    if not gates:
        print("  (없음)")
        return
    for name, elapsed in gates:
        print(f"  {name:24s} {elapsed:6d}ms")
    if total is not None:
        print(f"  {'합계':24s} {total:6d}ms")
    loads = [e for e in events if e["event"] == "repository_local_load"]
    if loads:
        m, f = loads[-1].get("metrics", {}), loads[-1].get("fields", {})
        print(f"  저장소 {m.get('rows', '?')}행 읽기 {m.get('read_ms', 0):.1f}ms "
              f"해독 {m.get('decode_ms', 0):.1f}ms 합 {m.get('total_ms', 0):.1f}ms — {f.get('kinds', '')}")

    # 그 실행에서 적재·준비가 얼마나 걸렸고, 준비가 몇 번 돌았는지.
    # 배경 갱신과 겹치면 같은 준비가 여러 번 돌거나 몇 배로 느려진다(2026-10-28).
    session = events[starts[-1]].get("session_id")
    items = [e for e in events if e.get("session_id") == session]
    finished = {e.get("fields", {}).get("operation_id"): e for e in items
                if e["event"] == "operation_finished"}
    for event in items:
        if event["event"] != "operation_started":
            continue
        name = event.get("fields", {}).get("operation")
        if name not in ("bootstrap_local_snapshot", "bootstrap_preparation",
                        "background_refresh"):
            continue
        done = finished.get(event.get("fields", {}).get("operation_id"))
        fields = done.get("fields", {}) if done else {}
        print(f"  {name:24s} {fields.get('duration_ms', '미완료'):>9}ms {fields.get('outcome', '')}")
    passes = sum(1 for e in items if e["event"] == "bootstrap_preparation_pass")
    print(f"  {'준비 반복':24s} {passes:9d}회")


def report(header, events):
    print(f"이벤트 {len(events)}개, 빌드 {sorted({e.get('build') for e in events})}, "
          f"스키마 {sorted({e.get('schema', 1) for e in events})}")
    if events:
        print(f"기간(KST) {local(events[0]['timestamp']):%m-%d %H:%M:%S} ~ {local(events[-1]['timestamp']):%m-%d %H:%M:%S}")
    sessions = collections.OrderedDict()
    for event in events:
        sessions.setdefault(event.get("session_id", "(없음)"), []).append(event)
    print(f"\n세션 {len(sessions)}개")
    for session, items in sessions.items():
        print(f"  {session}: {len(items)}건 {local(items[0]['timestamp']):%H:%M:%S}~{local(items[-1]['timestamp']):%H:%M:%S}")

    print("\n이벤트 종류별 개수(억제된 반복 포함)")
    counts, suppressed = collections.Counter(), collections.Counter()
    for event in events:
        counts[event["event"]] += 1
        suppressed[event["event"]] += int(event.get("fields", {}).get("suppressed_since_last", 0))
    for name, count in counts.most_common(15):
        extra = f" (+억제 {suppressed[name]})" if suppressed[name] else ""
        print(f"  {name:45s} {count:5d}{extra}")

    print("\n시작(launch) — 마지막 실행의 게이트 순서")
    print_launch(events)
    yielded = sum(1 for e in events if e["event"] == "background_refresh_yielded")
    print(f"  배경 갱신이 화면에 자리를 내준 횟수 {yielded}회")

    print("\n튄 위치(map_route_readings_prepared의 largest_jump_*) — 큰 순서")
    jumps = [e for e in events if e["event"] == "map_route_readings_prepared" and "largest_jump_m" in e.get("fields", {})]
    jumps.sort(key=lambda e: int(e["fields"]["largest_jump_m"]), reverse=True)
    for event in jumps[:5]:
        f = event["fields"]
        print(f"  {local(event['timestamp']):%H:%M:%S} 거리 {int(f['largest_jump_m'])/1000:.1f}km 간격 {f['largest_jump_gap_s']}s "
              f"속도 {f['largest_jump_speed_mps']}m/s 점시각 {f['largest_jump_at']} 품질 {f['largest_jump_quality']} "
              f"출처 {f['largest_jump_device']} 정확도 {f['largest_jump_accuracy_m']}m")
    if not jumps:
        print("  (없음)")

    print("\n가장 긴 예상 경로(expected_route_projection_built의 longest_route_*)")
    routes = [e for e in events if e["event"] == "expected_route_projection_built" and "longest_route_km" in e.get("fields", {})]
    seen = set()
    for event in sorted(routes, key=lambda e: int(e["fields"]["longest_route_km"]), reverse=True):
        f = event["fields"]
        key = (f["longest_route_kind"], f["longest_route_mode"], f["longest_route_km"], f["longest_route_start"])
        if key in seen:
            continue
        seen.add(key)
        print(f"  {f['longest_route_km']}km {f['longest_route_kind']}/{f['longest_route_mode']} "
              f"{f['longest_route_start']}~{f['longest_route_end']} ({f['longest_route_minutes']}분)")
        if len(seen) >= 5:
            break
    if not routes:
        print("  (없음)")

    print("\n정지 판정(location_gate_summary) — 합계")
    gates = [e.get("metrics", {}) for e in events if e["event"] == "location_gate_summary"]
    if gates:
        accepted = sum(g.get("accepted", 0) for g in gates)
        ignored = sum(g.get("ignored_still", 0) for g in gates)
        total = accepted + ignored
        print(f"  반영 {accepted:.0f} / 무시 {ignored:.0f} (무시 비율 {ignored / total:.0%}), 요약 {len(gates)}회")
    else:
        print("  (없음)")

    print("\n재생 확대·축소(playback_zoom_sample)")
    zooms = [e.get("metrics", {}) for e in events if e["event"] == "playback_zoom_sample"]
    if zooms:
        speeds = [z["speed_mps"] for z in zooms if z.get("speed_mps", -1) >= 0]
        print(f"  표본 {len(zooms)}개, 속도 {min(speeds, default=0):.1f}~{max(speeds, default=0):.1f}m/s, "
              f"목표 거리 {min(z['target_m'] for z in zooms):.0f}~{max(z['target_m'] for z in zooms):.0f}m")
    else:
        print("  (없음)")

    print("\n시간선 창(timeline_window) — 확대·손잡이·「현재 위치」")
    timeline = [e for e in events if e["event"] == "timeline_window"]
    if timeline:
        for event in timeline:
            m, f = event.get("metrics", {}), event.get("fields", {})
            ratio = m.get("handle_ratio", -1)
            ratio_text = "없음" if ratio < 0 else f"{ratio:.3f}"
            print(f"  {local(event['timestamp']):%H:%M:%S} {f.get('source', '?'):14s} "
                  f"창 {f.get('window', '?'):>10s} ({m.get('duration_minutes', 0):.0f}분) "
                  f"선택 {f.get('selected', '?'):>5s} 손잡이 {ratio_text}")
    else:
        print("  (없음)")

    print("\n사용자 동작")
    for name in ("sidebar_double_tap", "section_edit_open_requested", "map_style_changed"):
        print(f"  {name}: {counts.get(name, 0)}")

    print("\n환경 요약(앞 12개)")
    for key in list(header)[:12]:
        print(f"  {key}: {header[key]}")


def export_csv(events, path):
    keys = sorted({k for e in events for k in e.get("fields", {})} | {f"m.{k}" for e in events for k in e.get("metrics", {})})
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["time_kst", "session_id", "seq", "build", "level", "event"] + keys)
        for e in events:
            row = [local(e["timestamp"]).isoformat(), e.get("session_id", ""), e.get("seq", ""), e.get("build", ""),
                   e.get("level", ""), e["event"]]
            fields, metrics = e.get("fields", {}), e.get("metrics", {})
            for key in keys:
                row.append(metrics.get(key[2:], "") if key.startswith("m.") else fields.get(key, ""))
            writer.writerow(row)
    print(f"{len(events)}행을 {path}에 썼습니다.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--csv")
    parser.add_argument("--event", help="이 필드(또는 이벤트 이름)를 가진 기록만 JSON으로 출력")
    args = parser.parse_args()
    header, events = read_log(args.file)
    if args.csv:
        export_csv(events, args.csv)
    elif args.event:
        for e in events:
            if e["event"] == args.event or args.event in e.get("fields", {}) or args.event in e.get("metrics", {}):
                print(json.dumps(e, ensure_ascii=False))
    else:
        report(header, events)


if __name__ == "__main__":
    sys.exit(main())
