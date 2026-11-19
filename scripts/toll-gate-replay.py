#!/usr/bin/env python3
"""영업소 판정 거리(TGT1118A01) 점검: 원본 JSON(앱의 「어제·오늘 원본 업로드」)의 자동차 이동을 `LedgerTollGate.passes`와 같은 식으로 영업소 목록에 견줘 본다.

    python3 -I scripts/toll-gate-replay.py raw.json                      # 위치 간격·공백·정확도만(영업소 목록 없이)
    python3 -I scripts/toll-gate-replay.py raw.json toll-units.json      # 영업소마다 가장 가까웠던 거리·정확도

toll-units.json은 앱 `Library/Caches/toll-units.json`(아이폰에서 devicectl로 복사)이다. 좌표는 기기 밖으로 보내지 않고 출력도 거리·시각만 쓴다.
상수는 앱과 같다: 지남 150m, 확실함 80m·정확도 50m, 이음 120초·3km.
"""
import json, math, sys
from statistics import median

PASS_M, PRECISE_M, PRECISE_ACC, JOIN_S, JOIN_M = 150.0, 80.0, 50.0, 120.0, 3000.0
REF = 978307200  # Apple 기준일 → unix

def load(raw):
    day = json.load(open(raw))[0]
    fixes = sorted(
        (r['timestamp'], r['point']['latitude'], r['point']['longitude'], r['point']['horizontalAccuracy'])
        for r in day['readings'] if r.get('point') and 0 <= r['point']['horizontalAccuracy'] <= 100 and r.get('locationFixQuality') != 'approximate')
    drives = [t for t in day['travel'] if t['mode'] == 'car']
    return fixes, drives

def meters(a, b):
    x = (b[2] - a[2]) * 111320 * math.cos(a[1] * math.pi / 180); y = (b[1] - a[1]) * 110540
    return math.hypot(x, y)

def spacing(fixes):
    gaps = [b[0] - a[0] for a, b in zip(fixes, fixes[1:])]
    dist = [meters(a, b) for a, b in zip(fixes, fixes[1:])]
    over_s = sum(g > JOIN_S for g in gaps); over_m = sum(d > JOIN_M for d in dist)
    acc = sorted(f[3] for f in fixes)
    q = lambda p: acc[min(len(acc) - 1, int(len(acc) * p))]
    return dict(fixes=len(fixes), gap_median_s=round(median(gaps), 1) if gaps else None, gap_max_s=round(max(gaps), 1) if gaps else None,
                gaps_over_join_s=over_s, jumps_over_join_m=over_m, dist_median_m=round(median(dist), 1) if dist else None,
                dist_max_m=round(max(dist), 1) if dist else None, acc_p50=q(0.5), acc_p90=q(0.9), acc_max=acc[-1] if acc else None)

def closest(unit, fixes):
    best = None
    def local(f):
        return ((f[2] - unit['lng']) * 111320 * math.cos(unit['lat'] * math.pi / 180), (f[1] - unit['lat']) * 110540)
    def consider(m, at, acc):
        nonlocal best
        if m <= PASS_M and (best is None or m < best[0]): best = (m, at, acc)
    for i, f in enumerate(fixes):
        hx, hy = local(f); consider(math.hypot(hx, hy), f[0], f[3])
        if i == 0: continue
        p = fixes[i - 1]; bx, by = local(p); dx, dy = hx - bx, hy - by; ln = math.hypot(dx, dy)
        if ln <= 0 or ln > JOIN_M or f[0] - p[0] > JOIN_S: continue
        t = max(0, min(1, -(bx * dx + by * dy) / (ln * ln)))
        consider(math.hypot(bx + dx * t, by + dy * t), p[0] + (f[0] - p[0]) * t, max(f[3], p[3]))
    return best

if __name__ == '__main__':
    fixes, drives = load(sys.argv[1])
    units = json.load(open(sys.argv[2]))['units'] if len(sys.argv) > 2 else None
    for d in drives:
        s, e = d['span']['start'], d['span']['end']
        part = [f for f in fixes if s <= f[0] <= e]
        hour = round((s + REF + 9 * 3600) % 86400 / 3600, 2)
        print(f"이동 시작 {hour}시 {round(d['distanceMeters'] / 1000, 1)}km:", spacing(part) if part else '위치 없음')
        if units and part:
            lat = [f[1] for f in part]; lng = [f[2] for f in part]
            near = [u for u in units if min(lat) - .01 <= u['lat'] <= max(lat) + .01 and min(lng) - .01 <= u['lng'] <= max(lng) + .01]
            for u in near:
                c = closest(u, part)
                if c: print(f"  지남 {u['name']}({u['code']}) {c[0]:.0f}m 정확도 {c[2]:.0f}m {'확실' if c[0] <= PRECISE_M and c[2] <= PRECISE_ACC else '확인 필요'}")
