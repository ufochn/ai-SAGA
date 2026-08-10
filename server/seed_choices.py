#!/usr/bin/env python3
"""为 story_segments 的 choice_1/2/3 随机填充内容（测试用）。

用法：
    python3 seed_choices.py [数据库路径]

- 默认数据库路径：./data/ai_saga.db（与服务器 DATA_DIR 一致）
- 为每一段随机填充 3 个行动指令（每个 <= 70 字符），
  并随机留几段完全空白（最多 3 段，至少 1 段），便于观察空态效果。
- 幂等：重复运行会重新随机填充。
"""
import random
import sqlite3
import sys

DEFAULT_DB = "./data/ai_saga.db"


def _make_action() -> str:
    # 中性动作指令：不绑定具体剧情/人物，适配任意场景（仅用于查看 UI 效果）
    subjects = ["你", "主角", "二人", "一行人", "同伴"]
    verbs = [
        "继续前行", "停下脚步", "环顾四周", "压低声音询问", "打开房门", "走向前方",
        "转身离开", "侧耳倾听", "沿着路走下去", "上前搭话", "仔细观察", "跟上前去",
        "驻足思考", "试探着接近", "小心藏好", "拨开人群", "放慢脚步", "打量四周",
    ]
    objects = [
        "寻找线索", "确认周围的动静", "打听消息", "查看那个可疑的人", "观察街角的情况",
        "寻找出口", "询问路人", "检查身上的物品", "回忆刚才的细节", "找到同伴",
        "判断危险的方向", "留意身后的脚步声", "看看附近有没有人", "确认下一步的路线",
    ]
    tail = ["，小心为上。", "，切勿声张。", "，见机行事。", "，随后再作打算。", "，留意四周。", ""]
    while True:
        s = (
            f"{random.choice(subjects)}{random.choice(verbs)}"
            f"{random.choice(objects)}{random.choice(tail)}"
        )
        if len(s) <= 70:
            return s


def main() -> None:
    db = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DB
    conn = sqlite3.connect(db, timeout=15)
    conn.row_factory = sqlite3.Row
    try:
        has = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='story_segments'"
        ).fetchone()
        if not has:
            print(f"错误：{db} 中没有 story_segments 表（可能服务器还没跑过最新 schema，或这是空库）。")
            print("请先在服务器上以最新代码启动一次（会自动建表），或换用真实数据库路径。")
            return
        rows = conn.execute("SELECT id, seq FROM story_segments ORDER BY seq").fetchall()
        ids = [r["id"] for r in rows]
        if not ids:
            print(f"{db} 中 story_segments 为空（没有任何小说段），无需填充。")
            return
        print(f"总段数: {len(ids)}")
        blank_count = max(1, min(3, len(ids)))
        blank_ids = set(random.sample(ids, k=blank_count))
        print(f"留空段: {sorted(blank_ids)}")
        for rid in ids:
            if rid in blank_ids:
                conn.execute(
                    "UPDATE story_segments SET choice_1='', choice_2='', choice_3='' WHERE id=?",
                    (rid,),
                )
            else:
                conn.execute(
                    "UPDATE story_segments SET choice_1=?, choice_2=?, choice_3=? WHERE id=?",
                    (_make_action(), _make_action(), _make_action(), rid),
                )
        conn.commit()
        over = [
            r
            for r in conn.execute(
                "SELECT seq, choice_1, choice_2, choice_3 FROM story_segments"
            )
            if any(len(x or "") > 70 for x in (r[1], r[2], r[3]))
        ]
        blank_actual = conn.execute(
            "SELECT COUNT(*) c FROM story_segments WHERE choice_1='' AND choice_2='' AND choice_3=''"
        ).fetchone()[0]
        print(f"填充完成。超 70 字段: {len(over)}；全空白段: {blank_actual}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
