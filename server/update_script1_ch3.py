#!/usr/bin/env python3
"""向 fiction_script 脚本1（id=1）原样写入第三章脚本，choice2/choice3 保持空白（不二创）。"""

import os
import sqlite3

DB_PATH = os.environ.get("DB_PATH", "/code/data/ai_saga.db")

CHAPTER_3 = """这是一本互动小说，现在读者对后续剧情的发展要求是：“我喜欢米老鼠”。读者的输入你不可以绕开，想办法不崩逻辑的情况下，将读者的情节发展要求融入下面的剧情：主角进入（几选一：昏迷、梦境、幻觉）被引导到某个（荒村、荒废的女主和女鬼就读过的学校，或者什么合理但更恐怖的场所），主角赶到那里，看到被杀死的人和女主发生冲突（冲突的内容你随便编，让她们俩的关系显得爱恨纠缠，女主有杀人动机也显得合理，女主真的为死者担心也显得合理）。这时候，女主再次出现，被鬼附身，打昏男主。男主再次昏迷中出现梦境，看到鬼以前的残躯埋藏在某处。男主决定去那里。本段结束。"""

CHOICE_2 = ""
CHOICE_3 = ""


def main() -> None:
    print(f"连接数据库: {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    cur.execute(
        """UPDATE fiction_script
              SET chapter_script_3=?,
                  chapter_script_3_choice_2=?,
                  chapter_script_3_choice_3=?
            WHERE id=1""",
        (CHAPTER_3, CHOICE_2, CHOICE_3),
    )
    conn.commit()

    row = cur.execute(
        """SELECT chapter_script_3,
                  chapter_script_3_choice_2, chapter_script_3_choice_3
           FROM fiction_script WHERE id=1"""
    ).fetchone()
    print("更新成功：")
    print("chapter_script_3 长度:", len(row[0]))
    print("chapter_script_3 内容:")
    print(row[0])
    print("chapter_script_3_choice_2:", repr(row[1]))
    print("chapter_script_3_choice_3:", repr(row[2]))
    conn.close()


if __name__ == "__main__":
    main()
