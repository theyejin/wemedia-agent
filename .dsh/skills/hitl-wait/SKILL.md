---
name: hitl-wait
description: 在任何不可逆动作（发布、发送、删除、外部写入）之前暂停，把待执行内容完整呈现给真人，等待明确确认后才继续。当用户说「发布前让我确认」「这条先给我看」「等我点头再发」，或流程即将产生对外、不可撤销的影响时使用。Use before any irreversible or externally visible action, to require explicit human approval and never treat silence as consent.
whenToUse: 流程即将执行不可逆或对外可见的动作，必须由真人明确放行时。
---

# 人工确认等待（hitl-wait）

在不可逆动作之前把流程**停住**，等真人明确点头。

## 硬性规则（不可协商）

1. **沉默不是同意。** 没收到明确的肯定答复，一律视为未批准，绝不继续。
2. **绝不自动放行。** 不因为超时、轮询次数或重试次数到期而批准，也不因为「看起来没问题」而批准。
3. **绝不代替用户回答。** 不编造「用户已确认」，不把模型自己的判断当成用户的意思。
4. **一次只问一个决定。** 不要在一条消息里塞多个待确认项，让人分不清批准了哪个。
5. **被拒后不要原样重问。** 同一问题连续被驳回，就换方案、缩小范围或升级给人，而不是重复追问。
6. **等待期间零副作用。** 不发请求、不写库、不产生任何对外动作。

## 何时必须用

- 发布内容到任何平台（含模拟文案的演练发布）
- 对外发送：邮件、消息、评论、私信
- 删除或覆盖已有数据、文件、线上配置
- 任何花钱或不可撤回的操作
- 用户明确要求「先给我看」的环节

内部只读查询、草稿生成不需要走这里。

## 状态约定（重要）

`tasks.status` 的 CHECK 约束只有 `pending` / `running` / `done` / `failed` / `cancelled`，**没有 `waiting`**。
所以等待期间**保持 `running`**，用「已生成 `result` 但未置 `done`」表示待确认。

> 若要把「等待人工」持久化成独立状态，需要迁移 CHECK 约束（SQLite 改 CHECK 必须重建表）：
>
> ```sql
> BEGIN;
> ALTER TABLE tasks RENAME TO tasks_old;
> CREATE TABLE tasks ( /* 与原表一致，status 改为含 'waiting' */
>   status TEXT NOT NULL DEFAULT 'pending'
>     CHECK (status IN ('pending','running','waiting','done','failed','cancelled'))
>   /* ...其余列照抄原定义... */
> );
> INSERT INTO tasks SELECT * FROM tasks_old;
> DROP TABLE tasks_old;
> COMMIT;
> ```
>
> 迁移前务必先备份 `db/app.db`。

## 执行步骤

1. **读回待确认内容**：从库里取真实载荷，不要凭记忆复述。
2. **组一段可核对的摘要**，必须包含：
   - 将执行什么动作、发往哪个平台或对象
   - **完整载荷原文**（不改写、不摘要、不美化）
   - 是否可逆、影响范围
   - 该动作后任务会变成什么状态
3. **提一个决定**，用 `ask_user_question`，选项固定三项：`批准执行` / `驳回` / `修改后再看`。
4. **等待**。不要在同一轮里既问又做。
5. **按结果分支**：
   - **批准** → 执行动作 → `status='done'`、`finished_at=datetime('now','localtime')`
   - **驳回** → 不执行 → `status='failed'`、`error` 写明驳回原因 → 把原因回报用户
   - **修改后再看** → 按反馈改 `result`，**重新从第 2 步走一遍**（改完必须重新完整呈现）
   - **没有任何回复** → 停在 `running`，不做任何推进；明确告诉用户「已暂停，等你确认」以及如何恢复
6. **记录决定**，让后续可追溯。

## SQL

```sql
-- 批准
UPDATE tasks SET status='done', finished_at=datetime('now','localtime')
WHERE id = <ID> AND status = 'running';

-- 驳回
UPDATE tasks SET status='failed', error='人工驳回：<原因>'
WHERE id = <ID> AND status = 'running';
```

`WHERE status='running'` 是保护条件：状态若已被改动，UPDATE 影响 0 行。**必须检查影响行数**，为 0 说明状态漂移了，先查清再动。

## 自检

```sql
SELECT id, status, finished_at, error FROM tasks WHERE id = <ID>;
```

确认终态与人的决定一致：批准 → `done` 且 `finished_at` 非空；驳回 → `failed` 且 `error` 写明了原因。

## 反模式

- ❌ 把「用户没回」当默认同意
- ❌ 用超时兜底自动放行
- ❌ 摘要式呈现载荷、替用户省略细节（他批准的是你展示的那份）
- ❌ 被驳回后原样重问
- ❌ 等待期间顺手做了写库或对外调用

## 交接

`mock-copy-generate` 生成的文案（含模拟文案）在发布前都应经过本 skill。
