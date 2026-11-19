import assert from "node:assert/strict";
import test from "node:test";
import { analyze, fetchAll, parseArgs, render } from "../scripts/classifier-report.mjs";

const features = (extra = {}) => ({ averageSpeedKmh: 5, maximumSpeedKmh: 7.5, distanceMeters: 350, steps: 612, stepCadencePerMinute: 108, gpsAccuracyMeters: 10, dominantMotion: "walking", watchCovered: false, sampleCount: 6, ...extra });
let seq = 0;
const sample = (extra = {}) => ({
  seq: ++seq, schemaVersion: 1, id: `00000000-0000-4000-8000-${String(seq).padStart(12, "0")}`, kind: "activity", minuteOfDay: 870, weekdayIndex: 3, durationSeconds: 1200,
  predicted: "rest", predictedDetail: null, predictedConfidence: "high", predictedScore: 0.8, corrected: "work", correctedDetail: "work.meeting", correctedIsCustom: false,
  ruleVersion: "classifier-v1r4", features: features(), ...extra,
});

test("arguments: token comes only from the environment, unknown flags are refused", () => {
  const options = parseArgs(["--host", "relay.example.com", "--min-count", "3", "--json"], { CLASSIFIER_ADMIN_TOKEN: "t".repeat(40) });
  assert.equal(options.host, "relay.example.com");
  assert.equal(options.token, "t".repeat(40));
  assert.equal(options.minCount, 3);
  assert.equal(options.json, true);
  assert.throws(() => parseArgs(["--token", "x"]), /모르는 인자/);
  assert.throws(() => parseArgs(["--min-count", "0"]), /1 이상/);
  assert.throws(() => parseArgs(["--host"]), /값이 없습니다/);
});

test("fetchAll pages with since/limit, sends the bearer token and stops on a short page", async () => {
  const calls = [];
  const pages = [
    { samples: Array.from({ length: 500 }, () => sample()), next: 500 },
    { samples: Array.from({ length: 3 }, () => sample()), next: 503 },
  ];
  const fetchImpl = async (url, init) => { calls.push({ url, auth: init.headers.authorization }); return new Response(JSON.stringify(pages[calls.length - 1]), { status: 200 }); };
  const rows = await fetchAll({ host: "relay.example.com", token: "secret-token", fetchImpl });
  assert.equal(rows.length, 503);
  assert.deepEqual(calls.map((c) => c.url), ["https://relay.example.com/classifier-samples/admin?since=0&limit=500", "https://relay.example.com/classifier-samples/admin?since=500&limit=500"]);
  assert.ok(calls.every((c) => c.auth === "Bearer secret-token"));
});

test("fetchAll turns 401 and 503 into readable errors without echoing the token", async () => {
  for (const [status, pattern] of [[401, /401/], [503, /503/], [500, /500/]]) {
    await assert.rejects(fetchAll({ host: "h", token: "secret-token", fetchImpl: async () => new Response("{}", { status }) }), (error) => pattern.test(error.message) && !error.message.includes("secret-token"));
  }
});

test("analyze groups by predicted → corrected and builds hints from the shape of the samples", () => {
  const rows = [
    ...Array.from({ length: 6 }, () => sample({ minuteOfDay: 900, weekdayIndex: 2 })),
    ...Array.from({ length: 2 }, () => sample({ corrected: "study", correctedDetail: null, predictedConfidence: "low" })),
    ...Array.from({ length: 5 }, () => sample({ kind: "travel", predicted: "bus", corrected: "subway", correctedDetail: null, features: features({ averageSpeedKmh: 32, maximumSpeedKmh: 70, dominantMotion: "automotive" }) })),
    ...Array.from({ length: 5 }, () => sample({ predicted: "unconfirmed", corrected: "custom", correctedIsCustom: true, correctedDetail: null, predictedConfidence: null, predictedScore: null })),
    sample({ ruleVersion: "classifier-v0" }),
  ];
  const report = analyze(rows, { minCount: 5, ruleVersion: "classifier-v1r4" });
  assert.equal(report.total, 19);
  assert.equal(report.used, 18);
  assert.deepEqual(report.byKind, { activity: 13, travel: 5 });
  assert.deepEqual(report.candidates.map((p) => `${p.kind}:${p.predicted}>${p.corrected}:${p.count}`), ["activity:rest>work:6", "travel:bus>subway:5", "activity:unconfirmed>custom:5"]);
  assert.equal(report.skippedPairs, 1);
  const rest = report.candidates[0];
  assert.equal(rest.shareOfPredicted, 6 / 8);
  assert.ok(rest.hints.some((h) => h.includes("high") && h.includes("재보정")));
  assert.ok(rest.hints.some((h) => h.includes("오후(12~18시)")));
  assert.ok(report.candidates[2].hints.some((h) => h.includes("직접 만든 분류")));
  assert.ok(report.candidates[2].hints.some((h) => h.includes("자동 분류로 올릴")));
  const bus = report.candidates[1];
  assert.equal(bus.medianSpeedKmh, 32);
  assert.ok(bus.hints.some((h) => h.includes("32km/h")));
});

test("render: states when nothing repeats, otherwise lists candidates; never prints ids or timestamps", () => {
  assert.match(render(analyze([sample()], { minCount: 5 })), /아직 없습니다/);
  const rows = Array.from({ length: 5 }, () => sample());
  const text = render(analyze(rows, { minCount: 5 }));
  assert.match(text, /## 1\. 활동 rest → work \(5건/);
  assert.ok(!text.includes(rows[0].id));
});

test("analyze copes with an empty list", () => {
  const report = analyze([]);
  assert.equal(report.total, 0);
  assert.deepEqual(report.candidates, []);
  assert.doesNotThrow(() => render(report));
});
