#!/usr/bin/env python3
"""验证 completed_script_ids 新更新规则（追平最大值 / 已是最大则 +1）。"""

import re


def parse(s: str) -> dict:
    d = {}
    for m in re.finditer(r"(\d+)\((\d+)\)", s or ""):
        d[int(m.group(1))] = int(m.group(2))
    return d


def ser(d: dict) -> str:
    return "".join(f"{k}({v})" for k, v in d.items())


def update(tally: dict, sid: int) -> dict:
    cur = tally.get(sid, 0)
    mx = max((v for k, v in tally.items() if k != sid), default=0)
    if cur < mx:
        tally[sid] = mx
    else:
        tally[sid] = cur + 1
    return tally


base = "2(1)1(4)3(3)5(3)"
print("基准:", base)
for sid in (2, 3, 5, 1, 6):
    print(f"脚本 {sid} 结束 ->", ser(update(parse(base), sid)))

print("空表 脚本1 结束 ->", ser(update(parse(""), 1)))
print("单脚本1(3) 结束 ->", ser(update(parse("1(3)"), 1)))
