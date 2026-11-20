// ADM1120A01 운영 페이지 화면. 서버가 준 값은 모두 textContent로만 넣는다(innerHTML 없음).
const TOKEN = document.querySelector('meta[name="admin-token"]').content;
const $ = (id) => document.getElementById(id);

async function api(method, path, body) {
  const response = await fetch(path, {
    method, headers: { "x-admin-token": TOKEN, ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((data.errors ?? [data.error ?? `HTTP ${response.status}`]).join("\n"));
  return data;
}

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key === "class") node.className = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else node[key] = value;
  }
  for (const child of children.flat()) if (child !== null && child !== undefined && child !== false) node.append(child);
  return node;
}

function confirmDialog(text) {
  return new Promise((resolve) => {
    $("confirmText").textContent = text;
    const dialog = $("confirm");
    dialog.returnValue = "";
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "yes"), { once: true });
    dialog.showModal();
  });
}

function fail(error) { alert(error.message); refreshState(); }

// ---- 탭 ----
for (const tab of document.querySelectorAll(".tab")) {
  tab.addEventListener("click", () => {
    for (const other of document.querySelectorAll(".tab")) other.classList.toggle("on", other === tab);
    for (const id of ["notices", "packs", "settings"]) $(id).hidden = id !== tab.dataset.tab;
    if (tab.dataset.tab === "packs") loadPacks();
  });
}

// ---- 상태·기록 ----
async function refreshState() {
  try {
    const state = await api("GET", "/api/state");
    $("mode").hidden = !state.dryRun;
    $("busy").textContent = state.busy ? `${state.busy} 중…` : "";
    $("log").textContent = state.logs.join("\n");
    $("log").scrollTop = $("log").scrollHeight;
    const form = $("configForm");
    for (const key of ["host", "bucket", "wranglerConfig"]) if (document.activeElement !== form[key]) form[key].value = state.config[key] ?? "";
    $("configErrors").replaceChildren(...state.configErrors.map((text) => el("li", { textContent: text })));
    return state;
  } catch (error) { $("log").textContent = error.message; }
}

// ---- 공지 ----
let current = { version: 0, items: [] };
let pending = { items: [], remove: [] };
let editing = null;
let previewed = false;

const offset = () => {
  const minutes = -new Date().getTimezoneOffset();
  const sign = minutes >= 0 ? "+" : "-";
  const abs = Math.abs(minutes);
  return `${sign}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")}`;
};
const toIso = (local) => (local ? `${local}${offset()}` : "");
const toLocal = (iso) => {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
};
const when = (item) => [item.startsAt && `시작 ${new Date(item.startsAt).toLocaleString("ko-KR")}`, item.expiresAt && `끝 ${new Date(item.expiresAt).toLocaleString("ko-KR")}`,
  item.minBuild && `빌드 ≥ ${item.minBuild}`, item.maxBuild && `빌드 ≤ ${item.maxBuild}`].filter(Boolean).join(" · ");

function noticeRow(item, actions) {
  const expired = item.expiresAt && new Date(item.expiresAt) < new Date();
  return el("li", {},
    el("div", {},
      el("div", {}, el("span", { class: `kind ${item.kind}`, textContent: item.kind }), el("strong", { textContent: item.title }), expired ? el("span", { class: "muted", textContent: " (기간 끝남)" }) : null),
      el("div", { class: "body", textContent: item.body }),
      el("div", { class: "meta", textContent: [item.id, when(item), item.link, item.titleByLang?.en && `en: ${item.titleByLang.en}`].filter(Boolean).join(" · ") })),
    el("div", { class: "actions" }, actions));
}

async function loadNotices() {
  try {
    current = await api("GET", "/api/announcements");
    $("noticeVersion").textContent = `version ${current.version ?? 0} · ${current.items?.length ?? 0}건`;
    const rows = (current.items ?? []).map((item) => {
      const removing = pending.remove.includes(item.id);
      return noticeRow(item, [
        el("button", { textContent: "고치기", onclick: () => startEdit(item) }),
        el("button", { class: "danger", textContent: removing ? "내리기 취소" : "내리기", onclick: () => toggleRemove(item.id) }),
      ]);
    });
    $("noticeList").replaceChildren(...(rows.length ? rows : [el("li", { class: "muted", textContent: "올라간 공지가 없습니다" })]));
  } catch (error) {
    $("noticeList").replaceChildren(el("li", { class: "bad", textContent: `공지를 읽지 못했습니다: ${error.message}` }));
  }
}

function changed() { previewed = false; $("publishNotices").disabled = true; $("noticePreview").hidden = true; renderPending(); loadNotices(); }

function renderPending() {
  const rows = [
    ...pending.items.map((item) => noticeRow(item, [
      el("button", { textContent: "고치기", onclick: () => startEdit(item) }),
      el("button", { class: "danger", textContent: "빼기", onclick: () => { pending.items = pending.items.filter((x) => x !== item); changed(); } }),
    ])),
    ...pending.remove.map((id) => el("li", {}, el("div", { textContent: `내림: ${id}` }), el("div", { class: "actions" }, el("button", { textContent: "취소", onclick: () => toggleRemove(id) })))),
  ];
  $("pendingList").replaceChildren(...(rows.length ? rows : [el("li", { class: "muted", textContent: "아직 없습니다" })]));
}

function toggleRemove(id) {
  pending.remove = pending.remove.includes(id) ? pending.remove.filter((x) => x !== id) : [...pending.remove, id];
  changed();
}

function startEdit(item) {
  editing = item;
  const form = $("noticeForm");
  form.reset();
  for (const key of ["id", "kind", "title", "body", "link", "minBuild", "maxBuild"]) form[key].value = item[key] ?? "";
  form.titleEn.value = item.titleByLang?.en ?? "";
  form.bodyEn.value = item.bodyByLang?.en ?? "";
  form.startsAt.value = toLocal(item.startsAt);
  form.expiresAt.value = toLocal(item.expiresAt);
  form.id.readOnly = true;
  $("formTitle").textContent = `공지 고치기: ${item.id}`;
  $("queueButton").textContent = "고친 내용 넣기";
  $("cancelEdit").hidden = false;
  form.scrollIntoView({ behavior: "smooth" });
}

function endEdit() {
  editing = null;
  const form = $("noticeForm");
  form.reset(); form.id.readOnly = false;
  $("formTitle").textContent = "새 공지";
  $("queueButton").textContent = "변경 목록에 넣기";
  $("cancelEdit").hidden = true;
}

$("cancelEdit").addEventListener("click", endEdit);

$("noticeForm").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.target;
  const today = new Date(); const stamp = `${String(today.getFullYear()).slice(2)}${String(today.getMonth() + 1).padStart(2, "0")}${String(today.getDate()).padStart(2, "0")}`;
  const item = {
    id: form.id.value.trim() || `notice-${stamp}-${String(Date.now()).slice(-4)}`,
    title: form.title.value, body: form.body.value, kind: form.kind.value, link: form.link.value,
    startsAt: toIso(form.startsAt.value), expiresAt: toIso(form.expiresAt.value),
    minBuild: form.minBuild.value, maxBuild: form.maxBuild.value,
    titleByLang: { en: form.titleEn.value }, bodyByLang: { en: form.bodyEn.value },
  };
  pending.items = [...pending.items.filter((x) => x.id !== item.id && x !== editing), item];
  pending.remove = pending.remove.filter((id) => id !== item.id);
  endEdit();
  changed();
});

$("reloadNotices").addEventListener("click", loadNotices);
$("clearPending").addEventListener("click", () => { pending = { items: [], remove: [] }; changed(); });

$("previewNotices").addEventListener("click", async () => {
  try {
    const plan = await api("POST", "/api/announcements/preview", pending);
    $("noticePreview").hidden = false;
    $("noticePreview").textContent = plan.preview + (plan.errors.length ? `\n\n검사 실패:\n- ${plan.errors.join("\n- ")}` : "\n\n검사 통과");
    previewed = plan.errors.length === 0 && (pending.items.length + pending.remove.length) > 0;
    $("publishNotices").disabled = !previewed;
  } catch (error) { fail(error); }
});

$("publishNotices").addEventListener("click", async () => {
  if (!previewed) return;
  const ok = await confirmDialog(`공지 ${pending.items.length}건을 올리고 ${pending.remove.length}건을 내립니다.\n앱 사용자 모두에게 보입니다(최대 35분 안). 계속할까요?`);
  if (!ok) return;
  try {
    $("publishNotices").disabled = true;
    const result = await api("POST", "/api/announcements/publish", { ...pending, baseVersion: current.version ?? 0 });
    $("noticePreview").textContent = `${result.dryRun ? "[연습] " : ""}올렸습니다 → version ${result.next.version}\n${result.preview}`;
    pending = { items: [], remove: [] };
    previewed = false;
    renderPending();
    setTimeout(loadNotices, 1500);
  } catch (error) { fail(error); }
  refreshState();
});

// ---- 시즌 팩 ----
let lastBuild = null;
const kb = (bytes) => `${(bytes / 1024).toFixed(0)}KB`;
const windowText = (windows) => (windows ?? []).map((w) => `${w.from?.month}/${w.from?.day}~${w.to?.month}/${w.to?.day}`).join(", ");

/** 운영 기간 편집기. spans가 null이면 「매니페스트 기간 그대로」. value()는 null 또는 [{from,to}]. */
function scheduleEditor(spans, manifestWindows) {
  const rows = el("div", { class: "spans" });
  const mode = el("select", {},
    el("option", { value: "schedule", textContent: "운영 기간에만 공개" }),
    el("option", { value: "manifest", textContent: `매니페스트 기간 그대로 (${windowText(manifestWindows) || "없음"}, 매년)` }));
  const add = el("button", { type: "button", textContent: "+ 기간 추가", onclick: () => addRow() });
  const spanState = (from, to) => {
    const now = Date.now(), a = Date.parse(from), b = Date.parse(to);
    if (Number.isNaN(a) || Number.isNaN(b)) return "";
    return now < a ? "예정" : now < b ? "공개 중" : "끝남";
  };
  function addRow(span) {
    const from = el("input", { type: "datetime-local", value: span ? toLocal(span.from) : "" });
    const to = el("input", { type: "datetime-local", value: span ? toLocal(span.to) : "" });
    const badge = el("span", { class: "meta" });
    const update = () => { badge.textContent = from.value && to.value ? spanState(toIso(from.value), toIso(to.value)) : ""; };
    from.addEventListener("input", update); to.addEventListener("input", update); update();
    const row = el("div", { class: "span-row" }, from, el("span", { textContent: "~" }), to, badge,
      el("button", { type: "button", class: "danger", textContent: "빼기", onclick: () => row.remove() }));
    row.read = () => ({ from: from.value ? `${from.value}:00${offset()}` : "", to: to.value ? `${to.value}:00${offset()}` : "" });
    rows.append(row);
  }
  const sync = () => { rows.hidden = add.hidden = mode.value !== "schedule"; };
  mode.value = spans === null || spans === undefined ? "manifest" : "schedule";
  for (const span of spans ?? []) addRow(span);
  if (mode.value === "schedule" && !(spans ?? []).length) addRow();
  mode.addEventListener("change", () => { if (mode.value === "schedule" && !rows.children.length) addRow(); sync(); });
  sync();
  return {
    node: el("div", { class: "editor" }, mode, rows, add),
    value: () => mode.value === "manifest" ? null : [...rows.children].map((row) => row.read()).filter((s) => s.from || s.to),
  };
}

const describe = (schedule) => schedule === null ? "매니페스트 기간 그대로" : schedule.length
  ? schedule.map((s) => `${new Date(s.from).toLocaleString("ko-KR")} ~ ${new Date(s.to).toLocaleString("ko-KR")}`).join("\n") : "꺼 둠(기간 없음)";

async function loadPacks() {
  try {
    const data = await api("GET", "/api/packs");
    const live = data.catalog?.packs ?? [];
    $("catalogList").replaceChildren(...(data.catalogError ? [el("li", { class: "bad", textContent: data.catalogError })]
      : live.length ? live.map((entry) => {
        const editor = scheduleEditor(entry.schedule ?? null, entry.windows);
        return el("li", { class: "stack" },
          el("div", { class: "row between" },
            el("div", {}, el("strong", { textContent: `${entry.id} · v${entry.version}` }),
              el("div", { class: "meta", textContent: [entry.archive && kb(entry.archive.bytes), entry.updatedAt && `올린 때 ${new Date(entry.updatedAt).toLocaleString("ko-KR")}`].filter(Boolean).join(" · ") })),
            el("div", { class: "actions" }, el("button", { class: "danger", textContent: "카탈로그에서 내리기", onclick: () => withdraw(entry.id) }))),
          editor.node,
          el("div", { class: "row" }, el("button", { class: "primary", textContent: "기간 배포", onclick: () => deploySchedule(entry, editor.value()) })));
      })
      : [el("li", { class: "muted", textContent: "서버에 올라간 팩이 없습니다(앱은 번들 시드를 씁니다)" })]));
    $("localList").replaceChildren(...data.local.map((pack) => {
      if (pack.error) return el("li", { class: "bad", textContent: `${pack.dir}: ${pack.error}` });
      const onServer = live.find((entry) => entry.id === pack.id);
      const blocked = Boolean(onServer && onServer.version >= pack.version);
      const state = !onServer ? "서버에 없음" : blocked ? `서버에 v${onServer.version} 있음 — 기간만 바꾸려면 위에서, 새로 올리려면 manifest.json의 version을 올리세요` : `서버 v${onServer.version} → v${pack.version} (기기는 옛 버전을 지우고 새로 받음)`;
      const editor = blocked ? null : scheduleEditor(onServer ? onServer.schedule ?? null : [], pack.windows);
      return el("li", { class: "stack" },
        el("div", {}, el("strong", { textContent: `${pack.title} (${pack.id}) · v${pack.version}` }),
          el("div", { class: "meta", textContent: [pack.dir, `파일 ${pack.assets}개 ${kb(pack.bytes)}`, state].join(" · ") })),
        editor?.node ?? null,
        blocked ? null : el("div", { class: "row" }, el("button", { textContent: "묶어서 미리보기", onclick: () => build(pack, editor.value()) })));
    }));
  } catch (error) { $("catalogList").replaceChildren(el("li", { class: "bad", textContent: error.message })); }
}

async function deploySchedule(entry, schedule) {
  const ok = await confirmDialog(`${entry.id} v${entry.version}의 공개 기간을 배포합니다.\n\n${describe(schedule)}\n\n같은 버전을 이미 받은 기기는 다시 받지 않고 그대로 씁니다. 앱은 최대 35분 안에 따릅니다. 계속할까요?`);
  if (!ok) return;
  try {
    const result = await api("POST", "/api/packs/schedule", { id: entry.id, schedule });
    $("packOut").hidden = false;
    $("packOut").textContent = `${result.dryRun ? "[연습] " : ""}기간을 배포했습니다: ${entry.id}\n${describe(schedule)}`;
    setTimeout(loadPacks, 1500);
  } catch (error) { fail(error); }
  refreshState();
}

async function build(pack, schedule) {
  try {
    $("packOut").hidden = false;
    $("packOut").textContent = "묶는 중…";
    const result = await api("POST", "/api/packs/build", { dir: pack.dir, schedule });
    lastBuild = result;
    $("packOut").textContent = `묶었습니다: ${result.entry.archive.key} (${result.entry.archive.bytes.toLocaleString()}바이트)\nsha256 ${result.entry.archive.sha256}\n공개 기간: ${describe(result.entry.schedule ?? null)}\n\n올릴 카탈로그:\n${JSON.stringify(result.catalogAfter, null, 2)}`;
    $("publishPack").hidden = false;
  } catch (error) { $("packOut").textContent = error.message; $("publishPack").hidden = true; }
  refreshState();
}

$("publishPack").addEventListener("click", async () => {
  if (!lastBuild) return;
  const ok = await confirmDialog(`${lastBuild.entry.id} v${lastBuild.entry.version}을(를) 올립니다.\n파일을 먼저, 카탈로그를 나중에 올립니다. 앱이 다음에 켜질 때 받습니다. 계속할까요?`);
  if (!ok) return;
  try {
    $("publishPack").hidden = true;
    const result = await api("POST", "/api/packs/publish", { buildId: lastBuild.buildId });
    $("packOut").textContent = `${result.dryRun ? "[연습] " : ""}올렸습니다: ${result.entry.id} v${result.entry.version}\n이어받기(Range) 확인: ${result.check.skipped ? "생략" : result.check.ok ? "206 통과" : `실패 (${result.check.status})`}`;
    lastBuild = null;
    setTimeout(loadPacks, 1500);
  } catch (error) { fail(error); }
  refreshState();
});

async function withdraw(id) {
  const ok = await confirmDialog(`서버 카탈로그에서 ${id}을(를) 뺍니다.\n새로 받는 기기는 없고, 이미 받은 기기와 번들 시드는 그대로입니다. 계속할까요?`);
  if (!ok) return;
  try { await api("POST", "/api/packs/withdraw", { id }); setTimeout(loadPacks, 1500); } catch (error) { fail(error); }
  refreshState();
}

$("reloadPacks").addEventListener("click", loadPacks);

// ---- 설정 ----
$("configForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  try {
    await api("POST", "/api/config", { host: form.host.value, bucket: form.bucket.value, wranglerConfig: form.wranglerConfig.value });
    await refreshState(); loadNotices();
  } catch (error) { $("configErrors").replaceChildren(...error.message.split("\n").map((text) => el("li", { textContent: text }))); }
});

refreshState().then(loadNotices);
setInterval(refreshState, 3000);
