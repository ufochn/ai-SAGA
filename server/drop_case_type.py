#!/usr/bin/env python3
"""从 story_segments 表删除 case_type 列。"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute("ALTER TABLE story_segments DROP COLUMN case_type")
    conn.commit()

    cur.execute("PRAGMA table_info(story_segments)")
    cols = cur.fetchall()
    print(f"story_segments 列数: {len(cols)}")
    print("列:", [c[1] for c in cols])
    conn.close()


if __name__ == "__main__":
    main()
