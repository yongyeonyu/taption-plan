-- MER1121A01: 앱이 아이콘을 정하지 못한 가맹점 이름(「구분 안 되는 것」)을 모은다. 앱의 「가맹점 이름 보내기」를 켠 사용자만 올린다.
-- 이름만 모은다: 금액·시각·분류·좌표·계정 정보가 없다. owner는 하루 한도·「내가 보낸 것 지우기」·같은 사람이 부풀리지 못하게 하는 해시일 뿐이고 밖으로 내주지 않는다.
-- 운영자는 이름별 건수·보낸 사람 수만 본다(`GET /merchants/admin`). received_at(epoch 밀리초)은 1년 보관 삭제와 하루 한도에만 쓴다.
CREATE TABLE IF NOT EXISTS unknown_merchants (
  name TEXT NOT NULL,
  owner TEXT NOT NULL,
  hits INTEGER NOT NULL,
  first_at INTEGER NOT NULL,
  last_at INTEGER NOT NULL,
  PRIMARY KEY (name, owner)
);

CREATE INDEX IF NOT EXISTS unknown_merchants_last_at ON unknown_merchants (last_at);
CREATE INDEX IF NOT EXISTS unknown_merchants_owner ON unknown_merchants (owner, last_at);
