#!/usr/bin/env python3
"""创建 AI-SAGA SQLite 数据库（/code/data/ai_saga.db）中的 fiction_script（小说脚本）表。

结构说明（共 62 列）：
- 第 1 列：id（序号），INTEGER PRIMARY KEY，从 1 开始自然数，作为主键
- 第 2 列：case_core_prompt（TEXT），本脚本对应案件核心真相生成提示词
- 第 3..5 列：chapter_script_1, chapter_script_1_choice_2, chapter_script_1_choice_3
- 第 6..8 列：chapter_script_2, chapter_script_2_choice_2, chapter_script_2_choice_3
- ... 三个一组，依次排到 chapter_script_20 共 60 列（20 章 x 3 列）
"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")


def build_columns() -> str:
    """按规则生成 62 列定义（第一列 id 主键，第二列 case_core_prompt）。"""
    cols = ["id INTEGER PRIMARY KEY", "case_core_prompt TEXT DEFAULT ''"]
    for n in range(1, 21):
        cols.append(f"chapter_script_{n} TEXT DEFAULT ''")
        cols.append(f"chapter_script_{n}_choice_2 TEXT DEFAULT ''")
        cols.append(f"chapter_script_{n}_choice_3 TEXT DEFAULT ''")
    return ",\n    ".join(cols)


CREATE_SQL = f"""
CREATE TABLE fiction_script (
    {build_columns()}
);
"""


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    conn.execute(CREATE_SQL)
    conn.commit()
    print("表 fiction_script 创建完成")
    conn.close()


if __name__ == "__main__":
    main()
