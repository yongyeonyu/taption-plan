#!/usr/bin/env python3
"""Taption Plan 저장소 파이프라인 측정.

`TaptionPlan/Core/TaptionStoreV2.swift`의 실제 스키마·질의 문자열을 그대로 옮겨
합성 데이터로 잰다. 실제 기기 데이터가 아니므로 절대값이 아니라 **같은 조건에서의 차이**만 읽는다.

사용:
  python3 scripts/pipeline-bench.py --rows 525600 --out build/validation/DPL1024A01
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import statistics
import time
import uuid

# TaptionStoreV2.swift `TaptionReadingRowCodec.columns`와 같은 순서·타입.
REAL_COLUMNS = [
    "lat", "lon", "alt", "h_acc", "v_acc", "speed_mps", "speed_acc_mps",
    "course_deg", "course_acc_deg", "rel_alt_m", "pressure_kpa",
    "dm_acc_mean_g", "dm_acc_std_g", "dm_acc_peak_g",
    "dm_rot_mean", "dm_rot_std", "dm_rot_peak",
    "walk_dist_m", "pace_s_per_m", "cadence_hz", "screen_brightness",
    "watch_acc_x", "watch_acc_y", "watch_acc_z", "watch_acc_std", "watch_jerk",
]
TEXT_COLUMNS = [
    "fix_quality", "motion", "motion_conf", "source_device", "tracking_session_id",
    "tracking_kind", "power_state", "behavior", "station_name", "wifi_ssid",
    "behavior_conf", "watch_workout",
]
INT_COLUMNS = [
    "seq", "step_count", "dm_n", "floors_up", "floors_down", "system_floor",
]
BOOL_COLUMNS = [
    "gps_available", "tracking_auto", "session_ended", "nearby_station",
    "matches_rail", "screen_on", "matches_transit", "frequent_stops",
    "ride_hailing", "near_airport", "near_port", "on_water",
]

READING_COLUMNS = ["id", "ts", "day"] + REAL_COLUMNS + TEXT_COLUMNS + INT_COLUMNS + BOOL_COLUMNS + ["extra"]
COLUMN_LIST = ", ".join(READING_COLUMNS)

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS readings (
    id BLOB NOT NULL UNIQUE,
    ts REAL NOT NULL,
    day INTEGER NOT NULL,
    {",".join(f"{c} REAL" for c in REAL_COLUMNS)},
    {",".join(f"{c} TEXT" for c in TEXT_COLUMNS)},
    {",".join(f"{c} INTEGER" for c in INT_COLUMNS)},
    {",".join(f"{c} INTEGER" for c in BOOL_COLUMNS)},
    extra TEXT
);
CREATE INDEX IF NOT EXISTS readings_ts ON readings(ts);
CREATE TABLE IF NOT EXISTS records (
    id TEXT NOT NULL,
    kind TEXT NOT NULL,
    day INTEGER,
    start_ts REAL,
    end_ts REAL,
    updated_ts REAL NOT NULL,
    origin TEXT NOT NULL CHECK (origin IN ('auto', 'user', 'imported')),
    deleted INTEGER NOT NULL DEFAULT 0,
    ord INTEGER NOT NULL DEFAULT 0,
    body TEXT NOT NULL,
    PRIMARY KEY (kind, id)
);
CREATE INDEX IF NOT EXISTS records_kind_start ON records(kind, start_ts);
CREATE TABLE IF NOT EXISTS raw_events (
    kind TEXT NOT NULL,
    id TEXT NOT NULL,
    ts REAL NOT NULL,
    day INTEGER NOT NULL,
    seq INTEGER NOT NULL DEFAULT 0,
    origin TEXT NOT NULL CHECK (origin IN ('auto', 'imported')),
    provenance TEXT NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY (kind, id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS raw_events_kind_ts ON raw_events(kind, ts);
CREATE TABLE IF NOT EXISTS sealed_days (
    day INTEGER PRIMARY KEY,
    sealed_ts REAL NOT NULL,
    fingerprint TEXT,
    payload BLOB NOT NULL
);
"""

PRAGMAS = [
    "PRAGMA auto_vacuum=INCREMENTAL",
    "PRAGMA journal_mode=WAL",
    "PRAGMA secure_delete=ON",
    "PRAGMA synchronous=NORMAL",
    "PRAGMA foreign_keys=ON",
]

# 코드에 있는 질의 문자열 그대로.
Q_DAY_RANGES = "SELECT MIN(ts), MAX(ts) FROM readings GROUP BY day ORDER BY day"
Q_DAY_SLICE = f"SELECT {COLUMN_LIST} FROM readings WHERE ts >= ? AND ts <= ? ORDER BY ts, seq, id"
Q_ALL_READINGS = f"SELECT {COLUMN_LIST} FROM readings ORDER BY ts, seq, id"
Q_PAGE_COUNT = "SELECT COUNT(*), COALESCE(MAX(rowid), 0) FROM readings WHERE ts >= ? AND ts < ?"
Q_BACKUP_DAYS = (
    "SELECT DISTINCT CAST(v / 86400.0 AS INTEGER) AS d FROM ("
    " SELECT ts AS v FROM readings UNION ALL SELECT start_ts FROM records WHERE start_ts IS NOT NULL)"
)
Q_RECORDS_BY_KIND = (
    "SELECT id, kind, start_ts, end_ts, updated_ts, origin, deleted, ord, body"
    " FROM records WHERE kind = ? ORDER BY ord, id"
)
Q_HOT_COLUMNS = (
    "SELECT lat, lon, speed_mps, motion, behavior, h_acc FROM readings"
    " WHERE ts >= ? AND ts <= ? ORDER BY ts, seq, id"
)

SECONDS_PER_DAY = 86400


def open_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def create_schema(path: str) -> None:
    conn = sqlite3.connect(path)
    for pragma in PRAGMAS:
        conn.execute(pragma)
    conn.executescript(SCHEMA)
    conn.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1')")
    conn.commit()
    conn.close()


def synthesize(rows: int, start_ts: float):
    """1분 간격 위치 fix. 실제 수집 간격(GPSLoggingPreferences 1분)과 같게 둔다."""
    interval = 60.0
    rng = random.Random(1024)
    for i in range(rows):
        ts = start_ts + i * interval
        day = int(ts // SECONDS_PER_DAY)
        moving = 0.35 < ((i % 1440) / 1440.0) < 0.75
        values = [
            uuid.uuid4().bytes,
            ts,
            day,
            37.5 + rng.random() * 0.02,
            127.0 + rng.random() * 0.02,
            12.0,
            8.0,
            8.0,
            (9.0 if moving else 0.4),
            0.5,
            (2.5 if moving else 0.0),
            0.0,
            "gps",
            ("walking" if moving else "stationary"),
            "high",
            "iphone",
            (f"session-{day}" if moving else ""),
            ("walk" if moving else ""),
            "unplugged",
            ("walking" if moving else "stationary"),
            "",
            "",
            "medium",
            "",
        ]
        values += [rng.random() for _ in range(17)]  # rel_alt·압력·dm_*·걷기·watch_*
        values += [0 for _ in range(6)]  # seq·걸음·dm_n·층·층·시스템층
        values += [1 if moving else 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        values += [None]  # extra
        yield values


def bench_ingest(path: str, rows: int, start_ts: float) -> dict:
    """`insertNewReadings`와 같은 방식: 한 트랜잭션 + 준비된 문 + OR IGNORE."""
    conn = open_db(path)
    placeholders = ", ".join("?" for _ in READING_COLUMNS)
    sql = f"INSERT OR IGNORE INTO readings ({COLUMN_LIST}) VALUES ({placeholders})"
    started = time.perf_counter()
    conn.execute("BEGIN IMMEDIATE")
    conn.executemany(sql, synthesize(rows, start_ts))
    conn.execute("COMMIT")
    elapsed = time.perf_counter() - started
    count = conn.execute("SELECT COUNT(*) FROM readings").fetchone()[0]
    conn.close()
    return {"rows": count, "seconds": round(elapsed, 3), "rows_per_second": round(count / elapsed)}


def time_query(conn, sql, params=(), repeats: int = 5) -> dict:
    """준비·실행·소비를 모두 포함한 중앙값. 첫 실행은 캐시 워밍으로 버린다."""
    conn.execute(sql, params).fetchall()
    samples = []
    row_count = 0
    for _ in range(repeats):
        started = time.perf_counter()
        rows = conn.execute(sql, params).fetchall()
        samples.append((time.perf_counter() - started) * 1000.0)
        row_count = len(rows)
    return {
        "median_ms": round(statistics.median(samples), 2),
        "min_ms": round(min(samples), 2),
        "max_ms": round(max(samples), 2),
        "rows": row_count,
    }


def plan(conn, sql, params=()) -> list[str]:
    return [row[3] for row in conn.execute("EXPLAIN QUERY PLAN " + sql, params).fetchall()]


def file_bytes(path: str) -> dict:
    total = 0
    for suffix in ("", "-wal"):
        try:
            total += os.path.getsize(path + suffix)
        except OSError:
            pass
    return {"bytes": total, "megabytes": round(total / 1_048_576, 1)}


def measure(path: str, rows: int, start_ts: float, label: str) -> dict:
    conn = open_db(path)
    mid = start_ts + (rows // 2) * 60.0
    day_start, day_end = mid, mid + SECONDS_PER_DAY
    result = {"label": label, "size": file_bytes(path)}
    result["page_count"] = conn.execute("PRAGMA page_count").fetchone()[0]
    result["page_size"] = conn.execute("PRAGMA page_size").fetchone()[0]
    result["bytes_per_row"] = round(result["size"]["bytes"] / max(rows, 1), 1)
    result["queries"] = {
        "day_ranges (백업 날짜 범위)": time_query(conn, Q_DAY_RANGES),
        "day_slice (하루 60열)": time_query(conn, Q_DAY_SLICE, (day_start, day_end)),
        "day_slice_hot (하루 6열)": time_query(conn, Q_HOT_COLUMNS, (day_start, day_end)),
        "all_readings (전체 60열)": time_query(conn, Q_ALL_READINGS, repeats=3),
        "page_count (구간 행 수)": time_query(conn, Q_PAGE_COUNT, (day_start, day_end)),
        "backup_days (백업 날짜 목록)": time_query(conn, Q_BACKUP_DAYS, repeats=3),
        "records_by_kind": time_query(conn, Q_RECORDS_BY_KIND, ("plan",)),
    }
    result["plans"] = {
        "day_ranges": plan(conn, Q_DAY_RANGES),
        "day_slice": plan(conn, Q_DAY_SLICE, (day_start, day_end)),
        "day_slice_hot": plan(conn, Q_HOT_COLUMNS, (day_start, day_end)),
        "backup_days": plan(conn, Q_BACKUP_DAYS),
    }
    conn.close()
    return result


def apply_candidate_index(path: str, name: str, ddl: str) -> dict:
    conn = open_db(path)
    before = file_bytes(path)
    started = time.perf_counter()
    conn.execute(ddl)
    conn.commit()
    build_seconds = time.perf_counter() - started
    conn.execute("ANALYZE")
    conn.commit()
    after = file_bytes(path)
    conn.close()
    return {
        "index": name,
        "ddl": ddl,
        "build_seconds": round(build_seconds, 2),
        "size_delta_megabytes": round(after["megabytes"] - before["megabytes"], 1),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=525_600, help="1년치 1분 간격(525600)")
    parser.add_argument("--out", default="build/validation/DPL1024A01")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    start_ts = 1_767_225_600.0  # 2026-01-01 00:00 UTC 근처. 날짜 경계만 필요하다.
    base_path = os.path.join(args.out, "baseline.sqlite")
    tuned_path = os.path.join(args.out, "tuned.sqlite")
    for p in (base_path, tuned_path):
        for suffix in ("", "-wal", "-shm"):
            try:
                os.remove(p + suffix)
            except OSError:
                pass

    create_schema(base_path)
    ingest = bench_ingest(base_path, args.rows, start_ts)
    baseline = measure(base_path, ingest["rows"], start_ts, "기준선 (readings_ts만)")

    # 후보 색인. 코드의 질의 모양에서 직접 유도했다.
    import shutil
    shutil.copyfile(base_path, tuned_path)
    candidates = [
        ("readings_day_ts", "CREATE INDEX IF NOT EXISTS readings_day_ts ON readings(day, ts)"),
        ("readings_ts_seq_id", "CREATE INDEX IF NOT EXISTS readings_ts_seq_id ON readings(ts, seq, id)"),
        ("readings_hot_cover", "CREATE INDEX IF NOT EXISTS readings_hot_cover ON readings(ts, lat, lon, speed_mps, motion, behavior, h_acc)"),
    ]
    index_costs = [apply_candidate_index(tuned_path, name, ddl) for name, ddl in candidates]
    tuned = measure(tuned_path, ingest["rows"], start_ts, "후보 색인 적용")

    report = {
        "rows": ingest["rows"],
        "ingest": ingest,
        "baseline": baseline,
        "tuned": tuned,
        "index_costs": index_costs,
    }
    with open(os.path.join(args.out, "pipeline-bench.json"), "w") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)

    lines = [
        f"# 파이프라인 측정 — {ingest['rows']:,}행 (1분 간격 위치 fix)",
        "",
        "합성 데이터다. 절대값이 아니라 같은 조건에서의 차이를 읽는다.",
        "",
        f"- 적재: {ingest['rows']:,}행 / {ingest['seconds']}초 = **{ingest['rows_per_second']:,}행/초**",
        f"- 파일: 기준선 {baseline['size']['megabytes']}MB, 행당 **{baseline['bytes_per_row']}바이트**",
        f"- 페이지: {baseline['page_count']:,} × {baseline['page_size']}바이트",
        "",
        "| 질의 | 기준선 (ms) | 색인 후 (ms) | 배율 | 행 |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for key, base in baseline["queries"].items():
        tuned_value = tuned["queries"][key]["median_ms"]
        ratio = base["median_ms"] / tuned_value if tuned_value else 0
        lines.append(
            f"| {key} | {base['median_ms']} | {tuned_value} | {ratio:.2f}× | {base['rows']:,} |"
        )
    lines += ["", "## 질의 계획 (기준선)", ""]
    for key, value in baseline["plans"].items():
        lines.append(f"- `{key}`")
        for step in value:
            lines.append(f"  - {step}")
    lines += ["", "## 색인 비용", "", "| 색인 | 만드는 시간 | 파일 증가 |", "| --- | ---: | ---: |"]
    for cost in index_costs:
        lines.append(f"| `{cost['index']}` | {cost['build_seconds']}초 | +{cost['size_delta_megabytes']}MB |")

    with open(os.path.join(args.out, "pipeline-bench.md"), "w") as handle:
        handle.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
