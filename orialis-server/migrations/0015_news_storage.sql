CREATE TABLE news_cache (
    cache_key TEXT NOT NULL PRIMARY KEY,
    data_json TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    source TEXT NOT NULL,
    stale INTEGER NOT NULL DEFAULT 0 CHECK (stale IN (0, 1)),
    error TEXT,
    task_id TEXT
);

CREATE TABLE news_publish_tasks (
    task_id TEXT NOT NULL PRIMARY KEY,
    owner_user_id TEXT,
    idempotency_key TEXT,
    status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed')),
    started_at TEXT NOT NULL,
    finished_at TEXT,
    source TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    result_json TEXT,
    error TEXT,
    FOREIGN KEY (owner_user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX uq_news_publish_owner_idempotency
    ON news_publish_tasks (owner_user_id, idempotency_key)
    WHERE owner_user_id IS NOT NULL AND idempotency_key IS NOT NULL;

CREATE INDEX idx_news_publish_owner_started
    ON news_publish_tasks (owner_user_id, started_at DESC);

CREATE TABLE news_project_reports (
    user_id TEXT NOT NULL,
    project_key TEXT NOT NULL DEFAULT '',
    project_id TEXT,
    period TEXT NOT NULL CHECK (period IN ('daily', 'weekly')),
    report_date TEXT NOT NULL,
    report_json TEXT NOT NULL,
    source TEXT NOT NULL,
    task_id TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, project_key, period, report_date),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
    FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE
);

CREATE INDEX idx_news_project_reports_owner_date
    ON news_project_reports (user_id, report_date DESC, period);

CREATE INDEX idx_news_project_reports_project_date
    ON news_project_reports (user_id, project_id, report_date DESC);
