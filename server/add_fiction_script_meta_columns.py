#!/usr/bin/env python3
"""给 fiction_script 表新增两列（均为 TEXT/string）：
  completed_script_ids  TEXT  -- 已经完整运行过的脚本编号集合（如 "1,2,3"）
  current_script_id     TEXT  -- 当前脚本序号（如 "1"）
"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")


def main() -> None:
    print(f"[1/2] 连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    print("[2/2] 新增列：")
    cur.execute(
        "ALTER TABLE fiction_script ADD COLUMN completed_script_ids TEXT DEFAULT ''"
    )
    print("    completed_script_ids TEXT DEFAULT ''  (已经完整运行过的脚本编号集合)")
    cur.execute(
        "ALTER TABLE fiction_script ADD COLUMN current_script_id TEXT DEFAULT ''"
    )
    print("    current_script_id TEXT DEFAULT ''     (当前脚本序号)")

    conn.commit()

    cur.execute("PRAGMA table_info(fiction_script)")
    cols = cur.fetchall()
    print(f"迁移完成，当前列数: {len(cols)}（应为 63）")
    for c in cols:
        if c[1] in ("completed_script_ids", "current_script_id", "id"):
            print(f"  {c[1]:<22} type={c[2]!r} default={c[4]!r}")

    conn.close()


if __name__ == "__main__":
    main()
