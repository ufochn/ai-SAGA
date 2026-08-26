#!/usr/bin/env python3
"""向 fiction_script 插入第一个脚本（id=1）的第一章正文与两个选项。"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")

CHAPTER_1 = (
    "开篇必须先在（停尸房被解剖过的尸体、法医尸检或者年代久远设定的时候，"
    "原始尸检现场二选一）看死者的尸体，对话时亮明主角的职业，专门调查鬼杀人的人"
    "（但不要提及任何具体的事务所或侦探社之类的名头，只说主角的职业就行了），"
    "而且主角只接年轻女性委托的鬼案件。单元女主年龄二十多岁，极有异性吸引力，"
    "风格女性的话就熟女，说话风格开放。单元女主对男主有好感，主动行动撩拨男主。"
    "根据给你的核心设定，主角和单元女主赶往死者死亡现场，赶路过程中，单元女主编一段"
    "死亡时在死亡现场外看到听到的可怕异像。两人到达死亡现场，突然现场鬼再次现身并"
    "似乎把单元女主当作杀死前玩弄的猎物，这时候在主角不知情的情况下，单元女主表情或"
    "动作现出杀意，暗示单元女主可能就是鬼。"
)

CHOICE_2 = "相信第三者是鬼"
CHOICE_3 = "不相信第三者是鬼"


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute(
        """INSERT INTO fiction_script
             (id, case_core_prompt,
              chapter_script_1, chapter_script_1_choice_2, chapter_script_1_choice_3)
           VALUES (?, '', ?, ?, ?)""",
        (1, CHAPTER_1, CHOICE_2, CHOICE_3),
    )
    conn.commit()

    row = cur.execute(
        """SELECT id, case_core_prompt,
                  chapter_script_1, chapter_script_1_choice_2, chapter_script_1_choice_3
           FROM fiction_script WHERE id=1"""
    ).fetchone()
    print("插入成功：")
    print("id:", row[0])
    print("case_core_prompt:", repr(row[1]))
    print("chapter_script_1 长度:", len(row[2]))
    print("chapter_script_1 前 40 字:", row[2][:40])
    print("chapter_script_1_choice_2:", row[3])
    print("chapter_script_1_choice_3:", row[4])
    conn.close()


if __name__ == "__main__":
    main()
