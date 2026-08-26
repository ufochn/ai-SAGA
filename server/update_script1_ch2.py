#!/usr/bin/env python3
"""向 fiction_script 脚本1（id=1）原样写入第二章脚本与两个选项（不二创）。"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")

CHAPTER_2 = """这是一本互动小说，现在读者对后续剧情的发展要求是：“我喜欢米老鼠”。读者的输入你不可以绕开，想办法不崩逻辑的情况下，将读者的情节发展要求融入下面的剧情：详细搜查案发现场，将大纲中提到的案发现场细节搜查出来。他们发现死者疯狂的日记。这时候女主提及死者曾经拉住女主的手大喊自己会死于女主之手。
女主突然不对劲，似乎被附身，开始用杀死死者的方法对付主角。主角怎么努力也不能让女主摆脱附身，直到主角采取了超常规行动（你编一个），女主才摆脱附身回来。"""

CHOICE_2 = "转身逃离"
CHOICE_3 = "和鬼对抗"


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute(
        """UPDATE fiction_script
              SET chapter_script_2=?,
                  chapter_script_2_choice_2=?,
                  chapter_script_2_choice_3=?
            WHERE id=1""",
        (CHAPTER_2, CHOICE_2, CHOICE_3),
    )
    conn.commit()

    row = cur.execute(
        """SELECT chapter_script_2,
                  chapter_script_2_choice_2, chapter_script_2_choice_3
           FROM fiction_script WHERE id=1"""
    ).fetchone()
    print("更新成功：")
    print("chapter_script_2 长度:", len(row[0]))
    print("chapter_script_2 内容:")
    print(row[0])
    print("chapter_script_2_choice_2:", row[1])
    print("chapter_script_2_choice_3:", row[2])
    conn.close()


if __name__ == "__main__":
    main()
