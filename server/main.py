"""
AI-SAGA 审核网关 v2（账号 + 硬件公钥 + 试用/付费权益 + 云同步）

架构要点
========
- 身份：Apple / Google ID Token，服务器用官方 JWKS 校验，取稳定 sub 作为 user_id。
- 设备：每设备持有安全硬件公钥（私钥永不出硬件）。public_key UNIQUE 防止
  "同一硬件注册多个 ID"（同硬件 = 一身份 = 一份配额）。
- 试用：免费用户每 7 天（冷却期）获得 3 次试用，按 user_id 与 device_id
  双维度记账，防"同账号换机"与"同机换账号"刷试用。
- 付费：entitlements 表预留"有效期 + 购买次数"双模型；付费校验服务器端完成，
  平台推送（App Store Server Notifications / Google RTDN）吊销退款，预留接口。
- 成本控制：输入 ≤ MAX_INPUT_TOKENS（默认 5000），输出 ≤ DIFY_MAX_TOKENS（默认 4000）。
- 云同步：按 user_id 增量同步小说数据（预留 RAG 增量索引钩子）。
"""

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
from datetime import datetime, timezone
from typing import Any, Optional

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ================= 配置区域（均可通过环境变量覆盖） =================
# 开发模式：DEV_MODE=1 时启用 provider=dev（跳过 Apple/Google OAuth 校验，
# 仅用于本地/联调，生产环境必须保持关闭）
DEV_MODE = os.environ.get("DEV_MODE", "0") == "1"
DIFY_API_KEY = os.environ.get("DIFY_API_KEY", "")
DIFY_API_URL = os.environ.get("DIFY_API_URL", "https://api.dify.ai/v1/workflows/run")
# 输出 token 上限（Dify max_tokens，需在 Dify 画布 LLM 节点绑定 max_tokens 输入变量）
DIFY_MAX_TOKENS = int(os.environ.get("DIFY_MAX_TOKENS", "4000"))
# 输入 token 估算上限（入口硬拦，估算在花钱之前）
MAX_INPUT_TOKENS = int(os.environ.get("MAX_INPUT_TOKENS", "5000"))
# 输入字符数兜底上限（防止极端长文本撑爆估算）
MAX_INPUT_CHARS = int(os.environ.get("MAX_INPUT_CHARS", "40000"))

DATA_DIR = os.environ.get("DATA_DIR", "/code/data")
TOKEN_EXPIRY_DAYS = int(os.environ.get("TOKEN_EXPIRY_DAYS", "7"))
# 付费用户每日配额
PAID_DAILY_QUOTA = int(os.environ.get("PAID_DAILY_QUOTA", "100"))
# 付费用户每分钟限流
PAID_RATE_PER_MINUTE = int(os.environ.get("PAID_RATE_PER_MINUTE", "10"))
# 试用次数（每冷却期）
TRIAL_QUOTA = int(os.environ.get("TRIAL_QUOTA", "3"))
# 试用冷却期（秒）
TRIAL_COOLDOWN_SECONDS = int(os.environ.get("TRIAL_COOLDOWN_SECONDS", str(7 * 86400)))
# 每 IP 每小时注册次数（注册入口限流）
REGISTER_LIMIT_PER_IP_PER_HOUR = int(os.environ.get("REGISTER_LIMIT_PER_IP_PER_HOUR", "20"))

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

CREATE TABLE IF NOT EXISTS trials (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    TEXT NOT NULL,
    device_id  TEXT NOT NULL,
    granted_at INTEGER NOT NULL,
    used_count INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_trials_user  ON trials(user_id, granted_at);
CREATE INDEX IF NOT EXISTS idx_trials_device ON trials(device_id, granted_at);

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

-- 每分钟限流记录（按 user）
CREATE TABLE IF NOT EXISTS rate (
    user_id TEXT NOT NULL,
    ts      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rate_user_ts ON rate(user_id, ts);
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

app = FastAPI(title="AI-SAGA 审核网关 v2")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

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


class PurchaseData(BaseModel):
    provider: str            # 'appstore' | 'googleplay'
    receipt: str = ""        # App Store transaction/receipt 或 Google purchaseToken
    product_id: str = ""


class SyncPutData(BaseModel):
    key: str
    content: str = ""
    updated_at: int


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

        # 4) public_key UNIQUE 检查（同硬件多 ID 防护）
        existing = conn.execute(
            """SELECT device_id, user_id FROM devices WHERE public_key=?""",
            (data.public_key,),
        ).fetchone()
        if existing:
            if existing["device_id"] != device_id:
                raise HTTPException(
                    status_code=409,
                    detail="该设备已绑定其他身份，请复用原设备标识",
                )
            # 同 device_id 重绑公钥：仅当 id_token 校验的 user_id 一致才允许（密钥轮换）
            if existing["user_id"] != real_user_id:
                raise HTTPException(
                    status_code=409,
                    detail="设备身份与账号不匹配",
                )

        now = int(time.time())

        # 5) upsert user
        conn.execute(
            """INSERT INTO users (user_id, provider, email, created_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(user_id) DO UPDATE SET
                 provider=excluded.provider,
                 email=CASE WHEN excluded.email<>'' THEN excluded.email ELSE users.email END""",
            (real_user_id, data.provider, verified["email"], now),
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


# ================= 试用与权益（S4 / S5） =================
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


def _grant_trial_if_due(user_id: str, device_id: str) -> dict:
    """按 user_id 与 device_id 双维度检查冷却期，返回 (allow, remain)。

    - 若任一维度上次试用距今 < 冷却期 且 次数未用完 → 直接返回当前 grant。
    - 若两个维度冷却都过了 → 新发一次 grant（reset used_count=0）。
    """
    now = int(time.time())
    conn = _db()
    try:
        u_row = conn.execute(
            """SELECT * FROM trials WHERE user_id=?
               ORDER BY granted_at DESC LIMIT 1""",
            (user_id,),
        ).fetchone()
        d_row = conn.execute(
            """SELECT * FROM trials WHERE device_id=?
               ORDER BY granted_at DESC LIMIT 1""",
            (device_id,),
        ).fetchone()

        def fresh_enough(row) -> bool:
            return (now - row["granted_at"]) < TRIAL_COOLDOWN_SECONDS

        # 已有 grant 且在冷却期内
        if u_row and fresh_enough(u_row):
            remain = TRIAL_QUOTA - u_row["used_count"]
            return {"remain": max(remain, 0), "granted_at": u_row["granted_at"]}
        if d_row and fresh_enough(d_row):
            remain = TRIAL_QUOTA - d_row["used_count"]
            return {"remain": max(remain, 0), "granted_at": d_row["granted_at"]}

        # 冷却期已过（或首次）→ 新发试用
        conn.execute(
            """INSERT INTO trials (user_id, device_id, granted_at, used_count)
               VALUES (?, ?, ?, 0)""",
            (user_id, device_id, now),
        )
        conn.commit()
        return {"remain": TRIAL_QUOTA, "granted_at": now}
    finally:
        conn.close()


def _consume_trial(user_id: str, device_id: str) -> None:
    """试用次数 -1（记录到最新一次 grant）。"""
    conn = _db()
    try:
        row = conn.execute(
            """SELECT id FROM trials WHERE user_id=? AND device_id=?
               ORDER BY granted_at DESC LIMIT 1""",
            (user_id, device_id),
        ).fetchone()
        if row:
            conn.execute(
                """UPDATE trials SET used_count = used_count + 1 WHERE id=?""",
                (row["id"],),
            )
            conn.commit()
    finally:
        conn.close()


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

    # 输入成本控制（花钱之前硬拦）
    user_text = data.text
    _check_input_budget(user_text)

    ent = _get_entitlement(user_id)
    paid = _is_paid_active(ent)

    if paid:
        # 付费用户：按每日配额 + 限流
        _count_usage(user_id, int(time.time()), 0, PAID_DAILY_QUOTA, PAID_RATE_PER_MINUTE)
    else:
        # 免费用户：试用逻辑（3 次 + 7 天冷却）
        trial = _grant_trial_if_due(user_id, device_id)
        if trial["remain"] <= 0:
            raise HTTPException(
                status_code=403,
                detail="试用次数已用完，请购买后继续使用",
            )
        _consume_trial(user_id, device_id)

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
        dify_outputs = dify_data.get("data", {}).get("outputs", {})
        final_text = dify_outputs.get("text", "")
        if not final_text:
            raise HTTPException(
                status_code=500,
                detail="Dify 未返回有效的 text 字段，请检查画板 End 节点配置是否叫 text",
            )
        # 输出兜底截断（成本已在 max_tokens 锁死，这里是防异常返回超长文本）
        final_text = final_text[: MAX_INPUT_CHARS * 2]
        return final_text
    except httpx.RequestError as exc:
        raise HTTPException(status_code=503, detail=f"与 Dify 服务器通信网络异常: {str(exc)}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"网关内部解析异常: {str(e)}")


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
