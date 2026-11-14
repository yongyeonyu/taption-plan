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
  amount: (max, description) => field(
    (v) => typeof v === "number" && Number.isFinite(v) && v > 0 && v <= max,
    described({ type: "number", exclusiveMinimum: 0, maximum: max }, description)),
  integer: (min, max, description) => field(
    (v) => Number.isInteger(v) && v >= min && v <= max, described({ type: "integer", minimum: min, maximum: max }, description)),
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
