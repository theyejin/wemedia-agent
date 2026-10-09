-- ===== wemedia-agent 数据库结构 =====
-- 引擎：SQLite 3
-- 用途：自媒体 Agent —— 内容任务、执行步骤、产物、人工确认、版本留痕
-- 说明：全部使用 IF NOT EXISTS，可重复执行（幂等）。
-- 执行：sqlite3 db/app.db < db/schema.sql
--
-- 注意：PRAGMA foreign_keys 是「每连接」设置，只在当前连接生效；
--       命令行每次读写前都要重新开，或用 .sqliterc。

PRAGMA foreign_keys = ON;

-- ---- 1. 内容任务表 ----
-- 一条记录 = 一条可独立发布的内容。
CREATE TABLE IF NOT EXISTS tasks (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,          -- 任务 ID
    title        TEXT    NOT NULL,                           -- 任务标题
    platform     TEXT    NOT NULL DEFAULT 'general',         -- 目标平台：douyin/xiaohongshu/wechat/bilibili/general
    content_type TEXT    NOT NULL DEFAULT 'article'          -- 内容类型：article/video/image
                 CHECK (content_type IN ('article', 'video', 'image')),
    status       TEXT    NOT NULL DEFAULT 'pending'          -- 任务状态
                 CHECK (status IN ('pending', 'running', 'done', 'failed', 'cancelled')),
    priority     INTEGER NOT NULL DEFAULT 3                  -- 优先级：1 最高，5 最低
                 CHECK (priority BETWEEN 1 AND 5),
    prompt       TEXT,                                       -- 选题 / 生成提示词
    result       TEXT,                                       -- 产出内容或产出文件路径
    error        TEXT,                                       -- 失败原因
    scheduled_at TEXT,                                       -- 计划发布时间
    started_at   TEXT,                                       -- 实际开始时间
    finished_at  TEXT,                                       -- 实际结束时间
    created_at   TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    updated_at   TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_status    ON tasks (status);
CREATE INDEX IF NOT EXISTS idx_tasks_platform  ON tasks (platform);
CREATE INDEX IF NOT EXISTS idx_tasks_created   ON tasks (created_at DESC);

-- ---- 2. 任务执行步骤表 ----
-- 一条任务内部的执行环节（找素材 / 写文案 / 配图 / 送审 / 发布）。
-- 步骤不单独占 tasks 一行，避免污染任务表。
CREATE TABLE IF NOT EXISTS task_steps (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,           -- 步骤 ID
    task_id     INTEGER NOT NULL                             -- 所属任务
                REFERENCES tasks (id) ON DELETE CASCADE,
    step_no     INTEGER NOT NULL DEFAULT 1,                  -- 步骤序号，同任务内从 1 递增
    name        TEXT    NOT NULL,                            -- 步骤名
    skill       TEXT,                                        -- 执行该步骤的 skill 名
    status      TEXT    NOT NULL DEFAULT 'pending'           -- 步骤状态
                CHECK (status IN ('pending', 'running', 'done', 'failed', 'skipped')),
    input       TEXT,                                        -- 步骤输入
    output      TEXT,                                        -- 步骤产出（摘要或路径）
    error       TEXT,                                        -- 失败原因
    started_at  TEXT,                                        -- 开始时间
    finished_at TEXT,                                        -- 结束时间
    created_at  TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    updated_at  TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    UNIQUE (task_id, step_no)                                -- 同一任务内步骤号唯一
);

CREATE INDEX IF NOT EXISTS idx_task_steps_task   ON task_steps (task_id, step_no);
CREATE INDEX IF NOT EXISTS idx_task_steps_status ON task_steps (status);

-- ---- 3. 产物表 ----
-- 落地的产出：文案、图片、视频、外链等。短文本可内联进 content。
CREATE TABLE IF NOT EXISTS artifacts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,            -- 产物 ID
    task_id    INTEGER NOT NULL                              -- 所属任务
               REFERENCES tasks (id) ON DELETE CASCADE,
    step_id    INTEGER                                       -- 产自哪一步（可空）
               REFERENCES task_steps (id) ON DELETE SET NULL,
    kind       TEXT    NOT NULL DEFAULT 'text'               -- 产物类型
               CHECK (kind IN ('text', 'file', 'image', 'video', 'audio', 'url')),
    name       TEXT,                                         -- 产物名
    uri        TEXT,                                         -- 相对路径或 URL
    mime_type  TEXT,                                         -- MIME 类型
    bytes      INTEGER,                                      -- 体积（字节）
    content    TEXT,                                         -- 短文本产物正文
    meta       TEXT,                                         -- JSON 扩展信息
    created_at TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE INDEX IF NOT EXISTS idx_artifacts_task ON artifacts (task_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_step ON artifacts (step_id);

-- ---- 4. 人工确认事件表 ----
-- 每次「把载荷呈现给真人 → 等决定」记一条，payload 存呈现原文，便于事后追溯。
CREATE TABLE IF NOT EXISTS hitl_events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,          -- 事件 ID
    task_id      INTEGER NOT NULL                            -- 所属任务
                 REFERENCES tasks (id) ON DELETE CASCADE,
    step_id      INTEGER                                     -- 关联步骤（可空）
                 REFERENCES task_steps (id) ON DELETE SET NULL,
    artifact_id  INTEGER                                     -- 关联产物（可空）
                 REFERENCES artifacts (id) ON DELETE SET NULL,
    action       TEXT    NOT NULL DEFAULT 'request'          -- 事件类型：请求 / 批准 / 驳回 / 改后再看
                 CHECK (action IN ('request', 'approve', 'reject', 'revise')),
    payload      TEXT,                                       -- 呈现给真人的载荷原文，不改写
    decision     TEXT,                                       -- 决定内容
    reason       TEXT,                                       -- 驳回或修改的原因
    decided_by   TEXT    DEFAULT 'human',                    -- 决定人
    requested_at TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    decided_at   TEXT,                                       -- 决定时间
    created_at   TEXT    NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE INDEX IF NOT EXISTS idx_hitl_events_task   ON hitl_events (task_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS idx_hitl_events_action ON hitl_events (action);

-- ---- 5. 版本表 ----
-- 内容被改写前留快照，可回溯「哪一版、谁改的、为什么改」。
CREATE TABLE IF NOT EXISTS versions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,           -- 版本记录 ID
    entity_type TEXT    NOT NULL DEFAULT 'tasks'             -- 被留痕的表
                CHECK (entity_type IN ('tasks', 'task_steps', 'artifacts')),
    entity_id   INTEGER NOT NULL,                            -- 该表的主键
    version_no  INTEGER NOT NULL DEFAULT 1,                  -- 版本号，同一实体内从 1 递增
    content     TEXT,                                        -- 该版本完整快照
    change_note TEXT,                                        -- 变更说明
    author      TEXT    DEFAULT 'agent',                     -- 改动者：agent / human
    created_at  TEXT    NOT NULL DEFAULT (datetime('now', 'localtime')),
    UNIQUE (entity_type, entity_id, version_no)              -- 同一实体版本号唯一
);

CREATE INDEX IF NOT EXISTS idx_versions_entity ON versions (entity_type, entity_id, version_no DESC);

-- ---- 自动维护 updated_at ----
CREATE TRIGGER IF NOT EXISTS trg_tasks_updated_at
AFTER UPDATE ON tasks
FOR EACH ROW
BEGIN
    UPDATE tasks SET updated_at = datetime('now', 'localtime') WHERE id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_task_steps_updated_at
AFTER UPDATE ON task_steps
FOR EACH ROW
BEGIN
    UPDATE task_steps SET updated_at = datetime('now', 'localtime') WHERE id = OLD.id;
END;
