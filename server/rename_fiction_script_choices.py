#!/usr/bin/env python3
"""把 fiction_script 表的 choice 列改名（N=1..20，共 40 列）：
  chapter_script_N_choice_1 -> chapter_script_N_choice_2
  chapter_script_N_choice_2 -> chapter_script_N_choice_3

先 rename _choice_2 -> _choice_3，再 rename _choice_1 -> _choice_2，
避免目标列名冲突。
"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    for n in range(1, 21):
        cur.execute(
            f'ALTER TABLE fiction_script RENAME COLUMN "chapter_script_{n}_choice_2" '
            f'TO "chapter_script_{n}_choice_3"'
        )
        cur.execute(
            f'ALTER TABLE fiction_script RENAME COLUMN "chapter_script_{n}_choice_1" '
            f'TO "chapter_script_{n}_choice_2"'
        )
    conn.commit()

    cur.execute("PRAGMA table_info(fiction_script)")
    cols = cur.fetchall()
    print("列数:", len(cols))
    print(
        "chapter_script_1 相关列:",
        [c[1] for c in cols if c[1].startswith("chapter_script_1")],
    )
    print(
        "chapter_script_2 相关列:",
        [c[1] for c in cols if c[1].startswith("chapter_script_2")],
    )
    conn.close()


if __name__ == "__main__":
    main()
