#!/usr/bin/env python3
"""显示 fiction_script 表每列的名称与类型。"""

import sqlite3

conn = sqlite3.connect("/code/data/ai_saga.db")
cur = conn.cursor()
cur.execute("PRAGMA table_info(fiction_script)")
cols = cur.fetchall()
print(f"共 {len(cols)} 列：")
for c in cols:
    # (cid, name, type, notnull, dflt_value, pk)
    print(f"  {c[1]:<32} type={c[2]!r:<12} pk={c[5]} default={c[4]!r}")
conn.close()
