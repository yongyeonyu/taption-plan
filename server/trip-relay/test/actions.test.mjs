// AIX1114A01 P1: 동작 등록부. 새 동작은 actions.js 한 곳에서 검증·도구·목록이 만들어진다.
import assert from "node:assert/strict";
import test from "node:test";
import { f, makeRegistry, registry } from "../src/actions.js";
import { readFileSync } from "node:fs";
import { ACTIONS, COMMAND_FIELDS, cleanAppState, cleanCommand, isAppState, isCommand } from "../src/validate.js";

const sample = () => makeRegistry().add("setFxRate", {
  tool: "set_fx_rate", title: "Set an exchange rate", description: "KRW per one unit of a currency.", destructive: false, since: 340,
  fields: { currency: f.oneOf(["USD", "JPY"], "ISO 4217").required_(), krwPerUnit: f.amount(1e7, "KRW per unit").required_(), note: f.text(40, "Optional note") },
  check: (v) => v.currency !== "JPY" || v.krwPerUnit < 100,
});

test("registry: validates required and optional fields and the extra check", () => {
  const reg = sample();
  const ok = { action: "setFxRate", currency: "USD", krwPerUnit: 1400 };
  assert.equal(reg.validate(ok), true);
  assert.equal(reg.validate({ ...ok, note: "오늘 환율" }), true);
  assert.equal(reg.validate({ ...ok, note: "" }), false, "an empty optional text is refused");
  assert.equal(reg.validate({ ...ok, note: null }), true, "null counts as not given");
  assert.equal(reg.validate({ action: "setFxRate", currency: "USD" }), false, "missing required");
  assert.equal(reg.validate({ ...ok, currency: "EUR" }), false);
  assert.equal(reg.validate({ ...ok, krwPerUnit: -1 }), false);
  assert.equal(reg.validate({ action: "setFxRate", currency: "JPY", krwPerUnit: 900 }), false, "the action's own check");
  assert.equal(reg.validate({ action: "somethingElse" }), undefined, "unknown actions fall through to the old validator");
});

test("registry: field kinds", () => {
  assert.equal(f.date().check("2026-11-14"), true);
  assert.equal(f.date().check("2026-13-01"), false);
  assert.equal(f.time().check("23:59"), true);
  assert.equal(f.time().check("24:00"), false);
  assert.equal(f.id().check("abc-1.2:3_x"), true);
  assert.equal(f.id().check("a b"), false);
  assert.equal(f.integer(1, 5).check(3), true);
  assert.equal(f.integer(1, 5).check(3.5), false);
  assert.equal(f.flag().check(false), true);
  assert.equal(f.list(f.text(5), 2).check(["a", "b"]), true);
  assert.equal(f.list(f.text(5), 2).check(["a", "b", "c"]), false);
  assert.equal(f.list(f.text(5), 2).check(["toolong"]), false);
  assert.equal(f.text(3).check("​​"), false, "invisible characters alone are empty");
  assert.equal(f.match(/^[A-Z]{3}$/).check("USD"), true);
  assert.equal(f.match(/^[A-Z]{3}$/).check("usd"), false);
  assert.equal(f.number(-5, 5).check(-5), true);
  assert.equal(f.number(-5, 5).check(-6), false);
  assert.equal(f.number(-5, 5).check("1"), false);
  assert.equal(f.list(f.text(5), 2, "", 0).check([]), true, "a list may be allowed to be empty");
});

test("registry: tools, manifest and the minimum app build", () => {
  const reg = sample();
  const [tool] = reg.tools();
  assert.deepEqual([tool.name, tool.action, tool.destructive, tool.required], ["set_fx_rate", "setFxRate", false, ["currency", "krwPerUnit"]]);
  assert.deepEqual(Object.keys(tool.properties), ["currency", "krwPerUnit", "note"]);
  assert.deepEqual(reg.manifest().actions[0], { action: "setFxRate", tool: "set_fx_rate", destructive: false, since: 340, fields: ["currency", "krwPerUnit", "note"], required: ["currency", "krwPerUnit"] });
  assert.equal(reg.needsBuild("setFxRate", "338"), 340);
  assert.equal(reg.needsBuild("setFxRate", "340"), null);
  assert.equal(reg.needsBuild("setFxRate", undefined), null, "an unknown build is not blocked");
  assert.equal(reg.needsBuild("nope", "1"), null);
});

test("registry: refuses duplicates, bad names and reserved fields", () => {
  const reg = sample();
  assert.throws(() => reg.add("setFxRate", { tool: "set_fx_rate", fields: {} }), /duplicate/);
  assert.throws(() => makeRegistry().add("Bad", { tool: "bad_tool", fields: {} }), /bad action name/);
  assert.throws(() => makeRegistry().add("fine", { tool: "BadTool", fields: {} }), /bad action name/);
  assert.throws(() => makeRegistry().add("fine", { tool: "fine_tool", fields: { id: f.id() } }), /reserved/);
});

test("registry: every registered action is a command action with its fields", () => {
  for (const name of registry.names()) {
    assert.ok(ACTIONS.includes(name), name);
    assert.deepEqual(COMMAND_FIELDS[name], registry.fields(name));
  }
});

// MARK: ACT1114A07 — 등록부로 더한 동작.

const UUID = "A1B2C3D4-E5F6-4789-9ABC-DEF012345678";
const cmd = (action, extra = {}) => ({ format: "bokki-command", version: 1, id: "c1", action, ...extra });
const accepts = (action, extra) => assert.equal(isCommand(cmd(action, extra)), true, `${action} ${JSON.stringify(extra)}`);
const refuses = (action, extra) => assert.equal(isCommand(cmd(action, extra)), false, `${action} ${JSON.stringify(extra)}`);

test("actions: the fixture the app checks against is the registry's manifest", () => {
  const fixture = JSON.parse(readFileSync(new URL("./fixtures/actions.json", import.meta.url), "utf8"));
  assert.deepEqual(fixture, registry.manifest(), "run `npm run actions` after changing src/actions.js");
  for (const action of fixture.actions) assert.equal(action.since, 341, action.action);
  assert.equal(registry.needsBuild("setFxRate", "340"), 341);
  assert.equal(registry.needsBuild("setFxRate", "341"), null);
});

test("actions batch 1: ledger", () => {
  accepts("classifyInboxItem", { inboxId: UUID, choice: "internal" });
  refuses("classifyInboxItem", { inboxId: UUID, choice: "maybe" });
  refuses("classifyInboxItem", { inboxId: "x", choice: "expense" });
  accepts("setFxRate", { currency: "USD", krwPerUnit: 1400.5 });
  refuses("setFxRate", { currency: "KRW", krwPerUnit: 1 });
  refuses("setFxRate", { currency: "USD", krwPerUnit: 0 });
  refuses("setFxRate", { currency: "usd", krwPerUnit: 1400 });
  accepts("setPaymentSource", { name: "문자", income: false });
  accepts("setPaymentSource", { name: "Bank app", remove: true });
  refuses("setPaymentSource", { name: "Bank app" });
  refuses("setPaymentSource", { name: "Bank app", remove: true, expense: true });
  refuses("setPaymentSource", { name: "x".repeat(41), expense: true });
  accepts("setSkipWords", { add: ["광고"], remove: ["자동이체"] });
  refuses("setSkipWords", {});
  refuses("setSkipWords", { add: [] });
  refuses("setSkipWords", { add: ["a", "a"] });
  refuses("setSkipWords", { add: ["x".repeat(21)] });
  accepts("addLedgerTrip", { name: "Jeju", start: "2026-12-01", end: "2026-12-03", members: ["Mina", "Jun"] });
  accepts("addLedgerTrip", { name: "Jeju", start: "2026-12-01" });
  refuses("addLedgerTrip", { name: "Jeju", start: "2026-12-03", end: "2026-12-01" });
  refuses("addLedgerTrip", { name: "Jeju" });
  refuses("addLedgerTrip", { name: "Jeju", start: "2026-12-01", members: ["Mina", "Mina"] });
  accepts("updateLedgerTrip", { tripId: "ledger-1", members: [] });
  accepts("updateLedgerTrip", { tripId: "ledger-1", settlementKRW: -30000, settlementDate: "2026-12-05" });
  accepts("updateLedgerTrip", { tripId: "ledger-1", autoSettlement: true });
  refuses("updateLedgerTrip", { tripId: "ledger-1" });
  refuses("updateLedgerTrip", { tripId: "ledger-1", autoSettlement: true, settlementKRW: 0 });
  refuses("updateLedgerTrip", { tripId: "ledger-1", settlementKRW: 1e13 });
  refuses("updateLedgerTrip", { members: [] });
  accepts("deleteLedgerTrip", { tripId: "ledger-1" });
  refuses("deleteLedgerTrip", {});
  assert.deepEqual(cleanCommand(cmd("setFxRate", { currency: "USD", krwPerUnit: 1400, extra: 1 })), cmd("setFxRate", { currency: "USD", krwPerUnit: 1400 }));
});

test("actions batch 1: expenses take a trip, sharers, a note and (when edited) a new day and time", () => {
  const base = { amount: 12000, title: "Dinner" };
  accepts("addExpense", { ...base, tripId: "ledger-1", shareNames: ["@me", "Mina"], note: "half each" });
  refuses("addExpense", { ...base, shareNames: [] });
  refuses("addExpense", { ...base, shareNames: ["Mina", "Mina"] });
  refuses("addExpense", { ...base, note: "x".repeat(201) });
  accepts("updateExpense", { entryId: "e1", date: "2026-11-13" });
  accepts("updateExpense", { entryId: "e1", time: "09:30" });
  accepts("updateExpense", { entryId: "e1", tripId: "none" });
  accepts("updateExpense", { entryId: "e1", shareNames: [] });
  accepts("updateExpense", { entryId: "e1", note: "memo" });
  refuses("updateExpense", { entryId: "e1", time: "9:30" });
  refuses("updateExpense", { entryId: "e1" });
  assert.deepEqual(cleanCommand(cmd("updateExpense", { entryId: "e1", shareNames: ["@me"], date: "2026-11-13" })).shareNames, ["@me"]);
});

test("actions batch 2: plans and timed trip items", () => {
  accepts("planQuickAction", { planId: UUID, quickAction: "postpone30" });
  refuses("planQuickAction", { planId: UUID, quickAction: "skip" });
  refuses("planQuickAction", { planId: "p1", quickAction: "complete" });
  const item = { tripId: "trip-1", title: "Dinner", start: "2026-12-01T18:00+09:00", end: "2026-12-01T19:30+09:00" };
  accepts("addTripItem", item);
  accepts("addTripItem", { ...item, kind: "meal", note: "window seat" });
  refuses("addTripItem", { ...item, end: "2026-12-01T18:00+09:00" });
  refuses("addTripItem", { ...item, start: "2026-12-01 18:00" });
  refuses("addTripItem", { ...item, kind: "party" });
  refuses("addTripItem", { ...item, tripId: undefined });
  accepts("updateTripItem", { tripId: "trip-1", itemId: "m-1a2b3c4d", start: "2026-12-01T19:00+09:00" });
  accepts("updateTripItem", { tripId: "trip-1", itemId: "m-1a2b3c4d", note: "moved" });
  refuses("updateTripItem", { tripId: "trip-1", itemId: "m-1a2b3c4d" });
  refuses("updateTripItem", { tripId: "trip-1", itemId: "m-1a2b3c4d", start: "2026-12-01T19:00+09:00", end: "2026-12-01T18:00+09:00" });
  accepts("deleteTripItem", { tripId: "trip-1", itemId: "m-1a2b3c4d" });
  refuses("deleteTripItem", { tripId: "trip-1" });
  const photo = "https://upload.wikimedia.org/wikipedia/commons/a/ab/Sample.jpg";
  accepts("setTripItemPhoto", { itemId: "m-1a2b3c4d", photoUrl: photo, credit: "Author, CC BY-SA 4.0" });
  accepts("setTripItemPhoto", { itemId: "m-1a2b3c4d", remove: true });
  refuses("setTripItemPhoto", { itemId: "m-1a2b3c4d" });
  refuses("setTripItemPhoto", { itemId: "m-1a2b3c4d", photoUrl: photo, remove: true });
  refuses("setTripItemPhoto", { itemId: "m-1a2b3c4d", remove: false });
  for (const bad of ["http://upload.wikimedia.org/a.jpg", "https://example.com/a.jpg", "https://user@upload.wikimedia.org/a.jpg", "https://upload.wikimedia.org:8443/a.jpg", "https://upload.wikimedia.org.example.com/a.jpg"]) {
    refuses("setTripItemPhoto", { itemId: "m-1a2b3c4d", photoUrl: bad });
  }
  assert.equal(f.instant().check("2026-12-01T18:00:30Z"), true);
  assert.equal(f.instant().check("2026-12-01T18:00"), false);
});

test("actions batch 2: schedules take a category, the important mark and a parent goal", () => {
  const base = { title: "Dentist", start: "2026-11-20T15:00+09:00" };
  accepts("addSchedule", { ...base, categoryId: "health", important: true, parentGoalId: UUID });
  refuses("addSchedule", { ...base, important: "yes" });
  refuses("addSchedule", { ...base, parentGoalId: "none" });
  accepts("updateSchedule", { planId: "p1", important: false });
  accepts("updateSchedule", { planId: "p1", categoryId: "work" });
  accepts("updateSchedule", { planId: "p1", parentGoalId: "none" });
  accepts("updateSchedule", { date: "2026-11-20", startTime: "15:00", parentGoalId: UUID });
  refuses("updateSchedule", { planId: "p1", parentGoalId: "goal" });
  refuses("updateSchedule", { planId: "p1" });
  assert.equal(cleanCommand(cmd("addSchedule", { ...base, important: true, junk: 1 })).important, true);
});

test("actions batch 3: records, more travel modes and memo times", () => {
  accepts("deleteManualRecord", { recordId: UUID });
  refuses("deleteManualRecord", { recordId: "r1" });
  accepts("linkRecordToPlan", { recordId: UUID, planId: UUID });
  refuses("linkRecordToPlan", { recordId: UUID });
  accepts("resolveBoarding", { candidateId: "0123456789abcdef", decision: "confirm" });
  refuses("resolveBoarding", { candidateId: "0123456789abcdef", decision: "maybe" });
  refuses("resolveBoarding", { candidateId: "station-1-29000000", decision: "reject" });
  for (const mode of ["run", "cycling", "taxi", "ship", "walk"]) accepts("setTravelMode", { date: "2026-11-10", moveId: UUID, mode });
  refuses("setTravelMode", { date: "2026-11-10", moveId: UUID, mode: "other" });
  accepts("updateMemo", { memoId: "m1", text: "새 글" });
  accepts("updateMemo", { memoId: "m1", date: "2026-11-12" });
  accepts("updateMemo", { memoId: "m1", time: "08:30", text: "새 글" });
  refuses("updateMemo", { memoId: "m1" });
  refuses("updateMemo", { memoId: "m1", time: "8:30" });
  refuses("updateMemo", { memoId: "m1", text: " " });
  assert.equal(isAppState({ format: "bokki-app", version: 1, retentionDays: 7, settings: {}, boarding: [{ id: "0123456789abcdef", name: "역" }] }), true);
  assert.equal(isAppState({ format: "bokki-app", version: 1, retentionDays: 7, settings: {}, boarding: "x" }), false);
  assert.deepEqual(cleanAppState({ format: "bokki-app", version: 1, retentionDays: 7, settings: {}, boarding: [{ id: "a" }], secret: 1 }).boarding, [{ id: "a" }]);
});

test("actions batch 4: more settings, display options, screens and the Kakao map", () => {
  accepts("setMapStyle", { mapStyle: "kakao" });
  refuses("setMapStyle", { mapStyle: "google" });
  for (const option of ["sidebar", "vehicles", "mapPhotos"]) accepts("setDisplayOption", { option, enabled: false });
  refuses("setDisplayOption", { option: "memos", enabled: false });
  for (const screen of ["dayCard", "calendarConnect", "categoryAdd", "paymentAlerts", "aiRules", "ledger"]) accepts("openScreen", { screen });
  refuses("openScreen", { screen: "backup" });
  accepts("setSetting", { setting: "memoDisplay", value: "located" });
  refuses("setSetting", { setting: "memoDisplay", value: "none" });
  refuses("setSetting", { setting: "memoDisplay", value: true });
});

// MARK: ACT1114A09 — 5묶음(분류·장소·설정), 6묶음(시스템).

test("actions batch 5: categories, place floors, my stops, the day card, alerts, the cat outfit", () => {
  accepts("moveCategory", { categoryId: "work", position: 1 });
  refuses("moveCategory", { categoryId: "work", position: 0 });
  refuses("moveCategory", { categoryId: "work", position: 1.5 });
  refuses("moveCategory", { position: 1 });
  accepts("deleteCategory", { categoryId: "custom-1", moveTo: "work" });
  refuses("deleteCategory", { categoryId: "work", moveTo: "work" });
  refuses("deleteCategory", { categoryId: "work" });
  accepts("setPlaceFloor", { placeId: UUID, floor: -2 });
  accepts("setPlaceFloor", { placeId: UUID, floor: 100 });
  refuses("setPlaceFloor", { placeId: UUID, floor: 101 });
  refuses("setPlaceFloor", { placeId: "p1", floor: 2 });
  const stop = { name: "Home stop", kind: "busStop", latitude: 10.5, longitude: 20.5 };
  accepts("addMyStop", stop);
  accepts("addMyStop", { ...stop, kind: "subwayStation", floor: -3 });
  refuses("addMyStop", { ...stop, kind: "tram" });
  refuses("addMyStop", { ...stop, latitude: 91 });
  refuses("addMyStop", { ...stop, longitude: undefined });
  refuses("addMyStop", { ...stop, floor: 500 });
  refuses("addMyStop", { ...stop, name: "x".repeat(41) });
  accepts("updateMyStop", { stopId: UUID, name: "New name" });
  accepts("updateMyStop", { stopId: UUID, floor: 2 });
  accepts("updateMyStop", { stopId: UUID, clearFloor: true });
  refuses("updateMyStop", { stopId: UUID });
  refuses("updateMyStop", { stopId: UUID, floor: 2, clearFloor: true });
  refuses("updateMyStop", { stopId: UUID, clearFloor: false });
  accepts("deleteMyStop", { stopId: UUID });
  refuses("deleteMyStop", { stopId: "s1" });
  accepts("setDayCardItems", { items: ["sleep", "steps", "memos"] });
  accepts("setDayCardItems", { items: [] });
  refuses("setDayCardItems", { items: ["sleep", "sleep"] });
  refuses("setDayCardItems", { items: ["sleep", "steps", "memos", "work", "study"] });
  refuses("setDayCardItems", { items: ["mood"] });
  refuses("setDayCardItems", {});
  accepts("setDayCardTime", { time: "07:30" });
  refuses("setDayCardTime", { time: "24:00" });
  refuses("setDayCardTime", { time: "7:30" });
  accepts("setAlert", { alert: "wakeUp", enabled: false });
  refuses("setAlert", { alert: "nearbyMemo", enabled: true });
  refuses("setAlert", { alert: "wakeUp" });
  accepts("setCatOutfit", { accessoryId: "cat.accessory.sample-1" });
  refuses("setCatOutfit", { accessoryId: "hat" });
  refuses("setCatOutfit", {});
  accepts("setSetting", { setting: "strideCentimeters", value: 72 });
  refuses("setSetting", { setting: "strideCentimeters", value: 20 });
  refuses("setSetting", { setting: "strideCentimeters", value: 72.5 });
  for (const setting of ["watchAcceleration", "watchDataSync"]) {
    accepts("setSetting", { setting, value: "batterySaver" });
    refuses("setSetting", { setting, value: "max" });
  }
  assert.equal(registry.spec("deleteCategory").destructive, true);
  assert.equal(registry.spec("addMyStop").destructive, false);
  assert.equal(cleanCommand(cmd("addMyStop", { ...stop, junk: 1 })).junk, undefined);
  assert.equal(isAppState({ format: "bokki-app", version: 1, retentionDays: 7, settings: { myStops: [{ id: UUID, name: "Home stop", kind: "busStop" }], dayCard: { items: [], time: "08:00" } } }), true);
});

test("actions batch 6: refresh, tracking, calendars, restore; switching permissions on, the app lock, the PIN and erasing stay out", () => {
  accepts("refreshNow", { target: "records" });
  accepts("refreshNow", { target: "cloud" });
  refuses("refreshNow", { target: "all" });
  refuses("refreshNow", {});
  accepts("stopTracking", {});
  accepts("disconnectCalendar", { calendar: "device" });
  accepts("disconnectCalendar", { calendar: "google" });
  refuses("disconnectCalendar", { calendar: "outlook" });
  accepts("restoreFromBackup", {});
  assert.equal(cleanCommand(cmd("restoreFromBackup", { password: "123456" })).password, undefined, "a backup password never travels with the command");
  assert.match(registry.spec("restoreFromBackup").description, /never ask for it/);
  for (const setting of ["location", "photos", "notifications"]) {
    accepts("setSetting", { setting, value: false });
    refuses("setSetting", { setting, value: true });
  }
  for (const action of ["setAppLock", "changePin", "eraseAllData", "restoreBackup", "enableLocation"]) {
    assert.equal(ACTIONS.includes(action), false, action);
    refuses(action, {});
  }
  const tools = registry.tools();
  assert.deepEqual(tools.find((t) => t.action === "stopTracking").required, []);
  assert.equal(tools.find((t) => t.action === "refreshNow").destructive, false);
});
