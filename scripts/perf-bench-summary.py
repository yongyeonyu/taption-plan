#!/usr/bin/env python3
"""scripts/perf-bench.sh 결과 여러 개를 모아 항목별 가운데 값과 범위를 낸다(PRF1116A01).
사용: scripts/perf-bench-summary.py run1.txt run2.txt run3.txt"""
import statistics
import sys
from collections import defaultdict

values = defaultdict(list)
for path in sys.argv[1:]:
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.split()
        if len(parts) < 3 or parts[0] != "PRFBENCH":
            continue
        for pair in parts[2:]:
            key, _, value = pair.partition("=")
            try:
                values[(parts[1], key)].append(float(value))
            except ValueError:
                pass
for (name, key), items in sorted(values.items()):
    if key in ("round", "days_ago"):
        continue
    print("%-28s %-18s n=%-2d median %9.1f  min %9.1f  max %9.1f" % (
        name, key, len(items), statistics.median(items), min(items), max(items)))
