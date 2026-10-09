#!/usr/bin/env python3
"""把 db/app.db 的 tasks 表导出成 dashboard/data.js，供 dashboard/index.html 离线读取。

用法（在仓库根目录执行）：
    python3 dashboard/export_tasks.py

产物 data.js 是一个普通脚本，内容是 `window.TASKS_DATA = {...};`，
因此 index.html 用 <script src="data.js"> 加载即可——直接双击打开也能正常显示，
不受浏览器 file:// 下禁止 fetch 本地文件的限制。
"""

from __future__ import annotations

import datetime as _dt
import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "db" / "app.db"
OUT_PATH = Path(__file__).resolve().parent / "data.js"

# 与 db/schema.sql 中的 tasks 表保持一致
FIELDS = [
    "id",
    "title",
    "platform",
    "content_type",
    "status",
    "priority",
    "prompt",
    "result",
    "error",
    "scheduled_at",
    "started_at",
    "finished_at",
    "created_at",
    "updated_at",
]


def load_tasks() -> list[dict]:
    # 只读方式打开，避免导出动作意外改动数据库
    con = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    try:
        con.row_factory = sqlite3.Row
        sql = f"SELECT {', '.join(FIELDS)} FROM tasks ORDER BY id DESC"
        return [dict(row) for row in con.execute(sql).fetchall()]
    finally:
        con.close()


def main() -> int:
    if not DB_PATH.exists():
        print(f"[x] 找不到数据库：{DB_PATH}", file=sys.stderr)
        print("    请先执行 db/schema.sql 建表。", file=sys.stderr)
        return 1

    try:
        tasks = load_tasks()
    except sqlite3.Error as exc:
        print(f"[x] 读取 tasks 表失败：{exc}", file=sys.stderr)
        return 1

    payload = {
        "generatedAt": _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "source": "db/app.db",
        "count": len(tasks),
        "tasks": tasks,
    }
    body = json.dumps(payload, ensure_ascii=False, indent=2)
    OUT_PATH.write_text(f"window.TASKS_DATA = {body};\n", encoding="utf-8")

    rel = OUT_PATH.relative_to(ROOT)
    if tasks:
        print(f"[✓] 已导出 {len(tasks)} 条任务 → {rel}")
    else:
        print(f"[✓] tasks 表当前为空，已写出空快照 → {rel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
