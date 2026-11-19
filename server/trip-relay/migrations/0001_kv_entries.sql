-- D1R1119A01: 옛 KV(PLANS)를 대신하는 키-값 표. 값은 앱 코드가 이미 AES-GCM으로 잠근 문자열이다.
-- expires_at은 만료 시각(epoch 밀리초), NULL이면 만료 없음. 삭제 표식 행(src/d1kv.js)도 이 표에 둔다.
CREATE TABLE IF NOT EXISTS kv_entries (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  expires_at INTEGER
);

CREATE INDEX IF NOT EXISTS kv_entries_expires_at ON kv_entries (expires_at);
