#!/usr/bin/env python3
"""校验 fiction_script 表最终结构（列名、列数、主键）。"""

import sqlite3

conn = sqlite3.connect("/code/data/ai_saga.db")
cur = conn.cursor()
cur.execute("PRAGMA table_info(fiction_script)")
cols = cur.fetchall()
names = [c[1] for c in cols]

print("列数:", len(cols), "（应为 61）")
print("主键:", [c[1] for c in cols if c[5] > 0], "（应为 ['id']）")

bad = [n for n in names if n != "id" and not n.startswith("chapter_script_")]
print("不符合新命名的列:", bad if bad else "无（全部符合 chapter_script_*）")

missing_chapters = [i for i in range(1, 21) if f"chapter_script_{i}" not in names]
missing_choice1 = [
    i for i in range(1, 21) if f"chapter_script_{i}_choice_1" not in names
]
missing_choice2 = [
    i for i in range(1, 21) if f"chapter_script_{i}_choice_2" not in names
]
print("缺失的 chapter_script_N 列:", missing_chapters if missing_chapters else "无")
print("缺失的 chapter_script_N_choice_1 列:", missing_choice1 if missing_choice1 else "无")
print("缺失的 chapter_script_N_choice_2 列:", missing_choice2 if missing_choice2 else "无")

print("前 4 列:", names[:4])
print("最后 3 列:", names[-3:])
conn.close()
