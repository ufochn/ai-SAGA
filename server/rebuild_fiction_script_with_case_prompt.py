#!/usr/bin/env python3
"""给 fiction_script 表新增第二列 case_core_prompt（TEXT，本脚本对应案件核心真相生成提示词），
其余列全部后移一列。新项目：直接重建表，不做历史数据迁移。

新结构（共 62 列）：
  id, case_core_prompt, chapter_script_1, chapter_script_1_choice_1,
  chapter_script_1_choice_2, ..., chapter_script_20, chapter_script_20_choice_1,
  chapter_script_20_choice_2
"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")


def build_chapter_cols() -> list:
    """20 章 x 3 列的全部章节列名（不含 id / case_core_prompt）。"""
    cols = []
    for n in range(1, 21):
        cols.append(f"chapter_script_{n}")
        cols.append(f"chapter_script_{n}_choice_1")
        cols.append(f"chapter_script_{n}_choice_2")
    return cols


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    chapter_cols = build_chapter_cols()
    create_cols = (
        ["id INTEGER PRIMARY KEY", "case_core_prompt TEXT DEFAULT ''"]
        + [f"{c} TEXT DEFAULT ''" for c in chapter_cols]
    )
    create_sql = (
        "DROP TABLE fiction_script;\n"
        "CREATE TABLE fiction_script (\n    " + ",\n    ".join(create_cols) + "\n);"
    )
    cur.executescript(create_sql)
    conn.commit()

    cur.execute("PRAGMA table_info(fiction_script)")
    cols = cur.fetchall()
    print(f"列数: {len(cols)}（应为 62）")
    print("前 4 列:", [c[1] for c in cols[:4]])
    print("最后 3 列:", [c[1] for c in cols[-3:]])
    conn.close()


if __name__ == "__main__":
    main()
