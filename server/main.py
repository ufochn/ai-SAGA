"""
AI-SAGA 审核网关 v2（账号 + 硬件公钥 + 付费权益 + 云同步）

架构要点
========
- 身份：Apple / Google ID Token，服务器用官方 JWKS 校验，取稳定 sub 作为 user_id。
- 设备：每设备持有安全硬件公钥（私钥永不出硬件）。public_key UNIQUE 防止
  "同一硬件注册多个 ID"（同硬件 = 一身份 = 一份配额）。
- 配额：审核 Dify 流程全局 4000 次/天；生成 Dify 流程全局 1000 次/天（24h 滚动）。
- 付费：entitlements 表预留"有效期 + 购买次数"双模型；付费校验服务器端完成，
  平台推送（App Store Server Notifications / Google RTDN）吊销退款，预留接口。
- 成本控制：输入 ≤ MAX_INPUT_TOKENS（默认 5000），输出 ≤ DIFY_MAX_TOKENS（默认 4000）。
- 云同步：按 user_id 增量同步小说数据（预留 RAG 增量索引钩子）。
"""

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import sqlite3
import time
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Optional

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

# 加载同目录 .env（可选）：未安装 python-dotenv 时静默跳过，不影响启动
try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass

# ================= 配置区域（均可通过环境变量覆盖） =================
# 开发模式：DEV_MODE=1 时启用 provider=dev（跳过 Apple/Google OAuth 校验，
# 仅用于本地/联调，生产环境必须保持关闭）
DEV_MODE = os.environ.get("DEV_MODE", "0") == "1"
DIFY_API_KEY = os.environ.get("DIFY_API_KEY", "")
DIFY_API_URL = os.environ.get("DIFY_API_URL", "https://api.dify.ai/v1/workflows/run")
# 小说生成工作流（与审核工作流并行，必须显式配置独立 API Key，不允许兜底复用审核 Key）
STORY_DIFY_API_KEY = os.environ.get("STORY_DIFY_API_KEY", "")
STORY_DIFY_API_URL = os.environ.get("STORY_DIFY_API_URL", DIFY_API_URL)
# 小说流式正文来源（text_chunk 过滤）：Dify 最新版 text_chunk 事件带
# from_variable_selector（形如 ["节点名","输出变量"]）。若 Dify 把 LLM② 结构化
# 节点的流式原文也混进 text_chunk（导致正文里混入 action_a/action_b），
# 配置本变量为"小说正文来源节点的变量路径前缀"（如 llm_1），服务器只累计
# 匹配来源的 text_chunk、丢弃其余。留空 = 不过滤（保持原行为）。
STORY_STREAM_SOURCE = os.environ.get("STORY_STREAM_SOURCE", "").strip()
# 案件生成工作流（生成当前案件的类型与核心：case_type/case_core）。
# 无输入变量，仅接收返回结果（blocking 模式）。
# 注意：Key 必须通过环境变量 CASE_DIFY_API_KEY 提供（勿硬编码到代码/提交到仓库）。
CASE_DIFY_API_KEY = os.environ.get("CASE_DIFY_API_KEY", "")
CASE_DIFY_API_URL = os.environ.get("CASE_DIFY_API_URL", DIFY_API_URL)
# 输出 token 上限（Dify max_tokens，需在 Dify 画布 LLM 节点绑定 max_tokens 输入变量）
DIFY_MAX_TOKENS = int(os.environ.get("DIFY_MAX_TOKENS", "4000"))
# 输入 token 估算上限（入口硬拦，估算在花钱之前）
MAX_INPUT_TOKENS = int(os.environ.get("MAX_INPUT_TOKENS", "5000"))
# 输入字符数兜底上限（防止极端长文本撑爆估算）
MAX_INPUT_CHARS = int(os.environ.get("MAX_INPUT_CHARS", "4000"))
# 整本小说正文数组累计字符上限（与单次输入上限解耦）。
# 小说文本由用户付费生成，默认一亿字≈无实际限制；仅作兜底，防止异常超大
# payload 打爆内存/磁盘或触发反向代理请求体限制。
MAX_STORY_TOTAL_CHARS = int(os.environ.get("MAX_STORY_TOTAL_CHARS", "100000000"))

DATA_DIR = os.environ.get("DATA_DIR", "/code/data")
TOKEN_EXPIRY_DAYS = int(os.environ.get("TOKEN_EXPIRY_DAYS", "7"))
# 付费用户每日配额（预留，付费功能启用后再接入）
PAID_DAILY_QUOTA = int(os.environ.get("PAID_DAILY_QUOTA", "100"))
# 付费用户每分钟限流（预留）
PAID_RATE_PER_MINUTE = int(os.environ.get("PAID_RATE_PER_MINUTE", "10"))
# 每 IP 每小时注册次数（注册入口限流）
REGISTER_LIMIT_PER_IP_PER_HOUR = int(os.environ.get("REGISTER_LIMIT_PER_IP_PER_HOUR", "20"))
# 同硬件 24 小时内可切换/绑定的不同账号数上限（防换账号刷试用/配额）
HARDWARE_ACCOUNTS_PER_DAY = int(os.environ.get("HARDWARE_ACCOUNTS_PER_DAY", "2"))
# 小说生成工作流全局每日上限（24 小时滚动窗口，防止滥用/被刷）
STORY_DAILY_LIMIT = int(os.environ.get("STORY_DAILY_LIMIT", "1000"))
STORY_WINDOW_SECONDS = 24 * 3600
# 审核工作流全局每日上限（24 小时滚动窗口）：覆盖设定页审核与生成过程中的内容审核
AUDIT_DAILY_LIMIT = int(os.environ.get("AUDIT_DAILY_LIMIT", "4000"))
# 小说生成过程中的内容审核（增量滑动审核，每攒满一段即送审，通过才显示）：
# - STORY_AUDIT_STEP：每次审核窗口在正文中前进的新增字数（默认 400，即"400 字一次送审"），
#   也是审核的触发点——正文每满 STEP 的整倍数（400、800、1200、1600...）即触发一次审核。
# - STORY_AUDIT_OVERLAP：除第一次审核外，每次审核向前多带的回溯字数（默认 50，
#   使相邻审核窗口重叠 50 字，防边界漏网）。
# 第 k 次审核（k=1,2,3,...）的窗口为：
#   [max(0, STEP*(k-1)-OVERLAP), STEP*k)
#   即 [0,400)、[350,800)、[750,1200)、[1150,1600)...；审核通过后把该窗口新确认的
#   STEP 字正文以 chunk/reveal 事件送回 App 显示（打字机速度不变，由客户端控制）。
# 兼容旧环境变量名：STORY_SECOND_AUDIT_START（步长）。
STORY_AUDIT_STEP = int(
    os.environ.get("STORY_AUDIT_STEP", os.environ.get("STORY_SECOND_AUDIT_START", "400"))
)
STORY_AUDIT_OVERLAP = int(os.environ.get("STORY_AUDIT_OVERLAP", "50"))

# 【调试】生成前确认：服务器调 Dify 之前，把将要发送的 payload 先通过 SSE
# 事件 debug_payload 发回 App 弹窗展示，App 用户确认后再真正调 Dify。
# - DEBUG_PAYLOAD_PREVIEW=1 开启（默认开启，供开发调试；生产可设 0 关闭）
# - DEBUG_PAYLOAD_CONFIRM_TIMEOUT：等待 App 确认的最长秒数（默认 300）
DEBUG_PAYLOAD_PREVIEW = os.environ.get("DEBUG_PAYLOAD_PREVIEW", "1") == "1"
DEBUG_PAYLOAD_CONFIRM_TIMEOUT = int(os.environ.get("DEBUG_PAYLOAD_CONFIRM_TIMEOUT", "300"))
# 待确认的生成请求注册表：request_id -> asyncio.Event（App 点击确认后 set）
_pending_payload_confirm: dict[str, asyncio.Event] = {}

# 客户端配置（校验 ID Token 的 audience / issuer）
GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")
APPLE_SERVICE_ID = os.environ.get("APPLE_SERVICE_ID", "")
APPLE_APP_BUNDLE_ID = os.environ.get("APPLE_APP_BUNDLE_ID", "")

# 付费平台配置（预留，未配置时付费校验接口返回"未配置"）
APPSTORE_SHARED_SECRET = os.environ.get("APPSTORE_SHARED_SECRET", "")
GOOGLE_PLAY_SERVICE_ACCOUNT = os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT", "")
GOOGLE_PLAY_PACKAGE = os.environ.get("GOOGLE_PLAY_PACKAGE", "")

os.makedirs(DATA_DIR, exist_ok=True)
DB_PATH = os.environ.get("DB_PATH", os.path.join(DATA_DIR, "ai_saga.db"))
TOKEN_SECRET_FILE = os.path.join(DATA_DIR, "token_secret.txt")
LOCK_FILE = os.path.join(DATA_DIR, ".lock")

# ================= SQLite 初始化（S1） =================
SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    user_id    TEXT PRIMARY KEY,
    provider   TEXT NOT NULL,          -- 'google' | 'apple'
    email      TEXT,
    active_device_id TEXT,             -- 当前活跃硬件设备（防多设备同时登入）
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
    device_id   TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    public_key  TEXT NOT NULL UNIQUE,  -- 同硬件只能绑一个 device_id
    status      TEXT DEFAULT 'active',
    created_at  INTEGER NOT NULL,
    last_seen_at INTEGER,
    key_rotated_at INTEGER,
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);

-- 权益表：预留"有效期 + 购买次数"双模型
CREATE TABLE IF NOT EXISTS entitlements (
    user_id               TEXT PRIMARY KEY,
    plan                  TEXT DEFAULT 'free',   -- 'free' | 'paid'
    purchased_quota       INTEGER DEFAULT 0,     -- 购买的使用次数（次数型权益）
    used_quota            INTEGER DEFAULT 0,     -- 已使用次数
    purchased_at          INTEGER,
    expires_at            INTEGER,               -- 有效期（订阅型权益，预留）
    status                TEXT DEFAULT 'active', -- active | revoked
    updated_at            INTEGER,
    provider              TEXT,                  -- 'appstore' | 'googleplay'
    provider_purchase_id  TEXT,                  -- 平台交易标识
    -- 预留字段
    subscription_period_days INTEGER,
    grace_until           INTEGER,
    revoked_at            INTEGER
);

CREATE TABLE IF NOT EXISTS usage (
    user_id     TEXT NOT NULL,
    date        TEXT NOT NULL,
    count       INTEGER DEFAULT 0,
    tokens_used INTEGER DEFAULT 0,
    PRIMARY KEY (user_id, date)
);

-- 云同步（预留 RAG 增量索引钩子）
CREATE TABLE IF NOT EXISTS sync_data (
    user_id    TEXT NOT NULL,
    key        TEXT NOT NULL,
    content    TEXT,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, key)
);

-- 小说正文：每段一行（追加新段 = 一条 INSERT，不用重写整本；seq 即数组下标）
-- 每行额外记录本轮三个选择 + 生成该段时用户当前的设定快照（调试期直接建表，无需迁移）
CREATE TABLE IF NOT EXISTS story_segments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    TEXT NOT NULL,
    seq        INTEGER NOT NULL,          -- 段下标（0,1,2,...），即 App 数组下标
    content    TEXT NOT NULL,             -- 这一段文本
    created_at INTEGER NOT NULL,
    -- 本轮三个选择（choice_1/2/3，LLM② 推荐的下一轮行动；任一原因取不到时写入保底默认值）
    choice_1   TEXT DEFAULT '',
    choice_2   TEXT DEFAULT '',
    choice_3   TEXT DEFAULT '',
    -- 用户本轮实际选择（点击"继续"时从三个输入框所选/所输的文本；未选择时为空）
    user_choice TEXT DEFAULT '',
    -- 后续变量（LLM② 生成；任一原因取不到时写入保底默认值）
    music_style TEXT DEFAULT '',
    -- 用户当前设定快照（生成该段时点上的设定值，服务器权威保存）
    location       TEXT DEFAULT '',
    era            TEXT DEFAULT '',
    player_name    TEXT DEFAULT '',
    player_traits  TEXT DEFAULT '',
    language       TEXT DEFAULT '',
    -- 当前案件信息（凶杀案设定，Dify 输出 core_type/core_content，服务器权威保存）
    case_type      TEXT DEFAULT '',   -- 当前案件类型（如"反杀""纯意外"等）
    case_core      TEXT DEFAULT '',   -- 当前案件核心（死者身份/现场/真相背景等完整设定文本）
    -- 当前氛围（LLM 生成该段时的氛围快照，服务器权威保存）
    current_aura   TEXT DEFAULT '',   -- 当前氛围（如"紧张""温馨"等）
    UNIQUE(user_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_segments_user_seq ON story_segments(user_id, seq);

-- 注册挑战（一次性、短时有效）
CREATE TABLE IF NOT EXISTS challenges (
    challenge_id TEXT PRIMARY KEY,
    device_id    TEXT NOT NULL,
    challenge    TEXT NOT NULL,
    expires_at   INTEGER NOT NULL
);

-- 注册 IP 限流记录（持久化，重启不清零）
CREATE TABLE IF NOT EXISTS challenges_guard (
    ip  TEXT NOT NULL,
    ts  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_guard_ip_ts ON challenges_guard(ip, ts);

-- 同硬件 24 小时内使用过的不同账号（防换账号刷试用/配额）
CREATE TABLE IF NOT EXISTS hardware_accounts (
    public_key   TEXT NOT NULL,
    user_id      TEXT NOT NULL,
    last_seen_at INTEGER NOT NULL,
    PRIMARY KEY (public_key, user_id)
);
CREATE INDEX IF NOT EXISTS idx_hardware_accounts_pk_ts ON hardware_accounts(public_key, last_seen_at);

-- 每分钟限流记录（按 user）
CREATE TABLE IF NOT EXISTS rate (
    user_id TEXT NOT NULL,
    ts      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rate_user_ts ON rate(user_id, ts);

-- 小说生成工作流全局调用记录（24 小时滚动窗口限流）
CREATE TABLE IF NOT EXISTS story_usage (
    ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_story_usage_ts ON story_usage(ts);

-- 审核工作流全局调用记录（24 小时滚动窗口限流）
CREATE TABLE IF NOT EXISTS audit_usage (
    ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_usage_ts ON audit_usage(ts);
"""


def _db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    conn = _db()
    try:
        conn.executescript(SCHEMA)
        conn.commit()
    finally:
        conn.close()


init_db()

# ================= 令牌签名密钥 =================
def _get_token_secret() -> str:
    env = os.environ.get("TOKEN_SECRET")
    if env:
        return env
    if os.path.exists(TOKEN_SECRET_FILE):
        v = open(TOKEN_SECRET_FILE, "r", encoding="utf-8").read().strip()
        if v:
            return v
    v = base64.urlsafe_b64encode(os.urandom(32)).decode()
    with open(TOKEN_SECRET_FILE, "w", encoding="utf-8") as f:
        f.write(v)
    try:
        os.chmod(TOKEN_SECRET_FILE, 0o600)
    except Exception:
        pass
    return v


TOKEN_SECRET = _get_token_secret()

if not DIFY_API_KEY:
    raise RuntimeError(
        "环境变量 DIFY_API_KEY 未配置，无法启动。"
        "请在容器启动时通过 --env-file 注入 DIFY_API_KEY。"
    )

if not STORY_DIFY_API_KEY:
    raise RuntimeError(
        "环境变量 STORY_DIFY_API_KEY 未配置，无法启动。"
        "每次调用 Dify 必须显式指定工作流：请为小说生成工作流单独配置 STORY_DIFY_API_KEY"
        "（不可复用审核 Key，避免请求打到错误的 Dify 流程）。"
    )

app = FastAPI(title="AI-SAGA 审核网关 v2")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

logger = logging.getLogger("ai_saga")
if not logger.handlers:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def _extract_guardrail_output(dify_data: Any) -> str:
    """从 Dify blocking 响应中稳健地取出审核结果（JSON 字符串）。

    优先按标准结构 data.outputs.guardrail_return_json 读取：
    - 值为字符串时原样返回；
    - Dify guardrail 节点输出为 JSON 数组/对象（如 [{"action": "NONE", ...}]）
      时序列化为 JSON 字符串返回，后续 _parse_audit_output 会自动解析；
    若 Dify 返回结构出现嵌套 / 键名差异 / 大小写差异，则递归搜索整个响应，
    返回第一个名为 *guardrail_return_json（不区分大小写）的非空值。
    找不到返回 ""。
    """
    if not isinstance(dify_data, dict):
        return ""

    def _coerce(v: Any) -> str:
        """把 guardrail 值规范化为非空 JSON 字符串；不可用返回 ""。"""
        if isinstance(v, str):
            return v if v.strip() else ""
        if isinstance(v, (dict, list)) and v:
            try:
                return json.dumps(v, ensure_ascii=False)
            except Exception:
                return ""
        return ""

    data_block = dify_data.get("data")
    if isinstance(data_block, dict):
        outputs = data_block.get("outputs")
        if isinstance(outputs, dict):
            val = _coerce(outputs.get("guardrail_return_json"))
            if val:
                return val

    # 兜底：递归搜索任意层级的 *guardrail_return_json 键
    stack: list = [dify_data]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for k, v in node.items():
                if (
                    isinstance(k, str)
                    and k.strip().lower().endswith("guardrail_return_json")
                ):
                    val = _coerce(v)
                    if val:
                        return val
                if isinstance(v, (dict, list)):
                    stack.append(v)
        elif isinstance(node, list):
            stack.extend(item for item in node if isinstance(item, (dict, list)))
    return ""


async_http_client = httpx.AsyncClient(timeout=60.0)


@app.on_event("shutdown")
async def shutdown_event():
    await async_http_client.aclose()


# ================= 令牌工具 =================
def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(s: str) -> bytes:
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def create_token(user_id: str, device_id: str, expires_at: int) -> str:
    payload = _b64url_encode(
        json.dumps(
            {"u": user_id, "d": device_id, "exp": expires_at},
            separators=(",", ":"),
        ).encode()
    )
    sig = _b64url_encode(
        hmac.new(TOKEN_SECRET.encode(), payload.encode(), hashlib.sha256).digest()
    )
    return f"v1.{payload}.{sig}"


def validate_token(token: str) -> dict:
    """校验签名令牌，返回 {user_id, device_id}；失败抛 401。"""
    if not token:
        raise HTTPException(status_code=401, detail="缺少鉴权令牌")
    parts = token.split(".")
    if len(parts) != 3 or parts[0] != "v1":
        raise HTTPException(status_code=401, detail="令牌格式错误")
    _, payload_b64, sig_b64 = parts
    expected = _b64url_encode(
        hmac.new(TOKEN_SECRET.encode(), payload_b64.encode(), hashlib.sha256).digest()
    )
    if not hmac.compare_digest(expected, sig_b64):
        raise HTTPException(status_code=401, detail="令牌签名无效")
    try:
        payload = json.loads(_b64url_decode(payload_b64))
        user_id = payload["u"]
        device_id = payload["d"]
        exp = payload["exp"]
    except Exception:
        raise HTTPException(status_code=401, detail="令牌内容无效")
    if int(time.time()) > exp:
        raise HTTPException(status_code=401, detail="令牌已过期，请重新注册")
    return {"user_id": str(user_id), "device_id": str(device_id)}


# ================= 数据模型 =================
class ChallengeReq(BaseModel):
    device_id: str


class RegisterData(BaseModel):
    device_id: str
    public_key: str
    provider: str            # 'google' | 'apple'
    user_id: str             # 客户端自报的账号（最终以 ID Token 校验为准）
    id_token: str
    challenge_id: str        # 服务器签发的一次性挑战 ID
    challenge: str           # 与 challenge_id 对应的挑战原文（用于签名校验）
    signature: str           # 硬件私钥对 challenge 的签名（Base64）


class InputData(BaseModel):
    token: str = ""
    user_id: str = ""
    text: str


class StoryInputData(BaseModel):
    """小说生成请求：App 只上传用户最新输入，其余设定/上一段由服务器从数据库读取。
    （App 端有专门的 reset 功能，不走本生成接口。）

    choice_1/2/3：本轮用户在 App 三个输入框里输入的三个选项（随行快照，服务器存储）。
    """
    token: str = ""
    user_id: str = ""
    user_input: str = ""
    choice_1: str = ""
    choice_2: str = ""
    choice_3: str = ""
    # 时间树"从这里重写"：>=0 时表示从该 seq 截断后续段，并作为新段续写（-1=不重写）
    rewrite_from: int = -1
    # 第一轮生成时，App 把用户设定随请求上传，服务器随小说正文一起落库
    # （不再单独存储到 user_settings 表）
    location: str = ""
    era: str = ""
    player_name: str = ""
    player_traits: str = ""
    language: str = ""


class PurchaseData(BaseModel):
    provider: str            # 'appstore' | 'googleplay'
    receipt: str = ""        # App Store transaction/receipt 或 Google purchaseToken
    product_id: str = ""


class SyncPutData(BaseModel):
    key: str
    content: str = ""
    updated_at: int


class StoryData(BaseModel):
    """小说正文数组：每次生成的内容为数组的一个元素（与客户端 List<String> 对应）。"""
    segments: list[str] = []
    updated_at: int = 0


class ActivateData(BaseModel):
    """App 启动握手请求：上传本机硬件公钥与用户 id，服务器校验后更新硬件公钥。"""
    user_id: str = ""
    public_key: str = ""


# ================= 辅助函数 =================
_DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_PROVIDER_RE = re.compile(r"^(google|apple|dev)$")


def _validate_device_id(device_id: str) -> str:
    device_id = (device_id or "").strip()
    if not device_id:
        raise HTTPException(status_code=400, detail="缺少 device_id")
    if not _DEVICE_ID_RE.fullmatch(device_id):
        raise HTTPException(status_code=400, detail="device_id 含非法字符或过长")
    return device_id


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


# 多设备冲突的错误标识：App 检测到该 detail 时弹出"多设备同时登入"警告并重启
DEVICE_CONFLICT_DETAIL = "device_conflict"


def _enforce_active_device(user_id: str, device_id: str) -> None:
    """多设备防护：请求携带的设备必须与当前活跃设备一致，否则 409 冲突。

    若请求的 device_id 与该用户当前活跃设备不一致，抛出
    HTTPException(409, DEVICE_CONFLICT_DETAIL)，App 据此弹出
    "多个设备同时登入"警告并重启本 App。
    """
    conn = _db()
    try:
        row = conn.execute(
            "SELECT active_device_id FROM users WHERE user_id=?", (user_id,)
        ).fetchone()
        active = row["active_device_id"] if row else None
        if active and active != device_id:
            raise HTTPException(
                status_code=409,
                detail=DEVICE_CONFLICT_DETAIL,
            )
    finally:
        conn.close()


# 注册限流（进程内 + SQLite 持久化双保险）
def _throttle_register(ip: str) -> None:
    now = int(time.time())
    conn = _db()
    try:
        conn.execute(
            """INSERT INTO challenges_guard (ip, ts) VALUES (?, ?)""",
            (ip, now),
        )
        conn.commit()
        # 简单滑窗统计
        row = conn.execute(
            """SELECT COUNT(*) AS c FROM challenges_guard
               WHERE ip=? AND ts > ?""",
            (ip, now - 3600),
        ).fetchone()
        if row["c"] > REGISTER_LIMIT_PER_IP_PER_HOUR:
            raise HTTPException(status_code=429, detail="注册过于频繁，请稍后再试")
        # 清理旧记录
        conn.execute("DELETE FROM challenges_guard WHERE ts < ?", (now - 7200,))
        conn.commit()
    finally:
        conn.close()


# 同硬件 24 小时内使用账号记账（防换账号刷试用/配额）
def _touch_hardware_account(conn, public_key: str, user_id: str, now: int) -> None:
    conn.execute(
        """INSERT INTO hardware_accounts (public_key, user_id, last_seen_at)
           VALUES (?, ?, ?)
           ON CONFLICT(public_key, user_id) DO UPDATE SET
             last_seen_at=excluded.last_seen_at""",
        (public_key, user_id, now),
    )
    # 顺带清理 48 小时前的过期记录，控制表体积
    conn.execute(
        "DELETE FROM hardware_accounts WHERE last_seen_at < ?",
        (now - 2 * 86400,),
    )


# ================= 输入成本控制（S5） =================
def _estimate_tokens(text: str) -> int:
    """粗略估算 token 数（中文约 1 token/字，英文约 4 字符/token）。"""
    cjk = sum(1 for ch in text if "\u4e00" <= ch <= "\u9fff")
    other = len(text) - cjk
    return int(cjk * 1.0 + other / 3.5) + 1


def _check_input_budget(text: str) -> None:
    if not text or not text.strip():
        raise HTTPException(status_code=400, detail="缺少待处理文本 text")
    if len(text) > MAX_INPUT_CHARS:
        raise HTTPException(
            status_code=400,
            detail=f"输入过长（超过 {MAX_INPUT_CHARS} 字符）",
        )
    est = _estimate_tokens(text)
    if est > MAX_INPUT_TOKENS:
        raise HTTPException(
            status_code=400,
            detail=f"输入超过 {MAX_INPUT_TOKENS} token 上限，请精简内容",
        )


# ================= ID Token 校验（S2） =================
_jwks_cache: dict = {}
_JWKS_TTL = 3600


async def _get_jwks(provider: str) -> dict:
    """获取并缓存 provider 的 JWKS。"""
    now = time.time()
    cached = _jwks_cache.get(provider)
    if cached and now - cached["fetched_at"] < _JWKS_TTL:
        return cached["keys"]
    url = (
        "https://www.googleapis.com/oauth2/v3/certs"
        if provider == "google"
        else "https://appleid.apple.com/auth/keys"
    )
    resp = await async_http_client.get(url, timeout=15.0)
    if resp.status_code != 200:
        raise HTTPException(status_code=503, detail="无法获取身份校验密钥")
    keys = resp.json().get("keys", [])
    _jwks_cache[provider] = {"keys": keys, "fetched_at": now}
    return keys


def _verify_google_token(id_token: str) -> dict:
    keys = jwt.PyJWKClient(
        "https://www.googleapis.com/oauth2/v3/certs",
        cache_keys=True,
    ).get_signing_key_from_jwt(id_token)
    payload = jwt.decode(
        id_token,
        key=keys.key,
        algorithms=["RS256"],
        audience=GOOGLE_CLIENT_ID,
        issuer=["accounts.google.com", "https://accounts.google.com"],
    )
    return payload


def _verify_apple_token(id_token: str) -> dict:
    keys = jwt.PyJWKClient(
        "https://appleid.apple.com/auth/keys",
        cache_keys=True,
    ).get_signing_key_from_jwt(id_token)
    payload = jwt.decode(
        id_token,
        key=keys.key,
        algorithms=["RS256"],
        audience=APPLE_SERVICE_ID or APPLE_APP_BUNDLE_ID,
        issuer="https://appleid.apple.com",
    )
    return payload


async def verify_id_token(provider: str, id_token: str) -> dict:
    """校验 ID Token，返回 {user_id(sub), email}；失败抛 401。"""
    # 开发模式：provider=dev 跳过平台 OAuth 校验（仅联调用，生产必须关闭）
    if provider == "dev":
        if not DEV_MODE:
            raise HTTPException(status_code=403, detail="dev provider 未启用（DEV_MODE=1）")
        if not id_token:
            raise HTTPException(status_code=401, detail="缺少测试 user_id（id_token 字段）")
        return {"user_id": str(id_token).strip(), "email": ""}

    if not id_token:
        raise HTTPException(status_code=401, detail="缺少 ID Token")
    try:
        if provider == "google":
            if not GOOGLE_CLIENT_ID:
                raise HTTPException(status_code=500, detail="服务器未配置 GOOGLE_CLIENT_ID")
            payload = _verify_google_token(id_token)
        elif provider == "apple":
            if not (APPLE_SERVICE_ID or APPLE_APP_BUNDLE_ID):
                raise HTTPException(status_code=500, detail="服务器未配置 APPLE_SERVICE_ID")
            payload = _verify_apple_token(id_token)
        else:
            raise HTTPException(status_code=400, detail="不支持的 provider")
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"ID Token 校验失败: {e}")
    except HTTPException:
        raise
    sub = payload.get("sub")
    if not sub:
        raise HTTPException(status_code=401, detail="ID Token 缺少 sub")
    return {"user_id": str(sub), "email": payload.get("email") or ""}


# ================= 注册（S3） =================
@app.get("/api/health")
async def health():
    conn = _db()
    try:
        n_users = conn.execute("SELECT COUNT(*) AS c FROM users").fetchone()["c"]
        n_devices = conn.execute("SELECT COUNT(*) AS c FROM devices").fetchone()["c"]
    finally:
        conn.close()
    return {
        "status": "ok",
        "registered_users": n_users,
        "registered_devices": n_devices,
    }


@app.post("/api/register/challenge")
async def register_challenge(data: ChallengeReq, request: Request):
    """第一步：向服务器要一次性挑战（防重放）。"""
    device_id = _validate_device_id(data.device_id)
    _throttle_register(_client_ip(request))
    challenge = secrets.token_urlsafe(32)
    challenge_id = secrets.token_urlsafe(16)
    conn = _db()
    try:
        conn.execute(
            """INSERT INTO challenges (challenge_id, device_id, challenge, expires_at)
               VALUES (?, ?, ?, ?)""",
            (challenge_id, device_id, challenge, int(time.time()) + 300),
        )
        conn.commit()
    finally:
        conn.close()
    return {"challenge_id": challenge_id, "challenge": challenge}


@app.post("/api/register")
async def register(data: RegisterData, request: Request):
    """第二步：校验 ID Token + 硬件签名，绑定账号+设备+公钥，签发令牌。

    安全要点：
    - 用官方 JWKS 校验 id_token，取 sub 作为真实 user_id（不信客户端自报）。
    - 验 challenge 存在且未过期、且属于该 device_id。
    - 用该设备的公钥验 challenge 签名（证明持有硬件私钥）。
    - public_key UNIQUE：同硬件不能再绑到别的 device_id（防同硬件多 ID）。
    """
    device_id = _validate_device_id(data.device_id)
    if not _PROVIDER_RE.fullmatch((data.provider or "").strip()):
        raise HTTPException(status_code=400, detail="provider 非法")
    if not data.public_key or len(data.public_key) > 2048:
        raise HTTPException(status_code=400, detail="public_key 非法")

    # 1) 校验 ID Token → 真实 user_id
    verified = await verify_id_token(data.provider, data.id_token)
    real_user_id = verified["user_id"]

    # 2) 校验挑战
    conn = _db()
    try:
        row = conn.execute(
            """SELECT challenge, expires_at FROM challenges
               WHERE challenge_id=? AND device_id=?""",
            (data.challenge_id, device_id),
        ).fetchone()
        if not row:
            raise HTTPException(status_code=400, detail="挑战不存在")
        if row["expires_at"] < int(time.time()):
            raise HTTPException(status_code=400, detail="挑战已过期，请重新获取")
        # 客户端回传的 challenge 必须与服务器签发的一致（防伪造）
        if (data.challenge or "") != row["challenge"]:
            raise HTTPException(status_code=400, detail="挑战不匹配")
        expected_challenge = row["challenge"]

        # 3) 校验硬件签名（ECDSA SHA256）
        if not _verify_hardware_signature(
            data.public_key, expected_challenge, data.signature
        ):
            raise HTTPException(status_code=401, detail="硬件签名校验失败")

        now = int(time.time())

        # 4) public_key UNIQUE 检查（同硬件多账号防护，防换账号刷试用/配额）
        existing = conn.execute(
            """SELECT device_id, user_id FROM devices WHERE public_key=?""",
            (data.public_key,),
        ).fetchone()
        if existing and existing["user_id"] != real_user_id:
            # 同硬件换账号：
            #  - 该账号 24h 内已在这台硬件登入过 → 允许切回（不算新增不同账号）
            #  - 否则统计 24h 内已使用过的不同账号数；达到上限则拒绝。
            #    detail 使用机器可识别的错误码 hardware_account_limit，
            #    供 App 弹出英文警告并直接退出。
            used_before = conn.execute(
                """SELECT 1 FROM hardware_accounts
                   WHERE public_key=? AND user_id=? AND last_seen_at >= ?""",
                (data.public_key, real_user_id, now - 24 * 3600),
            ).fetchone()
            if not used_before:
                distinct_today = conn.execute(
                    """SELECT COUNT(DISTINCT user_id) AS c FROM hardware_accounts
                       WHERE public_key=? AND last_seen_at >= ?""",
                    (data.public_key, now - 24 * 3600),
                ).fetchone()["c"]
                if distinct_today >= HARDWARE_ACCOUNTS_PER_DAY:
                    raise HTTPException(
                        status_code=409,
                        detail="hardware_account_limit",
                    )
            # 换账号放行：该硬件换绑到新账号，删除旧 device 绑定
            if existing["device_id"] != device_id:
                conn.execute(
                    "DELETE FROM devices WHERE device_id=?",
                    (existing["device_id"],),
                )
        elif existing:
            # 同硬件 + 同账号：允许（应用重装/清数据后 device_id 变化时，
            # 删除旧绑定，以新 device_id 重新绑定，保证同账号能正常恢复使用）
            if existing["device_id"] != device_id:
                conn.execute(
                    "DELETE FROM devices WHERE device_id=?",
                    (existing["device_id"],),
                )

        # 记录/刷新该硬件 24h 内使用过的账号（同账号重装、换账号都记账）
        _touch_hardware_account(conn, data.public_key, real_user_id, now)

        # 5) upsert user（注册即把该设备登记为当前活跃硬件）
        conn.execute(
            """INSERT INTO users (user_id, provider, email, active_device_id, created_at)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(user_id) DO UPDATE SET
                 provider=excluded.provider,
                 active_device_id=excluded.active_device_id,
                 email=CASE WHEN excluded.email<>'' THEN excluded.email ELSE users.email END""",
            (real_user_id, data.provider, verified["email"], device_id, now),
        )

        # 6) upsert device（同 device_id 换公钥 = 密钥轮换，允许）
        is_rotation = existing is not None
        conn.execute(
            """INSERT INTO devices
                 (device_id, user_id, public_key, status, created_at, last_seen_at)
               VALUES (?, ?, ?, 'active', ?, ?)
               ON CONFLICT(device_id) DO UPDATE SET
                 user_id=excluded.user_id,
                 public_key=excluded.public_key,
                 last_seen_at=excluded.last_seen_at,
                 key_rotated_at=CASE WHEN devices.public_key<>excluded.public_key
                                     THEN excluded.last_seen_at ELSE devices.key_rotated_at END,
                 status='active'""",
            (device_id, real_user_id, data.public_key, now, now),
        )

        # 7) 清理已用挑战
        conn.execute("DELETE FROM challenges WHERE challenge_id=?", (data.challenge_id,))
        conn.commit()
    finally:
        conn.close()

    expires_at = now + TOKEN_EXPIRY_DAYS * 86400
    token = create_token(real_user_id, device_id, expires_at)
    return {
        "token": token,
        "token_type": "bearer",
        "user_id": real_user_id,
        "device_id": device_id,
        "key_rotated": is_rotation,
        "expires_at": expires_at,
        "expires_at_iso": datetime.fromtimestamp(
            expires_at, tz=timezone.utc
        ).isoformat(),
    }


def _verify_hardware_signature(public_key_b64: str, message: str, signature_b64: str) -> bool:
    """用 SPKI 公钥验 ECDSA P-256 (SHA256) 签名。兼容 DER 与 raw 两种签名格式。"""
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        from cryptography.exceptions import InvalidSignature

        pub = serialization.load_der_public_key(
            base64.b64decode(public_key_b64)
        )
        if not isinstance(pub, ec.EllipticCurvePublicKey):
            return False
        sig = base64.b64decode(signature_b64)
        msg = message.encode("utf-8")
        # 尝试 DER（X9.62）签名
        try:
            pub.verify(sig, msg, ec.ECDSA(hashes.SHA256()))
            return True
        except InvalidSignature:
            pass
        # 尝试 raw (r||s) 签名
        try:
            sig_len = len(sig)
            if sig_len % 2 != 0:
                return False
            half = sig_len // 2
            r = int.from_bytes(sig[:half], "big")
            s = int.from_bytes(sig[half:], "big")
            der = utils.encode_dss_signature(r, s)
            pub.verify(der, msg, ec.ECDSA(hashes.SHA256()))
            return True
        except Exception:
            return False
    except Exception:
        return False


# ================= 权益（S4 / S5，付费预留） =================
def _get_entitlement(user_id: str) -> Optional[dict]:
    conn = _db()
    try:
        row = conn.execute(
            """SELECT * FROM entitlements WHERE user_id=?""",
            (user_id,),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def _is_paid_active(ent: Optional[dict]) -> bool:
    if not ent:
        return False
    if ent.get("status") != "active":
        return False
    now = int(time.time())
    # 订阅型：有效期未过
    if ent.get("expires_at") and ent["expires_at"] <= now:
        return False
    # 次数型：还有剩余次数
    if ent.get("purchased_quota"):
        if ent.get("used_quota", 0) >= ent["purchased_quota"]:
            return False
    return True


def _count_usage(user_id: str, now: int, tokens: int, quota: int, rate: int) -> None:
    """按 user 每日配额 + 每分钟限流记账；超限抛 429。"""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    conn = _db()
    try:
        row = conn.execute(
            """SELECT count, tokens_used FROM usage WHERE user_id=? AND date=?""",
            (user_id, today),
        ).fetchone()
        count = row["count"] if row else 0
        if count >= quota:
            raise HTTPException(status_code=429, detail="今日次数已达上限，请明日再试")

        # 每分钟限流（用 usage 表 recent 时间戳：单独存 recent_timestamps）
        recent = conn.execute(
            """SELECT ts FROM rate WHERE user_id=? AND ts > ?""",
            (user_id, now - 60),
        ).fetchall()
        if len(recent) >= rate:
            raise HTTPException(status_code=429, detail="请求过于频繁，请稍后再试")

        conn.execute(
            """INSERT INTO rate (user_id, ts) VALUES (?, ?)""",
            (user_id, now),
        )
        # 清理一分钟前的限流记录，避免表无限增长
        conn.execute("DELETE FROM rate WHERE ts < ?", (now - 120,))
        conn.execute(
            """INSERT INTO usage (user_id, date, count, tokens_used)
               VALUES (?, ?, 1, ?)
               ON CONFLICT(user_id, date) DO UPDATE SET
                 count = usage.count + 1,
                 tokens_used = usage.tokens_used + excluded.tokens_used""",
            (user_id, today, tokens),
        )
        conn.commit()
    finally:
        conn.close()


# ================= 路由：审核（S5） =================
@app.post("/api/audit-and-chat")
async def audit_and_chat(data: InputData, request: Request):
    token = _extract_token(data, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)

    # 输入成本控制（花钱之前硬拦）
    user_text = data.text
    _check_input_budget(user_text)

    # 设定页审核无每用户限制，唯一硬限为全局审核 Dify 流程 AUDIT_DAILY_LIMIT（4000 次/天）
    _check_audit_quota(int(time.time()))

    headers = {
        "Authorization": f"Bearer {DIFY_API_KEY}",
        "Content-Type": "application/json",
    }
    dify_payload = {
        "inputs": {
            "text_to_screen": user_text,
            # 若 Dify 画布把 max_tokens 绑定为输入变量，则此处动态下发；
            # 否则 Dify 节点内固定 max_tokens=DIFY_MAX_TOKENS。
            "max_tokens": DIFY_MAX_TOKENS,
        },
        "response_mode": "blocking",
        "user": user_id,
    }

    try:
        response = await async_http_client.post(
            DIFY_API_URL, json=dify_payload, headers=headers
        )
        if response.status_code != 200:
            raise HTTPException(
                status_code=response.status_code,
                detail=f"Dify 接口调用失败，状态码: {response.status_code}，详情: {response.text}",
            )
        dify_data = response.json()
        data_block = dify_data.get("data") or {}
        # Dify blocking 模式下，工作流自身失败时 HTTP 仍为 200，但 status=failed 且无 outputs
        if data_block.get("status") == "failed":
            err = data_block.get("error") or data_block.get("message") or "未知错误"
            raise HTTPException(
                status_code=502,
                detail=f"Dify 审核工作流执行失败: {err}",
            )
        final_text = _extract_guardrail_output(dify_data)
        if not final_text:
            # 记录 Dify 原始返回，便于排查画板 End 节点输出结构
            raw_preview = json.dumps(dify_data, ensure_ascii=False)[:1200]
            logger.warning(
                "audit-and-chat: Dify 响应中未找到 guardrail_return_json，"
                "status=%s 原始响应=%s",
                data_block.get("status"),
                raw_preview,
            )
            keys = ", ".join(
                map(str, (data_block.get("outputs") or {}).keys())
            ) or "(未返回任何 outputs)"
            raise HTTPException(
                status_code=500,
                detail=(
                    "Dify 未返回有效的 guardrail_return_json 字段，"
                    "请检查画板 End 节点输出变量名是否为 guardrail_return_json。"
                    f"实际返回的输出字段: [{keys}]"
                ),
            )
        # 输出兜底截断（成本已在 max_tokens 锁死，这里是防异常返回超长文本）
        final_text = final_text[: MAX_INPUT_CHARS * 2]
        # 服务端统一解析并返回结构化判定，客户端只消费其中的 action 字段
        return _build_audit_verdict(final_text)
    except httpx.RequestError as exc:
        raise HTTPException(status_code=503, detail=f"与 Dify 服务器通信网络异常: {str(exc)}")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"网关内部解析异常: {str(e)}")


def _check_story_quota(now: int) -> None:
    """小说生成工作流全局 24 小时滚动配额：超限直接 429 报警，禁止继续调用。"""
    conn = _db()
    try:
        # 清理窗口外旧记录
        conn.execute("DELETE FROM story_usage WHERE ts < ?", (now - STORY_WINDOW_SECONDS,))
        row = conn.execute(
            "SELECT COUNT(*) AS c FROM story_usage WHERE ts > ?",
            (now - STORY_WINDOW_SECONDS,),
        ).fetchone()
        if row["c"] >= STORY_DAILY_LIMIT:
            raise HTTPException(
                status_code=429,
                detail=f"小说生成今日调用已达上限 {STORY_DAILY_LIMIT} 次，已触发报警并禁止继续调用，请 24 小时后再试",
            )
        # 记录本次调用
        conn.execute("INSERT INTO story_usage (ts) VALUES (?)", (now,))
        conn.commit()
    finally:
        conn.close()


def _check_audit_quota(now: int) -> None:
    """审核工作流全局 24 小时滚动配额：超限直接 429，禁止继续调用审核 Dify。"""
    conn = _db()
    try:
        # 清理窗口外旧记录
        conn.execute("DELETE FROM audit_usage WHERE ts < ?", (now - STORY_WINDOW_SECONDS,))
        row = conn.execute(
            "SELECT COUNT(*) AS c FROM audit_usage WHERE ts > ?",
            (now - STORY_WINDOW_SECONDS,),
        ).fetchone()
        if row["c"] >= AUDIT_DAILY_LIMIT:
            raise HTTPException(
                status_code=429,
                detail=f"审核服务今日调用已达上限 {AUDIT_DAILY_LIMIT} 次，已触发报警并禁止继续调用，请 24 小时后再试",
            )
        # 记录本次调用
        conn.execute("INSERT INTO audit_usage (ts) VALUES (?)", (now,))
        conn.commit()
    finally:
        conn.close()


def _sse(obj: dict) -> str:
    """把字典编码为一条 SSE 事件（data: {...}\n\n）。"""
    return f"data: {json.dumps(obj, ensure_ascii=False)}\n\n"


def _extract_first_object(data) -> Optional[dict]:
    """从解析后的 JSON 数据里取出一个对象（dict）。

    - dict → 直接返回；
    - list → 返回第一个对象元素；若元素是 JSON 字符串（Dify 常把
      数组元素显示为 String），则逐个解一层再取；
    - str → 顶层被 JSON 字符串包了一层（双重序列化），解一层再取；
    - 其它 / 取不到 → None（fail-closed）。
    """
    if isinstance(data, dict):
        return data
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                return item
        for item in data:
            if isinstance(item, str):
                try:
                    nested = json.loads(item)
                except Exception:
                    continue
                found = _extract_first_object(nested)
                if found is not None:
                    return found
        return None
    if isinstance(data, str):
        try:
            nested = json.loads(data)
        except Exception:
            return None
        return _extract_first_object(nested)
    return None


def _parse_audit_output(out: str) -> Optional[dict]:
    """解析审核工作流输出为一个 JSON 对象；失败返回 None。

    兼容多种形态：
    - 直接是 JSON 对象：{"action": "NONE", ...}
    - JSON 数组（Dify guardrail 节点输出为 Array）：
      [{"action": "NONE", ...}] 或 ["{\\"action\\": \\"NONE\\", ...}"]
      取第一个可用的对象元素；
    - 顶层被 JSON 字符串包了一层（双重序列化）。
    另兼容带 markdown 代码围栏（```json ... ```）的输出。
    """
    if not out or not out.strip():
        return None
    text = out.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\s*", "", text)
        text = re.sub(r"\s*```\s*$", "", text)
    try:
        data = json.loads(text)
    except Exception:
        return None
    return _extract_first_object(data)


def _parse_audit_json(out: str) -> Optional[str]:
    """严格读取审核结果中的 action 字段（大小写不敏感、忽略首尾空白）。

    只有真正的 action 字段才计数；解析失败 / 非对象 / 找不到 action /
    值不是字符串 → 返回 None（调用方按不通过处理，fail-closed）。
    """
    data = _parse_audit_output(out)
    if data is None:
        return None
    action = None
    for k, v in data.items():
        if isinstance(k, str) and k.strip().lower() == "action":
            action = v
            break
    if not isinstance(action, str):
        return None
    return action.strip().lower()


class ModerationOutcome(Enum):
    """审核结果三态：区分"明确违规"与"审核不可用"。

    - PASS：明确判定通过（action == "none"）。
    - REJECT：审核成功并返回非 none 的 action（明确判定违规）。
    - UNAVAILABLE：审核不可用（配额超限 / 网络失败 / 非 200 / 输出无法解析）。
      这是审核链路自身的问题，不代表内容违规，调用方应作为可重试错误处理，
      而不是弹出"内容违规"警告（避免弱网/审核服务抖动被误判为用户违规）。
    """
    PASS = "pass"
    REJECT = "reject"
    UNAVAILABLE = "unavailable"


def _build_audit_verdict(out: str) -> dict:
    """把审核工作流输出整理为结构化判定返回给客户端。

    客户端只消费其中的 action 字段：action=="none" 放行，否则不通过。
    解析失败 / 找不到 action → 一律返回 action="block"（fail-closed）。
    """
    data = _parse_audit_output(out)
    action = _parse_audit_json(out)
    if data is None or action is None:
        return {
            "action": "block",
            "category": "unknown",
            "confidence": 0.0,
            "reason": "audit_result_unparseable",
        }
    category = str(data.get("category") or "none")
    try:
        confidence = float(data.get("confidence") or 1.0)
    except Exception:
        confidence = 1.0
    return {
        "action": "none" if action == "none" else "block",
        "category": category,
        "confidence": confidence,
        "reason": str(data.get("reason") or ""),
    }


async def _moderate_story(text: str) -> ModerationOutcome:
    """调用审核工作流，返回三态判定（见 ModerationOutcome）。

    只把"审核成功且明确判为违规"当作 REJECT；配额超限、网络失败、
    非 200、输出无法解析等一律返回 UNAVAILABLE（可重试，非违规）。
    """
    if not text or not text.strip():
        return ModerationOutcome.PASS
    # 审核工作流全局配额（所有用户合计 AUDIT_DAILY_LIMIT 次/天）：
    # 超限时不调用 Dify，视为"审核不可用"（可重试），而非"内容违规"。
    try:
        _check_audit_quota(int(time.time()))
    except HTTPException:
        return ModerationOutcome.UNAVAILABLE
    headers = {
        "Authorization": f"Bearer {DIFY_API_KEY}",
        "Content-Type": "application/json",
    }
    payload = {
        "inputs": {"text_to_screen": text, "max_tokens": DIFY_MAX_TOKENS},
        "response_mode": "blocking",
        "user": "story-moderation",
    }
    try:
        resp = await async_http_client.post(
            DIFY_API_URL, json=payload, headers=headers, timeout=60.0
        )
        if resp.status_code != 200:
            return ModerationOutcome.UNAVAILABLE
        data = resp.json()
        out = _extract_guardrail_output(data)
        action = _parse_audit_json(out)
        if action is None:
            # 审核成功但无有效 action 判定：视为审核链路异常（可重试），非违规
            return ModerationOutcome.UNAVAILABLE
        return ModerationOutcome.PASS if action == "none" else ModerationOutcome.REJECT
    except Exception:
        # 网络 / 超时 / 解析异常：审核不可用（可重试），非违规
        return ModerationOutcome.UNAVAILABLE


def _moderation_failure_sse(mr: ModerationOutcome) -> Optional[dict]:
    """把非 PASS 的审核结果映射为应发送的 SSE 事件；PASS 返回 None。

    REJECT → abort（违规，弹"内容违规"）；UNAVAILABLE → error（可重试，网络式警告）。
    """
    if mr is ModerationOutcome.REJECT:
        return {"event": "abort", "reason": "生成内容包含违规信息，已中止"}
    if mr is ModerationOutcome.UNAVAILABLE:
        return {
            "event": "error",
            "message": "内容审核服务暂时不可用，请检查网络后重试",
        }
    return None


async def _generate_case_meta() -> dict:
    """调用"案件生成"Dify 工作流，生成当前案件的类型与核心（凶杀案设定）。

    该工作流无输入变量，只返回结果（blocking 模式）。
    返回 {"case_type": str, "case_core": str}，键与 story_segments 表、
    _extract_story_meta 的 defaults 完全对齐，可直接并入后续生成流程。
    Dify 返回 victim_identity / death_scene / murder_method 三个量，
    将其简单拼接（换行连接）后赋给 case_core；case_type 兼容
    case_type/core_type/type 多种键名。
    任何失败（网络 / 非 200 / 解析失败）都回退为空串，绝不抛异常。
    """
    headers = {
        "Authorization": f"Bearer {CASE_DIFY_API_KEY}",
        "Content-Type": "application/json",
    }
    payload = {
        "inputs": {},
        "response_mode": "blocking",
        "user": "case-generator",
    }
    empty = {"case_type": "", "case_core": ""}
    try:
        resp = await async_http_client.post(
            CASE_DIFY_API_URL, json=payload, headers=headers, timeout=60.0
        )
        if resp.status_code != 200:
            logger.warning("案件工作流返回非 200：%s", resp.status_code)
            return empty
        data = resp.json()
        data_block = data.get("data") if isinstance(data, dict) else None
        outputs = (
            data_block.get("outputs")
            if isinstance(data_block, dict) and isinstance(data_block.get("outputs"), dict)
            else {}
        )

        def _pick(*names: str) -> str:
            for n in names:
                v = outputs.get(n)
                if isinstance(v, str) and v.strip():
                    return v.strip()
            return ""

        victim_identity = _pick("victim_identity")
        death_scene = _pick("death_scene")
        murder_method = _pick("murder_method")
        # 将三个量简单拼接（换行连接）赋给 case_core（即 README 原设计）。
        # 注意：工作流代码节点另返回 core_content（= 生成案件的提示词）与 core_type（类型标签），
        # core_content 是提示词而非生成结果，绝不可作为 case_core 入库。
        core = "\n".join(
            p for p in (victim_identity, death_scene, murder_method) if p
        )
        return {
            "case_type": _pick("case_type", "core_type", "type"),
            "case_core": core,
        }
    except Exception:
        logger.warning("案件工作流调用失败", exc_info=True)
        return empty


def _get_story_count(user_id: str) -> int:
    """只读该用户小说段落总数（续写/全新判断用）。"""
    conn = _db()
    try:
        cnt = conn.execute(
            """SELECT COUNT(*) AS c FROM story_segments WHERE user_id=?""",
            (user_id,),
        ).fetchone()["c"]
        return cnt
    finally:
        conn.close()


# 一个案件/一卷的轮次数（案件设定刷新周期，也是 corrent_case_all_content 的正文回溯窗口）
CASE_ROUNDS = 14


def _get_current_case_story(user_id: str, seq: int) -> str:
    """汇总要回传给 Dify 的正文（corrent_case_all_content 的取值来源）。

    规则（seq 为当前正要生成的那一轮，0 起计；CASE_ROUNDS=14）：
    - seq == 0（第 0 轮，无前文）→ 返回空串；
    - seq 是 CASE_ROUNDS 的整倍数（14/28/42...，新一卷起点）→ 返回
      上一整卷全部正文（0~13 / 14~27 / 28~41），而不是空串；
    - 其余轮次 → 从最近一个 CASE_ROUNDS 整倍数轮次（含）到当前轮前一轮
      （seq-1，含）的正文，按 seq 升序以换行拼接；该区间无正文时返回空串。
    注：corrent_case_all_content 读的是 content 列（正文原文），
    为下一轮生成提供当前案件的完整续写上下文。
    """
    if seq == 0:
        return ""
    if seq % CASE_ROUNDS == 0:
        start = seq - CASE_ROUNDS
    else:
        start = (seq // CASE_ROUNDS) * CASE_ROUNDS
    end = seq - 1
    conn = _db()
    try:
        rows = conn.execute(
            """SELECT content FROM story_segments
               WHERE user_id=? AND seq BETWEEN ? AND ? ORDER BY seq ASC""",
            (user_id, start, end),
        ).fetchall()
        parts = [r["content"] for r in rows if r["content"] and r["content"].strip()]
        return "\n".join(parts)
    finally:
        conn.close()


# 后续变量保底默认值：任一原因取不到时写入数据库的兜底值
# choice_1/2/3 即 LLM② 推荐的下一轮行动（统一用 choices_1/2/3）。
# 默认行动选项按用户语言（App 随请求上传 / 最新段快照的 language）选择对应语言版本；
# 未知语言回退简体中文。music_style 是 Dify 工作流结构化枚举（白名单 MUSIC_STYLE_VALUES），
# 为保持与画布兼容，各语言统一用白名单内取值，不做本地化。
META_DEFAULTS = {
    "choice_1": "继续当前行动，深入探索",
    "choice_2": "停下脚步，先观察四周再行动",
    "choice_3": "换一个方向，探索其它可能",
    "music_style": "悬疑",
    "case_type": "",   # 当前案件类型（Dify core_type；无则保底为空）
    "case_core": "",   # 当前案件核心（Dify core_content；无则保底为空）
}
META_DEFAULTS_BY_LANG = {
    "zh": META_DEFAULTS,
    "zh-TW": {
        "choice_1": "繼續目前行動，深入探索",
        "choice_2": "停下腳步，先觀察四周再行動",
        "choice_3": "換一個方向，探索其他可能",
        "music_style": "悬疑",
    },
    "yue": {
        "choice_1": "繼續而家嘅行動，深入探索",
        "choice_2": "停低腳步，先睇下四周再行動",
        "choice_3": "轉另一個方向，探索其他可能",
        "music_style": "悬疑",
    },
    "en": {
        "choice_1": "Continue your current action and explore deeper",
        "choice_2": "Pause, observe your surroundings before acting",
        "choice_3": "Change direction and explore other possibilities",
        "music_style": "悬疑",
    },
    "es": {
        "choice_1": "Continúa tu acción actual y explora a fondo",
        "choice_2": "Detente, observa tu entorno antes de actuar",
        "choice_3": "Cambia de dirección y explora otras posibilidades",
        "music_style": "悬疑",
    },
    "fr": {
        "choice_1": "Continuez votre action actuelle et explorez en profondeur",
        "choice_2": "Arrêtez-vous, observez les alentours avant d'agir",
        "choice_3": "Changez de direction et explorez d'autres possibilités",
        "music_style": "悬疑",
    },
    "de": {
        "choice_1": "Setze deine aktuelle Handlung fort und erkunde tiefer",
        "choice_2": "Halte inne und beobachte zuerst deine Umgebung",
        "choice_3": "Schlage eine andere Richtung ein und erkunde weitere Möglichkeiten",
        "music_style": "悬疑",
    },
    "pt": {
        "choice_1": "Continue sua ação atual e explore a fundo",
        "choice_2": "Pare, observe ao redor antes de agir",
        "choice_3": "Mude de direção e explore outras possibilidades",
        "music_style": "悬疑",
    },
    "ja": {
        "choice_1": "現在の行動を続けて、深く探索する",
        "choice_2": "立ち止まり、まず周囲を観察してから行動する",
        "choice_3": "方向を変えて、他の可能性を探る",
        "music_style": "悬疑",
    },
    "ko": {
        "choice_1": "현재 행동을 계속하며 깊이 탐험한다",
        "choice_2": "멈추고, 먼저 주변을 관찰한 뒤 행동한다",
        "choice_3": "방향을 바꿔 다른 가능성을 탐색한다",
        "music_style": "悬疑",
    },
}


def _meta_defaults(language: Optional[str]) -> dict:
    """按用户语言返回后续变量保底默认值；未知/为空回退简体中文。

    先用简体中文 META_DEFAULTS 打底（含 case_type/case_core 等公共键），
    再用该语言的 choice/music_style 覆盖，保证任意语言都拥有完整键集合。
    """
    base = dict(META_DEFAULTS)
    base.update(META_DEFAULTS_BY_LANG.get((language or "").strip(), {}))
    return base


# music_style 合法取值白名单（与 Dify 提示词一致）
MUSIC_STYLE_VALUES = ["喜悦", "温情", "爱情", "黑暗", "悬疑", "推理", "惊悚", "幸福", "兴奋"]


def _extract_story_meta(
    outputs: Optional[dict], language: Optional[str] = None
) -> dict:
    """从 Dify outputs 中提取后续变量（choice_1/choice_2/choice_3/music_style）与案件信息。

    推演结果（LLM2 structured_output，经 End 节点扁平输出）映射：
      music / music_style     -> music_style
      action_a                -> choice_2
      action_b                -> choice_3
      choice_1 恒为空（用户后续自行填写，或直接选 choice_2/3）
    任一字段缺失 / 非字符串 / 为空 / music_style 不在白名单 → 用保底默认值。
    """
    src = outputs if isinstance(outputs, dict) else {}
    defaults = _meta_defaults(language)

    def _s(*names: str) -> str:
        for n in names:
            v = src.get(n)
            if isinstance(v, str) and v.strip():
                return v.strip()
        return ""

    meta = {
        "choice_1": "",  # 默认空白，由用户后续自行填写
        "choice_2": _s("action_a") or defaults["choice_2"],
        "choice_3": _s("action_b") or defaults["choice_3"],
        "music_style": _s("music", "music_style") or defaults["music_style"],
        "case_type": _s("case_type", "core_type", "type") or defaults["case_type"],
        "case_core": _s("case_core", "core_content", "content") or defaults["case_core"],
    }
    if meta["music_style"] not in MUSIC_STYLE_VALUES:
        meta["music_style"] = defaults["music_style"]
    return meta


def _has_inference_outputs(outputs: Optional[dict]) -> bool:
    """判断 Dify 返回里是否已包含推演三量（music/music_style、action_a、action_b）。

    三量齐备才认为推演完成，是"写入数据库新片段"的前置条件。
    """
    if not isinstance(outputs, dict):
        return False

    def _pick(*names: str) -> bool:
        return any(
            isinstance(outputs.get(n), str) and outputs.get(n).strip() for n in names
        )

    return (
        _pick("music_style", "music")
        and _pick("action_a")
        and _pick("action_b")
    )


async def _persist_story_segment(
    user_id: str,
    new_segment: str,
    settings: Optional[dict] = None,
    meta: Optional[dict] = None,
    case_meta: Optional[dict] = None,
) -> None:
    """追加本段为该用户小说数组的新元素（seq = 原最大下标 + 1），单行 INSERT。

    服务器从 Dify 收到完整文本（且审核通过）就立即写入，
    与 App 是否收全无关；App 断流/卡死重启后，冷启动同步即可拉回完整文本。
    每段一行，追加不重写任何旧数据。
    同时把生成该段时点上的"本轮三个选择（choice_1/2/3，LLM② 推荐的下一轮行动，
    取不到用保底默认值）"、"后续变量（music_style）"与"用户设定快照"
    随行落库，供后续 RAG / 时间树返回等功能回溯本段的生成上下文。

    案件设定：新条目序号能被 CASE_ROUNDS 整除（含 0，即全新小说 / 新的一卷）时，
    调用案件生成工作流刷新 case_type/case_core；调用失败则写入保底空值。
    """
    if not new_segment or not new_segment.strip():
        return
    now = int(time.time())
    settings = settings or {}
    # 直接用上层已提取好的后续变量（choice_1/2/3/music_style），只对缺失字段用保底补齐。
    # 不能再次 _extract_story_meta：它是在 Dify 原始输出里找 action_a/action_b，
    # 而这里收到的是已转成 choice_2/3 的 meta，action_a/b 已不存在；再提取会把
    # LLM 生成的选项全部回退成保底默认值（导致重启后最新段选项永远是保底选项）。
    m = dict(meta or {})
    _defaults = _meta_defaults(settings.get("language"))
    for _k in ("choice_1", "choice_2", "choice_3", "music_style"):
        if not m.get(_k):
            m[_k] = _defaults.get(_k, "")
    meta = m
    conn = _db()
    try:
        row = conn.execute(
            """SELECT COALESCE(MAX(seq), -1) AS m FROM story_segments WHERE user_id=?""",
            (user_id,),
        ).fetchone()
        next_seq = row["m"] + 1
        # 案件设定：CASE_ROUNDS 轮一循环。
        # - 调用方已前置生成案件（case_meta 非 None，见 generate_story）：直接复用，
        #   不再重复调用案件工作流（避免两次生成不一致/浪费一次 Dify 调用）；
        # - CASE_ROUNDS 整倍数轮（含 0，新一卷起点）：调用案件生成工作流刷新案件类型/核心，
        #   失败时返回空串保底，写入即为空值；
        # - 非 CASE_ROUNDS 整倍数轮：原样复制上一轮的 case_type/case_core（整卷 CASE_ROUNDS 轮保持不变）。
        if case_meta is not None:
            meta["case_type"] = case_meta.get("case_type") or ""
            meta["case_core"] = case_meta.get("case_core") or ""
        elif next_seq % CASE_ROUNDS == 0:
            case_meta = await _generate_case_meta()
            meta["case_type"] = case_meta.get("case_type") or ""
            meta["case_core"] = case_meta.get("case_core") or ""
        else:
            prev_row = conn.execute(
                """SELECT case_type, case_core FROM story_segments
                   WHERE user_id=? AND seq=? LIMIT 1""",
                (user_id, next_seq - 1),
            ).fetchone()
            if prev_row:
                meta["case_type"] = prev_row["case_type"] or ""
                meta["case_core"] = prev_row["case_core"] or ""
            else:
                # 上一轮不存在（异常兜底）：保留当前值（通常为空）
                meta["case_type"] = meta.get("case_type") or ""
                meta["case_core"] = meta.get("case_core") or ""
        conn.execute(
            """INSERT INTO story_segments
                 (user_id, seq, content, created_at,
                  choice_1, choice_2, choice_3,
                  user_choice,
                  music_style,
                  location, era, player_name, player_traits,
                  language,
                  case_type, case_core)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                user_id,
                next_seq,
                new_segment,
                now,
                meta["choice_1"],
                meta["choice_2"],
                meta["choice_3"],
                "",  # user_choice：新段刚生成，用户尚未选择；选择后由 generate_story 覆盖写入
                meta["music_style"],
                (settings.get("location") or ""),
                (settings.get("era") or ""),
                (settings.get("player_name") or ""),
                (settings.get("player_traits") or ""),
                (settings.get("language") or ""),
                (meta.get("case_type") or ""),
                (meta.get("case_core") or ""),
            ),
        )
        conn.commit()
    finally:
        conn.close()


def _resolve_story_settings(user_id: str, data: StoryInputData) -> dict:
    """解析本轮生成所用的用户设定快照。

    - 第一轮生成：用 App 随请求上传的设定（并随当段写入 story_segments 快照列）；
    - 续写：App 不再上传设定，从最新一段的快照列读取（含语言）。
    """
    req = {
        "location": data.location or "",
        "era": data.era or "",
        "player_name": data.player_name or "",
        "player_traits": data.player_traits or "",
        "language": data.language or "",
        # 案件信息来自 Dify 输出（非 App 上传），此处保底为空；续写时从快照读取
        "case_type": "",
        "case_core": "",
    }
    if any(
        req[k]
        for k in (
            "location",
            "era",
            "player_name",
            "player_traits",
            "language",
        )
    ):
        return req
    # 续写：读取最新一段快照列（含语言与案件信息）
    conn = _db()
    try:
        row = conn.execute(
            """SELECT location, era, player_name, player_traits, language,
                      case_type, case_core
               FROM story_segments WHERE user_id=? ORDER BY seq DESC LIMIT 1""",
            (user_id,),
        ).fetchone()
        return dict(row) if row else {}
    finally:
        conn.close()


# App 语言代码 → 发给 Dify 的明确语言名称（不要用 zh/yue/en 这类缩写，
# 直接告诉 LLM 用哪种语言/方言撰写，避免歧义）。未知/空值回退简体中文。
_LANGUAGE_DIFY_NAME = {
    "zh": "简体中文",
    "zh-TW": "繁體中文",
    "yue": "粤语（广府话 / Cantonese）",
    "en": "English",
    "ja": "日本語",
    "ko": "한국어",
    "es": "Español",
    "fr": "Français",
    "de": "Deutsch",
    "pt": "Português",
}


def _dify_language_name(lang: str) -> str:
    """把 App 语言代码映射为发给 Dify 的完整语言名称；未知回退简体中文。"""
    key = (lang or "").strip()
    return _LANGUAGE_DIFY_NAME.get(key, "简体中文")


def _reset_story(user_id: str) -> None:
    """全新生成/重新生成：清空该用户的全部段落（从 seq=0 重新开始）。"""
    conn = _db()
    try:
        conn.execute("DELETE FROM story_segments WHERE user_id=?", (user_id,))
        conn.commit()
    finally:
        conn.close()


def _strip_think(chunk: str, state: dict) -> str:
    """从流式文本中剥离 <think>...</think> 思考块（兼容跨 chunk 拆分）。

    - state 需在流开始时初始化为 {"in_think": False, "hold": ""}；
    - 思考块可能跨多个 text_chunk：未闭合前先缓冲到 state["hold"]，闭合后整段丢弃；
    - 若模型始终不闭合（格式坏），则该部分被整体丢弃（fail-closed，
      宁可少正文也不把思考内容显示/落库）。
    """
    buf = state["hold"] + (chunk or "")
    if state["in_think"]:
        end = buf.find("</think>")
        if end == -1:
            state["hold"] = buf
            return ""
        buf = buf[end + len("</think>"):]
        state["in_think"] = False
        state["hold"] = ""
    out = []
    while True:
        start = buf.find("<think>")
        if start == -1:
            out.append(buf)
            state["hold"] = ""
            break
        out.append(buf[:start])
        end = buf.find("</think>", start)
        if end == -1:
            state["hold"] = buf[start:]
            state["in_think"] = True
            break
        buf = buf[end + len("</think>"):]
    return "".join(out)


_CJK_RE = re.compile(r"[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uff00-\uffef]")


def _content_weight(text: str) -> int:
    """按内容量加权长度：汉字/全角字符计 1，英文字母/数字/半角符号计 0.5。

    使「1000 汉字」与「2000 英文字母」视为同等体量（对齐用户设定：
    每段约 1500 汉字 ≈ 3000 英文字母）。用于解壳兜底的体量门槛。
    """
    t = text or ""
    cjk = len(_CJK_RE.findall(t))
    other = len(t) - cjk
    return cjk + other // 2


def _unwrap_wrapped(text: str) -> str:
    """解壳兜底：模型把整段正文包在 <think>…</think> 或反引号代码块里时，
    去掉包裹壳，提取内部正文。壳内体量不足 1000 汉字当量视为无效
    （≈1000 汉字 或 2000 英文字母；避免把"纯思考没写正文"误当正文返回）。"""
    t = (text or "").strip()
    if t.startswith("<think>") and t.endswith("</think>"):
        t = t[len("<think>"):-len("</think>")].strip()
    if t.startswith("```") and t.endswith("```"):
        t = t[3:-3].strip()
    elif t.startswith("`") and t.endswith("`"):
        t = t[1:-1].strip()
    if _content_weight(t) < 1000:
        return ""
    return t.strip()


def _clean_story_text(raw: str) -> str:
    """净化小说正文：先按常规剥离 <think> 思考块；
    若剥离后为空但原文有实质内容（整篇被 think/反引号壳包住），改用解壳提取。"""
    state = {"in_think": False, "hold": ""}
    cleaned = _strip_think(raw or "", state)
    if not cleaned or not cleaned.strip():
        cleaned = _unwrap_wrapped(raw or "")
    return cleaned


# ================= 路由：小说生成（流式：每满 400 字增量审核 → 通过即 chunk/reveal 显示） =================
@app.post("/api/generate-story")
async def generate_story(data: StoryInputData, request: Request):
    token = _extract_token(data, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)

    # 防御性校验：续写必须有用户指引，禁止无指引生成新小说内容。
    # 第一轮全新生成（库中无任何段落）允许空白 user_input；其余情况
    # （时间树"从这里重写" rewrite_from>=0 / 已有正文的续写）一律要求
    # user_input 非空白。必须放在任何数据库写入/截断【之前】，空白输入
    # 不得破坏已有故事，也不得调用 Dify 无指引续写。
    if not (data.user_input or "").strip():
        _cnt = _get_story_count(user_id)
        _is_rewrite = data.rewrite_from is not None and data.rewrite_from >= 0
        if _cnt > 0 or _is_rewrite:
            raise HTTPException(
                status_code=400,
                detail="续写需要用户输入指引，请先填写内容再继续",
            )

    # 用户最新选择持久化：无论最新一段，还是时间树"从这里重新开始"的历史段
    # （rewrite_from），用户点击确定/继续时，把三个输入框当前值覆盖到对应段的
    # choice_1/2/3，永远保持服务器保存的是用户的最新选择。
    # 放在配额检查【之前】：即使配额不足（不允许再生成新文本），也先保存用户
    # 最新编辑的选择，且不消耗任何 LLM 资源。
    try:
        conn = _db()
        try:
            if data.rewrite_from is not None and data.rewrite_from >= 0:
                # 时间树重写：覆盖到被重写的历史段
                conn.execute(
                    """UPDATE story_segments
                          SET choice_1=?, choice_2=?, choice_3=?, user_choice=?
                        WHERE user_id=? AND seq=?""",
                    (
                        data.choice_1 or "",
                        data.choice_2 or "",
                        data.choice_3 or "",
                        data.user_input or "",  # 用户本轮实际选择文本
                        user_id,
                        data.rewrite_from,
                    ),
                )
            else:
                # 最新一段续写：覆盖到最新已生成段
                conn.execute(
                    """UPDATE story_segments
                          SET choice_1=?, choice_2=?, choice_3=?, user_choice=?
                        WHERE user_id=?
                          AND seq=(SELECT MAX(seq) FROM story_segments WHERE user_id=?)""",
                    (
                        data.choice_1 or "",
                        data.choice_2 or "",
                        data.choice_3 or "",
                        data.user_input or "",  # 用户本轮实际选择文本
                        user_id,
                        user_id,
                    ),
                )
            conn.commit()
        finally:
            conn.close()
    except Exception:
        # 保存用户选择失败不影响生成主流程
        logger.warning("保存用户选择失败", exc_info=True)

    # 小说生成工作流全局每日配额（默认 1000 次 / 24 小时滚动）
    _check_story_quota(int(time.time()))

    # 时间树"从这里重写"：截断该用户所有 seq > rewrite_from 的段落，
    # 之后的生成将作为 rewrite_from+1 续写（续写判断依据段落数）。
    if data.rewrite_from is not None and data.rewrite_from >= 0:
        try:
            conn = _db()
            try:
                conn.execute(
                    "DELETE FROM story_segments WHERE user_id=? AND seq > ?",
                    (user_id, data.rewrite_from),
                )
                conn.commit()
            finally:
                conn.close()
        except Exception:
            logger.warning("时间树重写截断失败", exc_info=True)

    # 设定解析：第一轮生成用 App 随请求上传的设定（随段落库），续写读最新一段快照
    settings = _resolve_story_settings(user_id, data)

    # 以数据库是否已有段落决定续写/全新；空库段落数为 0
    user_input_counter = _get_story_count(user_id)
    # 当前案件正文原文（corrent_case_all_content 取值来源；见 _get_current_case_story 的 CASE_ROUNDS 整倍数规则）
    corrent_case_all_content = _get_current_case_story(user_id, user_input_counter)

    # 输入成本控制（花钱之前硬拦）：设定 + 用户输入合并估算 token
    combined = " ".join(
        [
            settings.get("location") or "",
            settings.get("era") or "",
            settings.get("player_name") or "",
            settings.get("player_traits") or "",
            settings.get("language") or "",
            data.user_input or "",
        ]
    )
    _check_input_budget(combined)

    # 小说生成的唯一硬限为全局 STORY_DAILY_LIMIT（默认 1000 次/天，见 _check_story_quota）。

    # 案件前置生成：新案件轮（seq 为 CASE_ROUNDS 整倍数，含 0 = 全新小说 / 新一卷）时，
    # 在构建 Dify payload 之前先调用"案件生成"工作流生成 case_type/case_core，并写进
    # settings，使小说生成的 Dify 请求自带刚生成的案件设定（而不是首轮为空）。
    # pre_case_meta 同时传给 _persist_story_segment 直接复用，避免落库时重复调案件工作流。
    pre_case_meta = None
    if user_input_counter % CASE_ROUNDS == 0:
        pre_case_meta = await _generate_case_meta()
        settings["case_type"] = pre_case_meta.get("case_type") or ""
        settings["case_core"] = pre_case_meta.get("case_core") or ""

    # Dify 开始节点 required 变量必须非空，空值用占位符兜底
    def _fill(v: str) -> str:
        return v.strip() if v and v.strip() else "未设定"

    headers = {
        "Authorization": f"Bearer {STORY_DIFY_API_KEY}",
        "Content-Type": "application/json",
    }
    dify_payload = {
        "inputs": {
            # 用户设定
            "location": _fill(settings.get("location") or ""),
            "era": _fill(settings.get("era") or ""),
            "player_name": _fill(settings.get("player_name") or ""),
            # 语言用完整名称（如 简体中文/繁體中文/粤语（广府话 / Cantonese）/English...），
            # 不用 zh/yue/en 缩写，避免 LLM 歧义
            "language": _dify_language_name(settings.get("language") or ""),
            "player_traits": _fill(settings.get("player_traits") or ""),
            # 本轮信息
            "seq": user_input_counter,
            # 续写上下文：只传 corrent_case_all_content（当前案件正文原文）
            "corrent_case_all_content": corrent_case_all_content,
            "user_choice": data.user_input or "",
            # 当前案件（续写时从快照读取；首轮为空）
            "case_type": settings.get("case_type") or "",
            "case_core": settings.get("case_core") or "",
        },
        "response_mode": "streaming",
        "user": user_id,
    }

    async def _stream():
        try:
            # 【调试】生成前确认：调 Dify 之前先把 payload 发回 App 弹窗，
            # 等 App 用户点击确认后（POST /api/generate-story/confirm）才真正调 Dify。
            # 等待期间每 15s 发一个 debug_waiting 心跳，防止客户端 40s 无数据判定卡死。
            if DEBUG_PAYLOAD_PREVIEW:
                request_id = secrets.token_hex(16)
                confirm_ev = asyncio.Event()
                _pending_payload_confirm[request_id] = confirm_ev
                try:
                    yield _sse({
                        "event": "debug_payload",
                        "request_id": request_id,
                        "payload": dify_payload,
                    })
                    waited = 0.0
                    while not confirm_ev.is_set():
                        if waited >= DEBUG_PAYLOAD_CONFIRM_TIMEOUT:
                            yield _sse({"event": "error", "message": "等待 App 确认超时，已取消本次生成"})
                            return
                        try:
                            await asyncio.wait_for(confirm_ev.wait(), timeout=15)
                        except asyncio.TimeoutError:
                            waited += 15
                            yield _sse({"event": "debug_waiting"})
                finally:
                    _pending_payload_confirm.pop(request_id, None)

            async with async_http_client.stream(
                "POST", STORY_DIFY_API_URL, json=dify_payload, headers=headers
            ) as resp:
                if resp.status_code != 200:
                    body = (await resp.aread()).decode("utf-8", errors="replace")
                    yield _sse({"event": "error", "message": f"Dify 接口失败 {resp.status_code}: {body[:500]}"})
                    return

                # 增量审核状态：正文每满 STORY_AUDIT_STEP 的整倍数（400、800、1200...）
                # 即触发一次审核；审核窗口每步前进 STORY_AUDIT_STEP 字（其余窗口前带
                # OVERLAP 回溯重叠），审核通过后把新确认的正文送回 App（首段 chunk
                # 打字机、其后 reveal）。
                full_text = ""          # 累计全部正文（<think> 已剥离）
                displayed_len = 0       # 已发送给 App 的字符数
                audit_no = 1            # 下一次审核序号 k（窗口 [STEP*(k-1)-OVERLAP, STEP*k)）
                sent_first = False      # 是否已发送过首段 chunk
                outputs = {}
                think_state = {"in_think": False, "hold": ""}  # <think> 块剥离状态（跨 chunk）
                meta = _extract_story_meta({}, settings.get("language"))  # 后续变量（choice_1/2/3/music_style）；workflow_finished 时更新，失败用保底默认

                async def _audit_pipeline(text_arg: str, final: bool, final_outputs: Optional[dict] = None):
                    """增量审核管道：把当前累计正文按审核窗口逐批送审，审核通过后
                    把新确认的正文以 chunk/reveal 事件回发 App。

                    - 正文每满 STEP 的整倍数（400、800、1200...）触发一次审核，
                      把对应整窗口送审（final=False 时也只做这一步）；
                    - final=True 时，再把末尾不足 STEP 整倍数的剩余部分整体审一次
                      （窗口前仍带 OVERLAP 回溯，防边界漏网），并携带真实 outputs。
                    返回 (events, fail)：events 为待发送事件列表；fail 非 None 表示
                    审核未通过/不可用，应立即发送 fail 并终止。
                    """
                    nonlocal audit_no, displayed_len, sent_first
                    events: list = []
                    while len(text_arg) >= STORY_AUDIT_STEP * audit_no:
                        k = audit_no
                        win_end = STORY_AUDIT_STEP * k
                        if len(text_arg) < win_end:
                            break
                        win_start = max(
                            0, STORY_AUDIT_STEP * (k - 1) - STORY_AUDIT_OVERLAP
                        )
                        audit_text = text_arg[win_start:win_end]
                        mr = await _moderate_story(audit_text)
                        fail = _moderation_failure_sse(mr)
                        if fail is not None:
                            return events, fail
                        new_text = text_arg[displayed_len:win_end]
                        if not sent_first:
                            events.append({"event": "chunk", "text": new_text})
                        else:
                            events.append({"event": "reveal", "text": new_text, "outputs": {}})
                        logger.warning(
                            "STREAM audit k=%d OK win=[%d,%d) disp=[%d,%d)",
                            k, win_start, win_end, displayed_len, win_end,
                        )
                        displayed_len = win_end
                        audit_no += 1
                        sent_first = True
                    if final and displayed_len < len(text_arg):
                        win_start = max(
                            0, STORY_AUDIT_STEP * (audit_no - 1) - STORY_AUDIT_OVERLAP
                        )
                        audit_text = text_arg[win_start:]
                        mr = await _moderate_story(audit_text)
                        fail = _moderation_failure_sse(mr)
                        if fail is not None:
                            return events, fail
                        new_text = text_arg[displayed_len:]
                        if not sent_first:
                            events.append({"event": "chunk", "text": new_text})
                        else:
                            ev: dict = {"event": "reveal", "text": new_text}
                            if final_outputs:
                                ev["outputs"] = final_outputs
                            events.append(ev)
                        logger.warning(
                            "STREAM audit tail OK win_start=%d disp=[%d,%d)",
                            win_start, displayed_len, len(text_arg),
                        )
                        displayed_len = len(text_arg)
                        sent_first = True
                    return events, None

                async for line in resp.aiter_lines():
                    if not line.strip().startswith("data:"):
                        continue
                    raw = line.strip()[5:].strip()
                    if not raw:
                        continue
                    try:
                        evt = json.loads(raw)
                    except Exception:
                        continue
                    etype = evt.get("event")
                    edata = evt.get("data") or {}

                    if etype == "text_chunk":
                        # 来源过滤：Dify 最新版 text_chunk 事件带 from_variable_selector
                        # （来源节点变量路径），用于区分是哪个节点流出的文本。若 LLM②
                        # 结构化节点的流式原文也被 Dify 推出来（正是正文里混入
                        # action_a/action_b 的原因），配置 STORY_STREAM_SOURCE 后，
                        # 这里只累计小说节点的文本、丢弃其余来源（治本仍在 Dify 画布
                        # 关掉 LLM② 的流式；此处是服务器侧兜底）。
                        sel = edata.get("from_variable_selector") or []
                        sel_key = ".".join(str(x) for x in sel)
                        if STORY_STREAM_SOURCE:
                            if not sel_key:
                                # 无来源标记（旧版 Dify / 字段缺失）：无法过滤，保留原文并告警
                                logger.warning(
                                    "STREAM text_chunk 无来源标记(from_variable_selector 缺失)，"
                                    "无法过滤，保留原文"
                                )
                            elif not sel_key.startswith(STORY_STREAM_SOURCE):
                                logger.warning(
                                    "STREAM drop text_chunk key=%r (filter=%r)",
                                    sel_key, STORY_STREAM_SOURCE,
                                )
                                continue
                        txt = _strip_think(edata.get("text", "") or "", think_state)
                        if txt:
                            full_text += txt
                            events, fail = await _audit_pipeline(full_text, final=False)
                            if fail is not None:
                                yield _sse(fail)
                                return
                            for ev in events:
                                yield _sse(ev)

                    elif etype == "workflow_finished":
                        outputs = edata.get("outputs") or {}
                        meta = _extract_story_meta(
                            outputs, settings.get("language")
                        )
                        # 权威全文：只用"流式累计正文"（text_chunk 已按来源过滤，只含
                        # 小说节点文本）。不再信任 Dify 结束节点的 outputs["text"]——
                        # 它可能被 Dify 画布拼入 LLM② 的 action_a/action_b/music_style
                        # （导致正文尾部混入选项/音乐，并落库污染）。
                        out_text = _clean_story_text(full_text)
                        if not out_text or not out_text.strip():
                            yield _sse({"event": "error", "code": "empty_output", "message": "服务器未返回有效的小说正文，请检查额度是否已用尽，或稍后重试"})
                            return
                        final_segment = out_text
                        # 增量送审（含末尾兜底），通过后把剩余正文 reveal 给 App。
                        events, fail = await _audit_pipeline(
                            out_text,
                            final=True,
                            final_outputs={
                                **outputs,
                                **meta,
                            },
                        )
                        if fail is not None:
                            logger.warning("STREAM audit FAILED: %s", fail)
                            yield _sse(fail)
                            return
                        for ev in events:
                            yield _sse(ev)
                        # 只有"完整正文 + 推演三量（music/music_style、action_a、action_b）"
                        # 都收到，才真正落库；缺任一推演量则跳过持久化（正文仍照常推送给 App）。
                        fmeta = dict(meta)
                        if _has_inference_outputs(outputs):
                            try:
                                await _persist_story_segment(user_id, final_segment, settings, fmeta, case_meta=pre_case_meta)
                                logger.warning("STREAM persisted ok final_len=%d", len(final_segment))
                            except Exception as pe:
                                logger.warning("STREAM persist EXCEPTION: %s", pe, exc_info=True)
                        else:
                            logger.warning("STREAM skip persist: 推演三量未齐全 final_len=%d", len(final_segment))
                        logger.warning("STREAM yielding done")
                        yield _sse({"event": "done", "outputs": {**outputs, **fmeta}})
                        return

                    elif etype in ("error", "workflow_failed"):
                        yield _sse({"event": "error", "message": edata.get("message") or "Dify 工作流执行失败"})
                        return

                # 流意外结束（未收到 workflow_finished）：兜底，剩余内容仍须先审核再 reveal
                if full_text:
                    events, fail = await _audit_pipeline(full_text, final=True)
                    if fail is not None:
                        yield _sse(fail)
                        return
                    for ev in events:
                        yield _sse(ev)
                    # 未收到推演三量（无 workflow_finished），按新规则不落库，仅推送正文
                    logger.warning("STREAM fallback skip persist (无推演三量) final_len=%d", len(full_text))
                    yield _sse({"event": "done", "outputs": {**outputs, **meta}})
                else:
                    logger.warning("STREAM fallback empty_output full_len=%d sent_first=%s", len(full_text), sent_first)
                    yield _sse({"event": "error", "code": "empty_output", "message": "服务器未返回有效的小说正文，请检查额度是否已用尽，或稍后重试"})
        except httpx.RequestError as exc:
            logger.warning("STREAM RequestError: %s", exc, exc_info=True)
            yield _sse({"event": "error", "message": f"与 Dify 通信异常: {str(exc)}"})
        except Exception as e:
            logger.warning("STREAM Exception: %s", e, exc_info=True)
            yield _sse({"event": "error", "message": f"网关异常: {str(e)}"})

    return StreamingResponse(
        _stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # 关掉 nginx 缓冲，保证实时转发
        },
    )


class PayloadConfirmData(BaseModel):
    """【调试】App 用户点击"确认发送"后通知服务器：放行本次生成继续调 Dify。"""
    request_id: str = ""
    token: str = ""


@app.post("/api/generate-story/confirm")
async def generate_story_confirm(data: PayloadConfirmData, request: Request):
    """【调试】生成前确认端点。

    App 在弹窗里点击"确认"后调用本接口，用 request_id 匹配到正在等待的
    /api/generate-story 流式请求，set 其 asyncio.Event，使服务器继续调 Dify。
    """
    token = _extract_token(data, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)

    ev = _pending_payload_confirm.get(data.request_id)
    if ev is None:
        raise HTTPException(status_code=404, detail="待确认请求不存在或已超时")
    ev.set()
    return {"ok": True}


# ================= 付费验证（S6，预留） =================
@app.post("/api/verify-purchase")
async def verify_purchase(data: PurchaseData, request: Request):
    """付费验证入口（预留）。

    生产必须由服务器调用平台官方接口验证并处理退款：
    - App Store: App Store Server API / receipt verification + Server Notifications V2
    - Google Play: purchases.subscriptions.get / purchases.products.get + RTDN
    未配置平台凭据时返回"未配置"，不影响核心流程。
    """
    token = _extract_token(data, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)

    if data.provider == "appstore":
        if not APPSTORE_SHARED_SECRET:
            raise HTTPException(status_code=501, detail="App Store 校验未配置")
        # TODO(S6): 调 App Store 校验 receipt，解析 expires_date / 退款状态
    elif data.provider == "googleplay":
        if not GOOGLE_PLAY_SERVICE_ACCOUNT:
            raise HTTPException(status_code=501, detail="Google Play 校验未配置")
        # TODO(S6): 调 Google Play Developer API 校验 purchaseToken
    else:
        raise HTTPException(status_code=400, detail="provider 非法")

    # 校验通过后写入/更新 entitlements（这里为占位实现）
    conn = _db()
    try:
        conn.execute(
            """INSERT INTO entitlements
                 (user_id, plan, purchased_quota, used_quota, purchased_at, updated_at, provider, provider_purchase_id)
               VALUES (?, 'paid', ?, 0, ?, ?, ?, ?)
               ON CONFLICT(user_id) DO UPDATE SET
                 plan='paid', purchased_quota=excluded.purchased_quota,
                 purchased_at=excluded.purchased_at, updated_at=excluded.updated_at,
                 provider=excluded.provider, provider_purchase_id=excluded.provider_purchase_id,
                 status='active'""",
            (user_id, 0, int(time.time()), int(time.time()), data.provider, data.receipt[:200]),
        )
        conn.commit()
    finally:
        conn.close()
    return {"status": "ok", "user_id": user_id}


@app.post("/api/purchase-webhook")
async def purchase_webhook(request: Request):
    """平台推送回调（App Store Server Notifications V2 / Google RTDN）。

    用于服务器端自动处理：续期、过期、退款吊销，完全绕开 App。
    预留：实现时校验签名后，据此更新 entitlements（退款→status=revoked）。
    """
    body = await request.body()
    # TODO(S6): 校验平台推送签名后更新权益
    return {"status": "ok"}


# ================= 云同步（S7） =================
@app.get("/api/sync")
async def sync_get(request: Request, since: int = 0):
    """拉取该用户 updated_at > since 的所有同步条目（增量）。"""
    token = _extract_token(None, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)
    conn = _db()
    try:
        rows = conn.execute(
            """SELECT key, content, updated_at FROM sync_data
               WHERE user_id=? AND updated_at>? ORDER BY updated_at""",
            (user_id, since),
        ).fetchall()
    finally:
        conn.close()
    return {
        "entries": [
            {"key": r["key"], "content": r["content"], "updated_at": r["updated_at"]}
            for r in rows
        ]
    }


@app.post("/api/sync")
async def sync_put(data: SyncPutData, request: Request):
    """写入/更新同步条目（乐观并发：只接受更新的版本）。"""
    token = _extract_token(None, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)

    if not data.key or len(data.key) > 128:
        raise HTTPException(status_code=400, detail="key 非法")
    if len(data.content) > MAX_INPUT_CHARS * 4:
        raise HTTPException(status_code=400, detail="内容过大")

    conn = _db()
    try:
        row = conn.execute(
            """SELECT updated_at FROM sync_data WHERE user_id=? AND key=?""",
            (user_id, data.key),
        ).fetchone()
        if row and row["updated_at"] >= data.updated_at:
            # 服务器已有更新版本，拒绝旧版本写入（乐观锁）
            conn.close()
            return {"status": "ok", "applied": False}
        conn.execute(
            """INSERT INTO sync_data (user_id, key, content, updated_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(user_id, key) DO UPDATE SET
                 content=excluded.content, updated_at=excluded.updated_at""",
            (user_id, data.key, data.content, data.updated_at),
        )
        conn.commit()
    finally:
        conn.close()

    # TODO(RAG二期): 内容更新后，在此钩子触发该用户章节的增量切片 + 重新嵌入
    return {"status": "ok", "applied": True}


# ================= 多设备防护：App 启动握手（上传公钥 → 校验 → 更新硬件公钥） =================
@app.post("/api/device/activate")
async def device_activate(data: ActivateData, request: Request):
    """App 每次启动时调用：上传硬件公钥 + 用户 id，服务器校验后更新硬件公钥，
    并把该设备登记为该用户的最新活跃硬件。

    身份以签名令牌为准（user_id/device_id 由令牌解析，客户端 body 里的 user_id
    仅作展示核对）；硬件公钥上传后经校验（非空、长度合法、设备确属该用户）写入
    devices.public_key，完成"更新硬件公钥"。多设备同时登入时，最后启动的设备成为
    活跃设备；旧设备下一次操作会被 409 device_conflict 拒绝。
    """
    token = _extract_token(None, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]

    # 校验上传的硬件公钥（Base64 SPKI，长度受限）
    if not data.public_key or len(data.public_key) > 2048:
        raise HTTPException(status_code=400, detail="public_key 非法")

    now = int(time.time())
    conn = _db()
    try:
        dev = conn.execute(
            "SELECT device_id FROM devices WHERE device_id=? AND user_id=?",
            (device_id, user_id),
        ).fetchone()
        if not dev:
            raise HTTPException(status_code=404, detail="设备未注册")
        # 校验通过：更新该设备的硬件公钥，并登记为当前活跃设备
        conn.execute(
            "UPDATE devices SET public_key=?, last_seen_at=? WHERE device_id=?",
            (data.public_key, now, device_id),
        )
        conn.execute(
            "UPDATE users SET active_device_id=? WHERE user_id=?",
            (device_id, user_id),
        )
        conn.commit()
    finally:
        conn.close()
    return {
        "status": "ok",
        "active_device_id": device_id,
    }


# ================= 小说正文云存储（每段一行，与客户端 List<String> 数组对应） =================
@app.get("/api/story")
async def story_get(request: Request, before_seq: int = -1, limit: int = 0):
    """获取该用户的小说正文数组（每段一行，seq 即数组下标）。

    - 默认：返回全部段（按 seq 升序），并附 total。
    - ?limit=N：只返回最后 N 段（App 冷启动只拉尾部）；不统计 total（省 COUNT）。
    - ?before_seq=X&limit=N：返回 seq < X 的最近 N 段（App 向上懒加载更早段）；不统计 total。
    返回 {segments, start_seq, [total], updated_at}；start_seq 为 segments[0] 的
    绝对下标，保证 App 本地数组下标与服务器 seq 对齐。
    """
    token = _extract_token(None, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)
    conn = _db()
    try:
        if limit > 0 and before_seq >= 0:
            rows = conn.execute(
                """SELECT seq, content, choice_1, choice_2, choice_3, user_choice,
                          case_type, case_core
                   FROM story_segments
                   WHERE user_id=? AND seq < ? ORDER BY seq DESC LIMIT ?""",
                (user_id, before_seq, limit),
            ).fetchall()
            rows = list(reversed(rows))
        elif limit > 0:
            rows = conn.execute(
                """SELECT seq, content, choice_1, choice_2, choice_3, user_choice,
                          case_type, case_core
                   FROM story_segments
                   WHERE user_id=? ORDER BY seq DESC LIMIT ?""",
                (user_id, limit),
            ).fetchall()
            rows = list(reversed(rows))
        else:
            rows = conn.execute(
                """SELECT seq, content, choice_1, choice_2, choice_3, user_choice,
                          case_type, case_core
                   FROM story_segments
                   WHERE user_id=? ORDER BY seq ASC""",
                (user_id,),
            ).fetchall()
        updated_at = conn.execute(
            """SELECT COALESCE(MAX(created_at), 0) AS u FROM story_segments WHERE user_id=?""",
            (user_id,),
        ).fetchone()["u"]
        # 用户的金标准语言：取最新一段的语言快照（老用户换新设备时据此覆盖本地语言）
        lang_row = conn.execute(
            """SELECT language FROM story_segments
               WHERE user_id=? ORDER BY seq DESC LIMIT 1""",
            (user_id,),
        ).fetchone()
        language = (lang_row["language"] or "") if lang_row else ""
        total = None
        if limit <= 0:
            total = conn.execute(
                "SELECT COUNT(*) AS c FROM story_segments WHERE user_id=?", (user_id,)
            ).fetchone()["c"]
    finally:
        conn.close()
    segments = []
    choices = []
    user_choices = []
    case_types = []
    case_cores = []
    for r in rows:
        if isinstance(r["content"], str):
            segments.append(r["content"])
            choices.append(
                [
                    (r["choice_1"] or "") if isinstance(r["choice_1"], str) else "",
                    (r["choice_2"] or "") if isinstance(r["choice_2"], str) else "",
                    (r["choice_3"] or "") if isinstance(r["choice_3"], str) else "",
                ]
            )
            user_choices.append(
                (r["user_choice"] or "")
                if isinstance(r["user_choice"], str)
                else ""
            )
            case_types.append(
                (r["case_type"] or "") if isinstance(r["case_type"], str) else ""
            )
            case_cores.append(
                (r["case_core"] or "") if isinstance(r["case_core"], str) else ""
            )
    start_seq = rows[0]["seq"] if rows else 0
    resp = {
        "segments": segments,
        # 与 segments 一一对应的三个选项（choice_1/2/3），App 显示在对应段落的按钮中
        # 并预填正文底部第 1/2/3 个输入框
        "choices": choices,
        # 与 segments 一一对应的用户本轮实际选择文本（未选择为空）
        "user_choices": user_choices,
        # 与 segments 一一对应的当前案件类型 / 案件核心（凶杀案设定，无则为空串）
        "case_types": case_types,
        "case_cores": case_cores,
        "start_seq": start_seq,
        "updated_at": updated_at,
        # 用户的金标准语言（最新一段的语言快照；老用户换新设备时 App 用它覆盖本地语言）
        "language": language,
    }
    if total is not None:
        resp["total"] = total
    return resp


@app.get("/api/story/latest")
async def story_latest(request: Request):
    """【调试专用】返回当前用户最新一段 story_segments 的【全部字段】。

    与 /api/story 不同：本端点返回完整一行（含 content / music_style / created_at /
    设定快照/案件信息等所有列），供 App 在每次生成后弹窗核对"数据库落库内容"。
    仅返回当前用户自己的数据；无任何数据时 latest 为 null。
    """
    token = _extract_token(None, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)
    conn = _db()
    try:
        row = conn.execute(
            """SELECT id, seq, content, created_at,
                      choice_1, choice_2, choice_3, user_choice,
                      music_style,
                      location, era, player_name, player_traits, language,
                      case_type, case_core
               FROM story_segments
               WHERE user_id=?
               ORDER BY seq DESC, id DESC
               LIMIT 1""",
            (user_id,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return {"latest": None}
    return {"latest": dict(row)}


@app.post("/api/story")
async def story_put(data: StoryData, request: Request):
    """整组覆盖该用户的小说正文数组（删除旧段后按序写入；乐观并发：只接受更新的版本）。

    注：当前 App 已不再调用本接口（新增段走 _persist_story_segment 单行 INSERT），
    此端点保留以兼容外部整组写入。
    """
    token = _extract_token(None, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)

    if not isinstance(data.segments, list) or not all(
        isinstance(s, str) for s in data.segments
    ):
        raise HTTPException(status_code=400, detail="segments 必须是字符串数组")
    total_chars = sum(len(s) for s in data.segments)
    if total_chars > MAX_STORY_TOTAL_CHARS:
        raise HTTPException(status_code=400, detail="内容过大")

    now = int(time.time())
    conn = _db()
    try:
        # 乐观并发：以该用户最新段的创建时间作为版本号，只接受更新的版本
        row = conn.execute(
            """SELECT COALESCE(MAX(created_at), 0) AS u FROM story_segments WHERE user_id=?""",
            (user_id,),
        ).fetchone()
        if row["u"] >= data.updated_at:
            conn.close()
            return {"status": "ok", "applied": False}
        conn.execute("DELETE FROM story_segments WHERE user_id=?", (user_id,))
        conn.executemany(
            """INSERT INTO story_segments (user_id, seq, content, created_at)
               VALUES (?, ?, ?, ?)""",
            [(user_id, i, s, now) for i, s in enumerate(data.segments)],
        )
        conn.commit()
    finally:
        conn.close()
    return {"status": "ok", "applied": True}


@app.post("/api/story/reset")
async def story_reset(request: Request):
    """重新开始：清空该用户全部小说正文（服务器权威）。

    App 在「重新开始」确认后调用本接口删除服务器上该用户的所有小说正文，
    成功后 App 会重启；重启后同步拉取为空 → 判定为新用户 → 从设置重新开始。
    """
    token = _extract_token(None, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)
    _reset_story(user_id)
    return {"status": "ok", "cleared": True}


def _extract_token(data: Optional[InputData], request: Request) -> str:
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    if data is not None:
        return data.token
    raise HTTPException(status_code=401, detail="缺少鉴权令牌")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
