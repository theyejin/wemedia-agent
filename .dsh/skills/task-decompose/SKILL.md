---
name: task-decompose
description: 把一个笼统的自媒体内容目标拆成可独立执行、可发布的内容任务，并写入 db/app.db 的 tasks 表。当用户说「帮我拆解任务」「把选题排成计划」「本周要做 N 条内容」「生成发布排期」，或需要把一句模糊需求（例如「给小红书做美妆短视频」）变成带平台、内容类型、优先级与时间安排的任务清单时使用。Use when a vague content goal must become a concrete, executable task list persisted to the tasks table.
whenToUse: 用户给出笼统的内容目标，需要产出可执行的任务清单并落库时。
---

# 任务拆解（task-decompose）

把「一句话目标」变成 `tasks` 表里一行行可执行的任务。

## 一条任务是什么

**一个任务 = 一条可独立发布的内容。** 不是执行步骤。

- 是：`小红书 · 早C晚A护肤误区 · 视频`
- 不是：`写标题`、`找素材`、`写正文` —— 这些是同一条任务内部的执行步骤，不单独占一行。

## 前置检查（先做，不要跳过）

```bash
cd <工作区根目录>
sqlite3 db/app.db ".tables"                       # 应看到 tasks
sqlite3 db/app.db "PRAGMA table_info(tasks);"     # 确认列与约束
```

若 `tasks` 不存在，先执行 `db/schema.sql` 建表，不要自己另建一套结构。

> **注意**：dsh-sql 插件的默认连接是 `:memory:` 内存库，用 `sql_exec` 写进去的数据不会落盘。
> 除非已确认插件配置指向本文件的连接，否则**一律用 `sqlite3 db/app.db` 命令行读写**。

## 字段约定

写入前逐字段确认。任何一个越界都会让整条 INSERT 失败：

| 字段 | 约束 | 约定 |
| :-- | :-- | :-- |
| `platform` | 自由文本 | 固定用英文标识：`douyin` / `xiaohongshu` / `wechat` / `bilibili` / `general`。不要中英混用，否则按平台筛选会漏 |
| `content_type` | 仅 `article` / `video` / `image` | 越界直接触发 CHECK 失败 |
| `status` | 仅 `pending` / `running` / `done` / `failed` / `cancelled` | 新建任务**不要显式写**，用默认 `pending` |
| `priority` | 1–5 整数 | 1 最高。按「时效紧 + 阻塞他人」排，**不要全填 3** |
| `title` | 非空 | 写成「平台 · 主题 · 形式」，一眼可辨、彼此不重复 |
| `prompt` | 可为空 | **写清楚**：受众、核心卖点、调性、时长或字数、必须包含的信息、禁止出现的信息。下游 `mock-copy-generate` 直接吃这个字段 |
| `scheduled_at` | `YYYY-MM-DD HH:MM:SS` | 与 `created_at` 同格式（本地时间） |

## 执行步骤

1. **抽取要素**：从目标里取出平台、内容类型、数量、时间窗、硬性约束。
2. **缺关键信息就问，不要默认**。数量、截止时间、目标平台这三项只要缺一项，就先问清楚再拆 —— 猜错会让整批任务作废。注意别和用户已经说过的信息重复确认。
3. **做可行性校验**：拿数量和可用时间窗对一下。例如「3 天内出 10 条原创视频」不现实，直接指出并给出可行区间，不要闷头生成一张做不到的清单。
4. **先给清单草稿**：列成表格（序号 / 平台 / 形式 / 标题 / 优先级 / 计划时间），让用户确认或调整。**确认后再写库**。
5. **批量写入**：用事务一次插入，记下新任务 id。
6. **回读自检**（见下）。

## 写入 SQL

```sql
BEGIN;
INSERT INTO tasks (title, platform, content_type, priority, prompt, scheduled_at) VALUES
  ('小红书 · 早C晚A护肤误区 · 视频', 'xiaohongshu', 'video', 1,
   '受众：22-30岁女性；卖点：拆解三个常见误区；调性：专业但口语化；时长 60-90 秒；必须包含：成分浓度建议；禁止：绝对化疗效承诺',
   '2026-10-10 19:00:00'),
  ('抖音 · 换季敏感肌急救 · 视频', 'douyin', 'video', 2,
   '受众：敏感肌人群；卖点：三步急救法；调性：快节奏；时长 30-45 秒；禁止：医疗诊断表述',
   '2026-10-11 12:00:00');
COMMIT;
```

## 自检

```sql
SELECT COUNT(*) AS 新增数量 FROM tasks
WHERE status = 'pending' AND date(created_at) = date('now','localtime');

SELECT id, title, platform, content_type, priority, status
FROM tasks ORDER BY id DESC LIMIT 10;
```

逐项确认：数量与清单一致、`status` 均为 `pending`、`content_type` 与 `priority` 没有越界、`prompt` 非空。

## 反模式

- ❌ 把一条内容拆成「写标题 / 写正文 / 配图」多行 —— 那是执行步骤，会污染任务表
- ❌ `platform` 一会儿写「小红书」一会儿写 `xiaohongshu`
- ❌ `priority` 全部填 3，等于没有优先级
- ❌ 顺手把 `status` 写成 `pending` 之外的值，或自己编一个 `waiting`
- ❌ 编造计划发布时间，不跟用户确认档期
- ❌ 数量或截止时间没问清就开工

## 交接

拆解完成后，内容生成交给 `mock-copy-generate`，发布前的人工确认交给 `hitl-wait`。
