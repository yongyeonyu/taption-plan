-- CLS1119A01: 오분류 교정 표본(앱 「분류 개선 데이터 수집」을 켠 사용자가 「보내기」로 올린 비식별 특징값).
-- 표본 본문(body)에는 좌표·이름·제목·날짜가 없다(앱 형식 + 서버 허용 목록 검사). owner는 하루 한도·「내 표본 지우기」용 해시일 뿐 표본 안에는 없다.
-- received_at(epoch 밀리초)은 보관 기간(1년) 삭제와 하루 한도에만 쓰고 밖으로 내주지 않는다.
CREATE TABLE IF NOT EXISTS misclass_samples (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  owner TEXT NOT NULL,
  received_at INTEGER NOT NULL,
  rule_version TEXT NOT NULL,
  body TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS misclass_samples_received_at ON misclass_samples (received_at);
CREATE INDEX IF NOT EXISTS misclass_samples_owner ON misclass_samples (owner, received_at);
