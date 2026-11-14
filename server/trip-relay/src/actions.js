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
      for (const reserved of ["format", "version", "id", "action", "taskId", "keyId", "source"]) if (reserved in spec.fields) throw new Error("reserved field " + reserved);
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
/** 여행 카드 사진을 받아도 되는 서버(앱 `TravelPhotoLink.hosts`와 같다). */
export const PHOTO_HOSTS = ["upload.wikimedia.org", "images.unsplash.com", "images.pexels.com"];
const photoLink = (v) => {
  if (typeof v !== "string" || v.length > 500) return false;
  try {
    const url = new URL(v);
    return url.protocol === "https:" && !url.username && !url.password && !url.port && PHOTO_HOSTS.includes(url.hostname.toLowerCase());
  } catch { return false; }
};
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
  })
  .add("setTripItemPhoto", {
    tool: "set_trip_item_photo", title: "Set the photo of a trip card", since: SINCE,
    description: "Choose the photo shown on one trip card (itemId from get_activity trips[].items[]). Only a direct https image link on "
      + PHOTO_HOSTS.join(", ") + " that you actually found; never guess a link. credit names the author and licence. "
      + "remove:true goes back to the app's own search. The app downloads the picture itself; nothing but the link passes through here. Undoable.",
    fields: {
      itemId: f.id("Item id").required_(),
      photoUrl: field((v) => photoLink(v), { type: "string", maxLength: 500, description: "Direct https image link on an allowed host" }),
      credit: f.text(120, "Author and licence, shown under the photo"),
      remove: f.flag("true removes the chosen photo"),
    },
    check: (v) => (v.remove === true ? !anyOf(v, ["photoUrl", "credit"]) : !given(v.remove) && given(v.photoUrl)),
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

// 5묶음: 분류·장소·설정 (ACT1114A09). 값 목록은 앱의 것과 같다(층 범위, 정류장 종류, 하루 카드 항목, 알림 종류).
export const FLOORS = [-10, 100];
export const MY_STOP_KINDS = ["subwayStation", "busStop", "trainStation", "airport", "harbor"];
export const DAY_CARD_ITEMS = ["sleep", "movement", "study", "work", "exercise", "hobby", "distance", "places", "trips", "steps", "photos",
  "walkDistance", "carDistance", "transitDistance", "awayTime", "stepDistance", "calories", "income", "expense", "memos"];
export const ALERTS = ["arriveCompany", "leaveCompany", "arriveSchool", "leaveSchool", "arriveAcademy", "leaveAcademy", "arriveHome", "leaveHome",
  "wakeUp", "dailyCard", "rateChange", "breakEven"];
const floor = (description) => f.integer(FLOORS[0], FLOORS[1], description);
registry
  .add("moveCategory", {
    tool: "move_category", title: "Change the order of a category", since: SINCE,
    description: "Move one major category (get_app_state categories, listed in their order) to a new place in the list. position 1 is the top. Undoable.",
    fields: {
      categoryId: f.id("Category id from get_app_state categories").required_(),
      position: f.integer(1, 100, "New place in the list, 1 is the top").required_(),
    },
  })
  .add("deleteCategory", {
    tool: "delete_category", title: "Delete a category the user made", since: SINCE,
    description: "Delete one major category the user made (custom:true in get_app_state categories). Its plans and records move to moveTo. "
      + "Built-in categories cannot be deleted: hide them with update_category. Only when the user asked. Undoable.",
    fields: {
      categoryId: f.id("Category to delete").required_(),
      moveTo: f.id("Category that takes over its plans and records").required_(),
    },
    check: (v) => v.categoryId !== v.moveTo,
  })
  .add("setPlaceFloor", {
    tool: "set_place_floor", title: "Set the floor of a frequent place", since: SINCE,
    description: "Set which floor one registered place is on (placeId from get_app_state places). Basement floors are negative. Undoable.",
    fields: {
      placeId: f.match(UUID, "Place id from get_app_state places").required_(),
      floor: floor("Floor, -10 to 100").required_(),
    },
  })
  .add("addMyStop", {
    tool: "add_my_stop", title: "Add a station or stop the user uses", destructive: false, since: SINCE,
    description: "Register a station, stop, airport or harbour the user names (get_app_state settings.myStops), so rides from there are recognised. "
      + "latitude and longitude are required and are never sent back. Undoable.",
    fields: {
      name: f.text(40, "Name of the station or stop").required_(),
      kind: f.oneOf(MY_STOP_KINDS, "Kind of place").required_(),
      latitude: f.number(-90, 90, "Latitude").required_(),
      longitude: f.number(-180, 180, "Longitude").required_(),
      floor: floor("Platform floor, optional"),
    },
  })
  .add("updateMyStop", {
    tool: "update_my_stop", title: "Rename a station or stop, or set its floor", since: SINCE,
    description: "Change one of the user's stations or stops (stopId from get_app_state settings.myStops): name, floor, or clearFloor:true for no floor. "
      + "Give at least one. Undoable.",
    fields: {
      stopId: f.match(UUID, "Stop id from get_app_state settings.myStops").required_(),
      name: f.text(40, "New name"),
      floor: floor("New floor"),
      clearFloor: f.flag("true removes the floor"),
    },
    check: (v) => anyOf(v, ["name", "floor", "clearFloor"]) && v.clearFloor !== false && !(v.clearFloor === true && given(v.floor)),
  })
  .add("deleteMyStop", {
    tool: "delete_my_stop", title: "Delete a station or stop the user added", since: SINCE,
    description: "Delete one of the user's stations or stops. Only when the user asked. Undoable.",
    fields: { stopId: f.match(UUID, "Stop id from get_app_state settings.myStops").required_() },
  })
  .add("setDayCardItems", {
    tool: "set_day_card_items", title: "Choose the figures on the day card", since: SINCE,
    description: "Choose up to four figures shown on the daily share card, in order (current ones in get_app_state settings.dayCard.items). [] shows none. Undoable.",
    fields: { items: f.list(f.oneOf(DAY_CARD_ITEMS), 4, "Figures in the order shown", 0).required_() },
    check: (v) => new Set(v.items).size === v.items.length,
  })
  .add("setDayCardTime", {
    tool: "set_day_card_time", title: "Set the time of the day card alert", since: SINCE,
    description: "Set when the daily \"yesterday's card is ready\" alert arrives (get_app_state settings.dayCard.time). Undoable.",
    fields: { time: f.time("HH:mm (24h)").required_() },
  })
  .add("setAlert", {
    tool: "set_alert", title: "Switch one kind of alert on or off", since: SINCE,
    description: "Switch one kind of app alert on or off (those on are in get_app_state settings.alertsOn). This does not grant the iOS notification "
      + "permission: if notifications are not allowed, the user has to allow them. Undoable.",
    fields: {
      alert: f.oneOf(ALERTS, "Kind of alert").required_(),
      enabled: f.flag("true on, false off").required_(),
    },
  })
  .add("setCatOutfit", {
    tool: "set_cat_outfit", title: "Dress the user's cat", since: SINCE,
    description: "Put on one accessory the user already earned (get_app_state settings.outfit.owned; one hat, one scarf and one tail ribbon can be worn together). Undoable.",
    fields: { accessoryId: f.match(/^cat\.accessory\.[\w.-]{1,80}$/, "Accessory id from settings.outfit.owned").required_() },
  });

// 6묶음: 시스템 (ACT1114A09). 권한 켜기·앱 잠금·PIN·전부 지우기는 넣지 않는다(대표 결정).
registry
  .add("refreshNow", {
    tool: "refresh_now", title: "Refresh records or run the iCloud sync now", destructive: false, since: SINCE,
    description: "Run what the app's refresh buttons do: records re-reads the connected data (health, calendar, sensors) for today, cloud starts an iCloud sync. "
      + "It changes no settings and there is nothing to undo.",
    fields: { target: f.oneOf(["records", "cloud"], "What to refresh").required_() },
  })
  .add("stopTracking", {
    tool: "stop_tracking", title: "Stop the walk or run being tracked", since: SINCE,
    description: "End the walk or run the user started tracking in the app and save it as a record. Only when the user asked. Cannot be undone.",
    fields: {},
  })
  .add("disconnectCalendar", {
    tool: "disconnect_calendar", title: "Disconnect a calendar", since: SINCE,
    description: "Stop reading a calendar: device removes every iOS calendar from the app, google signs the linked Google account out. Events already in "
      + "the calendars stay there. Connecting again needs the user in the app. Only when the user asked. Cannot be undone.",
    fields: { calendar: f.oneOf(["device", "google"], "Which calendar connection").required_() },
  })
  .add("restoreFromBackup", {
    tool: "restore_from_backup", title: "Open the restore-from-backup screen", since: SINCE,
    description: "Open the app's data protection screen so the user can restore from a backup. The backup password is typed by the user in the app; "
      + "never ask for it or handle it. Nothing is restored until the user does it there. This action is switched off until the user turns it on in the app.",
    fields: {},
  });

// 승인 항목을 바로 실행으로 (APV1114A16). `request_approval`의 종류마다 하나씩이고, 앱의 스위치가 꺼져 있으면 `disabled`로 거절된다.
// 자료 공유를 넓히거나 보관을 늘리거나 되돌릴 수 없는 것은 사용자가 켜기 전에는 꺼져 있다.
// 전부 지우기·PIN 바꾸기는 넣지 않는다(대표 결정): 그 둘은 `request_approval`로만 한다. 복원은 위의 `restoreFromBackup`.
const SINCE_DIRECT = 343;
const IF_OFF = (request) => ` If the result is rejected with reason disabled, the user switched this action off: use request_approval with request ${request} instead.`;
const STARTS_OFF = " This action is switched off until the user turns it on in the app.";
registry
  .add("lowerShareLevel", {
    tool: "lower_share_level", title: "Share less with the AI", since: SINCE_DIRECT,
    description: "Lower how much the app shares with you, right away and without an approval card: summary (day summaries only) or off (nothing). "
      + "It must be lower than settings.shareLevel in get_app_state, otherwise it is rejected. The days the server holds are deleted and sent again "
      + "at the new level. Only when the user asked. Undoable." + IF_OFF("shareLevel"),
    fields: { level: f.oneOf(["off", "summary"], "The new, lower level").required_() },
  })
  .add("raiseShareLevel", {
    tool: "raise_share_level", title: "Share more with the AI", since: SINCE_DIRECT,
    description: "Raise how much the app shares with you, right away and without an approval card: summary (day summaries) or visits (place names and "
      + "times too). It must be higher than settings.shareLevel in get_app_state, otherwise it is rejected. Only when the user asked. Undoable."
      + STARTS_OFF + IF_OFF("shareLevel"),
    fields: { level: f.oneOf(["summary", "visits"], "The new, higher level").required_() },
  })
  .add("shortenRetention", {
    tool: "shorten_retention", title: "Keep days on the server for a shorter time", since: SINCE_DIRECT,
    description: "Shorten how long the server keeps the user's days, right away: 1 or 7 days. It must be shorter than settings.retentionDays in "
      + "get_app_state, otherwise it is rejected. The days the server holds are deleted and sent again. Only when the user asked. Undoable."
      + IF_OFF("retentionDays"),
    fields: { days: f.integer(1, 7, "1 or 7").required_() },
    check: (v) => [1, 7].includes(v.days),
  })
  .add("extendRetention", {
    tool: "extend_retention", title: "Keep days on the server for a longer time", since: SINCE_DIRECT,
    description: "Extend how long the server keeps the user's days, right away: 7 or 30 days. It must be longer than settings.retentionDays in "
      + "get_app_state, otherwise it is rejected. Only when the user asked. Undoable." + STARTS_OFF + IF_OFF("retentionDays"),
    fields: { days: f.integer(7, 30, "7 or 30").required_() },
    check: (v) => [7, 30].includes(v.days),
  })
  .add("turnOffHealth", {
    tool: "turn_off_health", title: "Turn off Health sync", since: SINCE_DIRECT,
    description: "Stop the Health sync right away. This removes the records brought from Health and Apple Watch from the app, and turning it on again "
      + "needs the user in the app. Only when the user asked. Cannot be undone." + STARTS_OFF + IF_OFF("healthOff"),
    fields: {},
  })
  .add("openBackup", {
    tool: "open_backup", title: "Open the backup screen", destructive: false, since: SINCE_DIRECT,
    description: "Open the app's data protection screen so the user can make a backup. The backup password is typed by the user in the app; "
      + "never ask for it or handle it. Nothing is backed up until the user does it there. It changes no data." + IF_OFF("backup"),
    fields: {},
  });
