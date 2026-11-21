// 일정 제목 분류 명령(setCalendarTitleDetail, HND1112A01)이 /command로 받아지는지 앱이 보내는 모양 그대로 견준다. 값은 모두 가짜다.
import assert from "node:assert/strict";
import test from "node:test";
import { handle } from "../src/index.js";
import { toolList } from "../src/mcp.js";
import { makeEnv } from "./fakes.mjs";

const ORIGIN = "https://relay.example.com";
const PIN = "135790";
const randomKey = () => Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const req = (path, method = "GET", body, key) => new Request(`${ORIGIN}${path}`, {
  method,
  headers: { ...(key ? { authorization: `Bearer ${key}` } : {}), "content-type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const send = (env, ...args) => handle(req(...args), env);

// 앱의 `CalendarTitleClassification.selectableDetailIDs`(record-classification.json에서 이동·미확인·자동 전용·걷기·경로를 뺀 것).
const APP_DETAIL_IDS = ["activity.rest", "activity.zoningOut", "activity.shower", "activity.friends", "activity.date", "activity.family", "activity.phoneCall",
  "activity.performanceMovie", "work.meeting", "work.rest", "study.academy", "study.rest", "hobby.rest", "hobby.reading", "hobby.game", "hobby.music",
  "hobby.video", "hobby.pet", "sleep.nap", "eating.meal", "eating.coffee", "health.recovery", "health.medication", "health.meditation", "health.hospital",
  "health.salon", "housework.chores", "housework.laundry", "housework.groceries", "housework.cooking", "housework.dishes"];

async function setup() {
  const { env } = makeEnv();
  const master = randomKey(), writer = randomKey();
  assert.equal((await send(env, "/register", "POST", {}, master)).status, 201);
  assert.equal((await send(env, "/pin", "POST", { pin: PIN }, master)).status, 200);
  assert.equal((await send(env, "/keys", "POST", { keys: [{ token: writer, scope: "write", expiresAt: null }], pin: PIN }, master)).status, 201);
  const post = async (fields) => send(env, "/command", "POST", { format: "bokki-command", version: 1, id: crypto.randomUUID(), action: "setCalendarTitleDetail", ...fields }, writer);
  return { env, master, writer, post };
}

test("setCalendarTitleDetail is accepted for every detail id the app can choose, and for none", async () => {
  const { post } = await setup();
  for (const detailId of [...APP_DETAIL_IDS, "none"]) {
    const response = await post({ title: "Weekly sync 「주간 회의」", detailId });
    assert.equal(response.status, 201, `${detailId}: ${JSON.stringify(await response.clone().json())}`);
  }
});

test("setCalendarTitleDetail rejects a missing title, a missing or malformed detail id, and unknown extra shapes", async () => {
  const { post } = await setup();
  for (const bad of [{ detailId: "work.meeting" }, { title: "x" }, { title: "", detailId: "work.meeting" }, { title: "x", detailId: "" },
    { title: "x", detailId: "Work.Meeting" }, { title: "x", detailId: "../etc" }, { title: "x", detailId: 3 }, { title: "x".repeat(201), detailId: "none" }]) {
    assert.equal((await post(bad)).status, 422, JSON.stringify(bad));
  }
});

test("the command is queued for the app with its title and detail id", async () => {
  const { env, master, post } = await setup();
  assert.equal((await post({ title: "Dentist", detailId: "health.hospital" })).status, 201);
  const response = await send(env, "/command", "GET", undefined, master);
  assert.equal(response.status, 200);
  const [command] = (await response.json()).commands;
  assert.equal(command.action, "setCalendarTitleDetail");
  assert.equal(command.title, "Dentist");
  assert.equal(command.detailId, "health.hospital");
});

test("the MCP tool set_calendar_title_detail exists with title and detailId", () => {
  const tool = toolList().find((entry) => entry.name === "set_calendar_title_detail");
  assert.ok(tool, "tool listed");
  for (const name of ["detailId", "title"]) assert.ok(name in tool.inputSchema.properties, name);
});

test("a rejected command says why: tool name instead of action, bad title, bad or missing detail id", async () => {
  const { env, writer } = await setup();
  const reason = async (body) => {
    const response = await send(env, "/command", "POST", { format: "bokki-command", version: 1, id: crypto.randomUUID(), ...body }, writer);
    assert.equal(response.status, 422);
    const json = await response.json();
    assert.equal(json.error, "not_command");
    return json.reason;
  };
  assert.equal(await reason({ action: "set_calendar_title_detail", title: "x", detailId: "none" }), "unknown_action:use_setCalendarTitleDetail");
  assert.equal(await reason({ action: "nope", title: "x" }), "unknown_action");
  assert.equal(await reason({ action: "setCalendarTitleDetail", title: "", detailId: "none" }), "bad_title");
  assert.equal(await reason({ action: "setCalendarTitleDetail", title: "x" }), "bad_detail_id:missing");
  assert.equal(await reason({ action: "setCalendarTitleDetail", title: "x", detailId: "meeting" }), "bad_detail_id:use_none_or_category.detail");
});
