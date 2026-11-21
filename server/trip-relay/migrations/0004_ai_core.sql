-- AIG1122A01 Step 1: 복희 AI 2단 구조의 서버 바탕(설계서 pickle-bridge/inbox/20261122-0030-bokki-ai-two-tier-architecture.md 3·5·10·11절).
-- 이 표들에는 좌표·글 원문·주인 키 원문을 두지 않는다. 사용자는 주인 키의 해시(owner_hash)와 16자리 ID(usr_…)로만 묶는다.

-- 사용자별 플랜과 서버 AI 사용량. 리셋은 사용자 현지 자정(time_zone) 기준이라 날짜 키(day_key·month_key)로 센다.
CREATE TABLE IF NOT EXISTS user_ai_quotas (
  user_id TEXT PRIMARY KEY,                 -- usr_ + 16자리
  owner_hash TEXT NOT NULL UNIQUE,          -- SHA-256("ai-user|" + 주인 키)
  plan TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free', 'pro')),
  plan_source TEXT,                         -- manual(운영자) · app_store(구매 확인, 나중 단계)
  created_at INTEGER NOT NULL,              -- 무료 웰컴 기간(첫 7일)의 시작
  time_zone TEXT NOT NULL DEFAULT 'Asia/Seoul',
  day_key TEXT NOT NULL DEFAULT '',         -- 현지 날짜 YYYY-MM-DD
  daily_cloud_count INTEGER NOT NULL DEFAULT 0,
  month_key TEXT NOT NULL DEFAULT '',       -- 현지 달 YYYY-MM
  monthly_cloud_count INTEGER NOT NULL DEFAULT 0,
  monthly_voice_sec INTEGER NOT NULL DEFAULT 0,
  reset_at INTEGER NOT NULL DEFAULT 0       -- 다음 현지 자정(epoch 밀리초)
);

-- 공통 가맹점·패턴 사전. 야간 학습·운영자·외부 AI 모범 사례가 후보를 올리고, active만 앱에 내려간다.
CREATE TABLE IF NOT EXISTS merchant_rules (
  pattern TEXT PRIMARY KEY,
  normalized_title TEXT NOT NULL,
  category TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0,
  source TEXT NOT NULL CHECK (source IN ('claude_nightly', 'manual', 'external_agent')),
  status TEXT NOT NULL DEFAULT 'candidate' CHECK (status IN ('candidate', 'active', 'retired')),
  hit_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS merchant_rules_status ON merchant_rules (status, hit_count);

-- 오답 노트(4절). 사용자가 고친 AI 결과. user_hash는 학습용 별도 해시라 user_id·owner_hash와 이어지지 않는다.
CREATE TABLE IF NOT EXISTS ai_feedback_logs (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  user_hash TEXT NOT NULL,
  task_type TEXT NOT NULL,
  ai_output TEXT NOT NULL,
  user_corrected_output TEXT NOT NULL,
  anonymized_context TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ai_feedback_logs_created ON ai_feedback_logs (created_at);

-- 내장 AI 오답 + 외부 AI 모범 처리 결과(10절 C). 본문은 AES-GCM 봉인(sealed)만 둔다.
CREATE TABLE IF NOT EXISTS ai_learning_events (
  id TEXT PRIMARY KEY,                      -- req_ + 16자리(같은 작업은 한 번만)
  user_hash TEXT NOT NULL,
  agt_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('built_in_ai', 'external_agent')),
  task_type TEXT NOT NULL,
  sealed TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ai_learning_events_created ON ai_learning_events (created_at);

-- 운영 레버(11절). 값은 JSON. 없는 키는 코드의 기본값을 쓴다.
CREATE TABLE IF NOT EXISTS system_ai_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

-- 에이전트 신원(3절 다중 에이전트). 내장 AI도 agt_ 하나를 갖는다. 토큰 원문은 두지 않는다(연결 키는 기존 /keys가 맡고, 여기는 해시 참조만).
CREATE TABLE IF NOT EXISTS agent_tokens (
  agt_id TEXT PRIMARY KEY,                  -- agt_ + 16자리
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('external')),
  label TEXT NOT NULL,
  key_ref TEXT,                             -- 연결 키 id의 해시(선택)
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX IF NOT EXISTS agent_tokens_user ON agent_tokens (user_id, revoked_at);

-- 내장 AI·외부 에이전트가 함께 보는 작업 표(10절 B). 선점은 조건부 UPDATE 한 번, 끝내기는 version 일치로만.
CREATE TABLE IF NOT EXISTS ai_tasks (
  req_id TEXT PRIMARY KEY,                  -- req_ + 16자리(같은 이벤트는 한 번만 생긴다)
  user_id TEXT NOT NULL,
  task_type TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'pending_external', 'claimed', 'done', 'failed')),
  source TEXT CHECK (source IN ('built_in_ai', 'external_agent')),
  owner_agt_id TEXT,
  updated_by_agt_id TEXT,
  version INTEGER NOT NULL DEFAULT 0,
  fallback_at INTEGER,                      -- 외부 우선 대기의 끝. 지나면 내장 AI가 맡을 수 있다
  claim_until INTEGER,                      -- 선점 유효 시각. 지나면 다시 맡을 수 있다
  sealed TEXT,                              -- 작업 본문(다음 단계, 봉인)
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ai_tasks_user_status ON ai_tasks (user_id, status);
CREATE INDEX IF NOT EXISTS ai_tasks_due ON ai_tasks (status, fallback_at);
