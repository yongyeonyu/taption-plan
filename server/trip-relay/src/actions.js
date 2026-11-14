// 동작 등록부(AIX1114A01, P1). 새 동작은 여기 한 곳에만 적는다.
// 검증(validate.js), MCP 도구·list_actions(mcp.js), OpenAPI(openapi.js)가 이 표에서 만들어진다.
// 예전 동작 50개는 validate.js의 COMMAND_FIELDS·isCommand에 그대로 있고, 차례로 이리 옮긴다.
// 다른 모듈을 불러오지 않는다(validate.js가 이 파일을 불러온다).

const stripInvisible = (text) => text.replace(/[​-‏‪-‮⁠-⁤﻿]/g, "");
const codePoints = (text) => [...text].length;
const field = (check, schema) => ({ check, schema, required: false, required_() { return { ...this, required: true }; } });
const described = (schema, description) => (description ? { ...schema, description } : schema);

/** 칸 하나: check(값) → 참·거짓, schema → JSON Schema 조각. `.required_()`를 붙이면 꼭 있어야 한다. */
export const f = {
  text: (max, description, min = 1) => field(
    (v) => typeof v === "string" && codePoints(stripInvisible(v).trim()) >= min && codePoints(v) <= max,
    described({ type: "string", maxLength: max }, description)),
  id: (description) => field((v) => typeof v === "string" && /^[\w.:-]{1,100}$/.test(v), described({ type: "string", maxLength: 100 }, description)),
  date: (description = "Day in the user's time zone, YYYY-MM-DD") => field(
    (v) => typeof v === "string" && /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(v),
    described({ type: "string", pattern: "^\\d{4}-\\d{2}-\\d{2}$" }, description)),
  time: (description = "HH:mm (24h)") => field(
    (v) => typeof v === "string" && /^([01]\d|2[0-3]):[0-5]\d$/.test(v),
    described({ type: "string", pattern: "^([01]\\d|2[0-3]):[0-5]\\d$" }, description)),
  /** 오프셋이 붙은 ISO 시각(초는 없어도 된다). */
  instant: (description = "ISO 8601 with offset, e.g. 2026-11-12T15:00+09:00") => field(
    (v) => typeof v === "string" && /^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?(Z|[+-]\d{2}:\d{2})$/.test(v) && !Number.isNaN(Date.parse(v)),
    described({ type: "string" }, description)),
  amount: (max, description) => field(
    (v) => typeof v === "number" && Number.isFinite(v) && v > 0 && v <= max,
    described({ type: "number", exclusiveMinimum: 0, maximum: max }, description)),
  integer: (min, max, description) => field(
    (v) => Number.isInteger(v) && v >= min && v <= max, described({ type: "integer", minimum: min, maximum: max }, description)),
  /** 정규식에 맞는 글(통화 코드·UUID). */
  match: (regex, description) => field((v) => typeof v === "string" && regex.test(v), described({ type: "string", pattern: regex.source }, description)),
  /** 음수도 되는 수. */
  number: (min, max, description) => field(
    (v) => typeof v === "number" && Number.isFinite(v) && v >= min && v <= max, described({ type: "number", minimum: min, maximum: max }, description)),
  flag: (description) => field((v) => typeof v === "boolean", described({ type: "boolean" }, description)),
  oneOf: (values, description) => field((v) => values.includes(v), described({ type: "string", enum: values }, description)),
  list: (item, max, description, min = 1) => field(
    (v) => Array.isArray(v) && v.length >= min && v.length <= max && v.every((x) => item.check(x)),
    described({ type: "array", items: item.schema, minItems: min, maxItems: max }, description)),
};

/** 등록부 하나를 만든다. 시험은 따로 만든 등록부로 돈다. */
export function makeRegistry() {
  const specs = new Map();
  return {
    /** spec: { tool, title, description, destructive?, since?, fields: {이름: f.…}, check?(v) } */
    add(name, spec) {
      if (specs.has(name)) throw new Error("duplicate action " + name);
      if (!/^[a-z][A-Za-z]{2,40}$/.test(name) || !/^[a-z][a-z_]{2,50}$/.test(spec.tool ?? "")) throw new Error("bad action name " + name);
      for (const reserved of ["format", "version", "id", "action", "taskId"]) if (reserved in spec.fields) throw new Error("reserved field " + reserved);
      specs.set(name, { destructive: true, since: 0, ...spec });
      return this;
    },
    names: () => [...specs.keys()],
    spec: (name) => specs.get(name),
    /** 그 동작이 받는 칸 이름. 모르는 동작이면 undefined. */
    fields: (name) => (specs.has(name) ? Object.keys(specs.get(name).fields) : undefined),
    /** 등록된 동작이면 참·거짓, 아니면 undefined(예전 검증으로 넘긴다). */
    validate(value) {
      const spec = specs.get(value?.action);
      if (!spec) return undefined;
      for (const [name, one] of Object.entries(spec.fields)) {
        const given = value[name] !== undefined && value[name] !== null;
        if (!given) { if (one.required) return false; continue; }
        if (!one.check(value[name])) return false;
      }
      return spec.check ? spec.check(value) === true : true;
    },
    /** 앱 빌드가 낮아 아직 못 하는 동작이면 필요한 빌드 번호, 아니면 null. 빌드를 모르면 막지 않는다. */
    needsBuild(name, appBuild) {
      const since = specs.get(name)?.since ?? 0;
      const build = Number(appBuild);
      return since > 0 && Number.isFinite(build) && build > 0 && build < since ? since : null;
    },
    /** MCP 도구 정의 조각들. mcp.js의 commandTool에 넘긴다. */
    tools: () => [...specs.entries()].map(([action, spec]) => ({
      name: spec.tool, action, title: spec.title, description: spec.description, destructive: spec.destructive, since: spec.since,
      properties: Object.fromEntries(Object.entries(spec.fields).map(([name, one]) => [name, one.schema])),
      required: Object.entries(spec.fields).filter(([, one]) => one.required).map(([name]) => name),
    })),
    /** 앱(Swift 등록부)과 맞춰 볼 목록. */
    manifest: () => ({
      format: "bokki-actions", version: 1,
      actions: [...specs.entries()].map(([action, spec]) => ({
        action, tool: spec.tool, destructive: spec.destructive, since: spec.since,
        fields: Object.keys(spec.fields), required: Object.entries(spec.fields).filter(([, one]) => one.required).map(([name]) => name),
      })),
    }),
  };
}

/** 서버가 쓰는 등록부. 새 동작은 아래에 `.add(...)`로 더한다. */
export const registry = makeRegistry();

// MARK: 동작 (ACT1114A07). 앱의 `AssistantOperations`와 이름·칸이 같아야 한다(test/fixtures/actions.json으로 견준다).
// 고친 뒤 `npm run actions`로 견본을 다시 뽑는다.

const SINCE = 341;
const UUID = /^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$/;
const given = (v) => v !== undefined && v !== null;
const anyOf = (v, names) => names.some((name) => given(v[name]));
const distinct = (list) => !given(list) || new Set(list.map((x) => x.trim())).size === list.length;
const ordered = (start, end) => !given(start) || !given(end) || end >= start;
const person = (description) => f.text(30, description);

// 1묶음: 가계부.
registry
  .add("classifyInboxItem", {
    tool: "classify_inbox_item", title: "Classify a received payment text", since: SINCE,
    description: "Decide what one received payment text (get_app_state inbox) is, exactly like the user tapping the choice in the app: expense or income adds it "
      + "to the ledger when the amount can be read, ignore drops it from the inbox, internal marks a transfer between the user's own accounts or a card top-up "
      + "(not spending; an entry the app already added for it is removed). Undoable.",
    fields: {
      inboxId: f.match(UUID, "Inbox item id from get_app_state inbox").required_(),
      choice: f.oneOf(["expense", "income", "ignore", "internal"], "What the text is").required_(),
    },
  })
  .add("setFxRate", {
    tool: "set_fx_rate", title: "Set an exchange rate", since: SINCE,
    description: "Set the user's own exchange rate for one currency (KRW per one unit). The ledger uses it instead of the fetched rate for new entries. Undoable.",
    fields: {
      currency: f.match(/^[A-Z]{3}$/, "ISO 4217 code, not KRW").required_(),
      krwPerUnit: f.amount(1e7, "KRW for one unit of the currency").required_(),
    },
    check: (v) => v.currency !== "KRW",
  })
  .add("setPaymentSource", {
    tool: "set_payment_source", title: "Switch a payment alert app on or off", since: SINCE,
    description: "Choose what the ledger keeps from one app's payment alerts (get_app_state settings.paymentSources): expense and income switches, or remove:true "
      + "to take the app off the list. The name \"문자\" stands for text messages. Undoable.",
    fields: {
      name: f.text(40, "App name as listed in settings.paymentSources").required_(),
      expense: f.flag("Keep spending alerts from this app"),
      income: f.flag("Keep income alerts from this app"),
      remove: f.flag("true removes the app from the list"),
    },
    check: (v) => (v.remove === true ? !anyOf(v, ["expense", "income"]) : anyOf(v, ["expense", "income"])),
  })
  .add("setSkipWords", {
    tool: "set_skip_words", title: "Edit the words that keep a text out of the ledger", since: SINCE,
    description: "Add or remove words (get_app_state settings.skipWords): a payment text or alert containing one of them is not added to the ledger. Undoable.",
    fields: {
      add: f.list(f.text(20), 10, "Words to add, 1-20 characters each"),
      remove: f.list(f.text(20), 10, "Words to remove"),
    },
    check: (v) => anyOf(v, ["add", "remove"]) && distinct(v.add) && distinct(v.remove),
  })
  .add("addLedgerTrip", {
    tool: "add_ledger_trip", title: "Create a trip ledger", destructive: false, since: SINCE,
    description: "Create a trip ledger that is not tied to a planned trip (for a planned trip use set_trip_budget with its tripId). members are the companions "
      + "without the user. The new id shows up in get_app_state ledger.trips. Undoable.",
    fields: {
      name: f.text(40, "Trip name").required_(),
      start: f.date("First day, YYYY-MM-DD").required_(),
      end: f.date("Last day, default the first day"),
      members: f.list(person(), 20, "Companion names, 1-30 characters each"),
    },
    check: (v) => ordered(v.start, v.end) && distinct(v.members),
  })
  .add("updateLedgerTrip", {
    tool: "update_ledger_trip", title: "Edit a trip ledger", since: SINCE,
    description: "Change a trip ledger (tripId from get_app_state ledger.trips): name, dates, companions (the whole list; [] for none), the date of the budget "
      + "transfer, or the settlement. settlementKRW fixes the settlement by hand (+ returned to the daily ledger, - extra cost, 0 none); autoSettlement:true goes back "
      + "to the automatic settlement. Give at least one field. Undoable.",
    fields: {
      tripId: f.id("Trip ledger id").required_(),
      name: f.text(40, "New name"),
      start: f.date("New first day"),
      end: f.date("New last day"),
      members: f.list(person(), 20, "All companion names (replaces the list)", 0),
      settlementKRW: f.number(-1e12, 1e12, "Settlement fixed by hand, in KRW"),
      autoSettlement: f.flag("true clears a hand-fixed settlement"),
      fundingDate: f.date("Day the budget moves from the daily ledger"),
      settlementDate: f.date("Day of the settlement"),
    },
    check: (v) => anyOf(v, ["name", "start", "end", "members", "settlementKRW", "autoSettlement", "fundingDate", "settlementDate"])
      && ordered(v.start, v.end) && distinct(v.members) && !(v.autoSettlement === true && given(v.settlementKRW)) && v.autoSettlement !== false,
  })
  .add("deleteLedgerTrip", {
    tool: "delete_ledger_trip", title: "Delete a trip ledger", since: SINCE,
    description: "Delete a trip ledger. Its budget and settlement transfers go too; the entries inside stay and return to the daily ledger. Only when the user asked. Undoable.",
    fields: { tripId: f.id("Trip ledger id from get_app_state ledger.trips").required_() },
  });

// 2묶음: 일정.
const TRIP_ITEM_KINDS = ["flight", "lodging", "meal", "cafe", "sight", "photo", "shopping", "activity", "rest", "sleep", "transfer", "other"];
const after = (start, end) => !given(start) || !given(end) || Date.parse(end) > Date.parse(start);
registry
  .add("planQuickAction", {
    tool: "plan_quick_action", title: "Complete, postpone, move or stop a plan", since: SINCE,
    description: "The quick actions of the app's widget on one plan (planId from get_activity plans): complete marks it done now, postpone30 moves it 30 minutes later, "
      + "moveToNextFree moves it to the next free time, stop ends it while it is running. Undoable.",
    fields: {
      planId: f.match(UUID, "Plan id from get_activity plans").required_(),
      quickAction: f.oneOf(["complete", "postpone30", "moveToNextFree", "stop"], "What to do").required_(),
    },
  })
  .add("addTripItem", {
    tool: "add_trip_item", title: "Add a timed trip item", destructive: false, since: SINCE,
    description: "Add one timed item (a flight, a meal, a sight) to a trip's plan (tripId from get_app_state trips). A plan for the same time is created with it. "
      + "The new itemId shows up in get_activity trips[].items[]. Undoable.",
    fields: {
      tripId: f.id("Trip id").required_(),
      title: f.text(200, "Item name").required_(),
      start: f.instant("Start, ISO 8601 with the local offset of the place").required_(),
      end: f.instant("End, after start").required_(),
      kind: f.oneOf(TRIP_ITEM_KINDS, "Kind of item, default activity"),
      note: f.text(500, "Note"),
    },
    check: (v) => after(v.start, v.end),
  })
  .add("updateTripItem", {
    tool: "update_trip_item", title: "Edit a timed trip item", since: SINCE,
    description: "Change a timed trip item (tripId and itemId from get_activity trips[].items[]): title, kind, start, end or note. Moving start alone keeps the length. "
      + "Its linked plan and map pin follow. Give at least one field. Undoable.",
    fields: {
      tripId: f.id("Trip id").required_(),
      itemId: f.id("Item id").required_(),
      title: f.text(200, "New name"),
      start: f.instant("New start"),
      end: f.instant("New end"),
      kind: f.oneOf(TRIP_ITEM_KINDS, "New kind"),
      note: f.text(500, "New note"),
    },
    check: (v) => anyOf(v, ["title", "start", "end", "kind", "note"]) && after(v.start, v.end),
  })
  .add("deleteTripItem", {
    tool: "delete_trip_item", title: "Delete a timed trip item", since: SINCE,
    description: "Delete a timed trip item with its detail items, linked plan and map pin. Only when the user asked. Undoable.",
    fields: { tripId: f.id("Trip id").required_(), itemId: f.id("Item id").required_() },
  });

// 3묶음: 기록.
registry
  .add("deleteManualRecord", {
    tool: "delete_manual_record", title: "Delete a record the user made", since: SINCE,
    description: "Delete one record the user added by hand (get_activity records with source user). Automatic records cannot be deleted: hide them with "
      + "hide_record instead. Only when the user asked. Undoable.",
    fields: { recordId: f.match(UUID, "Record id from get_activity records").required_() },
  })
  .add("linkRecordToPlan", {
    tool: "link_record_to_plan", title: "Link a record to a plan or goal", since: SINCE,
    description: "Count one record (get_activity records) as time spent on a plan or goal (planId from get_activity plans or goals). The record's time must overlap "
      + "the plan; repeating segments and calendar events cannot be targets. Undoable.",
    fields: {
      recordId: f.match(UUID, "Record id from get_activity records").required_(),
      planId: f.match(UUID, "Plan or goal id").required_(),
    },
  })
  .add("resolveBoarding", {
    tool: "resolve_boarding", title: "Confirm or reject a boarding the app detected", since: SINCE,
    description: "Answer one pending boarding candidate (get_app_state boarding: a station or stop where the app thinks the user got on): confirm sets the "
      + "ride's mode, reject drops the candidate. Only when the user told you. Undoable.",
    fields: {
      candidateId: f.match(/^[0-9a-f]{16}$/, "Candidate id from get_app_state boarding").required_(),
      decision: f.oneOf(["confirm", "reject"], "confirm or reject").required_(),
    },
  });
