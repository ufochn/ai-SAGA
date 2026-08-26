#!/usr/bin/env python3
"""最终校验：fiction_script 与 story_segments 两表结构。"""

import sqlite3

conn = sqlite3.connect("/code/data/ai_saga.db")
cur = conn.cursor()

for t in ("fiction_script", "story_segments"):
    cur.execute(f"PRAGMA table_info({t})")
    cols = cur.fetchall()
    print(f"=== {t}（{len(cols)} 列）===")
    for c in cols:
        pk = " PK" if c[5] else ""
        print(f"  {c[1]:<28} {c[2]:<10}{pk}")
    print()

conn.close()
