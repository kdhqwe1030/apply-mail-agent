-- 모집 문의 메일 1차 답장 에이전트
-- PostgreSQL 16 + pgvector
--
--   docker compose up -d   (docker-compose.yml, 로컬 5432와 겹치지 않게 호스트 포트 5333 사용)
--   접속: postgresql://postgres:postgres@localhost:5333/mailagent

CREATE EXTENSION IF NOT EXISTS vector;


-- ─────────────────────────────────────────────────────────────
-- faq : 지식 베이스
--   승인된 답변만 들어간다. 모델은 여기 있는 answer를 근거로만 답하고,
--   여기에 없는 질문은 답하지 않고 담당자에게 넘긴다.
--   같은 답변이라도 질문 표현이 다르면 행을 따로 넣어 검색 적중률을 올린다.
--   ("지원 자격이 뭔가요" / "제가 지원할 수 있는 조건이 뭔가요" → answer 동일, 2행)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE faq (
    id         serial PRIMARY KEY,       -- FAQ 고유 번호
    category   varchar(40)  NOT NULL,    -- 문의 유형(admission/schedule/curriculum/etc). 이관 시 담당자 결정 기준
    question   text         NOT NULL,    -- 질문 문장. 이 값을 임베딩해 검색 키로 쓴다
    answer     text         NOT NULL,    -- 승인된 답변 원문. 모델이 말을 지어내지 못하게 잡아두는 근거
    source_url text,                     -- 모집요강 등 출처 링크. 답장 하단에 인용해 신뢰도 확보
    embedding  vector(1536)              -- question의 임베딩 벡터 (text-embedding-3-small 기준 1536차원)
);

-- ANN 인덱스는 만들지 않는다.
-- IVFFlat은 클러스터를 나눌 만큼의 데이터가 있어야 제 성능이 나오는데,
-- 수십~수백 행 규모에서는 오히려 엉뚱한 결과를 내놓는다. full scan이 더 빠르고 정확하다.
-- 수천 건을 넘어가면 아래 주석을 풀면 된다.
-- CREATE INDEX idx_faq_embedding ON faq USING ivfflat (embedding vector_cosine_ops) WITH (lists = 50);


-- ─────────────────────────────────────────────────────────────
-- email_log : 처리한 메일 1통 = 1행
--   중복 답장 사고를 막는 게 첫 번째 역할이고,
--   시연 후 "어떤 메일이 어떻게 처리됐는지"를 한 번에 보여주는 게 두 번째 역할이다.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE email_log (
    id           serial PRIMARY KEY,                      -- 처리 기록 번호
    message_id   varchar(255) NOT NULL UNIQUE,            -- 메일 헤더의 Message-ID. UNIQUE가 같은 메일에 두 번 답장하는 사고를 막는다
    from_address varchar(255) NOT NULL,                   -- 발신자 주소. 답장 발송에만 쓰고 LLM 컨텍스트에는 넣지 않는다
    subject      text,                                    -- 메일 제목. 로그 조회용
    body_text    text,                                    -- 메일 원문 전체. 보관용이며 검색 쿼리로는 쓰지 않는다(인사말·서명이 유사도를 흐린다)
    decision     varchar(20),                             -- 판정 결과: auto_reply(자동 발송) / draft_review(초안+담당자 확인) / escalate(초안 없이 이관)
    reply_body   text,                                    -- 생성된 답장 본문. escalate면 NULL
    created_at   timestamptz  NOT NULL DEFAULT now()      -- 처리 시각
);

CREATE INDEX idx_email_log_created ON email_log(created_at DESC);


-- ─────────────────────────────────────────────────────────────
-- email_question : 메일에서 뽑아낸 질문 1개 = 1행
--   메일 한 통에 질문이 여러 개 들어오는 경우가 흔해서 행으로 나눈다.
--   "1번 질문은 FAQ에 있고 2번은 없다" 같은 부분 판정의 근거가 여기 남는다.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE email_question (
    id             serial PRIMARY KEY,                    -- 질문 고유 번호
    log_id         int      NOT NULL REFERENCES email_log(id) ON DELETE CASCADE,  -- 어느 메일에서 나온 질문인지
    seq            smallint NOT NULL,                     -- 메일 안에서의 질문 순서(1, 2, 3...)
    question_text  text     NOT NULL,                     -- 인사말·서명을 걷어낸 질문 문장. 실제 검색 쿼리는 이 값이다
    matched_faq_id int      REFERENCES faq(id),           -- 검색으로 찾은 FAQ. 임계값을 못 넘었으면 NULL
    distance       real,                                  -- 코사인 거리(0에 가까울수록 유사). 판정 근거이자 임계값 비교 대상
    UNIQUE (log_id, seq)                                  -- 같은 메일에 같은 순번이 두 번 들어가지 않게
);

CREATE INDEX idx_email_question_log ON email_question(log_id);


-- ─────────────────────────────────────────────────────────────
-- 시연 후 확인용 쿼리
--   메일별 판정과, 그 메일에서 가장 안 맞았던 질문의 거리를 같이 본다.
--   질문 셋 중 하나만 못 맞춰도 자동 발송하면 안 되므로 판정 기준은 MAX(최악값)다.
-- ─────────────────────────────────────────────────────────────
-- SELECT l.subject, l.decision, MAX(q.distance) AS worst_distance, COUNT(q.id) AS q_count
-- FROM email_log l
-- LEFT JOIN email_question q ON q.log_id = l.id
-- GROUP BY l.id
-- ORDER BY l.created_at DESC;
