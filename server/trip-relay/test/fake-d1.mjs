// D1 가짜(D1R1119A01). Node의 `node:sqlite` 위에서 진짜 SQL과 마이그레이션 파일을 그대로 돌린다.
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

export class FakeD1 {
  constructor() {
    this.db = new DatabaseSync(":memory:");
    for (const file of ["0001_kv_entries.sql", "0002_misclass_samples.sql", "0003_unknown_merchants.sql"]) {
      this.db.exec(readFileSync(new URL(`../migrations/${file}`, import.meta.url), "utf8"));
    }
    this.writes = 0; // INSERT·UPDATE·DELETE 실행 수
  }
  prepare(sql) {
    const stmt = this.db.prepare(sql);
    const isWrite = /^\s*(INSERT|UPDATE|DELETE)/i.test(sql);
    return {
      bind: (...args) => ({
        first: async () => stmt.get(...args) ?? null,
        all: async () => ({ results: stmt.all(...args) }),
        run: async () => { if (isWrite) this.writes++; stmt.run(...args); return { success: true }; },
      }),
    };
  }
  async batch(statements) { for (const statement of statements) await statement.run(); return []; }
  rows() { return this.db.prepare("SELECT key, value, expires_at FROM kv_entries ORDER BY key").all(); }
}
