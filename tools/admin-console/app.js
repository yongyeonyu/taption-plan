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

function confirmDialog(text, yesLabel = "올리기") {
  return new Promise((resolve) => {
    $("confirmText").textContent = text;
    $("confirm").querySelector('button[value="yes"]').textContent = yesLabel;
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
    for (const id of ["notices", "packs", "reset", "keys", "settings"]) $(id).hidden = id !== tab.dataset.tab;
    if (tab.dataset.tab === "packs") loadPacks();
    if (tab.dataset.tab === "reset") loadReset();
    if (tab.dataset.tab === "keys" || tab.dataset.tab === "settings") loadKeys();
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

const fileUrl = (pack, path) => `/api/pack-file?dir=${encodeURIComponent(pack.dir)}&path=${encodeURIComponent(path)}&t=${encodeURIComponent(TOKEN)}`;

/** 카드뉴스식 접이식 카드: 접으면 아이콘·이름·상태, 펼치면 내용. */
function card({ pack, title, meta, badge, body }) {
  const cover = pack?.cover ? el("img", { class: "cover", src: fileUrl(pack, pack.cover), alt: "" }) : el("div", { class: "cover empty", textContent: "📦" });
  return el("details", { class: "card" },
    el("summary", {}, cover, el("div", {}, el("strong", { textContent: title }), badge ? el("span", { class: "chip", textContent: badge }) : null, el("div", { class: "meta", textContent: meta }))),
    el("div", { class: "card-body" }, body));
}

/** 팩 내용 보기: 이미지 모아 보기, 음원 재생, 안내 글, 슬롯. */
function packContents(pack) {
  const images = pack.files.filter((f) => f.kind === "image");
  const parts = [];
  if (pack.intro.length) parts.push(el("div", {}, el("h3", { textContent: "앱에 보이는 안내 글" }), ...pack.intro.map((i) => el("p", { class: "intro", textContent: `${i.title ? `[${i.title}] ` : ""}${i.text}` }))));
  if (images.length) parts.push(el("div", {}, el("h3", { textContent: `이미지 ${images.length}개` }),
    el("div", { class: "thumbs" }, images.map((f) => el("div", { class: "thumb" }, el("img", { src: fileUrl(pack, f.path), alt: f.id, loading: "lazy" }), `${f.id} · ${kb(f.bytes)}`)))));
  if (pack.audio.length) parts.push(el("div", {}, el("h3", { textContent: "음원" }), ...pack.audio.map((a) => el("div", {},
    el("div", { class: "meta", textContent: `${a.title} · ${a.seconds}초${pack.lyricLines ? ` · 가사 ${pack.lyricLines}줄` : ""}` }),
    a.asset ? el("audio", { controls: true, preload: "none", src: fileUrl(pack, a.asset) }) : null))));
  const chips = [...pack.slots.map((s) => `슬롯 ${s}`), ...pack.actors.map((a) => `등장 ${a}`), ...pack.menuIcons.map((m) => `메뉴 ${m}`)];
  if (chips.length) parts.push(el("div", {}, el("h3", { textContent: "구성" }), el("div", { class: "chips" }, chips.map((t) => el("span", { textContent: t })))));
  if (pack.credits.length) parts.push(el("div", { class: "meta", textContent: pack.credits.join("\n") }));
  return parts;
}

async function loadPacks() {
  try {
    const data = await api("GET", "/api/packs");
    const live = data.catalog?.packs ?? [];
    $("catalogList").className = "cards";
    $("localList").className = "cards";
    $("catalogList").replaceChildren(...(data.catalogError ? [el("li", { class: "bad", textContent: data.catalogError })]
      : live.length ? live.map((entry) => {
        const editor = scheduleEditor(entry.schedule ?? null, entry.windows);
        const mine = data.local.find((p) => p.id === entry.id && !p.error);
        const spanText = entry.schedule === undefined ? "매니페스트 기간(매년)" : entry.schedule.length ? `기간 ${entry.schedule.length}칸` : "꺼 둠";
        return card({ pack: mine, title: `${entry.id} · v${entry.version}`, badge: "서버", meta: [spanText, entry.archive && kb(entry.archive.bytes), entry.updatedAt && `올린 때 ${new Date(entry.updatedAt).toLocaleString("ko-KR")}`].filter(Boolean).join(" · "),
          body: [
            ...(mine ? packContents(mine) : [el("div", { class: "meta", textContent: "이 맥에 같은 팩 폴더가 없어 내용을 미리 볼 수 없습니다." })]),
            editor.node,
            el("div", { class: "row" },
              el("button", { class: "primary", textContent: "기간 배포", onclick: () => deploySchedule(entry, editor.value()) }),
              el("button", { class: "danger", textContent: "카탈로그에서 내리기", onclick: () => withdraw(entry.id) }))] });
      })
      : [el("li", { class: "muted", textContent: "서버에 올라간 팩이 없습니다(앱은 번들 시드를 씁니다)" })]));
    $("localList").replaceChildren(...data.local.map((pack) => {
      if (pack.error) return el("li", { class: "bad", textContent: `${pack.dir}: ${pack.error}` });
      const onServer = live.find((entry) => entry.id === pack.id);
      const blocked = Boolean(onServer && onServer.version >= pack.version);
      const state = !onServer ? "서버에 없음" : blocked ? `서버에 v${onServer.version} 있음 — 기간만 바꾸려면 위에서, 새로 올리려면 manifest.json의 version을 올리세요` : `서버 v${onServer.version} → v${pack.version} (기기는 옛 버전을 지우고 새로 받음)`;
      const editor = blocked ? null : scheduleEditor(onServer ? onServer.schedule ?? null : null, pack.windows);
      return card({ pack, title: `${pack.title} (${pack.id}) · v${pack.version}`, badge: onServer ? (blocked ? "서버와 같음" : "새 버전") : "미배포",
        meta: [`파일 ${pack.assets}개 ${kb(pack.bytes)}`, state].join(" · "),
        body: [...packContents(pack), el("div", { class: "meta", textContent: pack.dir }), editor?.node ?? null,
          blocked ? null : el("div", { class: "row" },
            el("button", { class: "primary", textContent: "배포", onclick: () => deployNow(pack, editor.value()) }),
            el("button", { textContent: "묶어서 미리보기", onclick: () => build(pack, editor.value()) }))] });
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

/** 묶기 → 확인 → 올리기를 한 번에. */
async function deployNow(pack, schedule) {
  const ok = await confirmDialog(`${pack.id} v${pack.version}을(를) 묶어서 바로 배포합니다.\n공개 기간: ${describe(schedule)}\n파일을 먼저, 카탈로그를 나중에 올립니다. 앱 사용자 모두에게 보입니다. 계속할까요?`);
  if (!ok) return;
  try {
    $("packOut").hidden = false;
    $("packOut").textContent = "묶는 중…";
    const built = await api("POST", "/api/packs/build", { dir: pack.dir, schedule });
    $("packOut").textContent = `묶었습니다(${built.entry.archive.bytes.toLocaleString()}바이트). 올리는 중…`;
    const result = await api("POST", "/api/packs/publish", { buildId: built.buildId });
    $("packOut").textContent = `${result.dryRun ? "[연습] " : ""}배포했습니다: ${result.entry.id} v${result.entry.version}\n이어받기(Range) 확인: ${result.check.skipped ? "생략" : result.check.ok ? "206 통과" : `실패 (${result.check.status})`}`;
    $("publishPack").hidden = true; lastBuild = null;
    setTimeout(loadPacks, 1500);
  } catch (error) { $("packOut").textContent = `배포 실패: ${error.message}`; }
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

// ---- 초기화(ADM1120A03) ----
let resetPlan = null; // 미리보기 때 읽은 baseVersion·baseCatalogHash와 범위
const scopes = () => ({ notices: $("scopeNotices").checked, packs: $("scopePacks").checked, schedules: $("scopeSchedules").checked });
const describeSchedule = (spans) => (spans === null ? "매니페스트 기간" : spans.length ? spans.map((s) => `${s.from} ~ ${s.to}`).join(", ") : "꺼 둠");

function syncResetButtons() {
  $("applyReset").disabled = !(resetPlan && $("resetConfirm").value === "초기화" && resetPlan.errors.length === 0);
}

async function loadReset() {
  try {
    const state = await api("GET", "/api/reset/state");
    $("resetState").replaceChildren(
      el("div", { class: "card" }, el("b", { textContent: "공지" }), el("div", { textContent: `version ${state.announcements.version} · ${state.announcements.count}건` }),
        ...state.announcements.items.map((item) => el("div", { class: "muted", textContent: `${item.id} · ${item.title}` }))),
      el("div", { class: "card" }, el("b", { textContent: "팩 카탈로그" }),
        ...(state.catalog.packs.length ? state.catalog.packs.map((p) => el("div", { textContent: `${p.id} v${p.version} · ${describeSchedule(p.schedule)}` })) : [el("div", { class: "muted", textContent: "비어 있음" })])));
    $("resetLast").textContent = state.lastReset ? `되돌릴 수 있는 마지막 초기화: ${state.lastReset.dir}` : "되돌릴 초기화 기록이 없습니다";
    $("restoreReset").disabled = !state.lastReset;
  } catch (error) { $("resetState").replaceChildren(el("div", { class: "muted", textContent: error.message })); }
}

$("reloadReset").addEventListener("click", () => { resetPlan = null; syncResetButtons(); loadReset(); });
$("resetConfirm").addEventListener("input", syncResetButtons);
for (const id of ["scopeNotices", "scopePacks", "scopeSchedules"]) $(id).addEventListener("change", () => { resetPlan = null; for (const out of ["resetBefore", "resetAfter"]) $(out).hidden = true; syncResetButtons(); });

$("previewReset").addEventListener("click", async () => {
  try {
    const result = await api("POST", "/api/reset/preview", { scopes: scopes() });
    resetPlan = { ...result, scopes: scopes() };
    $("resetBefore").textContent = JSON.stringify(result.before, null, 2);
    $("resetAfter").textContent = JSON.stringify(result.after, null, 2) + (result.errors.length ? `\n\n검사 실패:\n${result.errors.join("\n")}` : "");
    $("resetBefore").hidden = $("resetAfter").hidden = false;
    syncResetButtons();
  } catch (error) { fail(error); }
});

$("applyReset").addEventListener("click", async () => {
  const chosen = resetPlan.scopes;
  const lines = [chosen.notices && "서버의 공지를 모두 내립니다", chosen.packs && "서버의 시즌 팩 카탈로그를 비웁니다(R2의 팩 파일은 그대로)", !chosen.packs && chosen.schedules && "팩 운영 기간을 지웁니다(매니페스트 기간으로 돌아감)"].filter(Boolean);
  const ok = await confirmDialog(`${lines.join("\n")}.\n앱 사용자 모두에게 보입니다(최대 35분 안). 직전 상태는 백업되고 「방금 초기화 되돌리기」로 되돌릴 수 있습니다. 계속할까요?`);
  if (!ok) return;
  try {
    const result = await api("POST", "/api/reset/apply", { scopes: chosen, baseVersion: resetPlan.baseVersion, baseCatalogHash: resetPlan.baseCatalogHash, confirm: $("resetConfirm").value });
    $("resetConfirm").value = ""; resetPlan = null; syncResetButtons();
    $("resetLast").textContent = `${result.dryRun ? "[연습] " : ""}초기화했습니다: ${result.dir}`;
    setTimeout(loadReset, 1500);
  } catch (error) { fail(error); }
  refreshState();
});

$("restoreReset").addEventListener("click", async () => {
  const ok = await confirmDialog("방금 초기화하기 직전의 공지와 팩 카탈로그를 그대로 다시 올립니다. 그 뒤에 바뀐 서버 내용은 덮어씁니다. 계속할까요?");
  if (!ok) return;
  try { await api("POST", "/api/reset/restore", {}); setTimeout(loadReset, 1500); } catch (error) { fail(error); }
  refreshState();
});

// ---- API 키(KEY1121A01) ----
// 서버는 원문을 주지 않는다(masked만). 입력 칸은 보낸 뒤 바로 비운다.
const EXPIRY_LABEL = { expired: "만료됨", soon7: "7일 이내", soon30: "30일 이내", ok: "여유", none: "만료일 없음" };
const expiryText = (key) => {
  const { state, days } = key.expiry;
  if (state === "none") return "만료일 없음";
  if (state === "expired") return `만료됨 · ${key.expiresAt}`;
  return `${key.expiresAt} · ${days === 0 ? "오늘까지" : `${days}일 남음`}`;
};

function copyButton(text) {
  return el("button", { class: "mini", textContent: "복사", onclick: async (event) => {
    try { await navigator.clipboard.writeText(text); event.target.textContent = "복사됨"; setTimeout(() => (event.target.textContent = "복사"), 1500); }
    catch { alert("복사하지 못했습니다. 명령을 직접 골라 복사하세요."); }
  } });
}

function keyCard(key) {
  const where = key.where === "server" ? "서버 시크릿" : "앱 빌드";
  const presence = key.where === "server"
    ? (key.onServer === null ? "서버: 미확인(위 「서버 시크릿 이름 읽기」)" : key.onServer ? "서버: 들어 있음" : "서버: 없음")
    : ({ empty: "앱 빌드 설정: 비어 있음", same: "앱 빌드 설정: 저장한 값과 같음", different: "앱 빌드 설정: 저장한 값과 다름", filled: "앱 빌드 설정: 채워져 있음(이 맥에는 미저장)" })[key.inAppBuild];
  const presenceBad = key.where === "server" ? key.onServer === false : key.inAppBuild === "empty" || key.inAppBuild === "different";

  const input = key.multiline
    ? el("textarea", { class: "secret-area", rows: 3, placeholder: ".p8 파일 내용 전체", autocomplete: "off", spellcheck: false })
    : el("input", { type: "password", placeholder: key.hasValue ? "새 값으로 교체" : "키 값 붙여 넣기", autocomplete: "off", spellcheck: false });
  const save = el("button", { class: "primary", textContent: key.hasValue ? "교체" : "저장", onclick: async () => {
    const value = input.value;
    input.value = "";
    if (!value.trim()) return alert("값을 넣으세요");
    if (key.danger && !(await confirmDialog(`${key.name}: ${key.danger}\n이 맥에만 저장하고 서버에는 넣지 않습니다. 계속할까요?`, "저장"))) return;
    try { renderKeys(await api("POST", "/api/keys/set", { name: key.name, value })); } catch (error) { fail(error); }
    refreshState();
  } });
  const remove = el("button", { class: "danger", textContent: "삭제", disabled: !key.hasValue, onclick: async () => {
    const ok = await confirmDialog(`${key.name}: 이 맥에 저장한 값을 지웁니다.\nCloudflare 시크릿·앱 빌드 설정은 그대로입니다(서버에서 빼려면 wrangler secret delete를 따로). 계속할까요?`, "지우기");
    if (!ok) return;
    try { renderKeys(await api("POST", "/api/keys/delete", { name: key.name })); } catch (error) { fail(error); }
    refreshState();
  } });

  const date = el("input", { type: "date", value: key.expiresAt ?? "" });
  const note = el("input", { placeholder: "갱신 주기·메모(예: 2년마다 연장 신청)", maxLength: 200, value: key.note ?? "" });
  const saveMeta = el("button", { textContent: "만료일 저장", onclick: async () => {
    try { renderKeys(await api("POST", "/api/keys/meta", { name: key.name, expiresAt: date.value || null, note: note.value })); } catch (error) { fail(error); }
    refreshState();
  } });

  const usage = key.usage.kind === "limit"
    ? [el("div", {}, el("span", { class: "usage limit", textContent: "한도" }), ` ${key.usage.limit}`), el("div", { class: "muted" }, "오늘 쓴 수: 확인 불가 — ", key.usage.reason)]
    : [el("div", {}, el("span", { class: `usage ${key.usage.kind}`, textContent: key.usage.label }), el("span", { class: "muted", textContent: ` ${key.usage.reason}` }))];

  const dropSlot = key.custom ? el("button", { class: "danger mini", textContent: "칸 지우기", onclick: async () => {
    if (!(await confirmDialog(`${key.name}: 직접 추가한 칸과 이 맥에 저장한 값·만료일을 지웁니다. 계속할까요?`, "지우기"))) return;
    try { renderKeys(await api("POST", "/api/keys/custom-remove", { name: key.name })); } catch (error) { fail(error); }
    refreshState();
  } }) : null;

  return el("div", { class: `keycard exp-${key.expiry.state}` },
    el("div", { class: "row between top" },
      el("div", {},
        el("code", { class: "keyname", textContent: key.name }),
        el("span", { class: `chip where ${key.where}`, textContent: where }),
        key.optional ? el("span", { class: "chip where", textContent: "선택" }) : null,
        dropSlot,
        el("div", { class: "muted small", textContent: `${key.group} · ${key.provider}` })),
      el("div", { class: "right" },
        el("div", { class: key.hasValue ? "good" : "muted", textContent: key.hasValue ? `저장됨 ${key.masked}` : "이 맥에 없음" }),
        key.savedAt ? el("div", { class: "muted small", textContent: new Date(key.savedAt).toLocaleString("ko-KR") }) : null,
        el("div", { class: presenceBad ? "bad small" : "muted small", textContent: presence }))),
    el("div", { class: "desc" }, el("div", { textContent: key.feature }), el("div", { class: "muted small", textContent: `없으면: ${key.missing}` }),
      key.danger ? el("div", { class: "bad small", textContent: `주의: ${key.danger}` }) : null),
    el("div", { class: "sub" }, el("h4", { textContent: "사용량" }), ...usage, el("div", { class: "muted small", textContent: `확인하는 곳: ${key.usage.where}` })),
    el("div", { class: "sub" }, el("h4", {}, "만료일 ", el("span", { class: `exp ${key.expiry.state}`, textContent: expiryText(key) })),
      el("div", { class: "muted small", textContent: `자동으로 알려 주는 공급자 없음 · ${key.expiryHint}` }),
      el("div", { class: "row" }, date, note, saveMeta)),
    el("div", { class: "sub" }, el("h4", { textContent: "입력 · 교체 · 삭제" }), el("div", { class: "row" }, input, save, remove)),
    el("details", { class: "apply" }, el("summary", { textContent: `반영 방법 — ${key.apply.how}` }),
      ...key.apply.commands.map((command) => el("div", { class: "cmd" }, el("code", { textContent: command }), copyButton(command))),
      key.where === "server" ? el("div", { class: "muted small", textContent: "첫 줄은 이 맥에 저장한 값을 화면에 찍지 않고 바로 넘깁니다. 둘째 줄은 값을 직접 붙여 넣습니다. 시크릿을 넣으면 Worker가 새 버전으로 바뀝니다." }) : null));
}

function renderKeys(view) {
  $("keyFile").textContent = `${view.file}${view.fileMode ? ` (${view.fileMode})` : " (아직 없음)"}`;
  $("legacyBox").hidden = !view.legacyFile;
  $("legacyText").textContent = view.legacyFile ? `처음 판의 키 파일 ${view.legacyFile}이(가) 남아 있습니다. 옮겨 온 뒤(이미 있는 이름은 덮지 않음) 확인하고 옛 파일은 직접 지우세요.` : "";
  // 설정 탭: wrangler 경로를 붙인 secret put 명령(값 없음).
  $("secretCommands").replaceChildren(...view.keys.filter((key) => key.where === "server").map((key) =>
    el("div", { class: "cmd" }, el("code", { textContent: key.apply.commands[0] }), copyButton(key.apply.commands[0]))));
  const counts = view.keys.reduce((acc, key) => { acc[key.expiry.state] = (acc[key.expiry.state] ?? 0) + 1; return acc; }, {});
  const stored = view.keys.filter((key) => key.hasValue).length;
  $("keySummary").textContent = [`${stored}/${view.keys.length}개 저장`, counts.expired && `만료 ${counts.expired}`, counts.soon7 && `7일 이내 ${counts.soon7}`, counts.soon30 && `30일 이내 ${counts.soon30}`,
    view.serverCheckedAt && `서버 확인 ${new Date(view.serverCheckedAt).toLocaleTimeString("ko-KR")}`].filter(Boolean).join(" · ");
  // 종류(서버 외부 / 서버 내부 / 앱 / 연동 예정)별로 나누고, 그 안은 기능 묶음별로.
  $("keyList").replaceChildren(...Object.entries(view.kinds).flatMap(([kind, label]) => {
    const keys = view.keys.filter((key) => key.kind === kind);
    if (!keys.length) return [];
    const groups = [...new Set(keys.map((key) => key.group))];
    return [el("h2", { class: "kind-title", textContent: `${label} (${keys.filter((key) => key.hasValue).length}/${keys.length})` }),
      ...groups.flatMap((group) => [groups.length > 1 ? el("h3", { textContent: group }) : null, ...keys.filter((key) => key.group === group).map(keyCard)])];
  }));
}

async function loadKeys() {
  try { renderKeys(await api("GET", "/api/keys")); }
  catch (error) { $("keyList").replaceChildren(el("p", { class: "bad", textContent: `키 목록을 읽지 못했습니다: ${error.message}` })); }
}
$("reloadKeys").addEventListener("click", loadKeys);
$("migrateKeys").addEventListener("click", async () => {
  try { const result = await api("POST", "/api/keys/migrate", {}); renderKeys(result); alert(`${result.migrated}칸을 옮겼습니다. 확인 뒤 옛 파일을 직접 지우세요.`); } catch (error) { fail(error); }
  refreshState();
});
$("customForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  try {
    renderKeys(await api("POST", "/api/keys/custom", { name: form.elements.namedItem("name").value.trim(), provider: form.provider.value, feature: form.feature.value, where: form.where.value }));
    form.reset();
  } catch (error) { fail(error); }
  refreshState();
});
$("readServerSecrets").addEventListener("click", async () => {
  try { renderKeys(await api("POST", "/api/keys/server-list", {})); } catch (error) { fail(error); }
  refreshState();
});

// ---- 설정 ----
$("configForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  try {
    await api("POST", "/api/config", { host: form.host.value, bucket: form.bucket.value, wranglerConfig: form.wranglerConfig.value });
    await refreshState(); loadNotices(); loadKeys();
  } catch (error) { $("configErrors").replaceChildren(...error.message.split("\n").map((text) => el("li", { textContent: text }))); }
});

refreshState().then(() => { loadNotices(); loadKeys(); });
setInterval(refreshState, 3000);
