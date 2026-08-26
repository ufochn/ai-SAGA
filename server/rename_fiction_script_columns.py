#!/usr/bin/env python3
"""一次性脚本：把 fiction_script 表中所有章节列重命名：
  chapter_N        -> chapter_script_N
  chapter_N_choice_1 -> chapter_script_N_choice_1
  chapter_N_choice_2 -> chapter_script_N_choice_2
（N = 1..20，共 60 列；id 主键列不变）
"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    for n in range(1, 21):
        for suffix in ("", "_choice_1", "_choice_2"):
            old = f"chapter_{n}{suffix}"
            new = f"chapter_script_{n}{suffix}"
            cur.execute(f'ALTER TABLE fiction_script RENAME COLUMN "{old}" TO "{new}"')
            print(f"    {old} -> {new}")

    conn.commit()
    print("重命名完成")
    conn.close()


if __name__ == "__main__":
    main()
