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
import math
import os
import random
import re
import secrets
import sqlite3
import struct
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
# 案件生成工作流（生成当前案件的核心真相：case_core）。
# 无输入变量，仅接收返回结果（blocking 模式）。
# 注意：Key 必须通过环境变量 CASE_DIFY_API_KEY 提供（勿硬编码到代码/提交到仓库）。
CASE_DIFY_API_KEY = os.environ.get("CASE_DIFY_API_KEY", "")
CASE_DIFY_API_URL = os.environ.get("CASE_DIFY_API_URL", DIFY_API_URL)
# 输出 token 上限（Dify max_tokens，需在 Dify 画布 LLM 节点绑定 max_tokens 输入变量）
DIFY_MAX_TOKENS = int(os.environ.get("DIFY_MAX_TOKENS", "4000"))
# ---- 统一超时策略（默认 30 秒）----
# 四段传输（App→FastAPI、FastAPI→Dify、Dify→FastAPI、FastAPI→App）一律 30 秒
# 空闲超时，且"收到任何数据或心跳即重置 30 秒"。服务器在等待阻塞式 Dify 调用期间
# 会持续推送心跳（15s 一次），避免慢 Dify 被误判超时；一旦真的超过 30 秒
# （任一端无数据/心跳），FastAPI 直接关闭当前任务不再等待，客户端 30 秒无数据
# 自然弹出"网络疑似超时，请重启重试"提示。
# 生产环境可用环境变量覆盖（默认均为 30）：
#   DIFY_HTTP_TIMEOUT         共享客户端默认（connect/read/write/pool）
#   CASE_DIFY_TIMEOUT         案件核心生成（blocking 工作流）
#   AUDIT_DIFY_TIMEOUT        内容审核（blocking 工作流）
#   STORY_DIFY_STREAM_TIMEOUT 小说正文流式读取（read 阶段，收数据即重置）
DIFY_HTTP_TIMEOUT = float(os.environ.get("DIFY_HTTP_TIMEOUT", "30"))
CASE_DIFY_TIMEOUT = float(os.environ.get("CASE_DIFY_TIMEOUT", "30"))
AUDIT_DIFY_TIMEOUT = float(os.environ.get("AUDIT_DIFY_TIMEOUT", "30"))
STORY_DIFY_STREAM_TIMEOUT = float(os.environ.get("STORY_DIFY_STREAM_TIMEOUT", "30"))
# ---- 违规自动修正工作流（可选）----
# 审核 REJECT 后，服务器自动把"违规文本 + guardrail 判定 JSON"发给本工作流改写，
# 改写文本重新送审，通过后覆盖原违规段继续打字；未配置 REVISE_DIFY_API_KEY 时
# 保持原行为（直接 abort 弹窗"重新输入"）。
REVISE_DIFY_API_KEY = os.environ.get("REVISE_DIFY_API_KEY", "")
REVISE_DIFY_API_URL = os.environ.get("REVISE_DIFY_API_URL", DIFY_API_URL)
REVISE_DIFY_TIMEOUT = float(os.environ.get("REVISE_DIFY_TIMEOUT", "30"))
# 修正-重审循环上限：一次违规最多连续修正 REVISE_MAX_ATTEMPTS 轮（每轮=改一遍+重审一遍），
# 仍违规则回退到现有 abort 弹窗，防止无限烧钱/死循环。
REVISE_MAX_ATTEMPTS = int(os.environ.get("REVISE_MAX_ATTEMPTS", "3"))
# 修正工作流输出 token 上限（改写文本不得超过，防止越写越长）。
REVISE_MAX_TOKENS = int(os.environ.get("REVISE_MAX_TOKENS", "1500"))
# 输入 token 估算上限（入口硬拦，估算在花钱之前）
MAX_INPUT_TOKENS = int(os.environ.get("MAX_INPUT_TOKENS", "5000"))
# 输入字符数兜底上限（防止极端长文本撑爆估算）
MAX_INPUT_CHARS = int(os.environ.get("MAX_INPUT_CHARS", "4000"))
# 整本小说正文数组累计字符上限（与单次输入上限解耦）。
# 小说文本由用户付费生成，默认一亿字≈无实际限制；仅作兜底，防止异常超大
# payload 打爆内存/磁盘或触发反向代理请求体限制。
MAX_STORY_TOTAL_CHARS = int(os.environ.get("MAX_STORY_TOTAL_CHARS", "100000000"))

# ---- RAG 记忆检索（嵌入 API：当前用 Jina v3，可切回 HF bge-m3）----
# 小说正文切块后经嵌入 API 编码（1024 维）。变量名沿用 HF_*（历史命名），
# 现在实际指向任意 OpenAI 兼容嵌入服务（如 Jina），_embed_texts 自动适配两种返回格式。
# 未配置 HF_TOKEN 时 RAG 整体优雅降级（跳过嵌入/检索，不影响原有生成流程）。
HF_TOKEN = os.environ.get("HF_TOKEN", "").strip()
EMBED_MODEL = os.environ.get("EMBED_MODEL", "jina-embeddings-v3").strip()
HF_EMBED_URL = os.environ.get("HF_EMBED_URL", "https://api.jina.ai/v1/embeddings").strip()
HF_EMBED_TIMEOUT = float(os.environ.get("HF_EMBED_TIMEOUT", "30"))
# 切块参数：600 token / 重复 100；结尾倒推 600（最后一块保证覆盖章节结尾）
RAG_CHUNK_TOKENS = int(os.environ.get("RAG_CHUNK_TOKENS", "600"))
RAG_CHUNK_OVERLAP = int(os.environ.get("RAG_CHUNK_OVERLAP", "100"))
# 语义检索：cosine top-k，只发射 ≥ 阈值的候选
RAG_TOP_K = int(os.environ.get("RAG_TOP_K", "3"))
RAG_SEMANTIC_THRESHOLD = float(os.environ.get("RAG_SEMANTIC_THRESHOLD", "0.65"))
# ---- RAG 补建与并发调优 ----
# 触发轮补建：非零且 seq 被 RAG_BACKFILL_EVERY(5) 整除时，先取当前章节向量，
# 成功后检测该用户缺向量的章节，按"补一条成功再续一条"顺序补，最多 RAG_BACKFILL_BATCH(5) 条。
RAG_BACKFILL_EVERY = int(os.environ.get("RAG_BACKFILL_EVERY", "5"))
RAG_BACKFILL_BATCH = int(os.environ.get("RAG_BACKFILL_BATCH", "5"))
# 检索（用户行动）等待向量返回的超时：RAG_RETRIEVE_TIMEOUT(3) 秒内拿不到就无感降级、放弃本轮 RAG。
RAG_RETRIEVE_TIMEOUT = float(os.environ.get("RAG_RETRIEVE_TIMEOUT", "3"))
# 应用层并发上限：同时最多 RAG_MAX_INFLIGHT(5) 个嵌入请求在飞，满了直接跳过（留给补建），不排队。
RAG_MAX_INFLIGHT = int(os.environ.get("RAG_MAX_INFLIGHT", "5"))
# HF 专用连接池上限（与 Dify 分离，便于定位瓶颈）：物理兜底。
HF_MAX_CONNECTIONS = int(os.environ.get("HF_MAX_CONNECTIONS", "50"))

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
# 空串/未设置视为开启（默认供开发调试）；仅显式 0/false/no/off 才关闭。
DEBUG_PAYLOAD_PREVIEW = (
    os.environ.get("DEBUG_PAYLOAD_PREVIEW", "1").strip().lower()
    not in ("0", "false", "no", "off", "")
)
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
    -- 当前案件信息（凶杀案设定，Dify 输出 core_content，服务器权威保存）
    case_core      TEXT DEFAULT '',   -- 当前案件核心（死者身份/现场/真相背景等完整设定文本）
    -- 当前氛围（LLM 生成该段时的氛围快照，服务器权威保存）
    current_aura   TEXT DEFAULT '',   -- 当前氛围（如"紧张""温馨"等）
    -- 脚本运行状态（均为 TEXT）
    completed_script_ids TEXT DEFAULT '',  -- 已经完整运行过的脚本编号集合
    current_script_id    TEXT DEFAULT '',  -- 当前脚本序号
    UNIQUE(user_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_segments_user_seq ON story_segments(user_id, seq);
-- 按脚本号去重的覆盖索引：支撑每次拉取时按 (user_id, current_script_id) 定点查
-- MAX(seq)，避免对整份小说做全表扫描。
CREATE INDEX IF NOT EXISTS idx_segments_user_script_seq
    ON story_segments(user_id, current_script_id, seq);

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

-- 小说脚本表（fiction_script）：每一行是一段小说脚本。
-- 第 1 列 id 为序号（主键，从 1 开始）；
-- 第 2 列 case_core_prompt 为本脚本对应案件核心真相生成提示词；
-- 之后每章 3 列一组：
--   chapter_script_n / chapter_script_n_choice_2 / chapter_script_n_choice_3
-- 一直排到 chapter_script_20，共 62 列。
CREATE TABLE IF NOT EXISTS fiction_script (
    id INTEGER PRIMARY KEY,
    case_core_prompt TEXT DEFAULT '',
    chapter_script_1 TEXT DEFAULT '',
    chapter_script_1_choice_2 TEXT DEFAULT '',
    chapter_script_1_choice_3 TEXT DEFAULT '',
    chapter_script_2 TEXT DEFAULT '',
    chapter_script_2_choice_2 TEXT DEFAULT '',
    chapter_script_2_choice_3 TEXT DEFAULT '',
    chapter_script_3 TEXT DEFAULT '',
    chapter_script_3_choice_2 TEXT DEFAULT '',
    chapter_script_3_choice_3 TEXT DEFAULT '',
    chapter_script_4 TEXT DEFAULT '',
    chapter_script_4_choice_2 TEXT DEFAULT '',
    chapter_script_4_choice_3 TEXT DEFAULT '',
    chapter_script_5 TEXT DEFAULT '',
    chapter_script_5_choice_2 TEXT DEFAULT '',
    chapter_script_5_choice_3 TEXT DEFAULT '',
    chapter_script_6 TEXT DEFAULT '',
    chapter_script_6_choice_2 TEXT DEFAULT '',
    chapter_script_6_choice_3 TEXT DEFAULT '',
    chapter_script_7 TEXT DEFAULT '',
    chapter_script_7_choice_2 TEXT DEFAULT '',
    chapter_script_7_choice_3 TEXT DEFAULT '',
    chapter_script_8 TEXT DEFAULT '',
    chapter_script_8_choice_2 TEXT DEFAULT '',
    chapter_script_8_choice_3 TEXT DEFAULT '',
    chapter_script_9 TEXT DEFAULT '',
    chapter_script_9_choice_2 TEXT DEFAULT '',
    chapter_script_9_choice_3 TEXT DEFAULT '',
    chapter_script_10 TEXT DEFAULT '',
    chapter_script_10_choice_2 TEXT DEFAULT '',
    chapter_script_10_choice_3 TEXT DEFAULT '',
    chapter_script_11 TEXT DEFAULT '',
    chapter_script_11_choice_2 TEXT DEFAULT '',
    chapter_script_11_choice_3 TEXT DEFAULT '',
    chapter_script_12 TEXT DEFAULT '',
    chapter_script_12_choice_2 TEXT DEFAULT '',
    chapter_script_12_choice_3 TEXT DEFAULT '',
    chapter_script_13 TEXT DEFAULT '',
    chapter_script_13_choice_2 TEXT DEFAULT '',
    chapter_script_13_choice_3 TEXT DEFAULT '',
    chapter_script_14 TEXT DEFAULT '',
    chapter_script_14_choice_2 TEXT DEFAULT '',
    chapter_script_14_choice_3 TEXT DEFAULT '',
    chapter_script_15 TEXT DEFAULT '',
    chapter_script_15_choice_2 TEXT DEFAULT '',
    chapter_script_15_choice_3 TEXT DEFAULT '',
    chapter_script_16 TEXT DEFAULT '',
    chapter_script_16_choice_2 TEXT DEFAULT '',
    chapter_script_16_choice_3 TEXT DEFAULT '',
    chapter_script_17 TEXT DEFAULT '',
    chapter_script_17_choice_2 TEXT DEFAULT '',
    chapter_script_17_choice_3 TEXT DEFAULT '',
    chapter_script_18 TEXT DEFAULT '',
    chapter_script_18_choice_2 TEXT DEFAULT '',
    chapter_script_18_choice_3 TEXT DEFAULT '',
    chapter_script_19 TEXT DEFAULT '',
    chapter_script_19_choice_2 TEXT DEFAULT '',
    chapter_script_19_choice_3 TEXT DEFAULT '',
    chapter_script_20 TEXT DEFAULT '',
    chapter_script_20_choice_2 TEXT DEFAULT '',
    chapter_script_20_choice_3 TEXT DEFAULT ''
);

-- RAG 记忆检索：人名登记（每章一份）+ 原文切块向量 + 名字→最新章节反查。
-- 人名来自 Dify 生成工作流 LLM② 返回量（并入氛围/背景音乐那一路，不新增 LLM 调用）。
CREATE TABLE IF NOT EXISTS story_chapter_distill (
    user_id      TEXT NOT NULL,
    segment_seq  INTEGER NOT NULL,          -- 对应 story_segments.seq
    current_script_id TEXT DEFAULT '',      -- "脚本id-章节"
    characters   TEXT NOT NULL DEFAULT '[]',-- JSON 数组：本章人物名单
    created_at   INTEGER NOT NULL,
    PRIMARY KEY (user_id, segment_seq)
);

-- 原文切块向量：600/100 切块（结尾倒推 600），bge-m3 1024 维 float32 BLOB
CREATE TABLE IF NOT EXISTS story_chunk_vectors (
    user_id      TEXT NOT NULL,
    chunk_id     TEXT NOT NULL,             -- f"{segment_seq}-{offset}"
    segment_seq  INTEGER NOT NULL,
    current_script_id TEXT DEFAULT '',
    text         TEXT NOT NULL,             -- 该块原文
    embedding    BLOB NOT NULL,             -- 1024 * float32
    created_at   INTEGER NOT NULL,
    PRIMARY KEY (user_id, chunk_id)
);
CREATE INDEX IF NOT EXISTS idx_chunk_vec_user_seq
    ON story_chunk_vectors(user_id, segment_seq);

-- 名字反查：每个名字只保留"最新记忆"（最靠后出现的章节 seq）。
-- 重名时用新章节覆盖旧条目（不区分脚本），删除老记忆。
CREATE TABLE IF NOT EXISTS story_character_lookup (
    user_id     TEXT NOT NULL,
    name        TEXT NOT NULL,
    segment_seq INTEGER NOT NULL,           -- 该名字最新出现的章节 seq
    updated_at  INTEGER NOT NULL,
    PRIMARY KEY (user_id, name)
);
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


async_http_client = httpx.AsyncClient(timeout=DIFY_HTTP_TIMEOUT)
# HF 嵌入专用客户端：与 Dify 连接池分离，便于日后定位"哪边不够用"。
hf_http_client = httpx.AsyncClient(
    timeout=HF_EMBED_TIMEOUT,
    limits=httpx.Limits(
        max_connections=HF_MAX_CONNECTIONS,
        max_keepalive_connections=max(5, HF_MAX_CONNECTIONS // 5),
    ),
)


@app.on_event("shutdown")
async def shutdown_event():
    await async_http_client.aclose()
    await hf_http_client.aclose()


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
    """审核结果：区分"明确违规"、"审核不可用"与"审核超时"。

    - PASS：明确判定通过（action == "none"）。
    - REJECT：审核成功并返回非 none 的 action（明确判定违规）。
    - UNAVAILABLE：审核不可用（配额超限 / 网络失败 / 非 200 / 输出无法解析）。
      这是审核链路自身的问题，不代表内容违规，调用方应作为可重试错误处理，
      而不是弹出"内容违规"警告（避免弱网/审核服务抖动被误判为用户违规）。
    - TIMEOUT：Dify 审核 30 秒无返回（超时）。按统一超时规则，流式层据此
      直接关闭当前流，客户端 30 秒无数据自然弹"网络疑似超时，请重启重试"。
    """
    PASS = "pass"
    REJECT = "reject"
    UNAVAILABLE = "unavailable"
    TIMEOUT = "timeout"


def _build_audit_verdict(out: str) -> dict:
    """把审核工作流输出整理为结构化判定返回给客户端。

    客户端只消费其中的 action 字段：action=="none" 放行，否则不通过。
    action 值获取失败（格式错误 / 断网 / 未知等一切原因）→ 不返回 action 字段，
    客户端解析不到 action 后按"网络问题请重试"提示，而不是"内容违规需修改"。
    """
    data = _parse_audit_output(out)
    action = _parse_audit_json(out)
    if data is None or action is None:
        # action 值获取失败（格式错误 / 断网 / 未知等一切原因）：
        # 不返回 action 判定字段，让客户端解析不到 action，
        # 从而走"网络连接似乎出现问题，请重试"提示，而不是让用户修改设定。
        return {
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


async def _moderate_story(text: str) -> tuple:
    """调用审核工作流，返回 (三态判定, guardrail 判定 dict)。

    只把"审核成功且明确判为违规"当作 REJECT；配额超限、网络失败、
    非 200、输出无法解析等一律返回 UNAVAILABLE（可重试，非违规）。
    第二元为 guardrail 结构化判定（action/category/confidence/reason），
    供"违规修正"工作流使用；无有效判定时为 None。
    """
    if not text or not text.strip():
        return ModerationOutcome.PASS, None
    # 审核工作流全局配额（所有用户合计 AUDIT_DAILY_LIMIT 次/天）：
    # 超限时不调用 Dify，视为"审核不可用"（可重试），而非"内容违规"。
    try:
        _check_audit_quota(int(time.time()))
    except HTTPException:
        return ModerationOutcome.UNAVAILABLE, None
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
            DIFY_API_URL, json=payload, headers=headers, timeout=AUDIT_DIFY_TIMEOUT
        )
        if resp.status_code != 200:
            return ModerationOutcome.UNAVAILABLE, None
        data = resp.json()
        out = _extract_guardrail_output(data)
        verdict = _build_audit_verdict(out)
        action = _parse_audit_json(out)
        if action is None:
            # 审核成功但无有效 action 判定：视为审核链路异常（可重试），非违规
            return ModerationOutcome.UNAVAILABLE, None
        return (
            ModerationOutcome.PASS if action == "none" else ModerationOutcome.REJECT,
            verdict,
        )
    except httpx.TimeoutException:
        # Dify 审核 30 秒无返回：按统一超时规则标记为 TIMEOUT（非内容违规），
        # 由流式层据此直接关闭当前流，客户端 30 秒无数据弹"重启"提示。
        return ModerationOutcome.TIMEOUT, None
    except Exception:
        # 网络 / 解析异常：审核不可用（可重试），非违规
        return ModerationOutcome.UNAVAILABLE, None


async def _revise_story(text: str, verdict: dict, language: str = "") -> Optional[str]:
    """调用"违规修正"工作流，返回改写后的文本；失败返回 None。

    工作流输入变量：novel_text（违规文本）、guardrail_json（guardrail 判定 JSON）、
    language（完整语言名，如"简体中文"，防止 LLM 改写时串用其它语言）。
    未配置 REVISE_DIFY_API_KEY 时直接返回 None（调用方回退到 abort 弹窗）。
    输出变量名依次尝试 revised_text / text / novel_text / output_text / result。
    """
    if not REVISE_DIFY_API_KEY:
        return None
    headers = {
        "Authorization": f"Bearer {REVISE_DIFY_API_KEY}",
        "Content-Type": "application/json",
    }
    payload = {
        "inputs": {
            "novel_text": text,
            "guardrail_json": json.dumps(verdict, ensure_ascii=False),
            "language": language or "简体中文",
            "max_tokens": REVISE_MAX_TOKENS,
        },
        "response_mode": "blocking",
        "user": "story-revise",
    }
    try:
        resp = await async_http_client.post(
            REVISE_DIFY_API_URL,
            json=payload,
            headers=headers,
            timeout=REVISE_DIFY_TIMEOUT,
        )
        if resp.status_code != 200:
            logger.warning("REVISE 工作流返回非 200：%s", resp.status_code)
            return None
        data = resp.json()
        data_block = data.get("data") if isinstance(data, dict) else None
        outputs = (
            data_block.get("outputs")
            if isinstance(data_block, dict)
            and isinstance(data_block.get("outputs"), dict)
            else {}
        )
        for key in ("revised_text", "text", "novel_text", "output_text", "result"):
            v = outputs.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
        logger.warning(
            "REVISE 工作流返回 200 但未取到修正文本 outputs=%s",
            list(outputs.keys()),
        )
        return None
    except httpx.TimeoutException:
        logger.warning("REVISE 工作流超时（%s 秒）", REVISE_DIFY_TIMEOUT)
        return None
    except Exception as e:
        logger.warning("REVISE 工作流调用失败: %s", e, exc_info=True)
        return None


def _moderation_failure_sse(mr: ModerationOutcome, snippet: str = "") -> Optional[dict]:
    """把非 PASS 的审核结果映射为应发送的 SSE 事件；PASS 返回 None。

    REJECT → abort（违规，弹"内容违规"，并附带审核未通过的片段原文 snippet，
            便于排查是真违规还是误判）；UNAVAILABLE → error（可重试，网络式警告）。
    """
    if mr is ModerationOutcome.REJECT:
        return {
            "event": "abort",
            "reason": "生成内容包含违规信息，已中止",
            "snippet": snippet,
        }
    if mr is ModerationOutcome.UNAVAILABLE:
        return {
            "event": "error",
            "message": "内容审核服务暂时不可用，请检查网络后重试",
        }
    return None


def _random_script_row(script_id: Optional[int] = None) -> Optional[dict]:
    """从脚本子数据库 fiction_script 读取一行（含全部列）。
    script_id 为 None 时随机抽一行，否则按指定 id 读取。表为空/不存在时返回 None。
    """
    conn = _db()
    try:
        if script_id is not None:
            return conn.execute(
                """SELECT * FROM fiction_script WHERE id=?""",
                (script_id,),
            ).fetchone()
        return conn.execute(
            """SELECT * FROM fiction_script
               ORDER BY RANDOM() LIMIT 1"""
        ).fetchone()
    finally:
        conn.close()


class CaseCoreError(Exception):
    """案件核心（case_core）生成失败：超时 / 非 200 / 网络异常 / 返回空核心。

    没有案件核心生成的小说不合格，绝不允许回退空 case_core 落库。
    统一向上抛出，由调用方终止整个生成请求。
    """


async def _generate_case_meta(chapter: int = 1, script_id: Optional[int] = None) -> dict:
    """调用"案件生成"Dify 工作流，生成当前案件的核心真相（凶杀案设定）。

    先从脚本子数据库 fiction_script 读取一行（script_id 为 None 时随机抽取）：
    - 取其 case_core_prompt（本脚本对应的案件核心真相生成提示词）作为输入变量
      随请求发给 Dify，让 Dify 按该提示词生成 case_core；
    - 同时取出该脚本条目第 chapter 章的正文（chapter_script_{chapter}）、两个选择
      （chapter_script_{chapter}_choice_2 / _choice_3）与脚本序号 id，
      供小说生成（第 3 次 Dify 调用）与落库使用。
    该工作流 blocking 模式，只返回结果。
    返回 {"case_core", "script_id", "chapter", "chapter_text", "choice_2", "choice_3"}。
    Dify 返回 victim_identity / death_scene / murder_method 三个量，
    将其简单拼接（换行连接）后赋给 case_core。
    任何失败（超时 / 非 200 / 网络异常 / 返回空核心）都抛 CaseCoreError，
    由调用方终止整个生成请求，绝不回退空 case_core 继续生成。
    """
    script_row = _random_script_row(script_id)
    if script_row is None:
        # 脚本库为空/未找到对应脚本：无法生成案件核心，同样视为不合格，终止本次生成
        logger.warning("脚本库为空或未找到脚本 script_id=%r，终止本次生成", script_id)
        raise CaseCoreError("脚本库为空或未找到对应脚本，无法生成案件核心")
    script_id = script_row["id"]
    case_core_prompt = (script_row["case_core_prompt"] or "").strip()
    chapter_text = (script_row[f"chapter_script_{chapter}"] or "").strip()
    choice_2 = (script_row[f"chapter_script_{chapter}_choice_2"] or "").strip()
    choice_3 = (script_row[f"chapter_script_{chapter}_choice_3"] or "").strip()
    logger.warning(
        "CASE 脚本抽取 script_id=%r chapter=%d prompt_len=%d chapter_len=%d",
        script_id, chapter, len(case_core_prompt), len(chapter_text),
    )
    headers = {
        "Authorization": f"Bearer {CASE_DIFY_API_KEY}",
        "Content-Type": "application/json",
    }
    payload = {
        "inputs": {
            "case_core_prompt": case_core_prompt,
        },
        "response_mode": "blocking",
        "user": "case-generator",
    }
    try:
        resp = await async_http_client.post(
            CASE_DIFY_API_URL, json=payload, headers=headers, timeout=CASE_DIFY_TIMEOUT
        )
        if resp.status_code != 200:
            logger.warning("案件工作流返回非 200：%s，终止本次生成", resp.status_code)
            raise CaseCoreError(f"案件工作流返回非 200：{resp.status_code}")
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
        # 注意：工作流代码节点另返回 core_content（= 生成案件的提示词），
        # core_content 是提示词而非生成结果，绝不可作为 case_core 入库。
        core = "\n".join(
            p for p in (victim_identity, death_scene, murder_method) if p
        )
        if not core or not core.strip():
            # Dify 返回 200 但未产出任何核心内容：同样视为不合格，终止本次生成
            logger.warning("案件工作流返回 200 但案件核心为空，终止本次生成")
            raise CaseCoreError("案件工作流返回 200 但案件核心为空")
        return {
            "case_core": core,
            "script_id": script_id,
            "chapter": chapter,
            "chapter_text": chapter_text,
            "choice_2": choice_2,
            "choice_3": choice_3,
        }
    except CaseCoreError:
        # 已构造好的案件核心失败信息：直接向上抛出，由调用方终止整个生成请求
        raise
    except httpx.TimeoutException:
        # 案件核心生成 30 秒超时：按统一超时规则把 httpx.TimeoutException 原样上抛，
        # 流式层捕获后直接关闭当前流（不发送错误事件），客户端 30 秒无数据弹"重启"提示。
        logger.warning("案件工作流调用超时（%s 秒），终止本次生成", CASE_DIFY_TIMEOUT)
        raise
    except Exception as e:
        logger.warning("案件工作流调用失败", exc_info=True)
        raise CaseCoreError(f"案件工作流调用失败：{e}")


def _load_next_script_chapter(user_id: str, current_count: int) -> Optional[dict]:
    """续写轮：从该用户上一段（seq = current_count - 1）读取脚本序号（"脚本id-章节"，
    如 "2-4"），章节号 +1（得到 "2-5"），再从 fiction_script 读取对应章节的正文
    （chapter_script_5）与两个选择（chapter_script_5_choice_2 / _choice_3）。

    返回与 _generate_case_meta 同构的 dict（case_core / script_id / chapter /
    chapter_text / choice_2 / choice_3）；上一段无有效脚本序号或脚本不存在时返回 None。
    """
    conn = _db()
    try:
        prev = conn.execute(
            """SELECT current_script_id, case_core FROM story_segments
               WHERE user_id=? AND seq=? LIMIT 1""",
            (user_id, current_count - 1),
        ).fetchone()
        if prev is None:
            return None
        cur_id = (prev["current_script_id"] or "").strip()
        parts = cur_id.split("-")
        if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
            return None
        script_id = int(parts[0])
        chapter = int(parts[1]) + 1
        row = conn.execute(
            """SELECT * FROM fiction_script WHERE id=?""",
            (script_id,),
        ).fetchone()
        if row is None:
            return None
        # 章节号超出脚本 20 章范围时，正文与选择取空串（脚本序号仍按递增记录）
        chapter_text = (
            (row[f"chapter_script_{chapter}"] or "").strip() if chapter <= 20 else ""
        )
        choice_2 = (
            (row[f"chapter_script_{chapter}_choice_2"] or "").strip()
            if chapter <= 20
            else ""
        )
        choice_3 = (
            (row[f"chapter_script_{chapter}_choice_3"] or "").strip()
            if chapter <= 20
            else ""
        )
        logger.warning(
            "CONTINUE 脚本推进 prev=%r -> script_id=%d chapter=%d",
            cur_id, script_id, chapter,
        )
        return {
            "case_core": prev["case_core"] or "",
            "script_id": script_id,
            "chapter": chapter,
            "chapter_text": chapter_text,
            "choice_2": choice_2,
            "choice_3": choice_3,
        }
    finally:
        conn.close()


def _parse_script_tally(s: str) -> dict:
    """解析 completed_script_ids 累计表："2(1)1(4)3(3)5(3)" → {2:1, 1:4, 3:3, 5:3}。"""
    result: dict = {}
    for m in re.finditer(r"(\d+)\((\d+)\)", s or ""):
        result[int(m.group(1))] = int(m.group(2))
    return result


def _serialize_script_tally(tally: dict) -> str:
    """把 {2:1, 1:4, 3:3, 5:3} 序列化为 "2(1)1(4)3(3)5(3)"（保持插入顺序）。"""
    return "".join(f"{k}({v})" for k, v in tally.items())


def _read_script_tally(user_id: str) -> dict:
    """读取该用户最新一段的 completed_script_ids 累计表（无数据返回空表）。"""
    conn = _db()
    try:
        row = conn.execute(
            """SELECT completed_script_ids FROM story_segments
               WHERE user_id=? ORDER BY seq DESC LIMIT 1""",
            (user_id,),
        ).fetchone()
        return _parse_script_tally((row["completed_script_ids"] or "") if row else "")
    finally:
        conn.close()


def _next_completed_script_ids(
    user_id: str, pre_case_meta: Optional[dict], choices_available: bool
) -> str:
    """计算本段落库应写入的 completed_script_ids 新值：
    - 脚本未耗尽（choices_available=True）：沿用当前累计表，不改变；
    - 脚本耗尽（choices_available=False）：当前脚本结束，规则为：
        若其计数小于其它脚本计数的最大值 → 直接追平到该最大值；
        若其已是最大值（含并列）→ 自身 +1；
        表中没有该脚本时按计数 0 处理（同样追平到最大值）。
      例如 2(1)1(4)3(3)5(3)：脚本 2/3/5 结束都追平到 4；脚本 1 结束则变 1(5)。
    返回序列化字符串。
    """
    tally = _read_script_tally(user_id)
    if not choices_available and pre_case_meta is not None:
        script_id = pre_case_meta.get("script_id")
        if script_id:
            sid = int(script_id)
            current = tally.get(sid, 0)
            # 其它脚本计数的最大值（不含当前脚本；无其它脚本时为 0）
            max_other = max(
                (v for k, v in tally.items() if k != sid), default=0
            )
            if current < max_other:
                tally[sid] = max_other
            else:
                tally[sid] = current + 1
    return _serialize_script_tally(tally)


def _pick_least_used_script(
    tally: dict, exclude_script_id: Optional[int] = None
) -> Optional[int]:
    """从 fiction_script 读取全部脚本序号，与累计表对比，找出"使用次数最少"的脚本；
    并列最少时随机抽取一个。
    可选 exclude_script_id：抽签时把该脚本排除（避免同一脚本连续运行两次），
    除非排除后没有其它可选脚本（即脚本库里只剩它一个）才保留。
    无脚本时返回 None。
    """
    conn = _db()
    try:
        rows = conn.execute("SELECT id FROM fiction_script").fetchall()
        if not rows:
            return None
        all_ids = [r["id"] for r in rows]
        # 排除刚运行完的脚本（避免连续），仅当排除后仍剩其它脚本才生效
        pool = (
            [sid for sid in all_ids if sid != exclude_script_id]
            if exclude_script_id is not None
            else all_ids
        )
        if not pool:
            pool = all_ids  # 只有被排除的那个脚本 → 退回去用它
        counts = {sid: tally.get(sid, 0) for sid in pool}
        min_count = min(counts.values())
        candidates = [sid for sid, c in counts.items() if c == min_count]
        return random.choice(candidates)
    finally:
        conn.close()


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


def _get_current_case_story(user_id: str, seq: int) -> str:
    """汇总要回传给 Dify 的正文（corrent_case_all_content 的取值来源）。

    返回该用户此前全部正文（seq < 当前轮），按 seq 升序换行拼接，
    为当前章节生成提供完整的续写上下文；无前文时返回空串。
    注：corrent_case_all_content 读的是 content 列（正文原文）。
    """
    conn = _db()
    try:
        rows = conn.execute(
            """SELECT content FROM story_segments
               WHERE user_id=? AND seq < ? ORDER BY seq ASC""",
            (user_id, seq),
        ).fetchall()
        parts = [r["content"] for r in rows if r["content"] and r["content"].strip()]
        return "\n".join(parts)
    finally:
        conn.close()


# 后续变量默认值：choice_1 恒为空白（用户想输入就输入，不输入就永远空白，不预填文案）。
# 【重要】choice_2/choice_3 一律不做任何兜底默认值：空即空，由脚本库当前章节提供；
# 脚本章节没有选择即为脚本结束（触发换脚本）。任何"取不到就用通用文案托底"的逻辑
# 都会让 choice_2/3 永不为空，导致"老脚本结束→换新脚本继续"永不触发，已彻底删除。
# music_style 是 Dify 工作流结构化枚举（白名单 MUSIC_STYLE_VALUES），
# 为保持与画布兼容，各语言统一用白名单内取值，不做本地化。
META_DEFAULTS = {
    "choice_1": "",
    "music_style": "悬疑",
    "case_core": "",   # 当前案件核心（Dify core_content；无则保底为空）
}
META_DEFAULTS_BY_LANG = {
    "zh": META_DEFAULTS,
    "zh-TW": {"choice_1": "", "music_style": "悬疑"},
    "yue": {"choice_1": "", "music_style": "悬疑"},
    "en": {"choice_1": "", "music_style": "悬疑"},
    "es": {"choice_1": "", "music_style": "悬疑"},
    "fr": {"choice_1": "", "music_style": "悬疑"},
    "de": {"choice_1": "", "music_style": "悬疑"},
    "pt": {"choice_1": "", "music_style": "悬疑"},
    "ja": {"choice_1": "", "music_style": "悬疑"},
    "ko": {"choice_1": "", "music_style": "悬疑"},
}


def _meta_defaults(language: Optional[str]) -> dict:
    """按用户语言返回后续变量保底默认值；未知/为空回退简体中文。

    先用简体中文 META_DEFAULTS 打底（含 case_core 等公共键），
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
    """从 Dify outputs 中提取后续变量（music_style）与案件信息。

    推演结果（LLM2 structured_output，经 End 节点扁平输出）映射：
      music / music_style     -> music_style
      choice_1 恒为空（用户后续自行填写，或直接选 choice_2/3）
      action_a / action_b     -> 输入框 2/3 的推荐行动（优先于脚本 choice_2/3）
    choice_2/choice_3 在流式段用 action_a/action_b 覆盖，取不到再用脚本当前章节的选择。
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

    def _pick_raw(*names: str) -> Any:
        for n in names:
            v = src.get(n)
            if v is not None and v != "":
                return v
        return None

    # 人物名单：来自 Dify 生成工作流 LLM② 返回量（并入氛围/背景音乐那一路，不新增调用）。
    # 兼容 JSON 数组字符串 / 真列表 / 逗号顿号换行分隔文本；缺失为空列表（人名登记跳过）。
    characters = _parse_character_names(
        _pick_raw("characters", "character_names", "characters_list", "人物名单", "人物")
    )

    meta = {
        "choice_1": "",  # 默认空白，由用户后续自行填写
        # choice_2/choice_3 默认空：流式段用 Dify action_a/action_b 覆盖，取不到再用脚本 choice_2/3
        "choice_2": "",
        "choice_3": "",
        # 推荐行动：Dify 生成工作流 LLM② 的结构化输出（action_a/action_b），
        # 流式段里用它覆盖输入框 2/3；取不到则回退脚本当前章节的 choice_2/3。
        "action_a": _s("action_a", "actionA", "action_a_text", "行动一"),
        "action_b": _s("action_b", "actionB", "action_b_text", "行动二"),
        "music_style": _s("music", "music_style") or defaults["music_style"],
        "case_core": _s("case_core", "core_content", "content") or defaults["case_core"],
        "characters": characters,
    }
    if meta["music_style"] not in MUSIC_STYLE_VALUES:
        meta["music_style"] = defaults["music_style"]
    return meta


def _has_inference_outputs(outputs: Optional[dict]) -> bool:
    """判断 Dify 返回里是否已包含推演所需量（music/music_style）。

    choice_2/choice_3 已改由脚本库提供（不再由 Dify 返回 action_a/action_b），
    因此这里只要求氛围 music/music_style 到位即可，作为"写入数据库新片段"的前置条件。
    """
    if not isinstance(outputs, dict):
        return False

    def _pick(*names: str) -> bool:
        return any(
            isinstance(outputs.get(n), str) and outputs.get(n).strip() for n in names
        )

    return _pick("music_style", "music")


async def _persist_story_segment(
    user_id: str,
    new_segment: str,
    settings: Optional[dict] = None,
    meta: Optional[dict] = None,
    case_meta: Optional[dict] = None,
    completed_script_ids: str = "",
) -> None:
    """追加本段为该用户小说数组的新元素（seq = 原最大下标 + 1），单行 INSERT。

    服务器从 Dify 收到完整文本（且审核通过）就立即写入，
    与 App 是否收全无关；App 断流/卡死重启后，冷启动同步即可拉回完整文本。
    每段一行，追加不重写任何旧数据。
    同时把生成该段时点上的"本轮三个选择（choice_1/2/3，LLM② 推荐的下一轮行动，
    取不到用保底默认值）"、"后续变量（music_style）"与"用户设定快照"
    随行落库，供后续 RAG / 时间树返回等功能回溯本段的生成上下文。

    案件设定：case_core 在首段（随机抽取脚本）时生成一次并随段落落库；
    后续段落沿用上一段的 case_core（调用方传入的 case_meta 或上一行快照）。
    """
    if not new_segment or not new_segment.strip():
        return
    now = int(time.time())
    settings = settings or {}
    # 直接用上层已提取好的后续变量（choice_1/2/3/music_style）。
    # 仅对 music_style 用保底；choice_1/2/3 不做任何托底（空即空，由脚本库/用户提供）。
    m = dict(meta or {})
    _defaults = _meta_defaults(settings.get("language"))
    if not m.get("music_style"):
        m["music_style"] = _defaults.get("music_style", "")
    meta = m
    conn = _db()
    try:
        row = conn.execute(
            """SELECT COALESCE(MAX(seq), -1) AS m FROM story_segments WHERE user_id=?""",
            (user_id,),
        ).fetchone()
        next_seq = row["m"] + 1
        # 案件设定：case_core 在首段生成一次并落库，后续沿用。
        # - 调用方已前置生成/推进案件（case_meta 非 None，见 generate_story）：直接复用；
        # - 无 case_meta 时：原样复制上一行的 case_core（保持整本小说案件一致）。
        if case_meta is not None:
            meta["case_core"] = case_meta.get("case_core") or ""
        else:
            prev_row = conn.execute(
                """SELECT case_core FROM story_segments
                   WHERE user_id=? AND seq=? LIMIT 1""",
                (user_id, next_seq - 1),
            ).fetchone()
            if prev_row:
                meta["case_core"] = prev_row["case_core"] or ""
            else:
                # 上一轮不存在（异常兜底）：保留当前值（通常为空）
                meta["case_core"] = meta.get("case_core") or ""
        # 脚本序号：格式 "脚本序号-章节序号"（如 "1-1"），来自本次随机抽取的脚本条目；无则为空
        _cm = case_meta or {}
        _script_id = _cm.get("script_id") or ""
        _chapter = _cm.get("chapter") or ""
        current_script_id = f"{_script_id}-{_chapter}" if _script_id and _chapter else ""
        conn.execute(
            """INSERT INTO story_segments
                 (user_id, seq, content, created_at,
                  choice_1, choice_2, choice_3,
                  user_choice,
                  music_style,
                  location, era, player_name, player_traits,
                  language,
                  case_core, current_script_id, completed_script_ids)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
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
                (meta.get("case_core") or ""),
                current_script_id,
                completed_script_ids,
            ),
        )
        conn.commit()
        # ---- RAG：人名登记 + 后台原文切块嵌入（异步，不阻塞生成流）----
        # 排除主角名（player_name）：主角无处不在，收录进名字记忆只会制造噪声、污染检索。
        _rag_names = meta.get("characters") or []
        _pname = (settings.get("player_name") or "").strip()
        if _pname:
            _rag_names = [n for n in _rag_names if n != _pname]
        # 触发轮（非零且 seq%5==0）：当前章节构建成功后顺序补建缺失；普通轮：fire-and-forget。
        if _is_rag_trigger_seq(next_seq):
            _schedule_rag_trigger_build(
                user_id, next_seq, current_script_id,
                new_segment, _rag_names,
            )
        else:
            _schedule_rag_build(
                user_id, next_seq, current_script_id,
                new_segment, _rag_names,
            )
    finally:
        conn.close()


def _persist_story_segments_atomic(
    user_id: str, segments: list
) -> None:
    """原子落库多条 story_segments（同一事务）：要么全部写入，要么一条都不写。

    用于"脚本耗尽换脚本"场景：第一次生成的段（脚本最后一章/空章节）与切换后的
    新脚本段必须成对存在——若后续段生成/落库失败，则成组丢弃，避免用户陷入
    "只有一段、无法继续"的死状态。

    segments：每项为 (new_segment, settings, meta, case_meta, completed_script_ids)。
    """
    conn = _db()
    try:
        row = conn.execute(
            """SELECT COALESCE(MAX(seq), -1) AS m FROM story_segments WHERE user_id=?""",
            (user_id,),
        ).fetchone()
        base_seq = row["m"] + 1
        rag_items: list = []
        for offset, item in enumerate(segments):
            new_segment, settings, meta, case_meta, completed_script_ids = item
            if not new_segment or not new_segment.strip():
                continue
            settings = settings or {}
            m = dict(meta or {})
            _defaults = _meta_defaults(settings.get("language"))
            # 仅对 music_style 用保底；choice_1/2/3 不做任何托底（空即空）
            if not m.get("music_style"):
                m["music_style"] = _defaults.get("music_style", "")
            meta = m
            next_seq = base_seq + offset
            # 案件设定：case_meta 非 None 直接用；否则复制上一行
            if case_meta is not None:
                meta["case_core"] = case_meta.get("case_core") or ""
            else:
                prev = conn.execute(
                    """SELECT case_core FROM story_segments
                       WHERE user_id=? AND seq=? LIMIT 1""",
                    (user_id, next_seq - 1),
                ).fetchone()
                meta["case_core"] = (
                    (prev["case_core"] or "") if prev else (meta.get("case_core") or "")
                )
            # 脚本序号："脚本id-章节"（如 "2-5"）
            _cm = case_meta or {}
            _sid = _cm.get("script_id") or ""
            _ch = _cm.get("chapter") or ""
            current_script_id = f"{_sid}-{_ch}" if _sid and _ch else ""
            conn.execute(
                """INSERT INTO story_segments
                     (user_id, seq, content, created_at,
                      choice_1, choice_2, choice_3,
                      user_choice,
                      music_style,
                      location, era, player_name, player_traits,
                      language,
                      case_core, current_script_id, completed_script_ids)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    user_id,
                    next_seq,
                    new_segment,
                    int(time.time()),
                    meta["choice_1"],
                    meta["choice_2"],
                    meta["choice_3"],
                    "",
                    meta["music_style"],
                    (settings.get("location") or ""),
                    (settings.get("era") or ""),
                    (settings.get("player_name") or ""),
                    (settings.get("player_traits") or ""),
                    (settings.get("language") or ""),
                    (meta.get("case_core") or ""),
                    current_script_id,
                    completed_script_ids,
                ),
            )
            # 排除主角名（player_name）：主角不进入名字记忆
            _pname = (settings.get("player_name") or "").strip()
            _cnames = meta.get("characters") or []
            if _pname:
                _cnames = [n for n in _cnames if n != _pname]
            rag_items.append((next_seq, current_script_id, new_segment, _cnames))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    # ---- RAG：成对落库后，为每段后台构建人名登记 + 原文切块嵌入 ----
    for _seq, _sid, _content, _names in rag_items:
        if _is_rag_trigger_seq(_seq):
            _schedule_rag_trigger_build(user_id, _seq, _sid, _content, _names)
        else:
            _schedule_rag_build(user_id, _seq, _sid, _content, _names)


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
                      case_core
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
        # RAG 同步删除：清空该用户全部 RAG（distill/vectors/lookup）
        _purge_rag_for_user(user_id, conn)
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


# ================= RAG 记忆检索（HF 托管 bge-m3） =================
# 设计（已与产品确认）：
#   - 每章落库后后台异步：人名登记（最新记忆）+ 原文切块(600/100, 结尾倒推600) 嵌入。
#   - 每次用户行动指引做双通道检索（名字精确子串 + 语义 cosine top-3 ≥ 0.65）。
#   - 检索【排除当前正在生成的脚本】（只对比之前脚本的人名和向量）。
#   - 任一命中 → 注入整个章节原文；语义优先；多章≥阈值取最高分、并列随机；最多注入一章。
#   - 未配置 HF_TOKEN 时 RAG 整体优雅降级（人名登记照常，嵌入/语义跳过）。


def _rag_enabled() -> bool:
    return bool(HF_TOKEN) and bool(EMBED_MODEL)


def _parse_character_names(raw: Any) -> list:
    """把 Dify 返回的「人物名单」解析为名字字符串列表（去空白/去空/去重，仅收 ≥2 字）。
    兼容 JSON 数组字符串、真列表、逗号/顿号/换行分隔文本。"""
    if raw is None:
        return []
    if isinstance(raw, list):
        items = raw
    elif isinstance(raw, str):
        s = raw.strip()
        if not s:
            return []
        if s.startswith("["):
            try:
                v = json.loads(s)
                items = v if isinstance(v, list) else [s]
            except Exception:
                items = [s]
        else:
            items = re.split(r"[、,，;；\n]+", s)
    else:
        items = [str(raw)]
    out: list = []
    for it in items:
        if not isinstance(it, str):
            continue
        t = it.strip().strip("《》「」\"'（）()【】")
        if len(t) >= 2 and t not in out:
            out.append(t)
    return out


def _chunk_text(
    text: str,
    chunk_tokens: int = RAG_CHUNK_TOKENS,
    overlap_tokens: int = RAG_CHUNK_OVERLAP,
) -> list:
    """原文切块：chunk_tokens / overlap_tokens，结尾倒推 chunk_tokens。
    例（1300 token）：0-600、500-1100、700-1300（倒推 600）。总长 ≤ chunk → 整段一块。
    近似 token：中日韩/全角单字符≈1 token，拉丁/数字词按 ~4 字符/token。"""
    if not text or not text.strip():
        return []
    n = len(text)
    starts: list = []   # 每个 token 起点的字符下标
    toks: list = []     # 每个起点之后的近似 token 数
    i = 0
    while i < n:
        ch = text[i]
        if (
            ("\u4e00" <= ch <= "\u9fff")
            or ("\u3400" <= ch <= "\u4dbf")
            or ("\u3040" <= ch <= "\u30ff")
            or ("\uac00" <= ch <= "\ud7af")
            or ("\uff00" <= ch <= "\uffef")
        ):
            starts.append(i)
            toks.append(1)
            i += 1
        elif ch.isalnum():
            j = i
            while j < n and text[j].isalnum():
                j += 1
            starts.append(i)
            toks.append(max(1, (j - i + 3) // 4))
            i = j
        else:
            starts.append(i)
            toks.append(1)
            i += 1
    total = sum(toks)
    if total <= chunk_tokens:
        return [text]
    pref = [0]
    for t in toks:
        pref.append(pref[-1] + t)

    def char_at_token(c: int) -> int:
        if c <= 0:
            return 0
        if c >= total:
            return n
        lo, hi = 0, len(pref) - 1
        while lo < hi:
            mid = (lo + hi) // 2
            if pref[mid] >= c:
                hi = mid
            else:
                lo = mid + 1
        return starts[min(lo, len(starts) - 1)]

    chunks: list = []
    step = max(1, chunk_tokens - overlap_tokens)
    start_t = 0
    while start_t < total:
        end_t = start_t + chunk_tokens
        if end_t > total:
            # 结尾倒推：最后一块 = 末尾往前 chunk_tokens
            start_t = total - chunk_tokens
            if start_t < 0:
                start_t = 0
            end_t = total
        piece = text[char_at_token(start_t):char_at_token(end_t)]
        if piece and (not chunks or piece != chunks[-1]):
            chunks.append(piece)
        if end_t >= total:
            break
        start_t = max(0, end_t - overlap_tokens)
    return chunks


def _normalize(v: list) -> list:
    norm = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / norm for x in v]


def _dot(a: list, b: list) -> float:
    return sum(x * y for x, y in zip(a, b))


def _pack_vec(v: list) -> bytes:
    return struct.pack("<%df" % len(v), *v)


def _unpack_vec(b: bytes) -> list:
    return list(struct.unpack("<%df" % (len(b) // 4), b))


# 应用层并发上限：同时最多 RAG_MAX_INFLIGHT 个嵌入请求在飞（满了跳过，不排队）。
_rag_inflight = 0
_rag_inflight_lock = asyncio.Lock()


def _is_openai_compat_embed_url(url: str) -> bool:
    """判断嵌入接口是否为 OpenAI 兼容格式（Jina 等）vs HF 原生格式。"""
    return ("jina.ai" in url) or ("/v1/embeddings" in url) or ("openai" in url.lower())


async def _embed_texts(texts: list) -> Optional[list]:
    """调用嵌入 API（当前 Jina v3，可切回 HF bge-m3）。返回归一化向量列表；失败返回 None。
    自动适配两种格式：
      - HF 原生：POST {"inputs":[...]} → 返回 [[vec], ...]
      - OpenAI 兼容（Jina）：POST {"model":..., "input":[...]} → 返回 {"data":[{embedding:...}, ...]}
    应用层并发上限（RAG_MAX_INFLIGHT）：满了直接跳过（返回 None），不排队等待。"""
    global _rag_inflight  # 函数内做了 +=1/-=1，需声明为模块级，避免被当作局部变量
    if not _rag_enabled():
        return None
    if not texts:
        return []
    async with _rag_inflight_lock:
        if _rag_inflight >= RAG_MAX_INFLIGHT:
            logger.info("RAG 嵌入并发已满(%d)，跳过本次", RAG_MAX_INFLIGHT)
            return None
        _rag_inflight += 1
    try:
        if _is_openai_compat_embed_url(HF_EMBED_URL):
            payload = {"model": EMBED_MODEL, "input": texts}
        else:
            payload = {"inputs": texts, "options": {"wait_for_model": True}}
        resp = await hf_http_client.post(
            HF_EMBED_URL,
            json=payload,
            headers={"Authorization": f"Bearer {HF_TOKEN}"},
            timeout=HF_EMBED_TIMEOUT,
        )
        if resp.status_code != 200:
            logger.warning(
                "RAG embed HTTP %d: %s", resp.status_code, (await resp.aread())[:300]
            )
            return None
        data = resp.json()
        vecs = None
        if isinstance(data, dict) and isinstance(data.get("data"), list):
            vecs = [d.get("embedding") for d in data["data"]]  # OpenAI/Jina 格式
        elif isinstance(data, list):
            vecs = data  # HF 原生格式
        if vecs is None or len(vecs) != len(texts):
            logger.warning("RAG embed 返回结构异常: %s", type(data))
            return None
        out = []
        for v in vecs:
            if not isinstance(v, list) or not v:
                return None
            out.append(_normalize(v))
        return out
    except httpx.TimeoutException:
        logger.warning("RAG embed 超时")
        return None
    except httpx.RequestError as e:
        logger.warning("RAG embed 请求失败: %s", e)
        return None
    except Exception as e:
        logger.warning("RAG embed 异常: %s", e, exc_info=True)
        return None
    finally:
        async with _rag_inflight_lock:
            _rag_inflight -= 1


def _register_character_names(user_id: str, conn, segment_seq: int, names: list) -> None:
    """人名登记：每个名字只保留"最新记忆"（重名时新章节覆盖旧条目，不区分脚本）。"""
    now = int(time.time())
    for name in names:
        conn.execute(
            """INSERT INTO story_character_lookup (user_id, name, segment_seq, updated_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(user_id, name) DO UPDATE SET
                 segment_seq=excluded.segment_seq, updated_at=excluded.updated_at""",
            (user_id, name, segment_seq, now),
        )


async def _rag_build_job(
    user_id: str, segment_seq: int, script_id: str, content: str, names=None, key=None
) -> bool:
    """后台 RAG 构建：原文切块 → 嵌入 → 写 story_chunk_vectors；人名登记最新记忆。
    names=None（触发轮补建）时以已入库的 story_chapter_distill.characters 为准，不覆盖。
    写入前反查源段落是否存在（防"删了又写回"）。返回 True=嵌入成功/无需嵌入；False=嵌入失败。"""
    emb_ok = True
    try:
        chunks = _chunk_text(content)
        vecs: list = []
        if chunks and _rag_enabled():
            got = await _embed_texts(chunks)
            if got is None:
                got = []
                emb_ok = False  # HF 不可用/并发满/超时：跳过向量，留给补建
            vecs = got
        conn = _db()
        try:
            src = conn.execute(
                "SELECT 1 FROM story_segments WHERE user_id=? AND seq=?",
                (user_id, segment_seq),
            ).fetchone()
            if not src:
                return False  # 源段落已删除/重写，丢弃本次构建
            if names is None:
                existing = conn.execute(
                    "SELECT characters FROM story_chapter_distill WHERE user_id=? AND segment_seq=?",
                    (user_id, segment_seq),
                ).fetchone()
                names = []
                if existing:
                    try:
                        names = json.loads(existing["characters"] or "[]")
                    except Exception:
                        names = []
            now = int(time.time())
            conn.execute(
                """INSERT OR REPLACE INTO story_chapter_distill
                     (user_id, segment_seq, current_script_id, characters, created_at)
                   VALUES (?, ?, ?, ?, ?)""",
                (user_id, segment_seq, script_id, json.dumps(names, ensure_ascii=False), now),
            )
            for offset, (piece, vec) in enumerate(zip(chunks, vecs)):
                chunk_id = f"{segment_seq}-{offset}"
                conn.execute(
                    """INSERT OR REPLACE INTO story_chunk_vectors
                         (user_id, chunk_id, segment_seq, current_script_id,
                          text, embedding, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (user_id, chunk_id, segment_seq, script_id, piece, _pack_vec(vec), now),
                )
            _register_character_names(user_id, conn, segment_seq, names)
            conn.commit()
        finally:
            conn.close()
    except Exception as e:
        logger.warning("RAG build 异常: %s", e, exc_info=True)
        emb_ok = False
    finally:
        if key is not None:
            _rag_building.discard(key)
    return emb_ok


def _schedule_rag_build(user_id: str, segment_seq: int, script_id: str, content: str, names=None) -> None:
    key = (user_id, segment_seq)
    if key in _rag_building:
        return
    try:
        _rag_building.add(key)
        asyncio.get_running_loop().create_task(
            _rag_build_job(user_id, segment_seq, script_id, content, names, key)
        )
    except RuntimeError:
        _rag_building.discard(key)


def _script_id_of(current_script_id: Any) -> str:
    return str(current_script_id or "").split("-")[0]


async def _retrieve_rag(user_id: str, query: str, current_script_id: Any) -> Optional[str]:
    """双通道检索：名字精确子串 + 语义 cosine（排除当前正在生成的脚本）。
    命中 → 返回整个章节正文；否则 None。语义优先；多章≥阈值取最高分，并列随机；最多一章。"""
    if not query or not query.strip() or not _rag_enabled():
        return None
    cur_sid = _script_id_of(current_script_id)
    conn = _db()
    try:
        # ---- 语义通道 ----
        sem_seq: Optional[int] = None
        q_vec_raw = await _embed_texts([query.strip()])
        if q_vec_raw:
            q_vec = q_vec_raw[0]
            rows = conn.execute(
                "SELECT segment_seq, current_script_id, embedding FROM story_chunk_vectors WHERE user_id=?",
                (user_id,),
            ).fetchall()
            scored = []
            for r in rows:
                if cur_sid and _script_id_of(r["current_script_id"]) == cur_sid:
                    continue
                sim = _dot(q_vec, _unpack_vec(r["embedding"]))
                scored.append((sim, r["segment_seq"]))
            scored.sort(key=lambda x: (-x[0], x[1]))
            above = [x for x in scored if x[0] >= RAG_SEMANTIC_THRESHOLD]
            if above:
                top_sim = above[0][0]
                ties = [x for x in above if abs(x[0] - top_sim) < 1e-9]
                sem_seq = random.choice(ties)[1]

        # ---- 名字通道（精确子串，100% 命中才引用；不做模糊/拼音）----
        name_seq: Optional[int] = None
        q = query.strip()
        names = conn.execute(
            "SELECT name, segment_seq FROM story_character_lookup WHERE user_id=?",
            (user_id,),
        ).fetchall()
        hits = []
        for r in names:
            nm = (r["name"] or "").strip()
            if len(nm) >= 2 and nm in q:
                hits.append(r["segment_seq"])
        if hits:
            cand = []
            for seq in set(hits):
                row = conn.execute(
                    "SELECT current_script_id FROM story_segments WHERE user_id=? AND seq=?",
                    (user_id, seq),
                ).fetchone()
                if row is None:
                    continue
                if cur_sid and _script_id_of(row["current_script_id"]) == cur_sid:
                    continue
                cand.append(seq)
            if cand:
                name_seq = max(cand)  # 最新记忆

        # ---- 合并：语义优先；双命中不同章只传语义章 ----
        pick_seq = sem_seq if sem_seq is not None else name_seq
        if pick_seq is None:
            return None
        row = conn.execute(
            "SELECT content FROM story_segments WHERE user_id=? AND seq=?",
            (user_id, pick_seq),
        ).fetchone()
        return row["content"] if row else None
    finally:
        conn.close()


def _purge_rag_for_user(user_id: str, conn, seqs=None, min_seq=None) -> None:
    """同一事务内删除该用户 RAG 数据（distill + chunk_vectors，按 seq），
    并重建名字反查表（只保留仍存在于 distill 的名字、指向最新 seq）。
    seqs=None 且 min_seq=None → 全删；min_seq → 删 segment_seq > min_seq。"""
    if seqs is None and min_seq is None:
        conn.execute("DELETE FROM story_chapter_distill WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM story_chunk_vectors WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM story_character_lookup WHERE user_id=?", (user_id,))
        return
    if seqs is not None:
        if not seqs:
            return
        marks = ",".join("?" * len(seqs))
        conn.execute(
            f"DELETE FROM story_chapter_distill WHERE user_id=? AND segment_seq IN ({marks})",
            [user_id, *seqs],
        )
        conn.execute(
            f"DELETE FROM story_chunk_vectors WHERE user_id=? AND segment_seq IN ({marks})",
            [user_id, *seqs],
        )
    else:
        conn.execute(
            "DELETE FROM story_chapter_distill WHERE user_id=? AND segment_seq > ?",
            (user_id, min_seq),
        )
        conn.execute(
            "DELETE FROM story_chunk_vectors WHERE user_id=? AND segment_seq > ?",
            (user_id, min_seq),
        )
    # 重建名字反查：只保留仍存在于 distill 的名字，且指向最新 seq
    conn.execute("DELETE FROM story_character_lookup WHERE user_id=?", (user_id,))
    rows = conn.execute(
        "SELECT segment_seq, characters FROM story_chapter_distill WHERE user_id=?",
        (user_id,),
    ).fetchall()
    latest: dict = {}
    for r in rows:
        try:
            names = json.loads(r["characters"] or "[]")
        except Exception:
            names = []
        for nm in names:
            if isinstance(nm, str):
                nm = nm.strip()
                if len(nm) >= 2 and (nm not in latest or r["segment_seq"] > latest[nm]):
                    latest[nm] = r["segment_seq"]
    now = int(time.time())
    for nm, seq in latest.items():
        conn.execute(
            """INSERT INTO story_character_lookup (user_id, name, segment_seq, updated_at)
               VALUES (?, ?, ?, ?)""",
            (user_id, nm, seq, now),
        )


# 名字通道靠人名登记（掉线时也会登记），这里只补语义向量；人名以 distill 已有为准。
# 触发轮补建：非零且 seq 被 5 整除时，先取当前章节向量，成功后再顺序补缺失（一条接一条，最多 5 条）。
_rag_building: set = set()  # 正在构建的 (user_id, seq)，避免并发重复


def _is_rag_trigger_seq(seq: int) -> bool:
    return RAG_BACKFILL_EVERY > 0 and seq >= RAG_BACKFILL_EVERY and seq % RAG_BACKFILL_EVERY == 0


async def _rag_trigger_build_task(
    user_id: str, current_seq: int, script_id: str, content: str, names, key
) -> None:
    """触发轮：先构建当前章节向量（await）；成功后再检测该用户缺向量的章节，
    按"补一条成功再续一条"的顺序补，最多 RAG_BACKFILL_BATCH(5) 条；任一条失败即停。
    全程在同一后台任务里串行 → 补建路径同一时刻最多 1 个嵌入请求在飞。"""
    try:
        ok = await _rag_build_job(user_id, current_seq, script_id, content, names, key)
        if not ok:
            logger.warning("RAG 触发轮：当前章节向量获取失败，跳过历史补建（HF 可能不健康）")
            return
        conn = _db()
        try:
            rows = conn.execute(
                """SELECT segment_seq, content, current_script_id
                   FROM story_segments
                   WHERE user_id=?
                     AND content IS NOT NULL AND trim(content) != ''
                     AND segment_seq NOT IN (
                         SELECT segment_seq FROM story_chunk_vectors WHERE user_id=?
                     )
                   ORDER BY segment_seq DESC
                   LIMIT ?""",
                (user_id, user_id, RAG_BACKFILL_BATCH),
            ).fetchall()
        finally:
            conn.close()
        for r in rows:
            bkey = (user_id, r["segment_seq"])
            if bkey in _rag_building:
                continue
            _rag_building.add(bkey)
            try:
                bok = await _rag_build_job(
                    user_id, r["segment_seq"], r["current_script_id"] or "", r["content"], None, bkey
                )
            except Exception:
                bok = False
            if not bok:
                logger.warning("RAG 补建失败，停止本轮顺序补建（HF 可能不健康）")
                break
    except Exception as e:
        logger.warning("RAG 触发轮异常: %s", e, exc_info=True)
    finally:
        _rag_building.discard(key)


def _schedule_rag_trigger_build(user_id: str, segment_seq: int, script_id: str, content: str, names) -> None:
    """触发轮入口：seq 非零且被 5 整除时，当前章节构建 + 顺序补建合并在一个后台任务里。"""
    if not _is_rag_trigger_seq(segment_seq):
        return
    if not _rag_enabled():
        return
    key = (user_id, segment_seq)
    if key in _rag_building:
        return
    try:
        _rag_building.add(key)
        asyncio.get_running_loop().create_task(
            _rag_trigger_build_task(user_id, segment_seq, script_id, content, names, key)
        )
    except RuntimeError:
        _rag_building.discard(key)


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
                # RAG 同步删除：截断 seq > rewrite_from 的向量/人名/提纯
                _purge_rag_for_user(user_id, conn, min_seq=data.rewrite_from)
                conn.commit()
            finally:
                conn.close()
        except Exception:
            logger.warning("时间树重写截断失败", exc_info=True)

    # 设定解析：第一轮生成用 App 随请求上传的设定（随段落库），续写读最新一段快照
    settings = _resolve_story_settings(user_id, data)

    # 以数据库是否已有段落决定续写/全新；空库段落数为 0
    user_input_counter = _get_story_count(user_id)
    # 当前案件正文原文（corrent_case_all_content 取值来源；见 _get_current_case_story）
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

    # pre_case_meta（案件核心 / 脚本章节）统一在 _stream 内解析：
    # - 首段：案件核心是阻塞式 Dify 调用，必须放在流内配合 15s 心跳，让 SSE 响应头
    #   立刻返回、客户端马上开始 30s 滚动计时，避免慢 Dify 在"响应头阶段"就被误判超时；
    # - 续写轮：读上一段脚本序号（"脚本id-章节"），章节 +1（纯 DB 读，不阻塞）。
    pre_case_meta = None

    # Dify 开始节点 required 变量必须非空，空值用占位符兜底
    def _fill(v: str) -> str:
        return v.strip() if v and v.strip() else "未设定"

    headers = {
        "Authorization": f"Bearer {STORY_DIFY_API_KEY}",
        "Content-Type": "application/json",
    }

    # 客户端断联标记（后台生成任务仍会继续执行，仅用于跳过需要用户交互的环节，
    # 如"生成前确认"等待——客户端已断开就不会再点确认了）。
    _conn_state = {"client_gone": False}

    async def _generate_sse():
        nonlocal pre_case_meta, user_input_counter
        try:
            # ---- 首段：案件核心在流内生成（SSE 响应头立刻返回）----
            # 等待 Dify 期间每 15s 推一次心跳重置客户端 30s 滚动计时；
            # 一旦真实超时（Dify 30s 无返回）或失败，按统一规则直接关闭当前流，
            # 客户端 30s 无数据自然弹出"网络疑似超时，请重启重试"。
            if user_input_counter == 0:
                yield _sse({"event": "heartbeat", "message": "正在生成案件核心"})
                case_task = asyncio.create_task(_generate_case_meta(1))
                while True:
                    done, _ = await asyncio.wait({case_task}, timeout=15)
                    if case_task in done:
                        try:
                            pre_case_meta = case_task.result()
                        except httpx.TimeoutException:
                            logger.warning("STREAM 首段案件核心 Dify 超时（30 秒），关闭流")
                            return
                        except CaseCoreError as ce:
                            logger.warning("STREAM 首段案件核心生成失败，关闭流: %s", ce)
                            yield _sse({"event": "error", "message": "案件核心生成失败，已终止本次生成，请稍后重试"})
                            return
                        break
                    yield _sse({"event": "heartbeat", "message": "正在生成案件核心"})
                settings["case_core"] = pre_case_meta.get("case_core") or ""
            else:
                # 续写轮：读上一段脚本序号（"脚本id-章节"），章节 +1
                pre_case_meta = _load_next_script_chapter(user_id, user_input_counter)
                if pre_case_meta is not None:
                    settings["case_core"] = pre_case_meta.get("case_core") or ""

            # ---- RAG 检索：用户行动指引对【之前脚本】做双通道匹配，命中注入整章 ----
            # 排除当前正在生成的脚本（当前脚本的 LLM 已能拿到自身信息，不重复喂）。
            # 检索加了 RAG_RETRIEVE_TIMEOUT(3s) 兜底超时：拿不到就无感降级、放弃本轮 RAG。
            rag_context = ""
            if _rag_enabled() and (data.user_input or "").strip():
                try:
                    rag_context = (
                        await asyncio.wait_for(
                            _retrieve_rag(
                                user_id,
                                data.user_input,
                                (pre_case_meta or {}).get("script_id") or "",
                            ),
                            timeout=RAG_RETRIEVE_TIMEOUT,
                        )
                        or ""
                    )
                except asyncio.TimeoutError:
                    logger.warning("RAG retrieve 超时（%ss），跳过注入", RAG_RETRIEVE_TIMEOUT)
                    rag_context = ""
                except Exception as rag_e:
                    logger.warning("RAG retrieve 异常，跳过注入: %s", rag_e)

            # Dify 开始节点 required 变量必须非空，空值用占位符兜底（debug 预览用 payload）
            dify_payload = {
                "inputs": {
                    "location": _fill(settings.get("location") or ""),
                    "era": _fill(settings.get("era") or ""),
                    "player_name": _fill(settings.get("player_name") or ""),
                    "language": _dify_language_name(settings.get("language") or ""),
                    "player_traits": _fill(settings.get("player_traits") or ""),
                    "seq": user_input_counter,
                    "corrent_case_all_content": corrent_case_all_content,
                    "user_choice": data.user_input or "",
                    "case_core": settings.get("case_core") or "",
                    "chapter_script": (pre_case_meta or {}).get("chapter_text") or "",
                    # RAG：之前脚本的整章记忆（无命中为空串）
                    "rag_context": rag_context or "",
                    # 脚本当前章节的推荐行动（choice_2/choice_3），供 LLM 在正文中呼应
                    "script_choice_2": (pre_case_meta or {}).get("choice_2") or "",
                    "script_choice_3": (pre_case_meta or {}).get("choice_3") or "",
                },
                "response_mode": "streaming",
                "user": user_id,
            }

            # 【调试】生成前确认：调 Dify 之前先把 payload 发回 App 弹窗，
            # 等 App 用户点击确认后（POST /api/generate-story/confirm）才真正调 Dify。
            # 等待期间每 15s 发一个 debug_waiting 心跳，重置客户端 30s 滚动计时。
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
                        # 客户端已断联：不会再点确认，跳过等待直接继续生成
                        # （服务器照常执行自己的操作并落库）。
                        if _conn_state["client_gone"]:
                            logger.info("STREAM 客户端已断联，跳过 App 确认直接继续生成")
                            break
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

            # 当前累计的案件正文（每段落库后更新，作为下一段 Dify 的续写上下文）
            current_case_content = corrent_case_all_content
            # 连续换脚本的护栏：避免脚本全无 choice2/3 时无限循环
            switch_guard = 0
            # 换脚本场景的"暂存段"：脚本耗尽生成的段先不落库，待下一段成功后再一起原子落库
            pending_segments: list = []

            # 段落生成循环：脚本当前章节 choice2/3 为空（脚本耗尽/无选择）时，
            # 先落库本段、更新 completed_script_ids、选出"最少使用"的新脚本，
            # 再像首段一样生成下一段……直到有可用选择才发送 done。
            while True:
                seg_payload = {
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
                        # 续写上下文：当前案件正文原文
                        "corrent_case_all_content": current_case_content,
                        "user_choice": data.user_input or "",
                        # 当前案件
                        "case_core": settings.get("case_core") or "",
                        # 当前章节脚本正文（来自与 case_core_prompt 同一脚本条目；续写轮无新选取则为空）
                        "chapter_script": (pre_case_meta or {}).get("chapter_text") or "",
                        # RAG：之前脚本的整章记忆（无命中为空串）
                        "rag_context": rag_context or "",
                        # 脚本当前章节的推荐行动（choice_2/choice_3），供 LLM 在正文中呼应
                        "script_choice_2": (pre_case_meta or {}).get("choice_2") or "",
                        "script_choice_3": (pre_case_meta or {}).get("choice_3") or "",
                    },
                    "response_mode": "streaming",
                    "user": user_id,
                }

                async with async_http_client.stream(
                    "POST", STORY_DIFY_API_URL, json=seg_payload, headers=headers,
                    timeout=STORY_DIFY_STREAM_TIMEOUT,
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
                    audit_aborted = False   # 本次审核是否以 abort/error/超时终止（调用方据此 return）
                    # 审核窗口基准偏移：正常为 0；违规修正覆盖违规段后重置为修正点，
                    # 之后窗口从该点重新编号（保持 400/50 增量审核不因变长改写而错位）。
                    _audit_base = 0
                    outputs = {}
                    think_state = {"in_think": False, "hold": ""}  # <think> 块剥离状态（跨 chunk）
                    meta = _extract_story_meta({}, settings.get("language"))  # 后续变量（choice_1/2/3/music_style）；workflow_finished 时更新，失败用保底默认

                    async def _audit_pipeline(text_arg: str, final: bool, final_outputs: Optional[dict] = None):
                        """增量审核管道（async generator）：把当前累计正文按审核窗口逐批送审，
                        逐个 yield 待发送的 SSE 事件（chunk/reveal）。

                        - 每窗口审核是阻塞式 Dify 调用（最长 AUDIT_DIFY_TIMEOUT 秒），等待期间
                          每 15s yield 一个 heartbeat，重置客户端 30s 滚动计时；
                        - REJECT（违规）→ 尝试"违规修正"工作流（最多 REVISE_MAX_ATTEMPTS 轮）：
                          把违规文本 + guardrail JSON 发给修正工作流，收到改写文本后覆盖
                          text_arg/full_text 中的违规段、让客户端回滚到违规窗口起点（truncate
                          事件），再按老逻辑整段重送审核；通过 → 整段 reveal 继续打字；
                          修正失败 / 未配置 / 超限 → 回退 yield abort（客户端弹窗"重新输入"）；
                        - UNAVAILABLE（不可用）→ yield error；TIMEOUT（Dify 审核 30s 无返回）→
                          不 yield 任何事件直接结束（关闭流），客户端 30s 无数据自然弹
                          "网络疑似超时，请重启重试"；
                        - 发生任一终止时置 audit_aborted=True，调用方据此 return 关闭整段流。
                        """
                        nonlocal audit_no, displayed_len, sent_first, audit_aborted, _audit_base

                        async def _handle_reject(
                            audit_text: str,
                            verdict,
                            win_start: int,
                            win_end: int,
                        ):
                            """违规窗口自动修正（async generator）：调修正 workflow（最多
                            REVISE_MAX_ATTEMPTS 轮）覆盖违规段后整段重审。
                            重审通过 → 整段发送（chunk/reveal），audit_aborted 保持 False；
                            修正失败/未配置/超限 → 已 yield abort 并置 audit_aborted=True。
                            （async generator 不能 return 值，用 audit_aborted 作成功/失败信号。）
                            """
                            nonlocal text_arg, full_text, displayed_len, audit_no, sent_first, audit_aborted, _audit_base
                            attempts = 0
                            cur_text = audit_text
                            cur_verdict = verdict
                            while True:
                                attempts += 1
                                if attempts > REVISE_MAX_ATTEMPTS:
                                    audit_aborted = True
                                    yield _moderation_failure_sse(
                                        ModerationOutcome.REJECT, cur_text
                                    )
                                    return
                                # 等修正工作流（阻塞式调用，等待期间每 15s 心跳，避免客户端误判断网）
                                yield {"event": "heartbeat", "message": "正在修正违规内容"}
                                revise_task = asyncio.create_task(
                                    _revise_story(
                                        cur_text,
                                        cur_verdict,
                                        _dify_language_name(
                                            settings.get("language") or ""
                                        ),
                                    )
                                )
                                while True:
                                    done, _ = await asyncio.wait({revise_task}, timeout=15)
                                    if revise_task in done:
                                        revised = revise_task.result()
                                        break
                                    yield {"event": "heartbeat", "message": "正在修正违规内容"}
                                if not revised or not revised.strip():
                                    # 修正失败 / 未配置修正工作流：回退现有 abort 弹窗
                                    audit_aborted = True
                                    yield _moderation_failure_sse(
                                        ModerationOutcome.REJECT, cur_text
                                    )
                                    return
                                # 覆盖违规段（text_arg 与 full_text 同步更新，后续 text_chunk 沿用修正后正文）
                                text_arg = (
                                    text_arg[:win_start]
                                    + revised
                                    + text_arg[win_end:]
                                )
                                full_text = text_arg
                                # 让客户端把当前段回滚到违规窗口起点，避免重叠区重复
                                yield {"event": "truncate", "keep": win_start}
                                # 重审修正后的剩余部分（老逻辑：送审核 Dify）
                                remainder = text_arg[win_start:]
                                audit_task = asyncio.create_task(
                                    _moderate_story(remainder)
                                )
                                while True:
                                    done, _ = await asyncio.wait({audit_task}, timeout=15)
                                    if audit_task in done:
                                        mr2, v2 = audit_task.result()
                                        break
                                    yield {"event": "heartbeat", "message": "内容审核中"}
                                if mr2 is ModerationOutcome.TIMEOUT:
                                    audit_aborted = True
                                    return
                                if mr2 is ModerationOutcome.REJECT:
                                    # 重审仍违规：再修正一轮
                                    cur_text = remainder
                                    cur_verdict = v2
                                    continue
                                if mr2 is not ModerationOutcome.PASS:
                                    # 重审不可用：回退（按审核链路问题处理）
                                    audit_aborted = True
                                    yield _moderation_failure_sse(
                                        ModerationOutcome.UNAVAILABLE, remainder
                                    )
                                    return
                                # 重审通过：整段发送（首段 chunk / 续段 reveal）
                                if win_start > 0:
                                    yield {
                                        "event": "reveal",
                                        "text": remainder,
                                        "outputs": {},
                                    }
                                else:
                                    yield {"event": "chunk", "text": remainder}
                                displayed_len = len(text_arg)
                                sent_first = True
                                # 已整段发送完毕：重置增量窗口基准到当前末尾，后续新文本继续增量审核
                                _audit_base = len(text_arg)
                                audit_no = 1
                                return

                        audit_aborted = False
                        while len(text_arg) >= _audit_base + STORY_AUDIT_STEP * audit_no:
                            k = audit_no
                            win_end = _audit_base + STORY_AUDIT_STEP * k
                            if len(text_arg) < win_end:
                                break
                            win_start = max(
                                _audit_base,
                                _audit_base
                                + STORY_AUDIT_STEP * (k - 1)
                                - STORY_AUDIT_OVERLAP,
                            )
                            audit_text = text_arg[win_start:win_end]
                            audit_task = asyncio.create_task(_moderate_story(audit_text))
                            while True:
                                done, _ = await asyncio.wait({audit_task}, timeout=15)
                                if audit_task in done:
                                    mr, verdict = audit_task.result()
                                    break
                                yield {"event": "heartbeat", "message": "内容审核中"}
                            if mr is ModerationOutcome.TIMEOUT:
                                logger.warning("STREAM audit Dify 超时（30 秒），关闭流")
                                audit_aborted = True
                                return
                            if mr is ModerationOutcome.REJECT:
                                # 违规：自动修正（覆盖违规段 → 整段重审 → 继续打字）
                                async for ev in _handle_reject(
                                    audit_text, verdict, win_start, win_end
                                ):
                                    yield ev
                                if audit_aborted:
                                    return
                                return  # 修正成功：已整段发送并重置窗口，结束本次调用
                            fail = _moderation_failure_sse(mr, audit_text)
                            if fail is not None:
                                audit_aborted = True
                                yield fail
                                return
                            new_text = text_arg[displayed_len:win_end]
                            if not sent_first:
                                yield {"event": "chunk", "text": new_text}
                            else:
                                yield {"event": "reveal", "text": new_text, "outputs": {}}
                            logger.warning(
                                "STREAM audit k=%d OK win=[%d,%d) disp=[%d,%d)",
                                k, win_start, win_end, displayed_len, win_end,
                            )
                            displayed_len = win_end
                            audit_no += 1
                            sent_first = True
                        if final and displayed_len < len(text_arg):
                            win_start = max(
                                _audit_base,
                                _audit_base
                                + STORY_AUDIT_STEP * (audit_no - 1)
                                - STORY_AUDIT_OVERLAP,
                            )
                            audit_text = text_arg[win_start:]
                            audit_task = asyncio.create_task(_moderate_story(audit_text))
                            while True:
                                done, _ = await asyncio.wait({audit_task}, timeout=15)
                                if audit_task in done:
                                    mr, verdict = audit_task.result()
                                    break
                                yield {"event": "heartbeat", "message": "内容审核中"}
                            if mr is ModerationOutcome.TIMEOUT:
                                logger.warning("STREAM audit tail Dify 超时（30 秒），关闭流")
                                audit_aborted = True
                                return
                            if mr is ModerationOutcome.REJECT:
                                async for ev in _handle_reject(
                                    audit_text, verdict, win_start, len(text_arg)
                                ):
                                    yield ev
                                if audit_aborted:
                                    return
                                return  # 修正成功：已整段发送
                            fail = _moderation_failure_sse(mr, audit_text)
                            if fail is not None:
                                audit_aborted = True
                                yield fail
                                return
                            new_text = text_arg[displayed_len:]
                            if not sent_first:
                                yield {"event": "chunk", "text": new_text}
                            else:
                                ev: dict = {"event": "reveal", "text": new_text}
                                if final_outputs:
                                    ev["outputs"] = final_outputs
                                yield ev
                            logger.warning(
                                "STREAM audit tail OK win_start=%d disp=[%d,%d)",
                                win_start, displayed_len, len(text_arg),
                            )
                            displayed_len = len(text_arg)
                            sent_first = True

                    # 本段是否已完整收到 workflow_finished（用于区分"换脚本继续"与"流意外结束"）
                    segment_ended = False
                    # Dify 流式读取配 15s 心跳看门狗：Dify 长时间不推 text_chunk
                    # （慢生成/思考停顿，实测可达 30~50s）时给客户端发心跳重置其 30s
                    # 滚动计时，避免慢 Dify 被误判卡死。read 在后台任务里继续跑，httpx
                    # 30s read 超时仍会触发（真实挂起时统一关闭流，不无限发心跳）。
                    async def _dify_lines_with_heartbeat():
                        _it = resp.aiter_lines().__aiter__()
                        while True:
                            read_task = asyncio.create_task(_it.__anext__())
                            try:
                                while True:
                                    done, _ = await asyncio.wait({read_task}, timeout=15)
                                    if read_task in done:
                                        try:
                                            line = read_task.result()
                                        except StopAsyncIteration:
                                            return
                                        yield line
                                        break
                                    yield None  # 心跳标记（15s 无新行）
                            finally:
                                if not read_task.done():
                                    read_task.cancel()

                    async for line in _dify_lines_with_heartbeat():
                        if line is None:
                            yield _sse({"event": "heartbeat", "message": "正在生成中"})
                            continue
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
                                # 增量审核（async generator，等待 Dify 期间自带 15s 心跳）
                                async for ev in _audit_pipeline(full_text, final=False):
                                    yield _sse(ev)
                                if audit_aborted:
                                    return

                        elif etype == "workflow_finished":
                            outputs = edata.get("outputs") or {}
                            meta = _extract_story_meta(
                                outputs, settings.get("language")
                            )
                            # 输入框 2/3 的显示值：Dify 生成工作流 LLM② 的 action_a/action_b 优先，
                            # 取不到再用脚本当前章节的 choice_2/3 保底。
                            # 注意：脚本结束判定（choices_available）仍【只看脚本 choice_2/3】
                            # （不看 action_a/b）——否则 Dify 恒输出 action 会让"老脚本结束→
                            # 换新脚本继续"永不触发。
                            script_c2 = (pre_case_meta or {}).get("choice_2") or ""
                            script_c3 = (pre_case_meta or {}).get("choice_3") or ""
                            choices_available = bool(script_c2 or script_c3)
                            meta["choice_2"] = (meta.get("action_a") or "") or script_c2
                            meta["choice_3"] = (meta.get("action_b") or "") or script_c3
                            # 权威全文：只用"流式累计正文"（text_chunk 已按来源过滤，只含
                            # 小说节点文本）。不再信任 Dify 结束节点的 outputs["text"]——
                            # 它可能被 Dify 画布拼入 LLM② 的 music_style
                            # （导致正文尾部混入音乐，并落库污染）。
                            out_text = _clean_story_text(full_text)
                            if not out_text or not out_text.strip():
                                yield _sse({"event": "error", "code": "empty_output", "message": "服务器未返回有效的小说正文，请检查额度是否已用尽，或稍后重试"})
                                return
                            final_segment = out_text
                            # 增量送审（含末尾兜底），通过后把剩余正文 reveal 给 App。
                            async for ev in _audit_pipeline(
                                out_text,
                                final=True,
                                final_outputs={
                                    **outputs,
                                    **meta,
                                },
                            ):
                                yield _sse(ev)
                            if audit_aborted:
                                return
                            # choices_available 已在上面按脚本 choice_2/3 计算（脚本结束判定的权威信号）
                            # 计算本段应写入的 completed_script_ids：
                            # - 存在暂存段（换脚本场景）：沿用最后一条暂存段的累计表
                            #   （已含对上一脚本的 +1），保证成对记录使用同一累计快照；
                            # - 否则：脚本耗尽时对当前脚本 +1，正常轮沿用当前累计表。
                            if pending_segments:
                                completed_ids = pending_segments[-1][4]
                            else:
                                completed_ids = _next_completed_script_ids(
                                    user_id, pre_case_meta, choices_available
                                )
                            fmeta = dict(meta)
                            # 本段数据打包（暂存或落库用）
                            seg_payload = (
                                final_segment,
                                dict(settings),
                                dict(meta),
                                dict(pre_case_meta) if pre_case_meta is not None else None,
                                completed_ids,
                            )
                            segment_ended = True
                            if choices_available:
                                # 有可用选择：这是本请求最后一段。
                                # - 若之前有暂存段（换脚本场景）：多条成对原子落库；
                                # - 否则：普通单段落库。
                                if _has_inference_outputs(outputs):
                                    try:
                                        if pending_segments:
                                            pending_segments.append(seg_payload)
                                            _persist_story_segments_atomic(user_id, pending_segments)
                                            logger.warning("STREAM persisted atomic ok segments=%d", len(pending_segments))
                                        else:
                                            await _persist_story_segment(
                                                user_id, final_segment, settings, fmeta,
                                                case_meta=pre_case_meta,
                                                completed_script_ids=completed_ids,
                                            )
                                            logger.warning("STREAM persisted ok final_len=%d", len(final_segment))
                                    except Exception as pe:
                                        logger.warning("STREAM persist EXCEPTION: %s", pe, exc_info=True)
                                else:
                                    logger.warning("STREAM skip persist: 氛围（music_style）未到位 final_len=%d", len(final_segment))
                                logger.warning("STREAM yielding done")
                                yield _sse({"event": "done", "outputs": {**outputs, **fmeta}})
                                return
                            # 脚本耗尽：本段先【暂存】不落库，切换到"最少使用"的新脚本再生成一段，
                            # 待下一段成功后再与下一段一起原子落库（保证成对存在/成对不存在）。
                            pending_segments.append(seg_payload)
                            switch_guard += 1
                            if switch_guard >= 5:
                                logger.warning("STREAM 连续换脚本达到上限，直接 done（暂存段不落库）")
                                yield _sse({"event": "done", "outputs": {**outputs, **fmeta}})
                                return
                            logger.warning("STREAM 脚本 choice 为空，切换脚本继续生成")
                            current_case_content = _get_current_case_story(user_id, user_input_counter + 1)
                            user_input_counter += 1
                            tally = _parse_script_tally(completed_ids)
                            # 排除刚运行完的脚本，避免同一脚本连续运行两次
                            exclude_sid = None
                            if pre_case_meta is not None and pre_case_meta.get("script_id"):
                                exclude_sid = int(pre_case_meta.get("script_id"))
                            new_script_id = _pick_least_used_script(
                                tally, exclude_script_id=exclude_sid
                            )
                            if new_script_id is None:
                                # 脚本库为空：无法继续，直接发送 done（无可用选择，暂存段不落库）
                                yield _sse({"event": "done", "outputs": {**outputs, **fmeta}})
                                return
                            # 换脚本：像首段一样为新脚本准备（第 1 章 + 生成 case_core）。
                            # 阻塞式 Dify 调用在等待期间每 15s 推心跳，重置客户端 30s 计时；
                            # 真实超时（Dify 30s 无返回）按统一规则直接关闭当前流。
                            yield _sse({"event": "heartbeat", "message": "正在生成新案件核心"})
                            case_task = asyncio.create_task(_generate_case_meta(1, script_id=new_script_id))
                            while True:
                                done, _ = await asyncio.wait({case_task}, timeout=15)
                                if case_task in done:
                                    try:
                                        pre_case_meta = case_task.result()
                                    except httpx.TimeoutException:
                                        logger.warning("STREAM 换脚本案件核心 Dify 超时（30 秒），关闭流")
                                        return
                                    except CaseCoreError as ce:
                                        # 案件核心生成失败（非超时 / 非 200 / 网络异常 / 空核心）：
                                        # 没有核心的小说不合格，终止整个生成流程
                                        # （本段脚本已暂存未落库，遵循"成对存在/成对不存在"原子规则）
                                        logger.warning("STREAM 案件核心生成失败，终止本次生成（暂存段不落库）: %s", ce)
                                        yield _sse({"event": "error", "message": "案件核心生成失败，已终止本次生成，请稍后重试"})
                                        return
                                    break
                                yield _sse({"event": "heartbeat", "message": "正在生成新案件核心"})
                            settings["case_core"] = pre_case_meta.get("case_core") or ""
                            # 案件核心已就绪，开始向 Dify 申请新小说开头前，再给 App 一个心跳
                            yield _sse({"event": "heartbeat", "message": "案件核心已就绪，开始生成新章节"})
                            break  # 结束本段 Dify 流，外层 while 继续生成下一段

                        elif etype in ("error", "workflow_failed"):
                            yield _sse({"event": "error", "message": edata.get("message") or "Dify 工作流执行失败"})
                            return

                    # 流意外结束（未收到 workflow_finished）：兜底，剩余内容仍须先审核再 reveal
                    if not segment_ended:
                        if full_text:
                            async for ev in _audit_pipeline(full_text, final=True):
                                yield _sse(ev)
                            if audit_aborted:
                                return
                            # 未收到 workflow_finished（无氛围等推演输出），按新规则不落库，仅推送正文
                            logger.warning("STREAM fallback skip persist (无氛围) final_len=%d", len(full_text))
                            yield _sse({"event": "done", "outputs": {**outputs, **meta}})
                        else:
                            logger.warning("STREAM fallback empty_output full_len=%d sent_first=%s", len(full_text), sent_first)
                            yield _sse({"event": "error", "code": "empty_output", "message": "服务器未返回有效的小说正文，请检查额度是否已用尽，或稍后重试"})
                        return
        except httpx.TimeoutException as exc:
            # Dify 任意一端 30 秒无数据/心跳：按统一规则直接关闭当前流，不再等待。
            # 客户端自身 30 秒滚动计时会触发"网络疑似超时，请重启重试"提示。
            logger.warning("STREAM Dify 超时（30 秒），关闭流: %s", exc)
            return
        except httpx.RequestError as exc:
            logger.warning("STREAM RequestError: %s", exc, exc_info=True)
            yield _sse({"event": "error", "message": f"与 Dify 通信异常: {str(exc)}"})
        except Exception as e:
            logger.warning("STREAM Exception: %s", e, exc_info=True)
            yield _sse({"event": "error", "message": f"网关异常: {str(e)}"})

    # 对外暴露的 SSE 生成器：把真正的生成逻辑（_generate_sse）放到后台任务里跑，
    # 与客户端连接生命周期解耦。客户端断联只取消本 consumer，后台任务继续执行
    # 自身操作（等待 Dify、审核、落库），保证用户重启 App 后同步能拉回完整数据。
    async def _stream():
        queue: asyncio.Queue = asyncio.Queue()

        async def _pump():
            try:
                try:
                    async for sse_line in _generate_sse():
                        await queue.put(sse_line)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    logger.warning("STREAM 后台生成任务异常: %s", exc, exc_info=True)
            finally:
                await queue.put(None)

        worker = asyncio.create_task(_pump())
        try:
            while True:
                item = await queue.get()
                if item is None:
                    break
                yield item
        finally:
            # 客户端断联：标记并【不取消】后台 worker，让服务器继续完成 Dify 收尾与落库。
            _conn_state["client_gone"] = True
            if not worker.done():
                logger.info("STREAM 客户端断联，后台生成任务继续执行（不取消）")

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
def _dedup_story_segments_by_script(user_id: str, rows: list) -> list:
    """按脚本号（current_script_id，如 "2-5"）对【本次拉取到的 rows】做"近距"去重。

    同一脚本号近期可能被脚本库合法复用（循环使用），所以不能见重复就删。只有当
    "距离很近"的两个同脚本号才是并发重复生成（客户端断联后后台任务仍在跑、同时又有
    新一轮请求并发写入同一脚本号）：
      - seq 差 ≤ 3（中间至多隔 3 行，如 1-1,1-1；1-1,1-2,1-1；1-1,1-2,1-3,1-1）
        → 删除较老的那个；
      - seq 差 ≥ 4（如 1-1,1-2,1-3,1-4,1-1）→ 视为合法复用，两个都保留。

    只对本次拉取窗口里出现的脚本号做定点查询，且只查"窗口 seq ±3"内的出现次数
    （近距判定只需这些，走 (user_id, current_script_id, seq) 覆盖索引），不扫整份小说。
    被判定为较老重复的行从数据库删除，并从返回中剔除（App 端不显示）。
    返回去重后的 rows（类型、顺序与传入一致）。
    """
    conn = _db()
    try:
        # 本次窗口里出现的非空脚本号（冷启动 3 个 / 懒加载 10 个）
        sids = []
        for r in rows:
            sid = r["current_script_id"]
            if isinstance(sid, str) and sid and sid not in sids:
                sids.append(sid)
        if not sids:
            return rows
        # 近距判定只需窗口附近的行：窗口 seq 范围 ±3 即覆盖"间隔≤3"的所有可能重复
        lo = min(r["seq"] for r in rows) - 3
        hi = max(r["seq"] for r in rows) + 3
        doomed: set = set()  # 判定为"较老重复章"待删除的 seq
        for sid in sids:
            occ = [
                x[0]
                for x in conn.execute(
                    """SELECT seq FROM story_segments
                       WHERE user_id=? AND current_script_id=?
                         AND seq BETWEEN ? AND ?
                       ORDER BY seq""",
                    (user_id, sid, lo, hi),
                ).fetchall()
            ]
            # 相邻两次出现：seq 差 ≤ 3 → 删除较老的那个（近距重复）；
            # seq 差 ≥ 4 → 合法复用，两个都保留。
            for i in range(1, len(occ)):
                if occ[i] - occ[i - 1] <= 3:
                    doomed.add(occ[i - 1])
        if doomed:
            for s in doomed:
                conn.execute(
                    "DELETE FROM story_segments WHERE user_id=? AND seq=?",
                    (user_id, s),
                )
            # RAG 同步删除：被去重删除的章节，其向量/人名/提纯一并删除并重建名字反查
            _purge_rag_for_user(user_id, conn, seqs=sorted(doomed))
            conn.commit()
            logger.warning("STORY 近距去重：删除较老的重复章节 seqs=%s", sorted(doomed))
        # 从返回中剔除被删除的行
        return [r for r in rows if r["seq"] not in doomed]
    finally:
        conn.close()


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
                          case_core, current_script_id
                   FROM story_segments
                   WHERE user_id=? AND seq < ? ORDER BY seq DESC LIMIT ?""",
                (user_id, before_seq, limit),
            ).fetchall()
            rows = list(reversed(rows))
        elif limit > 0:
            rows = conn.execute(
                """SELECT seq, content, choice_1, choice_2, choice_3, user_choice,
                          case_core, current_script_id
                   FROM story_segments
                   WHERE user_id=? ORDER BY seq DESC LIMIT ?""",
                (user_id, limit),
            ).fetchall()
            rows = list(reversed(rows))
        else:
            rows = conn.execute(
                """SELECT seq, content, choice_1, choice_2, choice_3, user_choice,
                          case_core, current_script_id
                   FROM story_segments
                   WHERE user_id=? ORDER BY seq ASC""",
                (user_id,),
            ).fetchall()
        # 按脚本号去重（只针对本次拉取的少量行做定点查询，不扫全表）：同一脚本号
        # 本次拉到的若不是全库最新一段，即较老的重复章 → 删库并剔除，App 端不显示。
        rows = _dedup_story_segments_by_script(user_id, rows)
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
    case_cores = []
    current_script_ids = []
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
            case_cores.append(
                (r["case_core"] or "") if isinstance(r["case_core"], str) else ""
            )
            current_script_ids.append(
                (r["current_script_id"] or "")
                if isinstance(r["current_script_id"], str)
                else ""
            )
    start_seq = rows[0]["seq"] if rows else 0
    resp = {
        "segments": segments,
        # 与 segments 一一对应的三个选项（choice_1/2/3），App 显示在对应段落的按钮中
        # 并预填正文底部第 1/2/3 个输入框
        "choices": choices,
        # 与 segments 一一对应的用户本轮实际选择文本（未选择为空）
        "user_choices": user_choices,
        # 与 segments 一一对应的当前案件核心（凶杀案设定，无则为空串）
        "case_cores": case_cores,
        # 与 segments 一一对应的脚本序号（"脚本id-章节"，如 "2-5"；无则为空串）。
        # App 据此判断某段是否为一个脚本的最后一章（下一段脚本 id 不同即切换点）
        "current_script_ids": current_script_ids,
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
                      case_core
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
        # RAG 同步删除：整组覆盖 → 清空该用户全部 RAG，由后台按新正文重建
        _purge_rag_for_user(user_id, conn)
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
