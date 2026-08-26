#!/usr/bin/env python3
"""修正：把 completed_script_ids / current_script_id 两列
从 fiction_script 表移到 story_segments 表（均 TEXT DEFAULT ''）。
"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    # 1) 从 fiction_script 删除
    cur.execute("ALTER TABLE fiction_script DROP COLUMN completed_script_ids")
    cur.execute("ALTER TABLE fiction_script DROP COLUMN current_script_id")
    print("已从 fiction_script 删除两列")

    # 2) 加到 story_segments
    cur.execute(
        "ALTER TABLE story_segments ADD COLUMN completed_script_ids TEXT DEFAULT ''"
    )
    cur.execute(
        "ALTER TABLE story_segments ADD COLUMN current_script_id TEXT DEFAULT ''"
    )
    print("已向 story_segments 新增两列")

    conn.commit()

    # 校验
    for t in ("fiction_script", "story_segments"):
        cur.execute(f"PRAGMA table_info({t})")
        cols = cur.fetchall()
        names = [c[1] for c in cols]
        print(
            f"  {t}: 列数={len(cols)}，"
            f"含 completed_script_ids={ 'completed_script_ids' in names }，"
            f"含 current_script_id={ 'current_script_id' in names }"
        )

    conn.close()


if __name__ == "__main__":
    main()
