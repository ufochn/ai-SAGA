#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""脚本数据库（fiction_script）本地管理工具 —— 仅本机 Chrome 可打开，不暴露到互联网。

功能：
- 在 127.0.0.1 上启动一个只读本机的 HTTP 服务（绑定回环地址，外网无法访问）。
- 通过 SSH（复用 ~/.ssh/ai_saga_deploy，与 deploy_helper.sh 相同）进入服务器上的
  Docker 容器，用容器内的 python3+sqlite3 读取 / 写入 fiction_script 表。
- 浏览器打开 http://127.0.0.1:<port> 即可看到可编辑表格；每个格子可直接改文本，
  改完点该行最左侧的"更新本行"按钮，把修改的格子上传到数据库对应位置。

用法：
    python3 AI-SAGA/server/script_admin.py            # 默认端口 8787
    python3 AI-SAGA/server/script_admin.py 9000       # 指定端口
    AI_SAGA_HOST=... AI_SAGA_USER=... AI_SAGA_SSH_KEY=...   # 可覆盖服务器参数

注意：本工具是本地开发工具，不随服务器部署；它不修改任何服务器代码。
"""

import base64
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

# ---------------- 服务器连接参数（与 deploy_helper.sh 一致，可用环境变量覆盖） ----------------
HOST = os.environ.get("AI_SAGA_HOST", "YOUR_SERVER_IP")
USER = os.environ.get("AI_SAGA_USER", "root")
KEY = os.environ.get("AI_SAGA_SSH_KEY", os.path.expanduser("~/.ssh/ai_saga_deploy"))
CONTAINER = os.environ.get("AI_SAGA_CONTAINER", "my-audit-app")
DB_PATH = os.environ.get("AI_SAGA_DB_PATH", "/code/data/ai_saga.db")
TABLE = os.environ.get("AI_SAGA_TABLE", "fiction_script")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787

SSH_OPTS = [
    "-i", KEY,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=15",
    "-o", "LogLevel=ERROR",
    "-o", "IdentitiesOnly=yes",
]

# 在服务器容器内执行的远端脚本（通过 stdin 喂给 `docker exec -i ... python3 -`）。
# 尾部由本地拼接一行调用，把命令以 base64 形式传入，彻底规避引号/转义问题。
REMOTE_HELPER = r'''
import base64, json, os, sqlite3

DB = %(db_path)r
TABLE = %(table)r

def _sanitize(v):
    if v is None:
        return ""
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return v

def run(op, payload):
    c = sqlite3.connect(DB)
    try:
        if op == "read":
            cur = c.execute('SELECT * FROM "' + TABLE + '"')
            cols = [d[0] for d in cur.description]
            rows = [{k: _sanitize(v) for k, v in zip(cols, r)} for r in cur.fetchall()]
            return {"ok": True, "columns": cols, "rows": rows}
        if op == "write":
            tbl = (payload or {}).get("table") or TABLE
            info = list(c.execute('PRAGMA table_info("' + tbl + '")'))
            allowed = [d[1] for d in info]
            pk = next((d[1] for d in info if d[5] > 0), "id")
            n = 0
            for u in (payload or {}).get("updates") or []:
                col = u.get("column")
                val = u.get("value")
                rid = u.get("id")
                if col not in allowed or col == pk:
                    continue
                c.execute('UPDATE "' + tbl + '" SET "' + col + '"=? WHERE "' + pk + '"=?', (val, rid))
                n += 1
            c.commit()
            return {"ok": True, "updated": n}
        return {"ok": False, "error": "unknown op: " + str(op)}
    except Exception as e:
        return {"ok": False, "error": repr(e)}
    finally:
        c.close()
''' % {"db_path": DB_PATH, "table": TABLE}


def _remote_payload(op, payload):
    """远端脚本 + 末尾一行调用 run(op, payload)，payload 用 base64 传递（无转义问题）。"""
    b64 = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
    trailer = (
        'print(json.dumps(run(%r, json.loads(base64.b64decode(%r).decode("utf-8")))))'
        % (op, b64)
    )
    return REMOTE_HELPER + "\n\n" + trailer + "\n"


def ssh_run(op, payload):
    """SSH 到服务器，在容器内跑 sqlite，返回解析后的 JSON dict。失败抛 RuntimeError。"""
    script = _remote_payload(op, payload)
    try:
        p = subprocess.run(
            ["ssh", *SSH_OPTS, "%s@%s" % (USER, HOST), "docker exec -i %s python3 -" % CONTAINER],
            input=script,
            capture_output=True,
            text=True,
            timeout=90,
        )
    except FileNotFoundError:
        raise RuntimeError("找不到 ssh 命令")
    except subprocess.TimeoutExpired:
        raise RuntimeError("SSH 连接超时")
    if p.returncode != 0:
        raise RuntimeError((p.stderr or "").strip() or "SSH 返回码 %d" % p.returncode)
    out = (p.stdout or "").strip()
    if not out:
        raise RuntimeError("远端未返回数据")
    try:
        return json.loads(out.splitlines()[-1])
    except Exception:
        raise RuntimeError("远端返回解析失败: %s" % out[:300])


# ---------------- HTML 页面（可编辑表格） ----------------
PAGE_HTML = """<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>脚本数据库管理 (fiction_script)</title>
<style>
  :root { --border:#cfd8e3; --head:#2f5d8a; --accent:#2f5d8a; }
  * { box-sizing:border-box; }
  body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;
         margin:0; background:#f4f7fb; color:#1c2733; }
  header { background:var(--head); color:#fff; padding:12px 20px; font-size:16px; font-weight:600;
           display:flex; align-items:center; gap:16px; position:sticky; top:0; z-index:5; }
  header .sub { font-size:12px; font-weight:400; opacity:.8; }
  #status { margin-left:auto; font-size:13px; font-weight:400; opacity:.95; }
  .wrap { padding:16px 20px; }
  .row-save { background:#5b7a9d; color:#fff; border:0; padding:6px 12px; font-size:12px;
              border-radius:4px; cursor:pointer; white-space:nowrap; }
  .row-save:disabled { opacity:.4; cursor:not-allowed; }
  .row-save.dirty { background:#e0a800; }
  th.ops { min-width:96px; }
  .table-scroll { overflow:auto; max-height:calc(100vh - 150px); border:1px solid var(--border);
                  background:#fff; border-radius:6px; }
  table { border-collapse:separate; border-spacing:0; min-width:100%; }
  th { position:sticky; top:0; background:#e8eef6; color:#27405c; font-size:12px; font-weight:600;
       text-align:left; padding:8px 10px; border-bottom:2px solid var(--border);
       border-right:1px solid var(--border); white-space:nowrap; z-index:2; }
  td { padding:4px; border-bottom:1px solid #edf1f6; border-right:1px solid #edf1f6; vertical-align:top; }
  td.pk { background:#f0f5fb; font-weight:700; color:#2f5d8a; text-align:center; min-width:48px; }
  textarea { width:100%; min-width:140px; border:1px solid #d7e0ea; border-radius:4px; padding:6px 8px;
             font-family:inherit; font-size:12px; line-height:1.5; resize:none; overflow:hidden; background:#fff;
             color:#1c2733; }
  textarea:focus { outline:2px solid #7aa5d6; border-color:#7aa5d6; }
  textarea.changed { background:#fff7d6; border-color:#e0a800; }
  .empty { padding:30px; text-align:center; color:#5a6b7b; }
</style>
</head>
<body>
<header>
  <span>脚本数据库管理（fiction_script）</span>
  <span class="sub" id="tableinfo"></span>
  <span id="status"></span>
</header>
<div class="wrap">
  <div class="table-scroll"><table id="grid"></table></div>
</div>
<script>
const grid = document.getElementById('grid');
const statusEl = document.getElementById('status');
const tableinfoEl = document.getElementById('tableinfo');
let columns = [];
let original = {};   // id -> { col: 原值 }
let dirty = {};      // id -> { col: 新值 }（仅已修改）

function setStatus(msg, err) {
  statusEl.textContent = msg;
  statusEl.style.color = err ? '#ffd9a0' : '#d9e8f7';
}

async function loadTable() {
  setStatus('正在读取服务器数据…');
  try {
    const resp = await fetch('/api/table');
    const data = await resp.json();
    if (!data.ok) throw new Error(data.error || '读取失败');
    columns = data.columns;
    original = {}; dirty = {};
    tableinfoEl.textContent = columns.length + ' 列 · ' + data.rows.length + ' 行';
    render(data.rows);
    setStatus('已加载（本地）');
  } catch (e) {
    setStatus('加载失败：' + e.message, true);
  }
}

function render(rows) {
  // 找主键列（优先名为 id）
  let pk = columns.indexOf('id');
  if (pk < 0) {
    for (let i = 0; i < columns.length; i++) if (columns[i].toLowerCase().endsWith('id')) { pk = i; break; }
  }
  const pkName = columns[pk] || 'id';
  let html = '<thead><tr><th class="ops">操作</th>';
  for (const c of columns) html += '<th>' + escapeHtml(c) + '</th>';
  html += '</tr></thead><tbody>';
  for (const row of rows) {
    const id = row[pkName];
    original[id] = {};
    html += '<tr><td><button class="row-save" data-id="' + escapeAttr(String(id)) + '" onclick="saveRow(this)" disabled>更新本行</button></td>';
    for (let ci = 0; ci < columns.length; ci++) {
      const col = columns[ci];
      const val = row[col] == null ? '' : String(row[col]);
      original[id][col] = val;
      if (ci === pk) {
        html += '<td class="pk">' + escapeHtml(String(id)) + '</td>';
      } else {
        html += '<td><textarea data-id="' + escapeAttr(String(id)) + '" data-col="' + escapeAttr(col) + '" rows="2" oninput="cellEdit(this); autoResize(this)">' + escapeHtml(val) + '</textarea></td>';
      }
    }
    html += '</tr>';
  }
  html += '</tbody>';
  grid.innerHTML = html;
  grid.querySelectorAll('textarea').forEach(autoResize);
  updateButtons();
}

function cellEdit(ta) {
  const id = ta.getAttribute('data-id');
  const col = ta.getAttribute('data-col');
  const val = ta.value;
  if (!(id in dirty)) dirty[id] = {};
  if (val === original[id][col]) {
    delete dirty[id][col];
    if (Object.keys(dirty[id]).length === 0) delete dirty[id];
    ta.classList.remove('changed');
  } else {
    dirty[id][col] = val;
    ta.classList.add('changed');
  }
  updateButtons();
}

// 每行的"更新本行"按钮：只上传这一行改动过的格子，避免一次性大批量修改出错
function updateButtons() {
  grid.querySelectorAll('button.row-save').forEach(function (b) {
    const id = b.getAttribute('data-id');
    const hasDirty = (id in dirty) && Object.keys(dirty[id]).length > 0;
    b.disabled = !hasDirty;
    b.classList.toggle('dirty', hasDirty);
  });
}

async function saveRow(btn) {
  const id = btn.getAttribute('data-id');
  const changes = dirty[id];
  if (!changes || Object.keys(changes).length === 0) return;
  const updates = Object.keys(changes).map(function (col) {
    return { id: Number(id), column: col, value: changes[col] };
  });
  btn.disabled = true;
  setStatus('正在更新第 ' + id + ' 行的 ' + updates.length + ' 个格子…');
  try {
    const resp = await fetch('/api/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ table: 'fiction_script', updates }),
    });
    const data = await resp.json();
    if (!data.ok) throw new Error(data.error || '保存失败');
    await loadTable();
    setStatus('已更新第 ' + id + ' 行（' + data.updated + ' 个格子）✔');
  } catch (e) {
    updateButtons();
    setStatus('更新第 ' + id + ' 行失败：' + e.message, true);
  }
}

function escapeHtml(s) {
  // 强制转字符串（id 等数值字段可能传入）；用运行时数字实体，避免源码里的
  // &...; 被任何文本编码/解码改写，保证真正转义 < > & "。
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

loadTable();
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
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, "application/json; charset=utf-8", json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path in ("/", "/index.html"):
                self._send(200, "text/html; charset=utf-8", PAGE_HTML.encode("utf-8"))
            elif path == "/api/table":
                self._json(ssh_run("read", None))
            else:
                self._json({"ok": False, "error": "not found"}, 404)
        except Exception as e:
            self._json({"ok": False, "error": str(e)}, 500)

    def do_POST(self):
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
                self._json(ssh_run("write", payload))
            else:
                self._json({"ok": False, "error": "not found"}, 404)
        except Exception as e:
            self._json({"ok": False, "error": str(e)}, 500)

    def log_message(self, fmt, *args):  # 静默请求日志
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    # 只绑定回环地址：仅本机可访问，绝不暴露到互联网
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("=" * 60)
    print(" 脚本数据库管理工具（仅本机访问）")
    print(" 打开: http://127.0.0.1:%d" % PORT)
    print(" 服务器: %s@%s  容器: %s  表: %s" % (USER, HOST, CONTAINER, TABLE))
    print(" 本工具绑定 127.0.0.1，外部网络无法访问。Ctrl+C 退出。")
    print("=" * 60)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出")
        server.server_close()


if __name__ == "__main__":
    main()
