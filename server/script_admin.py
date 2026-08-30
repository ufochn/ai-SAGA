#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI-SAGA 数据库本地管理工具 —— 仅本机 Chrome 可打开，不暴露到互联网。

功能（在原 fiction_script 单表基础上扩展为全部子数据库/表）：
- 在 127.0.0.1 上启动一个只读本机的 HTTP 服务（绑定回环地址，外网无法访问；
  并对请求做 Host / Origin 本地校验，防止 DNS 重绑定 / 跨站请求）。
- 通过 SSH（复用 ~/.ssh/ai_saga_deploy，与 deploy_helper.sh 相同）进入服务器上的
  Docker 容器，用容器内的 python3+sqlite3 读取 / 写入数据库。
- 浏览器打开 http://127.0.0.1:<port> 即可看到顶部「子数据库切换按钮」：
  点击任意按钮，以类似 Excel 的表格展示该表全部数据；每一行都配「保存本行」
  按钮，改完点它即可把本行所有改动格子写回数据库对应行。
- 支持数据库中所有用户表（users / story_segments / fiction_script / ...），
  每行均以 SQLite 内部 rowid 定位，可安全编辑复合主键表、无主键表的所有列。

用法：
    python3 AI-SAGA/server/script_admin.py            # 默认端口 8787
    python3 AI-SAGA/server/script_admin.py 9000       # 指定端口
    AI_SAGA_HOST=... AI_SAGA_USER=... AI_SAGA_SSH_KEY=...   # 可覆盖服务器参数
    AI_SAGA_MAX_ROWS=5000                             # 单表一次最多显示行数

注意：本工具是本地开发工具，不随服务器部署；它不修改任何服务器代码。
"""

import atexit
import base64
import json
import os
import queue
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# ---------------- 服务器连接参数（与 deploy_helper.sh 一致，可用环境变量覆盖） ----------------
HOST = os.environ.get("AI_SAGA_HOST", "")
if not HOST:
    # 自动从同仓库 AI-SAGA/.env 的 AUDIT_API_URL 推导服务器 IP（避免把真实 IP 硬编码进代码库）。
    # 找不到时保持占位符，由用户通过 AI_SAGA_HOST 显式指定。
    _script_dir = os.path.dirname(os.path.abspath(__file__))
    for _rel in ("../.env", "../../AI-SAGA/.env", "./AI-SAGA/.env"):
        _env_path = os.path.join(_script_dir, _rel)
        if not os.path.isfile(_env_path):
            continue
        try:
            for _line in open(_env_path, encoding="utf-8"):
                _line = _line.strip()
                if _line.startswith("AUDIT_API_URL="):
                    _url = _line.split("=", 1)[1].strip().strip('"').strip("'")
                    _m = re.match(r"https?://([^/:]+)", _url)
                    if _m:
                        HOST = _m.group(1)
                        break
        except Exception:
            pass
        if HOST:
            break
if not HOST:
    HOST = "YOUR_SERVER_IP"
USER = os.environ.get("AI_SAGA_USER", "root")
KEY = os.environ.get("AI_SAGA_SSH_KEY", os.path.expanduser("~/.ssh/ai_saga_deploy"))
CONTAINER = os.environ.get("AI_SAGA_CONTAINER", "my-audit-app")
DB_PATH = os.environ.get("AI_SAGA_DB_PATH", "/code/data/ai_saga.db")
TABLE = os.environ.get("AI_SAGA_TABLE", "fiction_script")   # 默认/初始选中的表
MAX_ROWS = int(os.environ.get("AI_SAGA_MAX_ROWS", "2000"))   # 单表一次最多显示行数（防浏览器卡死）
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787

# 各表的友好中文名（用于顶部切换按钮的显示；未列出的表直接显示原名）
TABLE_LABELS = {
    "fiction_script": "小说脚本库 fiction_script",
    "story_segments": "小说正文段 story_segments",
    "story_chapter_distill": "章节人物蒸馏",
    "story_chunk_vectors": "章节向量(只读)",
    "story_character_lookup": "人物反查",
    "users": "用户 users",
    "devices": "设备 devices",
    "entitlements": "权益 entitlements",
    "usage": "用量 usage",
    "sync_data": "云同步 sync_data",
    "challenges": "注册挑战",
    "challenges_guard": "注册限流",
    "hardware_accounts": "硬件账号",
    "rate": "限流 rate",
    "story_usage": "生成调用记录",
    "audit_usage": "审核调用记录",
}

SSH_OPTS = [
    "-i", KEY,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=15",
    "-o", "LogLevel=ERROR",
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3",
]

# 在服务器容器内执行的远端脚本（通过 stdin 喂给 `docker exec -i ... python3 -`）。
# 尾部由本地拼接一行调用，把命令以 base64 形式传入，彻底规避引号/转义问题。
REMOTE_HELPER = r'''
import base64, json, os, sqlite3, sys, unicodedata

DB = __DB_PATH__
DEFAULT_TABLE = __TABLE__
MAX_ROWS = __MAX_ROWS__

def _sanitize(v, ctype):
    # 字节(BLOB)值：转成只读占位文本，防止前端误改二进制向量数据。
    if isinstance(v, bytes):
        return "[BLOB %d bytes]" % len(v)
    if v is None:
        return ""
    return v

def _tables(c):
    cur = c.execute(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    )
    return [r[0] for r in cur.fetchall()]

def _table_info(c, tbl):
    return list(c.execute('PRAGMA table_info("' + tbl + '")'))

# 长文本预览策略：按"显示宽度"取前 30 个字（汉字/全角=2，拉丁字母/数字=1），
# 全文按可见性后台预载。
PREVIEW_UNITS = 30

def _unit_width(ch):
    # 汉字（东亚宽/全角）算 2 个单位，拉丁字母、数字等算 1 个单位
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1

def _text_units(text):
    return sum(_unit_width(ch) for ch in text)

def _preview_text(text, limit=PREVIEW_UNITS):
    # 返回 (预览文本, 是否被截断)；总显示宽度未超限时原样返回。
    if _text_units(text) <= limit:
        return text, False
    units = 0
    out = []
    for ch in text:
        u = _unit_width(ch)
        if units + u > limit:
            break
        units += u
        out.append(ch)
    if not out and text:          # 极端：首个字符超限也至少保留一个
        out = [text[0]]
    return "".join(out), True

def run(op, payload):
    c = sqlite3.connect(DB, timeout=30)
    try:
        if op == "list_tables":
            return {"ok": True, "tables": _tables(c)}

        if op == "read":
            tbl = (payload or {}).get("table") or DEFAULT_TABLE
            info = _table_info(c, tbl)
            if not info:
                return {"ok": False, "error": "表不存在或无列: " + str(tbl)}
            cols = [d[1] for d in info]
            coltypes = [(d[2] or "TEXT").upper() for d in info]
            limit = int((payload or {}).get("limit") or MAX_ROWS)
            if limit <= 0:
                limit = MAX_ROWS
            preview = bool((payload or {}).get("preview"))
            total = c.execute('SELECT COUNT(*) FROM "' + tbl + '"').fetchone()[0]
            # 用内部 rowid 唯一标识每一行：兼容复合主键表、无主键表，且可安全编辑任意列。
            # 排序：优先"最近修改/生成"时间列（updated_at/last_seen_at/created_at/ts…），
            # 其次 date / id，最后按 rowid；一律倒序，保证最新内容排在最上面。
            _TIME_COLS = ("updated_at", "last_seen_at", "modified_at", "created_at", "ts")
            order_col = None
            for _t in _TIME_COLS:
                if _t in cols:
                    order_col = _t
                    break
            if order_col is None and "date" in cols:
                order_col = "date"
            if order_col is None and "id" in cols:
                order_col = "id"
            if order_col is not None:
                order_sql = ' ORDER BY "' + order_col + '" DESC, rowid DESC'
            else:
                order_sql = " ORDER BY rowid DESC"
            cur = c.execute('SELECT rowid, * FROM "' + tbl + '"' + order_sql + ' LIMIT ?', (limit,))
            rows = []
            for r in cur.fetchall():
                rowid = r[0]
                vals = r[1:]
                row = {"__rowid__": rowid}
                _last = None
                _trunc = {}
                for k, v, t in zip(cols, vals, coltypes):
                    sv = _sanitize(v, t)
                    row[k] = sv
                    # 预览模式：长文本只保留前 30 个字，标记该列被截断（全文按可见性预载）
                    if preview and isinstance(sv, str):
                        _pv, _cut = _preview_text(sv)
                        if _cut:
                            row[k] = _pv
                            _trunc[k] = True
                    # 记录本行最新一次生成/修改时间（各时间列取最大值）
                    if k in _TIME_COLS and isinstance(v, (int, float)) and v:
                        _last = v if _last is None else max(_last, v)
                row["__last_time__"] = _last
                row["__trunc__"] = _trunc if _trunc else None
                rows.append(row)
            return {
                "ok": True,
                "columns": cols,
                "types": coltypes,
                "rows": rows,
                "total": total,
                "shown": len(rows),
                "truncated": total > limit,
                "order_by": order_col or "rowid",
                "preview": preview,
            }

        if op == "fetch_full":
            # 按 rowid 批量返回指定行的完整内容（用于可见性后台预载）
            tbl = (payload or {}).get("table") or DEFAULT_TABLE
            rowids = (payload or {}).get("rowids") or []
            info = _table_info(c, tbl)
            if not info:
                return {"ok": False, "error": "表不存在或无列: " + str(tbl)}
            cols = [d[1] for d in info]
            coltypes = [(d[2] or "TEXT").upper() for d in info]
            rows = []
            if rowids:
                marks = ",".join("?" * len(rowids))
                cur = c.execute(
                    'SELECT rowid, * FROM "' + tbl + '" WHERE rowid IN (' + marks + ')',
                    list(rowids),
                )
                for r in cur.fetchall():
                    rowid = r[0]
                    vals = r[1:]
                    row = {"__rowid__": rowid}
                    for k, v, t in zip(cols, vals, coltypes):
                        row[k] = _sanitize(v, t)
                    rows.append(row)
            return {"ok": True, "columns": cols, "types": coltypes, "rows": rows}

        if op == "write":
            tbl = (payload or {}).get("table") or DEFAULT_TABLE
            info = _table_info(c, tbl)
            if not info:
                return {"ok": False, "error": "表不存在或无列: " + str(tbl)}
            allowed = [d[1] for d in info]
            n = 0
            for u in (payload or {}).get("updates") or []:
                col = u.get("column")
                val = u.get("value")
                rid = u.get("rowid")
                if col not in allowed:
                    continue
                c.execute('UPDATE "' + tbl + '" SET "' + col + '"=? WHERE rowid=?', (val, rid))
                n += 1
            c.commit()
            return {"ok": True, "updated": n}

        return {"ok": False, "error": "unknown op: " + str(op)}
    except Exception as e:
        return {"ok": False, "error": repr(e)}
    finally:
        c.close()

# 常驻循环：从 stdin 逐行读取命令，处理完把单行 JSON 写回 stdout。
# 这样整条 SSH→docker exec→python 链路只建立一次，之后每次请求只是
# 一次进程内 IPC（毫秒级），不再每请求都重新做 SSH 握手 + 登录 shell +
# docker exec + python 启动（这些每次要 6~10 秒）。
for _line in sys.stdin:
    _line = _line.strip()
    if not _line:
        continue
    try:
        _op, _b64 = _line.split(" ", 1)
        _payload = json.loads(base64.b64decode(_b64).decode("utf-8"))
        _resp = run(_op, _payload)
    except Exception as _e:
        _resp = {"ok": False, "error": repr(_e)}
    print(json.dumps(_resp, ensure_ascii=False), flush=True)
'''.replace("__DB_PATH__", repr(DB_PATH)) \
    .replace("__TABLE__", repr(TABLE)) \
    .replace("__MAX_ROWS__", str(MAX_ROWS))


class _RemoteWorker:
    """常驻远端 worker：只建立一次 SSH→docker exec→python 链路并保持打开，
    之后每次请求往其 stdin 写一行命令、从 stdout 读一行 JSON，避免每请求都重新连接。"""

    def __init__(self):
        self.proc = None
        self._lock = threading.Lock()
        self._stderr_q = queue.Queue()

    def _ensure(self):
        if self.proc is not None and self.proc.poll() is None:
            return
        # 把远端循环脚本 base64 编码后经 -c 传入，stdin 留给逐条命令（毫秒级 IPC）。
        # python3 -u -c "import base64;exec(base64.b64decode('...'))" 之后，
        # 脚本内 from sys.stdin 逐行读取命令；stdin 不再被当脚本消费。
        _b64 = base64.b64encode(REMOTE_HELPER.encode("utf-8")).decode("ascii")
        cmd = [
            "ssh", *SSH_OPTS,
            "%s@%s" % (USER, HOST),
            "docker exec -i %s python3 -u -c \"import base64;exec(base64.b64decode('%s'))\""
            % (CONTAINER, _b64),
        ]
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        except FileNotFoundError:
            raise RuntimeError("找不到 ssh 命令")

        def _drain():
            try:
                for _line in self.proc.stderr:
                    self._stderr_q.put(_line.rstrip())
            except Exception:
                pass

        threading.Thread(target=_drain, daemon=True).start()

    def call(self, op, payload):
        with self._lock:
            self._ensure()
            if self.proc.poll() is not None:
                self.proc = None
                raise RuntimeError("SSH 远端连接已断开")
            b64 = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
            try:
                self.proc.stdin.write(op + " " + b64 + "\n")
                self.proc.stdin.flush()
                line = self.proc.stdout.readline()
            except (BrokenPipeError, OSError) as e:
                self.proc = None
                raise RuntimeError("SSH 远端连接中断: %s" % e)
            if not line:
                errs = []
                while not self._stderr_q.empty():
                    errs.append(self._stderr_q.get())
                self.proc = None
                raise RuntimeError("远端未返回数据：%s" % ("; ".join(errs[-3:]) or "连接已断开"))
            try:
                return json.loads(line.strip())
            except Exception:
                self.proc = None
                raise RuntimeError("远端返回解析失败: %s" % line.strip()[:300])

    def close(self):
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            except Exception:
                pass
        self.proc = None


_REMOTE = _RemoteWorker()
atexit.register(_REMOTE.close)


def ssh_run(op, payload):
    """经常驻 SSH 链路在服务器容器内跑 sqlite，返回解析后的 JSON dict。失败抛 RuntimeError。"""
    return _REMOTE.call(op, payload)


def list_tables():
    return ssh_run("list_tables", None)


def read_table(table, preview=False):
    return ssh_run("read", {"table": table, "limit": MAX_ROWS, "preview": bool(preview)})


def fetch_full(table, rowids):
    return ssh_run("fetch_full", {"table": table, "rowids": list(rowids)})


def write_table(table, updates):
    return ssh_run("write", {"table": table, "updates": updates})


# ---------------- HTML 页面（子数据库切换 + 可编辑表格） ----------------
PAGE_HTML = """<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>AI-SAGA 数据库管理</title>
<style>
  :root { --border:#cfd8e3; --head:#2f5d8a; --accent:#2f5d8a; }
  * { box-sizing:border-box; }
  body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;
         margin:0; background:#f4f7fb; color:#1c2733; }
  header { background:var(--head); color:#fff; padding:0 20px; font-size:16px; font-weight:600;
           display:flex; align-items:center; gap:16px; position:sticky; top:0; z-index:5; height:48px; }
  header .sub { font-size:12px; font-weight:400; opacity:.85; }
  #status { margin-left:auto; font-size:13px; font-weight:400; opacity:.95; white-space:nowrap; }
  .tabs { display:flex; flex-wrap:wrap; gap:8px; padding:10px 20px; background:#eef3fa;
          border-bottom:1px solid var(--border); position:sticky; top:48px; z-index:4; }
  .tab { background:#fff; border:1px solid var(--border); color:#2f5d8a; padding:6px 12px;
         font-size:12px; border-radius:14px; cursor:pointer; white-space:nowrap; transition:all .15s; }
  .tab:hover { border-color:#7aa5d6; }
  .tab.active { background:var(--accent); color:#fff; border-color:var(--accent); }
  .wrap { padding:16px 20px; }
  .row-save { background:#5b7a9d; color:#fff; border:0; padding:6px 12px; font-size:12px;
              border-radius:4px; cursor:pointer; white-space:nowrap; }
  .row-save:disabled { opacity:.4; cursor:not-allowed; }
  .row-save.dirty { background:#e0a800; }
  th.ops { min-width:104px; }
  .table-scroll { overflow:auto; max-height:calc(100vh - 180px); border:1px solid var(--border);
                  background:#fff; border-radius:6px; }
  table { border-collapse:separate; border-spacing:0; min-width:100%; }
  th { position:sticky; top:0; background:#e8eef6; color:#27405c; font-size:12px; font-weight:600;
       text-align:left; padding:8px 10px; border-bottom:2px solid var(--border);
       border-right:1px solid var(--border); white-space:nowrap; z-index:2; }
  td { padding:4px; border-bottom:1px solid #edf1f6; border-right:1px solid #edf1f6; vertical-align:top; }
  .ops-cell { white-space:nowrap; text-align:center; min-width:104px; }
  .rowid { display:block; font-size:10px; color:#8a99ab; margin-top:4px; }
  td.blob { color:#9aa7b5; font-size:11px; font-style:italic; padding:8px 10px; background:#f8fafc; }
  textarea { width:100%; min-width:140px; border:1px solid #d7e0ea; border-radius:4px; padding:6px 8px;
             font-family:inherit; font-size:12px; line-height:1.5; resize:none; overflow:hidden; background:#fff;
             color:#1c2733; }
  textarea:focus { outline:2px solid #7aa5d6; border-color:#7aa5d6; }
  textarea.changed { background:#fff7d6; border-color:#e0a800; }
  .empty { padding:30px; text-align:center; color:#5a6b7b; }
  .toolbar { margin-bottom:8px; }
  .toolbar .refresh { background:#fff; border:1px solid var(--border); color:#2f5d8a;
                      padding:6px 14px; font-size:12px; border-radius:14px; cursor:pointer; }
  .toolbar .refresh:hover { border-color:#7aa5d6; background:#eef3fa; }
  .row-time { display:block; font-size:10px; color:#6d7c8c; margin-top:4px; white-space:nowrap; }
  .lc { position:relative; }
  .lc-ta { min-width:140px; padding:6px 8px; font-family:inherit; font-size:12px; line-height:1.5;
           border:1px solid #d7e0ea; border-radius:4px; background:#fbfcfe; color:#1c2733;
           resize:none; overflow:hidden; }
  .lc-ta.lc-open { background:#fff; border-color:#7aa5d6; }
  .lc-ta:focus { outline:2px solid #7aa5d6; }
  .lc-btn { margin-top:4px; background:#eef3fa; border:1px solid var(--border); color:#2f5d8a;
            font-size:11px; padding:2px 10px; border-radius:10px; cursor:pointer; }
  .lc-btn:hover { border-color:#7aa5d6; background:#e0ecf7; }
  .modal-mask { position:fixed; inset:0; background:rgba(20,30,45,.45); display:flex; align-items:center;
                justify-content:center; z-index:100; }
  .modal { background:#fff; border-radius:10px; padding:20px 24px; max-width:440px; width:90%;
           box-shadow:0 10px 40px rgba(0,0,0,.25); }
  .modal-title { font-size:15px; font-weight:600; color:#b03a2e; margin-bottom:10px; }
  .modal-msg { font-size:13px; color:#1c2733; line-height:1.6; white-space:pre-wrap; word-break:break-all;
               max-height:220px; overflow:auto; }
  .modal-btn { margin-top:16px; background:#2f5d8a; color:#fff; border:0; padding:8px 18px; border-radius:6px;
               cursor:pointer; }
  .modal-btn:hover { background:#1f4a6e; }
</style>
</head>
<body>
<header>
  <span>AI-SAGA 数据库管理</span>
  <span class="sub" id="dbpath"></span>
  <span id="status"></span>
</header>
<nav class="tabs" id="tabs"></nav>
<div class="wrap">
  <div class="toolbar"><button class="refresh" onclick="refreshCurrent()">⟳ 刷新当前子数据库</button></div>
  <div class="table-scroll"><table id="grid"></table></div>
</div>
<div id="errModal" class="modal-mask" style="display:none">
  <div class="modal">
    <div class="modal-title">⚠️ 上传失败</div>
    <div class="modal-msg" id="errModalMsg"></div>
    <button class="modal-btn" onclick="closeErrModal()">知道了</button>
  </div>
</div>
<script>
const grid = document.getElementById('grid');
const tabsEl = document.getElementById('tabs');
const statusEl = document.getElementById('status');
const dbpathEl = document.getElementById('dbpath');
let tables = [];
let current = 'fiction_script';
let columns = [];
let colTypes = {};
let original = {};      // rowid -> { col: 原值（完整值） }
let dirty = {};         // rowid -> { col: 新值 }（仅已修改）
let fullData = {};      // rowid -> { col: 完整值 }（后台预载到的全文）
let truncCols = {};     // rowid -> { col: true }（该行哪些列是长文本被截断）
let previewText = {};   // "rid:col" -> 前 30 个字预览文本
let expanded = {};      // "rid:col" -> true（当前已展开）
let pendingFull = {};   // rowid -> true（待批量预载全文）
let fullTimer = null;
let observer = null;
const PREVIEW_UNITS = 30;

function setStatus(msg, err) {
  statusEl.textContent = msg;
  statusEl.style.color = err ? '#ffd9a0' : '#d9e8f7';
}

async function loadTables() {
  setStatus('正在读取子数据库列表…');
  try {
    const resp = await fetch('/api/tables');
    const data = await resp.json();
    if (!data.ok) throw new Error(data.error || '读取表列表失败');
    tables = data.tables || [];
    renderTabs();
    if (tables.length) {
      if (tables.some(t => t.name === current)) {
        highlightTabs();
        await loadTable(current);
      } else {
        current = tables[0].name;
        highlightTabs();
        await loadTable(current);
      }
    } else {
      setStatus('数据库为空（无表）');
    }
  } catch (e) {
    setStatus('加载表列表失败：' + e.message, true);
  }
}

function renderTabs() {
  tabsEl.innerHTML = '';
  for (const t of tables) {
    const b = document.createElement('button');
    b.className = 'tab';
    b.dataset.name = t.name;
    b.textContent = t.label;
    b.title = t.name;
    b.onclick = function () { selectTable(this.dataset.name); };
    tabsEl.appendChild(b);
  }
  highlightTabs();
}

function highlightTabs() {
  tabsEl.querySelectorAll('button.tab').forEach(function (b) {
    b.classList.toggle('active', b.dataset.name === current);
  });
}

async function selectTable(name) {
  if (name === current) return;
  current = name;
  highlightTabs();
  await loadTable(name);
}

async function loadTable(name) {
  setStatus('正在读取「' + name + '」数据…');
  try {
    const resp = await fetch('/api/table?table=' + encodeURIComponent(name) + '&preview=1');
    const data = await resp.json();
    if (!data.ok) throw new Error(data.error || '读取失败');
    columns = data.columns || [];
    colTypes = {};
    for (let i = 0; i < columns.length; i++) colTypes[columns[i]] = (data.types || [])[i];
    original = {}; dirty = {}; fullData = {}; truncCols = {}; previewText = {}; expanded = {}; pendingFull = {};
    if (fullTimer) { clearTimeout(fullTimer); fullTimer = null; }
    if (observer) { observer.disconnect(); observer = null; }
    const shown = data.shown || 0;
    let info = name + ' · ' + shown + ' 行';
    if (data.order_by) info += ' · 按 ' + data.order_by + ' 倒序';
    if (data.total != null && data.total > shown) info += '（共 ' + data.total + ' 行，已截断）';
    dbpathEl.textContent = info;
    render(data.rows || []);
    let msg = '已加载 ' + shown + ' 行（长文本显示前 ' + PREVIEW_UNITS + ' 个字，滚动到可见时后台加载全文）';
    if (data.truncated) msg += '（超过单页上限 ' + columns.length + ' 列 × ' + shown + ' 行）';
    setStatus(msg);
  } catch (e) {
    setStatus('加载「' + name + '」失败：' + e.message, true);
  }
}

// 相对时间：X日X小时X分X秒前（用浏览器本地时区计算当前时间差）
function fmtTimeAgo(epochSec) {
  let diff = Math.floor(Date.now() / 1000) - epochSec;
  if (diff < 0) diff = 0;
  const d = Math.floor(diff / 86400);
  const h = Math.floor((diff % 86400) / 3600);
  const m = Math.floor((diff % 3600) / 60);
  const s = diff % 60;
  return d + '日' + h + '小时' + m + '分' + s + '秒前';
}

// 绝对本地时间：YYYY-MM-DD HH:MM:SS（按电脑当前时区显示）
function fmtLocal(epochSec) {
  const dt = new Date(epochSec * 1000);
  const p = n => String(n).padStart(2, '0');
  return dt.getFullYear() + '-' + p(dt.getMonth() + 1) + '-' + p(dt.getDate()) +
         ' ' + p(dt.getHours()) + ':' + p(dt.getMinutes()) + ':' + p(dt.getSeconds());
}

// 刷新当前子数据库
async function refreshCurrent() {
  await loadTable(current);
}

function render(rows) {
  let html = '<thead><tr><th class="ops">保存本行</th>';
  for (const c of columns) html += '<th>' + escapeHtml(c) + '</th>';
  html += '</tr></thead><tbody>';
  if (!rows.length) {
    html += '<tr><td colspan="' + (columns.length + 1) + '" class="empty">（空表，无数据）</td></tr>';
  }
  for (const row of rows) {
    const rid = row.__rowid__;
    const lt = row.__last_time__;
    const trunc = row.__trunc__ || null;
    original[rid] = {};
    truncCols[rid] = trunc ? Object.assign({}, trunc) : {};
    html += '<tr data-rid="' + rid + '"><td class="ops-cell"><button class="row-save" data-rid="' + rid +
            '" onclick="saveRow(this)" disabled>保存本行</button><span class="rowid">#' + rid + '</span>' +
            '<span class="row-time" title="' + (lt ? '本行本地时间：' + fmtLocal(lt) : '该表无时间列') + '">' +
            (lt ? fmtTimeAgo(lt) : '—') + '</span></td>';
    for (const col of columns) {
      const val = row[col] == null ? '' : String(row[col]);
      original[rid][col] = val;
      if (colTypes[col] === 'BLOB' || val.indexOf('[BLOB ') === 0) {
        html += '<td class="blob" title="二进制数据，只读不可编辑">' + escapeHtml(val) + '</td>';
      } else if (trunc && trunc[col]) {
        // 长文本：只显示前 30 个字预览 + 更多按钮；全文按可见性后台预载，加载前不可编辑
        const key = rid + ':' + col;
        previewText[key] = val;
        html += '<td><div class="lc" data-rid="' + rid + '" data-col="' + escapeAttr(col) + '">' +
                '<textarea class="lc-ta" data-rid="' + rid + '" data-col="' + escapeAttr(col) +
                '" rows="2" readonly oninput="cellEdit(this); setLcHeight(this)">' + escapeHtml(val) + '</textarea>' +
                '<button class="lc-btn" data-rid="' + rid + '" data-col="' + escapeAttr(col) + '" onclick="toggleLong(this)">更多</button>' +
                '</div></td>';
      } else {
        html += '<td><textarea data-rid="' + rid + '" data-col="' + escapeAttr(col) +
                '" rows="2" oninput="cellEdit(this); autoResize(this)">' + escapeHtml(val) + '</textarea></td>';
      }
    }
    html += '</tr>';
  }
  html += '</tbody>';
  grid.innerHTML = html;
  grid.querySelectorAll('textarea:not(.lc-ta)').forEach(autoResize);
  grid.querySelectorAll('.lc-ta').forEach(setLcHeight);
  updateButtons();
  setupObserver();
}

function setLcHeight(ta) {
  ta.style.height = 'auto';
  ta.style.height = (ta.scrollHeight + 2) + 'px';
}

// 长文本展开 / 收起（更多 / 收起按钮）
function toggleLong(btn) {
  const rid = btn.getAttribute('data-rid');
  const col = btn.getAttribute('data-col');
  const key = rid + ':' + col;
  expanded[key] = !expanded[key];
  if (expanded[key] && !(fullData[rid] && fullData[rid][col] !== undefined)) {
    queueFull(rid);       // 保险：全文尚未预载到则立刻拉取
    if (fullTimer) clearTimeout(fullTimer);
    flushFull();
  }
  syncLcCells();
}

// 按当前状态（展开/收起、是否已有全文）同步所有长文本单元格
function syncLcCells() {
  grid.querySelectorAll('.lc').forEach(function (lc) {
    const rid = lc.getAttribute('data-rid');
    const col = lc.getAttribute('data-col');
    const key = rid + ':' + col;
    const ta = lc.querySelector('.lc-ta');
    const btn = lc.querySelector('.lc-btn');
    const hasFull = fullData[rid] && fullData[rid][col] !== undefined;
    if (expanded[key] && hasFull) {
      // 正在输入时不覆盖内容，避免丢字
      if (document.activeElement !== ta) {
        ta.value = (dirty[rid] && dirty[rid][col] !== undefined) ? dirty[rid][col] : fullData[rid][col];
      }
      ta.readOnly = false;
      ta.classList.add('lc-open');
      setLcHeight(ta);
      btn.textContent = '收起';
    } else if (expanded[key] && !hasFull) {
      ta.value = previewText[key] || '';
      ta.readOnly = true;
      btn.textContent = '加载中…';
    } else {
      ta.value = previewText[key] || '';
      ta.readOnly = true;
      ta.classList.remove('lc-open');
      btn.textContent = '更多';
    }
  });
  updateButtons();
}

// 可见性预载：行进入视口 -> 批量后台拉全文
function setupObserver() {
  if (!('IntersectionObserver' in window)) return;
  const rootEl = document.querySelector('.table-scroll');
  observer = new IntersectionObserver(function (entries) {
    for (const en of entries) {
      if (en.isIntersecting) {
        const rid = en.target.getAttribute('data-rid');
        if (rid && rowNeedsFull(rid)) queueFull(rid);
      }
    }
  }, { root: rootEl, rootMargin: '200px 0px' });
  grid.querySelectorAll('tbody tr[data-rid]').forEach(function (tr) { observer.observe(tr); });
}

function rowNeedsFull(rid) {
  const cols = truncCols[rid] || {};
  const full = fullData[rid] || {};
  return Object.keys(cols).some(function (c) { return full[c] === undefined; });
}

function queueFull(rid) {
  pendingFull[rid] = true;
  if (fullTimer) clearTimeout(fullTimer);
  fullTimer = setTimeout(flushFull, 120);
}

async function flushFull() {
  fullTimer = null;
  const ids = Object.keys(pendingFull);
  if (!ids.length) return;
  pendingFull = {};
  try {
    const resp = await fetch('/api/full?table=' + encodeURIComponent(current) + '&rowids=' + ids.join(','));
    const data = await resp.json();
    if (!data.ok) throw new Error(data.error || '预载全文失败');
    applyFull(data.rows || []);
  } catch (e) {
    // 失败保持预览即可，用户点更多时会再触发
  }
}

function applyFull(rows) {
  for (const row of rows) {
    const rid = row.__rowid__;
    fullData[rid] = fullData[rid] || {};
    for (const col of columns) {
      if (row[col] !== undefined) {
        fullData[rid][col] = row[col];
        if (!(dirty[rid] && dirty[rid][col] !== undefined)) {
          original[rid][col] = row[col];   // 原值=完整值，保证 dirty 对比正确
        }
      }
    }
  }
  syncLcCells();
}

function cellEdit(ta) {
  const rid = ta.getAttribute('data-rid');
  const col = ta.getAttribute('data-col');
  const val = ta.value;
  if (!(rid in dirty)) dirty[rid] = {};
  if (val === original[rid][col]) {
    delete dirty[rid][col];
    if (Object.keys(dirty[rid]).length === 0) delete dirty[rid];
    ta.classList.remove('changed');
  } else {
    dirty[rid][col] = val;
    ta.classList.add('changed');
  }
  updateButtons();
}

// 每行的「保存本行」按钮：只上传这一行改动过的格子，避免一次性大批量修改出错
function updateButtons() {
  grid.querySelectorAll('button.row-save').forEach(function (b) {
    const rid = b.getAttribute('data-rid');
    const hasDirty = (rid in dirty) && Object.keys(dirty[rid]).length > 0;
    b.disabled = !hasDirty;
    b.classList.toggle('dirty', hasDirty);
  });
}

async function saveRow(btn) {
  const rid = Number(btn.getAttribute('data-rid'));
  const changes = dirty[rid];
  if (!changes || Object.keys(changes).length === 0) return;
  const updates = Object.keys(changes).map(function (col) {
    return { rowid: rid, column: col, value: changes[col] };
  });
  // 点击即置灰：把这批改动从“待保存”取出；按钮随后由 updateButtons 按
  // “是否还有未上传的新改动”重新点亮（后台传输期间也可继续改、继续传）。
  const saved = Object.assign({}, changes);
  for (const col of Object.keys(changes)) delete dirty[rid][col];
  if (Object.keys(dirty[rid]).length === 0) delete dirty[rid];
  btn.disabled = true;
  setStatus('正在上传修改内容到数据库…');
  try {
    const resp = await fetch('/api/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ table: current, updates }),
    });
    const data = await resp.json();
    if (!data.ok) throw new Error(data.error || '保存失败');
    // 上传成功：不刷新页面，只把已保存格子标记为新基线；若用户上传期间又改了，
    // 保留其更新的改动（dirty 里的为准）。
    for (const col of Object.keys(saved)) {
      if (!(dirty[rid] && dirty[rid][col] !== undefined)) {
        original[rid][col] = saved[col];
        if (fullData[rid]) fullData[rid][col] = saved[col];
        if (truncCols[rid] && truncCols[rid][col]) {
          previewText[rid + ':' + col] = makePreview(saved[col]);
        }
      }
    }
    grid.querySelectorAll('textarea[data-rid="' + rid + '"]').forEach(function (ta) {
      ta.classList.remove('changed');
    });
    setStatus('修改成功 ✔');
  } catch (e) {
    // 上传失败：弹窗警告，并把这批改动放回“待保存”（无需重打）
    for (const col of Object.keys(saved)) {
      if (!(dirty[rid] && dirty[rid][col] !== undefined)) {
        if (!(rid in dirty)) dirty[rid] = {};
        dirty[rid][col] = saved[col];
      }
    }
    setStatus('上传失败：' + e.message, true);
    showErrModal('上传修改内容到数据库失败：\n' + e.message);
  }
  syncLcCells();   // 刷新折叠预览/展开态，并据此重算保存按钮状态
}

// 与服务端一致的 30 字预览宽度（汉字/全角=2，拉丁字母/数字=1）
function unitWidth(ch) {
  const c = ch.codePointAt(0);
  return (
    (c >= 0x1100 && c <= 0x115F) || c === 0x2329 || c === 0x232A ||
    (c >= 0x2E80 && c <= 0xA4CF) || (c >= 0xAC00 && c <= 0xD7A3) ||
    (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE10 && c <= 0xFE19) ||
    (c >= 0xFE30 && c <= 0xFE6F) || (c >= 0xFF00 && c <= 0xFF60) ||
    (c >= 0xFFE0 && c <= 0xFFE6) || (c >= 0x1F300 && c <= 0x1F64F) ||
    (c >= 0x1F900 && c <= 0x1F9FF) || (c >= 0x20000 && c <= 0x2FFFD) ||
    (c >= 0x30000 && c <= 0x3FFFD)
  ) ? 2 : 1;
}
function makePreview(text) {
  const s = String(text == null ? '' : text);
  let units = 0, out = '';
  for (const ch of s) {
    const u = unitWidth(ch);
    if (units + u > 30) break;
    units += u;
    out += ch;
  }
  return out;
}

// 上传失败警告弹窗
function showErrModal(msg) {
  document.getElementById('errModalMsg').textContent = msg;
  document.getElementById('errModal').style.display = 'flex';
}
function closeErrModal() {
  document.getElementById('errModal').style.display = 'none';
}

function escapeHtml(s) {
  // 强制转字符串；用运行时数字实体，避免源码里的 &...; 被任何文本编码/解码改写，
  // 保证真正转义 < > & "。
  return String(s).replace(/[&<>"]/g, function (c) {
    return '&#' + c.charCodeAt(0) + ';';
  });
}
function escapeAttr(s) {
  return escapeHtml(s).replace(/'/g, function () {
    return '&#' + 39 + ';';
  });
}

// 让文本框随内容自动撑高（不用上下滚动才能看全）
function autoResize(ta) {
  ta.style.height = 'auto';
  ta.style.height = (ta.scrollHeight + 2) + 'px';
}

loadTables();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, content_type, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, "application/json; charset=utf-8", json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def _is_local_request(self):
        """仅允许本机访问：校验 Host 为回环地址，并拦截来自外域的跨站请求（CSRF/防黑）。"""
        host = (self.headers.get("Host") or "").strip().lower()
        if ":" in host:
            host = host.split(":")[0]
        if host not in ("127.0.0.1", "localhost", "::1", "[::1]"):
            return False
        origin = (self.headers.get("Origin") or "").strip().lower()
        if origin:
            try:
                ohost = urlparse(origin).hostname or ""
                ohost = ohost.strip("[]").lower()
            except Exception:
                ohost = ""
            if ohost not in ("127.0.0.1", "localhost", "::1"):
                return False
        return True

    def do_GET(self):
        if not self._is_local_request():
            self._json({"ok": False, "error": "仅允许本地访问，请通过 http://127.0.0.1 打开"}, 403)
            return
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)
        try:
            if path in ("/", "/index.html"):
                self._send(200, "text/html; charset=utf-8", PAGE_HTML.encode("utf-8"))
            elif path == "/api/tables":
                data = list_tables()
                if data.get("ok"):
                    data["tables"] = [
                        {"name": t, "label": TABLE_LABELS.get(t, t)}
                        for t in data.get("tables", [])
                    ]
                self._json(data)
            elif path == "/api/table":
                table = (params.get("table") or [TABLE])[0]
                preview = (params.get("preview") or ["0"])[0].lower() in ("1", "true", "yes")
                self._json(read_table(table, preview=preview))
            elif path == "/api/full":
                table = (params.get("table") or [TABLE])[0]
                rowids = [int(x) for x in (params.get("rowids") or [""])[0].split(",") if x.strip()]
                self._json(fetch_full(table, rowids))
            else:
                self._json({"ok": False, "error": "not found"}, 404)
        except Exception as e:
            self._json({"ok": False, "error": str(e)}, 500)

    def do_POST(self):
        if not self._is_local_request():
            self._json({"ok": False, "error": "仅允许本地访问，请通过 http://127.0.0.1 打开"}, 403)
            return
        path = urlparse(self.path).path
        try:
            if path == "/api/save":
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length)
                try:
                    payload = json.loads(raw.decode("utf-8"))
                except Exception:
                    self._json({"ok": False, "error": "请求体不是合法 JSON"}, 400)
                    return
                table = (payload or {}).get("table") or TABLE
                self._json(write_table(table, (payload or {}).get("updates") or []))
            else:
                self._json({"ok": False, "error": "not found"}, 404)
        except Exception as e:
            self._json({"ok": False, "error": str(e)}, 500)

    def log_message(self, fmt, *args):  # 静默请求日志
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    # 只绑定回环地址：仅本机可访问，绝不暴露到互联网
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("=" * 64)
    print(" AI-SAGA 数据库管理工具（仅本机访问）")
    print(" 打开: http://127.0.0.1:%d" % PORT)
    print(" 服务器: %s@%s  容器: %s  数据库: %s" % (USER, HOST, CONTAINER, DB_PATH))
    print(" 本工具绑定 127.0.0.1 并校验 Host/Origin，外部网络无法访问。Ctrl+C 退出。")
    print("=" * 64)

    # 启动时在后台线程顺带列出子数据库，方便确认连接（失败不阻塞、不打断服务）
    def _probe():
        try:
            data = list_tables()
            if data.get("ok"):
                names = data.get("tables") or []
                print(" [探测] 子数据库(%d): %s" % (len(names), ", ".join(names)))
            else:
                print(" [探测] 无法读取子数据库: %s" % data.get("error"))
        except Exception as e:
            print(" [探测] 无法连接服务器（%s）；请用 AI_SAGA_HOST 等环境变量指定连接参数。" % e)

    threading.Thread(target=_probe, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出")
        server.server_close()


if __name__ == "__main__":
    main()
