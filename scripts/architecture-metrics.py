#!/usr/bin/env python3
"""구조 지표를 재는 읽기 전용 도구.

리팩터링은 "느낌"이 아니라 숫자로 확인한다. 이 스크립트는 제품 소스(테스트 제외)만
훑어서 파일·타입 크기와 위험 표시를 세고, 기준선(baseline)과 비교한다.

    python3 scripts/architecture-metrics.py                 # 사람이 읽는 요약
    python3 scripts/architecture-metrics.py --json          # 기계가 읽는 전체
    python3 scripts/architecture-metrics.py --progress      # 목표치까지의 거리
    python3 scripts/architecture-metrics.py --write-baseline docs/architecture-baseline.json
    python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json

`--check`는 지표가 기준선보다 나빠지면 1로 끝난다. CI에서 쓰라고 만든 것이다.
`--progress`는 TARGETS까지 얼마나 남았는지 보여준다. 판정에는 쓰지 않는다.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOTS = [
    "TaptionPlan",
    "TaptionPlanWidget",
    "TaptionPlanWatch",
    "TaptionPlanWatchWidget",
    "Packages",
]
SKIP = ("/Tests/", "/.build/", "/DerivedData/", "/.git/")

# 나빠지면 안 되는 것들. 늘어나면 실패한다. 전부 "Swift 6 모드에서 사람이 손으로
# 연 안전장치"이거나 "프로세스를 죽이는 코드"라서, 늘어나는 것 자체가 퇴행이다.
RISK_PATTERNS = {
    "unchecked_sendable": r"@unchecked\s+Sendable",
    "nonisolated_unsafe": r"nonisolated\(unsafe\)",
    "detached_tasks": r"Task\.detached",
    "force_try": r"\btry!",
    "fatal_error": r"\bfatalError\(",
    "main_queue": r"DispatchQueue\.main",
}

# 크기만 세는 것들. 참고용이라 실패 조건에 넣지 않는다.
# (`.shared`는 URLSession·UIApplication 같은 애플 API라 결함 지표가 아니다.)
SIZE_PATTERNS = {
    "state_properties": r"@State\b",
    "observable_types": r"@Observable\b",
    "view_types": r":\s*View\b",
    "funcs": r"\bfunc\s+\w+",
    "singleton_reach": r"\.shared\b",
}

# 목표치. `--progress`가 여기까지의 거리를 보여준다. 통과/실패 판정에는 쓰지 않는다
# (목표는 아직 멀고, 게이트는 "지금보다 나빠지지 않기"만 본다).
TARGETS = {
    "largest_file_lines": 1_200,
    "largest_type_lines": 1_500,
    "unchecked_sendable": 0,
    "nonisolated_unsafe": 0,
    "detached_tasks": 0,
    "fatal_error": 0,
    "main_queue": 0,
}

# 한 파일이 이 줄 수를 넘으면 게이트가 실패한다. 이미 넘은 파일은 동결 대상으로
# baseline에 기록되고, 그 파일만은 "줄이지 않으면 안 되고 늘리면 안 된다".
FILE_BUDGET = 1_200

TYPE_RE = re.compile(
    r"^(?P<indent>[ \t]*)"
    r"(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|private\s+|fileprivate\s+|internal\s+|final\s+|@MainActor\s+)*"
    r"(?P<kind>struct|class|enum|extension|actor|protocol)\s+"
    r"(?P<name>[\w.<>]+)"
)


def product_files() -> list[str]:
    found: list[str] = []
    for root in ROOTS:
        if not os.path.isdir(root):
            continue
        for base, dirs, names in os.walk(root):
            path = base + "/"
            if any(skip.strip("/") in path for skip in SKIP):
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if d not in {".build", "DerivedData", ".git"}]
            for name in names:
                if name.endswith(".swift"):
                    found.append(os.path.join(base, name))
    return sorted(found)


def type_sizes(lines: list[str]) -> list[tuple[int, str, str]]:
    """(줄 수, 종류, 이름). 괄호 짝으로 최상위 선언의 끝을 찾는다."""
    sizes: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        match = TYPE_RE.match(line)
        if not match or len(match.group("indent").expandtabs(4)) > 4:
            continue
        depth = 0
        opened = False
        end = index
        for cursor in range(index, len(lines)):
            depth += lines[cursor].count("{") - lines[cursor].count("}")
            if "{" in lines[cursor]:
                opened = True
            if opened and depth <= 0:
                end = cursor
                break
        sizes.append((end - index + 1, match.group("kind"), match.group("name")))
    return sorted(sizes, reverse=True)


def collect() -> dict:
    files = []
    risk = {key: 0 for key in RISK_PATTERNS}
    size = {key: 0 for key in SIZE_PATTERNS}
    for path in product_files():
        source = open(path, encoding="utf-8", errors="ignore").read()
        lines = source.splitlines()
        entry = {
            "path": path,
            "lines": len(lines),
            "largest_type": None,
            "largest_type_lines": 0,
            "types": 0,
        }
        sizes = type_sizes(lines)
        if sizes:
            biggest = sizes[0]
            entry["largest_type"] = f"{biggest[1]} {biggest[2]}"
            entry["largest_type_lines"] = biggest[0]
            entry["types"] = len(sizes)
        for key, pattern in RISK_PATTERNS.items():
            risk[key] += len(re.findall(pattern, source))
        for key, pattern in SIZE_PATTERNS.items():
            size[key] += len(re.findall(pattern, source))
        files.append(entry)

    total = sum(f["lines"] for f in files)
    buckets = {"<500": 0, "500-1000": 0, "1000-2000": 0, "2000-5000": 0, "5000+": 0}
    for f in files:
        n = f["lines"]
        if n < 500:
            buckets["<500"] += 1
        elif n < 1_000:
            buckets["500-1000"] += 1
        elif n < 2_000:
            buckets["1000-2000"] += 1
        elif n < 5_000:
            buckets["2000-5000"] += 1
        else:
            buckets["5000+"] += 1

    return {
        "files": len(files),
        "lines": total,
        "buckets": buckets,
        "risk": risk,
        "size": size,
        "metrics": {
            "largest_file_lines": max((f["lines"] for f in files), default=0),
            "largest_type_lines": max((f["largest_type_lines"] for f in files), default=0),
        },
        # 예산을 넘은 파일은 "동결" 목록으로 남긴다. 새로 넘는 파일은 즉시 실패한다.
        "frozen_files": {
            f["path"]: f["lines"] for f in files if f["lines"] > FILE_BUDGET
        },
        "largest_files": sorted(files, key=lambda f: -f["lines"])[:12],
        "largest_types": sorted(
            ({"path": f["path"], "type": f["largest_type"], "lines": f["largest_type_lines"]}
             for f in files if f["largest_type"]),
            key=lambda f: -f["lines"],
        )[:12],
    }


def summary(data: dict) -> str:
    out = [
        f"파일 {data['files']}개 · {data['lines']:,}줄",
        "크기 분포: " + " · ".join(f"{k} {v}개" for k, v in data["buckets"].items()),
        "",
        "위험 표시:",
    ]
    for key, value in data["risk"].items():
        out.append(f"  {key:22} {value:5}")
    out += ["", "가장 큰 파일:"]
    for f in data["largest_files"][:8]:
        out.append(f"  {f['lines']:6}  {f['path']}")
    out += ["", "가장 큰 타입:"]
    for f in data["largest_types"][:8]:
        out.append(f"  {f['lines']:6}  {f['type']}  ({f['path']})")
    return "\n".join(out)


def check(data: dict, baseline_path: str) -> int:
    baseline = json.load(open(baseline_path, encoding="utf-8"))
    failures = []
    for key, before in baseline.get("risk", {}).items():
        after = data["risk"].get(key, 0)
        if after > before:
            failures.append(f"{key}: {before} → {after}")
    for key, before in baseline.get("metrics", {}).items():
        after = data["metrics"].get(key, 0)
        if after > before:
            failures.append(f"{key}: {before:,} → {after:,}")
    if data["lines"] > baseline.get("lines", 0) * 1.10:
        failures.append(f"총 줄 수: {baseline['lines']:,} → {data['lines']:,} (+10% 초과)")
    frozen = baseline.get("frozen_files", {})
    for path, count in sorted(data["frozen_files"].items()):
        if path not in frozen:
            failures.append(f"새 거대 파일: {path} ({count:,}줄 > 예산 {FILE_BUDGET:,})")
        elif count > frozen[path]:
            failures.append(f"거대 파일이 커짐: {path} ({frozen[path]:,} → {count:,})")
    if failures:
        print("구조 지표가 기준선보다 나빠졌습니다:", file=sys.stderr)
        for line in failures:
            print(f"  - {line}", file=sys.stderr)
        return 1
    print("구조 지표 기준선 통과.")
    return 0


def progress(data: dict) -> str:
    current = dict(data["risk"])
    current.update(data["metrics"])
    out = ["목표까지:", ""]
    for key, target in TARGETS.items():
        value = current.get(key, 0)
        if key in {"largest_file_lines", "largest_type_lines"}:
            mark = "달성" if value <= target else f"-{value - target:,}줄"
            out.append(f"  {key:22} {value:8,} / {target:8,}   {mark}")
        else:
            mark = "달성" if value <= target else f"-{value - target}"
            out.append(f"  {key:22} {value:8,} / {target:8,}   {mark}")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="전체를 JSON으로 출력")
    parser.add_argument("--write-baseline", metavar="PATH")
    parser.add_argument("--check", metavar="PATH")
    parser.add_argument("--progress", action="store_true", help="목표치까지의 거리")
    args = parser.parse_args()

    data = collect()
    if args.write_baseline:
        os.makedirs(os.path.dirname(args.write_baseline) or ".", exist_ok=True)
        with open(args.write_baseline, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        print(f"기준선을 썼습니다: {args.write_baseline}")
        return 0
    if args.check:
        return check(data, args.check)
    if args.progress:
        print(progress(data))
    elif args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(summary(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
