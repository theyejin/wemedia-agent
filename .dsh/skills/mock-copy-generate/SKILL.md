---
name: mock-copy-generate
description: 为 tasks 表里的待办任务生成结构合规的模拟文案，用于端到端流程演练或真实生成能力接入前的占位，产物写入 tasks.result。当用户说「先用假文案跑一遍流程」「生成模拟文案」「占位内容先占上」「测一下发布链路」，或需要在没有真实素材与外部 API 的情况下验证管线时使用。Use when a pipeline needs structurally valid placeholder copy, clearly marked as mock, instead of real published content.
whenToUse: 需要用占位文案演练或验证流程，而不是产出可发布真内容时。
---

# 模拟文案生成（mock-copy-generate）

产出**结构正确、格式合规、但明确标记为模拟**的文案，让流程能跑通。

## 这不是什么

这个 skill **不产出可发布的内容**。它产出占位文案，用途是：

- 真实生成能力（模型、素材库、外部 API）还没接上，先把链路打通
- 验证发布前的确认、排期、审核环节是否正常
- 给前端或下游做展示用的样例数据

**要真内容，不要用这个 skill。**

## 硬性规则（安全红线，不可协商）

1. **首行必须是标记**：`【模拟文案 · 不可直接发布】`。固定在正文第一行，不允许放末尾、不允许省略。
2. **不得编造事实性数据**：销量、用户评价、复购率、专家背书、检测报告、临床结论、具体价格 —— 一律不许写。占位处用 `〔待填：…〕`。
3. **不得冒用真实主体**：真实品牌名、真人姓名、机构名、直播间名，一律用 `〔品牌〕`、`〔达人〕` 这类占位符。
4. **不得规避标记**：不允许以「看起来更真实」为由去掉或弱化标记。下游若把模拟文案误当终稿发出去，这是最严重的事故。

## 前置检查

```bash
cd <工作区根目录>
sqlite3 db/app.db "SELECT id,title,platform,content_type,status,prompt FROM tasks WHERE id=<ID>;"
```

**状态校验**：只处理 `status='pending'` 或 `status='failed'`（重试）的任务。
`done` 是已定稿、`running` 是已生成待确认 —— **都不要覆盖**，避免把已定稿的内容冲掉。

> dsh-sql 插件默认连接是 `:memory:` 内存库，写入不会落盘。**用 `sqlite3 db/app.db` 命令行读写。**

## 平台结构模板

按 `platform` 选结构，`content_type` 决定体裁：

| 平台 | 结构 |
| :-- | :-- |
| `xiaohongshu` | 标题 ≤ 20 字（带 1-2 个 emoji）→ 正文分段 → 3-6 个话题标签 |
| `douyin` | 口播脚本：`【0-3s 钩子】`、`【3-15s 展开】`、`【15-30s 收尾+引导】`，逐段写画面与口播 |
| `wechat` | 标题 → 导语 → 2-4 个小标题段落 → 结尾引导 |
| `bilibili` | 标题（≤ 30 字）→ 简介（2-3 句）→ 分段大纲 |
| `general` | 标题 + 正文 + 可选标签 |

长度：`article` 400-800 字；`video` 按脚本分段写满时长；`image` 图注 20-50 字。

内容取材自 `prompt` 字段的 brief（受众、卖点、调性、必须包含、禁止出现）。**brief 里禁止的东西一条都不能出现。**

## 执行步骤

1. 按上面读任务并做状态校验。
2. 按平台结构生成模拟文案：首行加标记，事实性内容用 `〔待填：…〕` 占位。
3. 写入库：置 `running`、记 `started_at`、把文案写进 `result`。
4. 检查 UPDATE 影响行数。
5. 回读确认。
6. 交 `hitl-wait` 走人工确认；确认通过后才置 `done`。

## 写入 SQL

```sql
UPDATE tasks
SET status = 'running',
    started_at = datetime('now','localtime'),
    result = '【模拟文案 · 不可直接发布】
标题：换季烂脸自救〔待填：产品名〕
【0-3s】〔待填：钩子口播〕
【3-15s】〔待填：三步急救法展开〕
【15-30s】〔待填：引导互动〕'
WHERE id = <ID> AND status IN ('pending','failed');
```

`WHERE status IN (...)` 是并发保护：若期间状态被别人改了，这条 UPDATE 影响 0 行。**必须检查影响行数**，别当成功。

`updated_at` 由触发器自动维护，不要手写。

## 自检

```sql
SELECT id, status,
       (result LIKE '【模拟文案%') AS 标记在首行,
       (result LIKE '%〔待填%')   AS 含占位符,
       length(result)             AS 文案长度
FROM tasks WHERE id = <ID>;
```

确认：`status='running'`、`标记在首行 = 1`、无编造数据。

## 反模式

- ❌ 去掉或弱化模拟标记
- ❌ 编造销量、评价、专家、价格等事实性内容
- ❌ 覆盖 `done` 状态已定稿的文案
- ❌ 不检查 UPDATE 影响行数就当写成功
- ❌ 把模拟文案直接交给发布环节（必须先过 `hitl-wait`）

## 交接

生成后交给 `hitl-wait` 做人工确认 —— 模拟文案尤其不能被自动放行。
