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
# 注意：Key 必须通过环境变量 CASE_DIFY_API_KEY 提供（勿硬编码到代码/提交到仓库）。
CASE_DIFY_API_KEY = os.environ.get("CASE_DIFY_API_KEY", "")
CASE_DIFY_API_URL = os.environ.get("CASE_DIFY_API_URL", DIFY_API_URL)
# 分章节大纲工作流（2026-09 新逻辑）：每次开新小说实时生成整份分章大纲。
# 输入：location / era / player_name / player_traits；response_mode=streaming。
# 输出（实测）：outputs.text = 整份大纲 JSON（含 chapter_script_01..10）；
#              outputs.text_1 = 合规判定字符串（"true" 才允许把其余章落库）。
# Key 必须通过环境变量 OUTLINE_DIFY_API_KEY 提供（勿硬编码/提交仓库）。
OUTLINE_DIFY_API_KEY = os.environ.get("OUTLINE_DIFY_API_KEY", "")
OUTLINE_DIFY_API_URL = os.environ.get("OUTLINE_DIFY_API_URL", DIFY_API_URL)
# 大纲流整体超时（分钟级：整份大纲 + 合规判定可能 30s~数分钟）
OUTLINE_DIFY_TIMEOUT = float(os.environ.get("OUTLINE_DIFY_TIMEOUT", "300"))
# 大纲流读取超时（与小说流一致）：收到任何 Dify 数据即重置；持续无数据 30s 视为断/失败。
# 服务端不再发“纯粹心跳”；App 只在收到实质内容时重置其 30s 等待。
OUTLINE_DIFY_STREAM_TIMEOUT = float(os.environ.get("OUTLINE_DIFY_STREAM_TIMEOUT", "30"))
# 大纲 JSON 字段约定：chapter_script_01..10
OUTLINE_CHAPTER_PREFIX = "chapter_script_"
OUTLINE_MAX_CHAPTERS = int(os.environ.get("OUTLINE_MAX_CHAPTERS", "10"))
# 大纲防重名：used_name 输入 = 最近 USED_NAME_RECENT_STORIES 个故事已用过的
# 人名（每本主角 + distill 副角），以顿号连接的字符串传给大纲工作流。
USED_NAME_RECENT_STORIES = int(os.environ.get("USED_NAME_RECENT_STORIES", "10"))
# 大纲 debug：申请大纲流前先给 App 弹窗展示要发给 Dify 的全部变量
# （outline_debug_payload 事件；弹窗期间每 15s heartbeat 续命；确认后照常发送）。
OUTLINE_DEBUG_PREVIEW = (
    os.environ.get("OUTLINE_DEBUG_PREVIEW", "1").strip().lower()
    in ("1", "true", "yes", "on")
)
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
# 修正-重审循环上限：一次违规最多让用户确认并自动修正 REVISE_MAX_ATTEMPTS 次
# （每轮=弹窗请用户确认 → 调修正工作流 → 重审一遍）。默认 5 次；第 5 次修正后的
# 文本重审仍不过 → 【放行】：直接把该文本按"通过"送出继续（不再中止、不再无限循环）。
# 设为 0（或负数）= 不限次数（实验用；正式放开请用正数）。
REVISE_MAX_ATTEMPTS = int(os.environ.get("REVISE_MAX_ATTEMPTS", "5"))
# 修正前"等待 App 用户确认"的最大秒数（超过则回退 abort 弹窗）
REVISE_CONFIRM_TIMEOUT = int(os.environ.get("REVISE_CONFIRM_TIMEOUT", "120"))
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
# ---- 大纲"故事底稿"(the_script) —— 技术核心，勿外漏 ----
# 框架模板内容含层层"几选一"，属机密：文件放 gitignore 的 server/data/ 目录
# （容器内为 /code/data，由服务器单独部署），绝不提交仓库、绝不发给 App。
# 每次开新小说：FastAPI 先对模板做一层层等概率抽签，组合成一段完整底稿文本，
# 作为 the_script 输入发给 Dify 大纲工作流；文件缺失/不可读则跳过该输入（优雅降级）。
# 路径可用环境变量 THE_SCRIPT_FRAMEWORK_FILE 覆盖。
THE_SCRIPT_FRAMEWORK_FILE = os.environ.get(
    "THE_SCRIPT_FRAMEWORK_FILE",
    os.path.join(DATA_DIR, "the_script_framework.txt"),
)
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
# 违规修正前的确认注册表：request_id -> asyncio.Event（App 点击"送 Dify 修正"后 set）
_pending_revise_confirm: dict[str, asyncio.Event] = {}

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
    content    TEXT NOT NULL,             -- 这一段文本（建行时为空，正文生成后回填）
    outline    TEXT NOT NULL DEFAULT '',  -- 本章分场大纲（大纲一建立即建行并落大纲）
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

-- 最新登入口令（写者守卫）：每用户一行。
-- register / device/activate（App 启动第一件事）覆盖为最新登入(device_id, login_ts)。
-- 每次"逻辑写单元"落库前，在同一条 SQLite 事务里校验本请求口令 == 此处当前值；
-- 不等（已被更新设备顶掉）→ 该笔一个字节都不写，返回"多客户端"冲突。
CREATE TABLE IF NOT EXISTS user_write_guard (
    user_id    TEXT PRIMARY KEY,
    device_id  TEXT NOT NULL,
    login_ts   INTEGER NOT NULL
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
    """从 Dify blocking 响应中取出审核结果（JSON 字符串）。

    新接口（2026-09 起）：审核工作流 End 节点输出变量名为 text，
    值为 string 形式的判定 JSON（也兼容对象/数组，这里统一序列化为字符串）。
    只读 data.outputs.text；找不到返回 ""（调用方按"无有效审核输出"处理）。
    """
    if not isinstance(dify_data, dict):
        return ""

    def _coerce(v: Any) -> str:
        """把审核输出值规范化为非空 JSON 字符串；不可用返回 ""。"""
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
            return _coerce(outputs.get("text"))
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


def create_token(user_id: str, device_id: str, expires_at: int,
                 login_ts: Optional[int] = None) -> str:
    """签发令牌；login_ts 为本次登入口令的时间戳（服务器铸造）。"""
    payload = _b64url_encode(
        json.dumps(
            {"u": user_id, "d": device_id, "t": login_ts, "exp": expires_at},
            separators=(",", ":"),
        ).encode()
    )
    sig = _b64url_encode(
        hmac.new(TOKEN_SECRET.encode(), payload.encode(), hashlib.sha256).digest()
    )
    return f"v1.{payload}.{sig}"


def validate_token(token: str) -> dict:
    """校验签名令牌，返回 {user_id, device_id, login_ts}；失败抛 401。"""
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
        login_ts = payload.get("t")
    except Exception:
        raise HTTPException(status_code=401, detail="令牌内容无效")
    if int(time.time()) > exp:
        raise HTTPException(status_code=401, detail="令牌已过期，请重新注册")
    return {
        "user_id": str(user_id),
        "device_id": str(device_id),
        "login_ts": (int(login_ts) if login_ts is not None else None),
    }


# ================= 写者守卫（最新登入口令） =================
class StoryWriteConflict(Exception):
    """口令不符（本设备已被更新的设备顶掉）：该逻辑写单元一个字节都不写。"""

    def __init__(self):
        super().__init__("multi_client")


def _guard_upsert(conn: sqlite3.Connection, user_id: str, device_id: str,
                  login_ts: int) -> None:
    """登录/激活后写入（覆盖）该用户的最新登入口令。调用方自行 COMMIT。

    注意：不得清掉任何"进行中写者"的状态（本设计无跨写持锁，故只需覆盖口令）。
    """
    conn.execute(
        """INSERT INTO user_write_guard (user_id, device_id, login_ts)
           VALUES (?, ?, ?)
           ON CONFLICT(user_id) DO UPDATE SET
             device_id=excluded.device_id, login_ts=excluded.login_ts""",
        (user_id, device_id, login_ts),
    )


def _run_write_unit(user_id: str, device_id: str, login_ts: Optional[int], work):
    """执行一个"逻辑写单元"：同一条写事务内 校验口令 → work(conn) 全部因果写 → COMMIT。

    - 口令不符（本请求已不是最新登入）→ ROLLBACK、不写任何字节，抛 StoryWriteConflict；
    - work(conn) 内部不得自行 COMMIT/ROLLBACK/关闭连接（由本函数统一收尾）；
    - 用 BEGIN IMMEDIATE 取写锁，保证"校验口令 + 该单元全部写"在 SQLite 单写者下原子、
      跨进程也成立（登录事务与写单元事务被串行化，绝不交错）。
    """
    conn = _db()
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT device_id, login_ts FROM user_write_guard WHERE user_id=?",
            (user_id,),
        ).fetchone()
        ok = (
            row is not None
            and login_ts is not None
            and str(row["device_id"]) == str(device_id)
            and int(row["login_ts"]) == int(login_ts)
        )
        if not ok:
            conn.rollback()
            raise StoryWriteConflict()
        work(conn)
        conn.commit()
    finally:
        conn.close()


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
    # 用户本轮实际选择（点第 2/3 个推荐输入框或自由输入后确认的文本），
    # App 以 user_choice 字段显式上传，服务器据此写入 user_choice 列与 Dify 变量。
    user_choice: str = ""
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
    """已收口到"最新登入口令"写者守卫（2026-09 冻结规格）。

    旧的"按 users.active_device_id 判多设备"被 `_run_write_unit`（写前校验
    device_id+login_ts == user_write_guard）取代；读放行、写由口令把关。
    保留本函数为空实现以兼容既有调用点（读不拦；写端点各自走受口令保护的事务）。
    """
    return


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

        # 7) 注册/再登入 = 写最新登入口令（先已建好 user/device 两个 id，再造口令）
        _guard_upsert(conn, real_user_id, device_id, now)

        # 8) 清理已用挑战
        conn.execute("DELETE FROM challenges WHERE challenge_id=?", (data.challenge_id,))
        conn.commit()
    finally:
        conn.close()

    expires_at = now + TOKEN_EXPIRY_DAYS * 86400
    token = create_token(real_user_id, device_id, expires_at, login_ts=now)
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
                "audit-and-chat: Dify 响应中未找到审核输出(text)，status=%s 原始响应=%s",
                data_block.get("status"),
                raw_preview,
            )
            keys = ", ".join(
                map(str, (data_block.get("outputs") or {}).keys())
            ) or "(未返回任何 outputs)"
            raise HTTPException(
                status_code=500,
                detail=(
                    "Dify 未返回有效的审核输出（期望 End 输出变量名为 text，"
                    "值为判定 JSON 字符串）。"
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


def _parse_audit_action_marker(out: str) -> Optional[str]:
    """从审核结果文本的头部 'Action: XXX' 提取动作标记（大小写不敏感）。

    新接口（2026-09 起，Bedrock guardrail 文本格式）的返回形如：
        Action: NONE
        Processed Output: ...
        Assessments:
        - Policy=..., Data=...
    过审 = Action: NONE；其它 Action 值视为违规(block)。
    找不到 Action: 行 → 返回 None（调用方按"不可用/无法解析"处理）。
    """
    if not out or not isinstance(out, str):
        return None
    m = re.search(r"(?im)^\s*Action\s*:\s*(\S+)", out)
    if not m:
        return None
    return m.group(1).strip().lower()


def _parse_audit_json(out: str) -> Optional[str]:
    """读取审核结果中的 action 判定（大小写不敏感、忽略首尾空白）。

    兼容两种输出形态：
    - JSON：{action: ...} / 数组等，读其中的 action 字段；
    - 纯文本（新 Bedrock guardrail 格式）：读首行 'Action: XXX' 标记。
    读不到 action → 返回 None（调用方按不可用/无法解析处理，fail-closed）。
    """
    data = _parse_audit_output(out)
    if data is not None:
        # JSON 形态：读 action 字段
        for k, v in data.items():
            if isinstance(k, str) and k.strip().lower() == "action":
                if isinstance(v, str):
                    return v.strip().lower()
        return None
    # 纯文本形态（非 JSON）：读 'Action: XXX' 标记
    return _parse_audit_action_marker(out)


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
    data = _parse_audit_output(out) or {}
    action = _parse_audit_json(out)
    if action is None:
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
        if verdict and out:
            # 把审核返回的原始反馈串带上，供"违规修正"工作流以 guardrail_json 原样转发
            verdict = dict(verdict)
            verdict["__audit_feedback__"] = out
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

    工作流输入变量：novel_text（违规文本）、guardrail_json、language、max_tokens。
    guardrail_json 优先发送【审核返回的原始反馈串】（verdict 里由 _moderate_story
    附带的 __audit_feedback__，即 Bedrock guardrail 那类整段文本）；没有原文时才回退
    发送最小判定 JSON（action/category/confidence/reason）。
    language：完整语言名（如"简体中文"，防止 LLM 改写时串用其它语言）。
    未配置 REVISE_DIFY_API_KEY 时直接返回 None（调用方回退到 abort 弹窗）。
    输出变量名依次尝试 revised_text / text / novel_text / output_text / result。
    """
    if not REVISE_DIFY_API_KEY:
        return None
    headers = {
        "Authorization": f"Bearer {REVISE_DIFY_API_KEY}",
        "Content-Type": "application/json",
    }
    # 审核返回的原始反馈串优先作为 guardrail_json 发给修正流
    audit_feedback = (verdict or {}).get("__audit_feedback__")
    guardrail_value = (
        audit_feedback if isinstance(audit_feedback, str) and audit_feedback.strip()
        else json.dumps(verdict, ensure_ascii=False)
    )
    payload = {
        "inputs": {
            "novel_text": text,
            "guardrail_json": guardrail_value,
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


# ================= 分章节大纲：解析与流式切分（2026-09 新逻辑） =================
# 大纲 Dify 流一次产出整份 JSON：{"chapter_script_01": "...", ..., "chapter_script_10": "..."}
# text_chunk 逐字携带该 JSON（第 1 章在最前），可增量切出第 1 章提前开写；
# workflow_finished.outputs 里 text=整份 JSON、text_1=合规值。

def _json_string_end(raw: str, start: int) -> int:
    """从 raw[start]（应为 '"'）开始扫描到闭合引号，返回闭合引号下标；未闭合返回 -1。"""
    i = start + 1
    n = len(raw)
    while i < n:
        c = raw[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i
        i += 1
    return -1


def _decode_json_string_literal(seg: str) -> str:
    """把一个含引号的 JSON 字符串字面量解码为真实文本；失败则剥引号返回。"""
    try:
        return json.loads(seg)
    except Exception:
        s = seg.strip()
        if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
            return s[1:-1]
        return s


def _incremental_chapter1(raw: str) -> Optional[str]:
    """从累计的流式原始文本里切出第 1 章大纲（JSON 最前字段）；未齐返回 None。"""
    marker = '"' + OUTLINE_CHAPTER_PREFIX + "01" + '"'
    i = raw.find(marker)
    if i < 0:
        return None
    colon = raw.find(":", i + len(marker))
    if colon < 0:
        return None
    p = colon + 1
    n = len(raw)
    while p < n and raw[p] in " \t\r\n":
        p += 1
    if p >= n or raw[p] != '"':
        return None
    end = _json_string_end(raw, p)
    if end < 0:
        return None
    text = _decode_json_string_literal(raw[p:end + 1]).strip()
    return text or None


def _parse_outline_outputs(outputs: Optional[dict]) -> dict:
    """解析 workflow_finished.outputs，返回 {"chapters":{1:..n:..},"check":Optional[bool],"raw":str}。

    固定契约（实测）：outputs['text'] = 整份大纲 JSON 字符串（含 chapter_script_01..10）；
    outputs['text_1'] = 合规判定字符串（"true"）。check 归一化 == "true" 才为 True。
    """
    outs = outputs or {}
    chapters: dict = {}
    raw_text = ""
    check = None

    raw = outs.get("text")
    if isinstance(raw, str) and raw.strip():
        s = raw.strip()
        st = s.find("{")
        if st >= 0:
            try:
                obj = json.loads(s[st:])
            except Exception:
                obj = None
            if isinstance(obj, dict):
                got = {}
                for n in range(1, OUTLINE_MAX_CHAPTERS + 1):
                    cv = obj.get(f"{OUTLINE_CHAPTER_PREFIX}{n:02d}")
                    if isinstance(cv, str) and cv.strip():
                        got[n] = cv.strip()
                    elif isinstance(cv, str) and not cv.strip():
                        break
                    else:
                        break
                if got:
                    chapters = got
                    raw_text = s[st:]

    t1 = outs.get("text_1")
    if isinstance(t1, str) and t1.strip():
        check = t1.strip().lower() == "true"
    if check is None and chapters:
        logger.warning("大纲 outputs 未含合规判定字段，按未通过处理（其余章不落库）")
        check = False
    return {"chapters": chapters, "check": check, "raw": raw_text}


def _collect_recent_used_names(user_id: str, script_no: int) -> str:
    """最近 USED_NAME_RECENT_STORIES 个故事（脚本号 < script_no 的最后 N 本）用过的名字。

    主角 = story_segments.player_name（每段快照），副角 = story_chapter_distill.characters；
    只统计脚本号落在 [max(1, script_no-N), script_no-1] 的章节。去重后以顿号"、"连接。
    """
    if script_no <= 1:
        return ""
    lower = max(1, script_no - USED_NAME_RECENT_STORIES)
    upper = script_no - 1
    seen = set()
    out: list = []

    def _add(n) -> None:
        s = str(n or "").strip()
        if s and s not in seen:
            seen.add(s)
            out.append(s)

    conn = _db()
    try:
        rows = conn.execute(
            """SELECT seq, player_name FROM story_segments
               WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''
                 AND TRIM(COALESCE(current_script_id,'')) <> ''
                 AND CAST(substr(current_script_id, 1,
                                 instr(current_script_id,'-') - 1) AS INTEGER)
                     BETWEEN ? AND ?""",
            (user_id, lower, upper),
        ).fetchall()
        seqs = []
        for r in rows:
            _add(r["player_name"])
            seqs.append(r["seq"])
        if seqs:
            marks = ",".join("?" * len(seqs))
            for d in conn.execute(
                f"""SELECT characters FROM story_chapter_distill
                    WHERE user_id=? AND segment_seq IN ({marks})""",
                [user_id, *seqs],
            ).fetchall():
                try:
                    chars = json.loads(d["characters"] or "[]")
                except Exception:
                    chars = []
                if isinstance(chars, list):
                    for nm in chars:
                        _add(nm)
    finally:
        conn.close()
    return "、".join(out)


# ================= the_script：大纲"故事底稿"等概率抽签组合（技术核心，勿外漏） =================
# 框架模板（层层"几选一"）属机密：文件放 gitignore 的 server/data/（容器内 /code/data，
# 由服务器单独部署），绝不提交仓库、绝不发给 App。每次开新小说先对模板做一层层等概率
# 抽签，组合成一段完整底稿文本，作为 the_script 输入发给 Dify 大纲工作流；文件缺失→跳过。

_TS_OPEN2CLOSE = {
    "\uff08": "\uff09",   # （ ）
    "\u300c": "\u300d",   # 「 」
    "\u300e": "\u300f",   # 『 』
    "\u3010": "\u3011",   # 【 】
    "(": ")",
}
_TS_CLOSE2OPEN = {v: k for k, v in _TS_OPEN2CLOSE.items()}
_TS_CN = "[一二三四五六七八九十百千万]"
_TS_LABEL_RE = re.compile(
    r"[\uff08\u300c\u300e\u3010(](?:第" + _TS_CN + r"+层)?(?:"
    + _TS_CN + r"+|[0-9\uff10-\uff19]+|\u51e0)选一："
)
_TS_NUM_PREFIX_RE = re.compile(
    r"^[ \t\f\v\u3000]*[0-9\uff10-\uff19]+[\u3001\u3002.．:：]?"
)


def _ts_matching_close(text, i):
    """text[i] 是开括号：用同类型括号计数找配对的闭括号下标；找不到返回 -1。"""
    op = text[i]
    cl = _TS_OPEN2CLOSE[op]
    depth = 0
    for j in range(i, len(text)):
        ch = text[j]
        if ch == op:
            depth += 1
        elif ch == cl:
            depth -= 1
            if depth == 0:
                return j
    return -1


def _ts_split_at_top(body):
    """把一段文字按"括号外的全角分号；"切开（括号内的分号属于更深一层，不切）。"""
    parts = []
    stack = []
    start = 0
    for i, ch in enumerate(body):
        if ch in _TS_OPEN2CLOSE:
            stack.append(ch)
        elif ch in _TS_CLOSE2OPEN:
            if stack and stack[-1] == _TS_CLOSE2OPEN[ch]:
                stack.pop()
        elif ch == "\uff1b" and not stack:  # ；
            parts.append(body[start:i])
            start = i + 1
    parts.append(body[start:])
    return parts


def _ts_parse_options(full, label_end, close):
    """取某个"几选一"的选项文本列表：切分并剥掉编号前缀。"""
    opts = []
    for part in _ts_split_at_top(full[label_end:close]):
        part = part.strip()
        if not part:
            continue
        part = _TS_NUM_PREFIX_RE.sub("", part, count=1).strip()
        if part:
            opts.append(part)
    return opts


def _ts_next_choice(text):
    """找文本里第一个"几选一"选择：返回 (开括号下标, 闭括号下标, 选项列表) 或 None。"""
    m = _TS_LABEL_RE.search(text)
    if not m:
        return None
    oi = m.start()
    ci = _ts_matching_close(text, oi)
    if ci <= oi:
        return None
    return (oi, ci, _ts_parse_options(text, m.end(), ci))


def _ts_resolve(text, _depth=0):
    """从外到内把每一层"几选一"各抽一次签（等概率 random.choice），逐层替换成所选分支。"""
    if _depth > 50:
        return text
    while True:
        node = _ts_next_choice(text)
        if node is None:
            break
        oi, ci, opts = node
        if not opts:
            return text
        picked = random.choice(opts)
        text = text[:oi] + _ts_resolve(picked, _depth + 1) + text[ci + 1:]
    return text


def _the_script_framework() -> str:
    """读机密框架模板（含层层"几选一"）。文件缺失/不可读返回 ''（调用方跳过该输入）。"""
    try:
        with open(THE_SCRIPT_FRAMEWORK_FILE, "r", encoding="utf-8") as f:
            return (f.read() or "").strip()
    except Exception as e:
        logger.warning(
            "THE_SCRIPT 框架模板不可读（%s），本次不注入 the_script: %s",
            THE_SCRIPT_FRAMEWORK_FILE, e,
        )
        return ""


def _compose_the_script() -> str:
    """每次开新小说：读机密框架 → 一层层等概率抽签组合成完整底稿文本（the_script）。
    框架未配置/解析异常时返回 ""（调用方不加该输入，保持旧行为）。"""
    fw = _the_script_framework()
    if not fw:
        return ""
    try:
        return _ts_resolve(fw)
    except Exception as e:
        logger.warning("THE_SCRIPT 组合异常，本次不注入 the_script: %s", e)
        return ""


def _outline_inputs(
    settings: dict, user_id: str, script_no: int,
    the_script: Optional[str] = None,
) -> dict:
    """构造发大纲工作流的 inputs（弹窗展示与实际发送共用同一份，保证所见即所得）。

    字段：location/era/player_name/player_traits/language（语言规范全名）/
    used_name（最近 USED_NAME_RECENT_STORIES 个故事已用人名，顿号连接）/
    the_script（每次开新小说对机密框架抽签组合出的完整故事底稿；传 None 时现场组合；
    为空串或框架缺失则不加入 inputs）。
    """
    if the_script is None:
        the_script = _compose_the_script()
    d = {
        "location": settings.get("location") or "未设定",
        "era": settings.get("era") or "未设定",
        "player_name": settings.get("player_name") or "未设定",
        "player_traits": settings.get("player_traits") or "未设定",
        "language": _dify_language_name(settings.get("language") or ""),
        "used_name": _collect_recent_used_names(user_id, script_no),
    }
    if the_script:
        d["the_script"] = the_script
    return d


async def _request_outline_chapters(
    settings: dict, user_id: str, script_no: int,
    on_chapter1=None, on_activity=None,
    the_script: Optional[str] = None,
) -> dict:
    """调大纲工作流（streaming）跑一次，返回 _parse_outline_outputs 同构 dict。

    user_id / script_no：当前正要开的新小说（脚本号），据此把最近
    USED_NAME_RECENT_STORIES 个故事已用过的名字（主角+副角）以顿号连接成
    used_name 传给大纲流，让大纲避免与老角色重名。
    on_chapter1：可选 async callable(chapter1_text)；第 1 章增量切出后立即回调
    （用于提前建章/开写）。失败抛 httpx.TimeoutException / httpx.RequestError /
    RuntimeError（未配置 Key 或 Dify 非 200）。
    """
    if not OUTLINE_DIFY_API_KEY:
        raise RuntimeError("OUTLINE_DIFY_API_KEY 未配置，无法生成大纲")
    headers = {
        "Authorization": f"Bearer {OUTLINE_DIFY_API_KEY}",
        "Content-Type": "application/json",
    }
    inputs = _outline_inputs(settings, user_id, script_no, the_script=the_script)
    logger.warning(
        "OUTLINE used_name(%s) len=%d the_script=%d",
        script_no, len(inputs.get("used_name") or ""),
        len(inputs.get("the_script") or ""),
    )
    payload = {
        "inputs": inputs,
        "response_mode": "streaming",
        "user": "outline",
    }
    buf = ""
    early = None
    async with async_http_client.stream(
        "POST", OUTLINE_DIFY_API_URL, json=payload, headers=headers,
        timeout=OUTLINE_DIFY_STREAM_TIMEOUT,
    ) as resp:
        if resp.status_code != 200:
            body = (await resp.aread()).decode("utf-8", "replace")
            raise RuntimeError(f"大纲工作流非 200：{resp.status_code}: {body[:400]}")
        async for line in resp.aiter_lines():
            if not line or not line.startswith("data:"):
                continue
            raw = line[5:].strip()
            if not raw or raw == "[DONE]":
                continue
            try:
                ev = json.loads(raw)
            except Exception:
                continue
            etype = ev.get("event")
            data = ev.get("data") or {}
            if etype == "text_chunk":
                txt = data.get("text")
                if not isinstance(txt, str):
                    continue
                buf += txt
                if on_activity is not None:
                    on_activity()   # 收到 Dify 大纲实质内容：驱动"大纲活动心跳"
                if early is None:
                    c1 = _incremental_chapter1(buf)
                    if c1:
                        early = c1
                        if on_chapter1 is not None:
                            try:
                                await on_chapter1(c1)
                            except Exception as e:
                                logger.warning("大纲 on_chapter1 回调异常: %s", e)
            elif etype == "workflow_finished":
                if on_activity is not None:
                    on_activity()
                result = _parse_outline_outputs(data.get("outputs") or {})
                result["chapter1_early"] = early
                return result
    result = _parse_outline_outputs({})
    result["chapter1_early"] = early
    logger.warning("大纲流未收到 workflow_finished 即结束")
    return result


# ================= 分章节大纲：DB 层（2026-09 新逻辑） =================
# 大纲模型：每章一个 story_segments 行；大纲一建立即建占位行（content=''、outline=该章大纲），
# 正文生成后再回填 content。current_script_id = "小说序数-章节"（如 "2-3"）。

def _parse_cur_script_id(cur: Any) -> Optional[tuple]:
    """解析 current_script_id "s-c" → (script_no:int, chapter:int)；非法返回 None。"""
    m = re.match(r"^(\d+)-(\d+)$", str(cur or "").strip())
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def _next_seq(user_id: str, conn: Optional[sqlite3.Connection] = None) -> int:
    """该用户下一个 seq（当前最大 seq + 1）。传 conn 时用同连接内查询（事务内防竞态）。"""
    c = conn if conn is not None else _db()
    try:
        row = c.execute(
            "SELECT COALESCE(MAX(seq), -1) AS m FROM story_segments WHERE user_id=?",
            (user_id,),
        ).fetchone()
        return int(row["m"]) + 1
    finally:
        if conn is None:
            c.close()


def _latest_written_segment(user_id: str) -> Optional[sqlite3.Row]:
    """该用户正文非空的最新一行（脚本号/章节/大纲据此推进）。"""
    conn = _db()
    try:
        return conn.execute(
            """SELECT * FROM story_segments
               WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''
               ORDER BY seq DESC LIMIT 1""",
            (user_id,),
        ).fetchone()
    finally:
        conn.close()


def _find_placeholder(user_id: str, script_no: int, chapter: int) -> Optional[sqlite3.Row]:
    """查找 (script_no, chapter) 的大纲占位行：outline 非空且正文为空。无则 None。"""
    conn = _db()
    try:
        return conn.execute(
            """SELECT * FROM story_segments
               WHERE user_id=? AND current_script_id=?
                 AND TRIM(COALESCE(outline,'')) <> ''
                 AND TRIM(COALESCE(content,'')) = ''
               ORDER BY seq DESC LIMIT 1""",
            (user_id, f"{script_no}-{chapter}"),
        ).fetchone()
    finally:
        conn.close()


def _story_needs_next_novel(user_id: str) -> bool:
    """启动自愈判定：最新正文行是否已把"当前小说"写满（其下一章已无占位行）。

    与生成入口"无下一章占位行 → 开新小说"同一条判据：
    只要最新有正文的一行（最大 seq）不是某本小说的"未完待续"（即它的下一章
    没有大纲占位行），就说明老小说已完整，而数据库里没有更新的小说 →
    App 打开时应自动开始生成下一本（自愈"老小说写满却没生成新小说"的死角）。
    """
    latest = _latest_written_segment(user_id)
    if latest is None:
        return False
    parsed = _parse_cur_script_id(latest["current_script_id"])
    if parsed is None:
        return False
    script_no, chapter = parsed
    return _find_placeholder(user_id, script_no, chapter + 1) is None






def _fill_content_row(user_id: str, device_id: str, login_ts: Optional[int],
                      script_no: int, chapter: int,
                      content: str, settings: dict, meta: dict,
                      choice_1: str = "", choice_2: str = "", choice_3: str = "") -> str:
    """单章正文回填（写者守卫保护；content 空串跳过）。

    返回 'ok' / 'conflict'（口令不符，被顶掉，未写）/ 'fail'。
    choice_2/3 传空表示"废弃不显示/不入库"（最后一章），保留该行原空值。
    """
    if not content or not content.strip():
        return "ok"
    cur_id = f"{script_no}-{chapter}"

    def _w(conn: sqlite3.Connection) -> None:
        row = conn.execute(
            """SELECT seq FROM story_segments
               WHERE user_id=? AND current_script_id=? ORDER BY seq DESC LIMIT 1""",
            (user_id, cur_id),
        ).fetchone()
        if row is None:
            # 没有占位行：正常流程不应出现（整本原子落库已建占位）。
            # 不回填也不追加，避免合规驳回清理后又被重建。
            logger.warning("FILL 找不到 %s 占位行，跳过回填", cur_id)
            return
        conn.execute(
            """UPDATE story_segments
                  SET content=?, choice_1=?, choice_2=?, choice_3=?,
                      user_choice=?,
                      music_style=?,
                      location=?, era=?, player_name=?, player_traits=?, language=?,
                      current_aura=?
                WHERE user_id=? AND current_script_id=? AND seq=?""",
            (
                content,
                choice_1,
                choice_2,
                choice_3,
                "",                       # user_choice：新章刚生成，用户尚未选择
                meta.get("music_style") or "",
                settings.get("location") or "",
                settings.get("era") or "",
                settings.get("player_name") or "",
                settings.get("player_traits") or "",
                _language_name(settings.get("language")),
                meta.get("current_aura") or "",
                user_id, cur_id, row["seq"],
            ),
        )

    try:
        _run_write_unit(user_id, device_id, login_ts, _w)
        return "ok"
    except StoryWriteConflict:
        logger.warning("FILL 口令不符（被顶掉）s=%d ch=%d", script_no, chapter)
        return "conflict"
    except Exception as e:
        logger.warning("FILL 回填失败（整体回滚）: %s", e, exc_info=True)
        return "fail"





def _get_story_count(user_id: str) -> int:
    """只读该用户【已生成正文】的段落数（续写/全新判断、以及生成 seq 用）。

    只统计 content 非空的行，不把"仅含大纲、正文空白的占位行"（如新本的第 2..10 章
    预建占位）算进去。这样新本第 1 章落库后此值为 1，第 2 章生成的 seq=1（对应要填的
    '1-2' 占位行），第 3 章=2 … 与"seq 按已写正文顺序增长、填最小空白占位"一致；
    空库仍为 0（判定全新故事）。
    """
    conn = _db()
    try:
        cnt = conn.execute(
            """SELECT COUNT(*) AS c FROM story_segments
               WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''""",
            (user_id,),
        ).fetchone()["c"]
        return cnt
    finally:
        conn.close()


def _get_current_case_story(user_id: str, seq: int) -> str:
    """汇总要回传给 Dify 的正文（corrent_case_all_content 的取值来源）。

    新逻辑（2026-09，按需求确认）——从最新一段向上逐段回溯，三个停止条件：
    - 取该用户最新一段（seq < 当前轮 且最大）的 current_script_id（形如 "3-4"），解析出脚本号 S；
    - 从最新段按 seq 递减逐段向上回溯，收集属于"当前这段脚本运行"的连续章节；
      遇到以下任一情况即停（触发停止的段不包含，唯一例外是条件1）：
        1) 章节号到 1（S-1）→ 停，且 S-1 这一段【包含】（它是本轮脚本的起点）；
        2) 章节号变大（更早一节的章节号 > 当前这一节的章节号）→ 停；
        3) 脚本号开头不再是 S（如遇到 4-x）→ 停；
    - 收集到的章节按 seq 升序（老→新）拼接 content。
    - 兜底：最新一段取不到 / current_script_id 空白或解析不出脚本号 / 用户无任何段 → 返回空串。
    注：corrent_case_all_content 读的是 content 列（正文原文）。
    """
    conn = _db()
    try:
        rows = conn.execute(
            """SELECT seq, current_script_id, content FROM story_segments
               WHERE user_id=? AND seq < ? ORDER BY seq DESC""",
            (user_id, seq),
        ).fetchall()
        if not rows:
            return ""
        # 最新一段：确定当前脚本号 S 与起始章节号
        m = re.match(r"^(\d+)-(\d+)$", (rows[0]["current_script_id"] or "").strip())
        if not m:
            return ""
        script_no = int(m.group(1))
        prev_chapter = int(m.group(2))

        # 从最新段向上逐段回溯（rows 已按 seq 降序 = 新→旧）
        items = []  # [(seq, content)] 收集属于本轮脚本运行的章节
        for idx, row in enumerate(rows):
            if idx == 0:
                # 最新一段总是属于本轮运行
                items.append((row["seq"], row["content"] or ""))
                if prev_chapter == 1:  # 最新段就是 S-1：只有它自己
                    break
                continue
            cid = (row["current_script_id"] or "").strip()
            m2 = re.match(r"^(\d+)-(\d+)$", cid)
            if not m2:
                break  # 脚本号异常，停止
            sid = int(m2.group(1))
            ch = int(m2.group(2))
            if sid != script_no:
                break  # 条件3：脚本号不再是 S
            if ch > prev_chapter:
                break  # 条件2：章节号变大（往上回溯不允许）
            items.append((row["seq"], row["content"] or ""))
            if ch == 1:
                break  # 条件1：到 S-1（本轮起点），包含后结束
            prev_chapter = ch

        # 按 seq 升序（老→新）拼接
        items.sort(key=lambda x: x[0])
        parts = [c for _, c in items if c and c.strip()]
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

    先用简体中文 META_DEFAULTS 打底，再用该语言的 choice/music_style 覆盖，
    保证任意语言都拥有完整键集合。
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
        "characters": characters,
    }
    if meta["music_style"] not in MUSIC_STYLE_VALUES:
        meta["music_style"] = defaults["music_style"]
    return meta


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
        # 只取正文非空的最近一行（大纲占位行无设定快照，不可作为续写依据）
        row = conn.execute(
            """SELECT location, era, player_name, player_traits, language
               FROM story_segments
               WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''
               ORDER BY seq DESC LIMIT 1""",
            (user_id,),
        ).fetchone()
        if row is None:
            return {}
        d = dict(row)
        # DB 语言列存"规范全名"；回读时还原成 App 语言代码（内部 switch 用代码）
        if d.get("language"):
            d["language"] = _language_code(d["language"])
        return d
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
# 规范全名（值） → App 语言代码（键）
_LANGUAGE_CODE_BY_NAME = {v: k for k, v in _LANGUAGE_DIFY_NAME.items()}


def _language_name(lang: str) -> str:
    """返回语言"规范全名"（简体中文/繁體中文/English/…），用于与小说一同落库。
    已是规范全名则原样返回；App 语言代码映射为全名；空值保持空；未知非空回退简体中文。
    """
    key = (lang or "").strip()
    if not key:
        return ""
    if key in _LANGUAGE_CODE_BY_NAME:
        return key
    return _LANGUAGE_DIFY_NAME.get(key, "简体中文")


def _dify_language_name(lang: str) -> str:
    """发给 Dify 的语言（规范全名，直接让 LLM 明白用哪种语言写）。
    已是规范全名则原样；语言代码映射为全名；空值/未知回退简体中文。
    """
    key = (lang or "").strip()
    if not key:
        return "简体中文"
    if key in _LANGUAGE_CODE_BY_NAME:
        return key
    return _LANGUAGE_DIFY_NAME.get(key, "简体中文")


def _language_code(lang: str) -> str:
    """规范全名 → App 语言代码（App 本地化 switch 用代码，如 zh/en）。
    已是语言代码则原样返回；空值/未知回退 'zh'。
    """
    key = (lang or "").strip()
    if key in _LANGUAGE_DIFY_NAME:
        return key
    return _LANGUAGE_CODE_BY_NAME.get(key, "zh")


def _reset_story(user_id: str, device_id: str, login_ts: Optional[int]) -> str:
    """清空重来（写者守卫保护）：DELETE 全部 story_segments + 清 RAG，同一事务。

    返回 'ok' / 'conflict'（口令不符，被顶掉，未清）/ 'fail'。
    """
    def _w(conn: sqlite3.Connection) -> None:
        conn.execute("DELETE FROM story_segments WHERE user_id=?", (user_id,))
        # RAG 同步删除：清空该用户全部 RAG（distill/vectors/lookup）
        _purge_rag_for_user(user_id, conn)

    try:
        _run_write_unit(user_id, device_id, login_ts, _w)
        return "ok"
    except StoryWriteConflict:
        logger.warning("RESET 口令不符（被顶掉），未清空 user=%s", user_id)
        return "conflict"
    except Exception as e:
        logger.warning("RESET 清空失败（整体回滚）: %s", e, exc_info=True)
        return "fail"


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




def _script_id_of(current_script_id: Any) -> str:
    return str(current_script_id or "").split("-")[0]


async def _retrieve_rag(
    user_id: str,
    query: str,
    current_script_id: Any,
    protagonist_name: str = "",
) -> Optional[str]:
    """双通道检索：名字精确子串 + 语义 cosine（排除当前正在生成的脚本）。
    命中 → 返回整个章节正文；否则 None。语义优先；多章≥阈值取最高分，并列随机；最多一章。

    protagonist_name：当前主角名。主角每章/每本都出现，若用户输入恰好带主角名，
    精确子串会把"历史旧本里同主角的章节"也命中——那是噪音；这里把它从人名通道剔除，
    避免主角名引来历史 RAG 素材（语义通道不受影响）。"""
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
        # 主角名过滤：当前主角每一章/每一本都会出现，用户输入若恰好带主角名，
        # 精确子串会把"历史旧本里同主角的章节"也命中——那是噪音；直接剔除。
        name_seq: Optional[int] = None
        q = query.strip()
        protagonist = (protagonist_name or "").strip()
        names = conn.execute(
            "SELECT name, segment_seq FROM story_character_lookup WHERE user_id=?",
            (user_id,),
        ).fetchall()
        hits = []
        for r in names:
            nm = (r["name"] or "").strip()
            if protagonist and nm == protagonist:
                continue  # 主角名不作为人名命中依据，避免引来历史 RAG 素材
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


def _schedule_rag_build(user_id: str, segment_seq: int, script_id: str,
                        content: str, names=None) -> None:
    """普通轮 RAG 构建：人名登记 + 后台原文切块嵌入（异步，不阻塞生成流）。"""
    if not content or not content.strip() or not _rag_enabled():
        return
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


async def _rag_trigger_build_task(
    user_id: str, current_seq: int, script_id: str, content: str, names, key
) -> None:
    """触发轮：先构建当前章节向量（await）；成功后再检测该用户缺向量的章节，
    按"补一条成功再续一条"的顺序补，最多 RAG_BACKFILL_BATCH 条；任一条失败即停。
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
                    user_id, r["segment_seq"], r["current_script_id"] or "",
                    r["content"], None, bkey,
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


def _schedule_rag_trigger_build(user_id: str, segment_seq: int, script_id: str,
                                content: str, names) -> None:
    """触发轮入口：seq 非零且被 RAG_BACKFILL_EVERY 整除时，
    当前章节构建 + 顺序补建合并在一个后台任务里。"""
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


def _seq_of_script_chapter(user_id: str, script_no: int, chapter: int) -> Optional[int]:
    """取 (script_no, chapter) 行的 seq（章节落库后给 RAG 用）。"""
    conn = _db()
    try:
        row = conn.execute(
            """SELECT seq FROM story_segments
               WHERE user_id=? AND current_script_id=?
               ORDER BY seq DESC LIMIT 1""",
            (user_id, f"{script_no}-{chapter}"),
        ).fetchone()
        return row["seq"] if row is not None else None
    finally:
        conn.close()


def _schedule_rag_after_persist(user_id: str, script_no: int, chapter: int,
                                content: str, names) -> None:
    """章节正文落库成功后调用：按原逻辑触发 RAG 人名登记 + 原文切块嵌入（异步）。

    规则同旧版：seq 被 RAG_BACKFILL_EVERY 整除 → 触发轮（当前章 + 顺序补建）；
    否则普通轮（fire-and-forget 单章构建）。全程不阻塞生成流。
    """
    if not content or not content.strip() or not _rag_enabled():
        return
    seq = _seq_of_script_chapter(user_id, script_no, chapter)
    if seq is None:
        return
    sid = f"{script_no}-{chapter}"
    if _is_rag_trigger_seq(seq):
        _schedule_rag_trigger_build(user_id, seq, sid, content, names)
    else:
        _schedule_rag_build(user_id, seq, sid, content, names)








# ================= 分章节大纲：新小说并发会话（2026-09 新逻辑） =================
# 一次"开新小说"的大纲流会话：第 1 章大纲一就绪即建占位行并放行正文开写（打字机加速）；
# 其余章大纲收齐 + check_result 判定后再建行；check 未通过则删除本小说全部行并标记 rejected。
# 生成器用 ch1_event / done_event + 心跳轮询推进；失败以 error 呈现。

def _persist_new_novel_atomic(
    user_id: str, device_id: str, login_ts: Optional[int], script_no: int,
    settings: dict, meta: dict,
    ch1_outline: str, ch1_body: str, chapters: dict,
    choice_1: str = "", choice_2: str = "", choice_3: str = "",
    lead: Optional[dict] = None,
) -> str:
    """整本一次性原子落库（金标准 + 写者守卫）。

    一次逻辑写单元：同一条事务内 校验口令 → [可选 lead：把"老小说末章"延迟回填
    （正文已在本次 worker 生成、开新小说时暂存）] → ch1(大纲+正文+选项+设定) +
    2..N(仅大纲)，全部因果写一次集中完成 → COMMIT。
    lead 形如 {"script_no","chapter","content","settings","meta",
              "choice_1","choice_2","choice_3"}；None 表示无合并。
    这样"老小说的结尾 + 新小说(ch1 + 十章大纲)"同生共死：要么都在、要么都不在；
    中间任何一步被新设备顶掉（conflict）都整批回滚，绝不留下
    "老结尾已落、新小说被拒"的无下一章占位死胡同。
    返回：
      'ok'       写入 / 该 script_no 已存在则跳过（视为成功）；
      'conflict' 口令不符（本设备已被更新的设备顶掉）→ 一个字节都不写；
      'fail'     其它异常，整体回滚。
    """
    if not ch1_body or not ch1_body.strip():
        return "fail"

    def _w(conn: sqlite3.Connection) -> None:
        # （可选）合并"老小说末章"的延迟回填：与本本同一条事务一起原子落库。
        if lead is not None:
            _l_sn = int(lead["script_no"])
            _l_ch = int(lead["chapter"])
            _l_cur = f"{_l_sn}-{_l_ch}"
            _l_row = conn.execute(
                """SELECT seq FROM story_segments
                   WHERE user_id=? AND current_script_id=? ORDER BY seq DESC LIMIT 1""",
                (user_id, _l_cur),
            ).fetchone()
            if _l_row is None:
                logger.warning("PERSIST lead 找不到 %s 占位行，跳过合并回填", _l_cur)
            else:
                _ls = lead.get("settings") or {}
                _lm = lead.get("meta") or {}
                conn.execute(
                    """UPDATE story_segments
                          SET content=?, choice_1=?, choice_2=?, choice_3=?,
                              user_choice=?, music_style=?,
                              location=?, era=?, player_name=?, player_traits=?,
                              language=?, current_aura=?
                        WHERE user_id=? AND current_script_id=? AND seq=?""",
                    (
                        lead.get("content") or "",
                        lead.get("choice_1") or "",
                        lead.get("choice_2") or "",
                        lead.get("choice_3") or "",
                        "",
                        _lm.get("music_style") or "",
                        _ls.get("location") or "",
                        _ls.get("era") or "",
                        _ls.get("player_name") or "",
                        _ls.get("player_traits") or "",
                        _language_name(_ls.get("language")),
                        _lm.get("current_aura") or "",
                        user_id, _l_cur, _l_row["seq"],
                    ),
                )
                logger.warning(
                    "PERSIST lead 合并回填 ok s=%d ch=%d", _l_sn, _l_ch)
        exist = conn.execute(
            """SELECT COUNT(*) AS c FROM story_segments
               WHERE user_id=? AND current_script_id LIKE ?""",
            (user_id, f"{script_no}-%"),
        ).fetchone()["c"]
        if exist:
            logger.warning("PERSIST 重复整本 script_no=%s 跳过", script_no)
            return
        chs = set(int(k) for k in chapters)
        chs.add(1)
        now = int(time.time())
        for ch in sorted(chs):
            is_first = (ch == 1)
            outline = (ch1_outline if is_first else str(chapters.get(ch) or "")).strip()
            content = ch1_body if is_first else ""
            cur_id = f"{script_no}-{ch}"
            if is_first:
                conn.execute(
                    """INSERT INTO story_segments
                         (user_id, seq, content, outline, created_at,
                          choice_1, choice_2, choice_3, user_choice, music_style,
                          location, era, player_name, player_traits, language,
                          current_aura, completed_script_ids, current_script_id)
                       VALUES (?,?,?,?,?, ?,?,?,?,?, ?,?,?,?,?, ?,?,?)""",
                    (
                        user_id, _next_seq(user_id, conn), content, outline, now,
                        choice_1, choice_2, choice_3, "",
                        meta.get("music_style") or "",
                        settings.get("location") or "",
                        settings.get("era") or "",
                        settings.get("player_name") or "",
                        settings.get("player_traits") or "",
                        _language_name(settings.get("language")),
                        meta.get("current_aura") or "",
                        "", cur_id,
                    ),
                )
            else:
                conn.execute(
                    """INSERT INTO story_segments
                         (user_id, seq, content, outline, created_at,
                          current_script_id)
                       VALUES (?,?,?,?,?,?)""",
                    (
                        user_id, _next_seq(user_id, conn), content, outline, now,
                        cur_id,
                    ),
                )

    try:
        _run_write_unit(user_id, device_id, login_ts, _w)
        return "ok"
    except StoryWriteConflict:
        logger.warning("PERSIST 口令不符（被顶掉），整本未写 s=%d", script_no)
        return "conflict"
    except Exception as e:
        logger.warning("PERSIST 整本原子落库失败（整体回滚）: %s", e, exc_info=True)
        return "fail"


class OutlineSession:
    """一次"开新小说"的大纲流会话（金标准：不提前建行/分步落库）。

    打字机取到 ch1 大纲就放行正文流（可在 App 打字机显示），但**不写库**；
    必须等整份大纲（1..N）+ check_result + 第 1 章正文都齐后，由调用方一次性原子落库。
    """

    def __init__(self, user_id: str, script_no: int, settings: dict,
                 the_script: Optional[str] = None):
        self.user_id = user_id
        self.script_no = script_no
        self.settings = dict(settings or {})
        self.the_script = the_script or ""   # 本次开新小说抽签组合出的故事底稿（the_script）
        self.ch1 = ""                    # 增量切出/兜底得到的第 1 章大纲（供驱动正文）
        self.chapters: dict = {}         # {chapter:int: outline:str}（check 通过后的全量 1..N）
        self.check: Optional[bool] = None
        self.error: Optional[str] = None
        self.rejected = False            # check_result != true
        self.persisted = False           # 本小说是否已一次性原子落库
        self.ch1_event = asyncio.Event()
        self.done_event = asyncio.Event()
        self.last_activity = time.time() # 最近收到 Dify 大纲实质内容的时刻（驱动"大纲活动心跳"）

    def _activity(self) -> None:
        self.last_activity = time.time()

    async def _on_ch1(self, text: str) -> None:
        """第 1 章大纲增量切出：只记录并放行正文流；不建行（落库在整本齐后一次做）。"""
        self.ch1 = (text or "").strip()
        self._activity()
        self.ch1_event.set()

    async def run(self) -> None:
        """驱动大纲流直至结束；全程不写库。"""
        try:
            result = await _request_outline_chapters(
                self.settings, self.user_id, self.script_no,
                on_chapter1=self._on_ch1, on_activity=self._activity,
                the_script=self.the_script,
            )
            self.chapters = result.get("chapters") or {}
            self.check = result.get("check")
            # 兜底1：流式没切出 ch1 但结果带 chapter1_early
            if not self.ch1 and result.get("chapter1_early"):
                self.ch1 = str(result["chapter1_early"]).strip()
            # 兜底2（金标准）：切分失败但整份 parse 里有 chapter_script_01
            if not self.ch1 and self.chapters.get(1):
                self.ch1 = str(self.chapters[1]).strip()
            if self.ch1 and not self.ch1_event.is_set():
                self.ch1_event.set()
            self._activity()
            if self.check is not True:
                self.rejected = True
                logger.warning(
                    "OUTLINE check 未通过（不落库）script_no=%s", self.script_no
                )
            # check 通过：不建行；等第 1 章正文 + 本会话都完成后由调用方原子落库
        except httpx.TimeoutException:
            self.error = "大纲生成超时"
            logger.warning("OUTLINE 超时 script_no=%s", self.script_no)
        except httpx.RequestError as exc:
            self.error = f"大纲请求网络异常: {exc}"
            logger.warning("OUTLINE RequestError: %s", exc)
        except Exception as e:
            self.error = str(e)
            logger.warning("OUTLINE 异常: %s", e, exc_info=True)
        finally:
            if not self.ch1_event.is_set():
                self.ch1_event.set()   # 防止生成器死等；ch1 为空由调用方判失败
            self._activity()
            self.done_event.set()


async def _outline_activity_events(session: OutlineSession, ev: asyncio.Event):
    """等待 session 的某个事件，期间若 Dify 大纲近期有实质内容则节流发"大纲活动心跳"。

    每收到实质内容都会刷新 session.last_activity（由 _request 回调查到）；
    本生成器约每 5s 一次、仅在"最近有活动"时 yield 心跳事件字典（由调用方 _sse 转发）。
    Dify 真卡住 ≥30s → 无活动无心跳 → run() 读超时置 error → 本循环随 ev/error 退出。
    绝不在"无内容"时无限发心跳。
    """
    last_hb = 0.0
    while True:
        if ev.is_set() or session.error is not None:
            return
        now = time.time()
        if now - last_hb >= 5.0 and (now - session.last_activity) <= 6.0:
            last_hb = now
            yield {"event": "heartbeat", "message": "正在等待完整大纲"}
        await asyncio.sleep(0.25)




# ---------------- 同用户"生成 worker"闸门：按【口令（device_id + login_ts）】限流 ----------------
# 规则：同一个口令同时最多存活一个生成 worker；不同口令各自允许一个、互不顶替：
#   - 同口令重复请求（App 双击 / HTTP 层重复投递）→ 拒绝（入口返回空 SSE，App 走重启同步）；
#   - 重启 App / 换设备登入会产生【新 login_ts / 新口令】→ 允许它再起一个 worker；
#     旧口令的 worker 若仍在跑，会因登录已过期、在落库时被"写者守卫"口令不符拒绝，
#     不会写脏数据（仅白烧一次 token），跑完即释放，不会越积越多。
#   - 每个口令的锁带 15 分钟租约：该口令 worker 真卡死超 15 分钟，同口令新请求可强占。
# 生效范围是"进程内"（当前 uvicorn 单进程）；多进程部署须改用共享注册表。
# key = (device_id, login_ts)；value = {"since": float, "user_id": str}
_GEN_BUSY: dict = {}
_GEN_BUSY_LEASE_S = 15 * 60   # 防呆：同口令锁超时视为僵尸，允许后到者强占


def _gen_busy_key(device_id: str, login_ts):
    return (device_id, login_ts)


def _gen_try_claim(user_id: str, device_id: str, login_ts) -> bool:
    now = time.time()
    key = _gen_busy_key(device_id, login_ts)
    ent = _GEN_BUSY.get(key)
    if ent is None:
        _GEN_BUSY[key] = {"since": now, "user_id": user_id}
        return True
    if now - ent["since"] > _GEN_BUSY_LEASE_S:
        logger.warning("GATE 强占僵尸口令锁 dev=%s login_ts=%s", device_id, login_ts)
        _GEN_BUSY[key] = {"since": now, "user_id": user_id}
        return True
    # 同一口令已有存活 worker → 重复请求，拒绝
    logger.warning("GATE 口令 dev=%s login_ts=%s 已有 worker，拒绝重复请求", device_id, login_ts)
    return False


def _gen_release(user_id: str, device_id=None, login_ts=None) -> None:
    """worker 跑完释放对应【口令】的注册；不同口令互不影响，无需按 user 比对。"""
    if device_id is None:
        return
    _GEN_BUSY.pop(_gen_busy_key(device_id, login_ts), None)


def _gen_refuse_response():
    """第二个并发请求：返回一个"立即结束、零事件"的 SSE。

    App 端读到 EOF 但未收到 done → 走 story_service 的 post-loop onStalled →
    “网络异常，请重启”→ 重启后启动同步以数据库为准对齐。全程不新起 worker。
    """

    async def _empty():
        if False:  # 使本函数成为异步生成器（不产出任何事件，立即 EOF）
            yield None

    return StreamingResponse(
        _empty(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


def _single_flight_generate(fn):
    """装饰 /api/generate-story：同会话防重（新登入可顶替旧 worker）。

    拿锁必须在入口（任何 DB 写入/截断之前）；释放走两条路且都幂等：
      - fn 正常返回 StreamingResponse → 由后台 worker 的 finally 释放；
      - fn 在返回流之前抛异常（400/429/预算等）→ 此处释放后重抛，防锁泄漏。
    """

    async def wrapper(data: StoryInputData, request: Request):
        token = _extract_token(data, request)
        claims = validate_token(token)
        user_id = claims["user_id"]
        device_id = claims["device_id"]
        login_ts = claims.get("login_ts")
        _enforce_active_device(user_id, device_id)
        if not _gen_try_claim(user_id, device_id, login_ts):
            # 拒因已在 _gen_try_claim 内记录（同一口令已有存活 worker）
            return _gen_refuse_response()
        try:
            return await fn(data, request)
        except BaseException:
            _gen_release(user_id, device_id, login_ts)
            raise

    return wrapper


# ================= 路由：小说生成（流式：每满 400 字增量审核 → 通过即 chunk/reveal 显示） =================
@app.post("/api/generate-story")
@_single_flight_generate
async def generate_story(data: StoryInputData, request: Request):
    token = _extract_token(data, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    login_ts = claims.get("login_ts")
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

    # 用户本轮"实际选择"文本：App 显式上传 user_choice（点的是哪个输入框，其文本即此值，
    # 写入 DB user_choice 列并作为发给 Dify 的 user_choice）；缺省时用 user_input 兜底，
    # 保证该值一定传递到 Dify（user_choice 与 user_input 在本协议里同义）。
    chosen_choice = (data.user_choice or data.user_input or "")

    # 用户最新选择持久化（受写者守卫保护的逻辑写单元）：无论最新一段，还是时间树
    # "从这里重新开始"的历史段，把三个输入框当前值覆盖到对应段的 choice_1/2/3。
    # 口令不符（本设备已被顶掉）→ 不写任何字节，直接在入口 409"多客户端"，不开始生成。
    def _save_choices(conn: sqlite3.Connection) -> None:
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
                    chosen_choice,  # 用户本轮实际选择文本
                    user_id,
                    data.rewrite_from,
                ),
            )
        else:
            # 最新一段续写：覆盖到"最新已生成正文段"。
            # 注意：占位模型下不能取 MAX(seq)——当前小说 2..10 章的占位行 seq 都排在
            # 已写正文之后，MAX(seq) 恒为小说末尾那行"空占位章"，会把用户的选择写错行。
            # 必须以【正文非空】的最新一行为准（口径同 _latest_written_segment）。
            conn.execute(
                """UPDATE story_segments
                      SET choice_1=?, choice_2=?, choice_3=?, user_choice=?
                    WHERE user_id=?
                      AND seq=(SELECT MAX(seq) FROM story_segments
                                WHERE user_id=? AND TRIM(COALESCE(content,'')) <> '')""",
                (
                    data.choice_1 or "",
                    data.choice_2 or "",
                    data.choice_3 or "",
                    chosen_choice,  # 用户本轮实际选择文本
                    user_id,
                    user_id,
                ),
            )

    try:
        _run_write_unit(user_id, device_id, login_ts, _save_choices)
    except StoryWriteConflict:
        logger.warning("GEN 入口口令不符（被顶掉），拒绝开始生成")
        raise HTTPException(status_code=409, detail="multi_client")
    except Exception:
        # 保存用户选择失败不影响生成主流程
        logger.warning("保存用户选择失败", exc_info=True)

    # 小说生成工作流全局每日配额（默认 1000 次 / 24 小时滚动）
    _check_story_quota(int(time.time()))

    # 时间树"从这里重写"（2026-09 大纲化规则）：
    # - 被点击章 K 所在小说 script_no = sc_k；
    # - 删除"更晚换大纲/换小说"后的所有条目：script_no > sc_k 的全部行（大纲+正文一起删）；
    # - 同小说内只把 seq > K 的正文清空（content=''），大纲行保留不变（据此重写正文）。
    # 之后的生成目标 = sc_k 的 K+1 章占位行（若 K 是末章则自动开新小说）。
    if data.rewrite_from is not None and data.rewrite_from >= 0:

        def _rewrite_truncate(conn: sqlite3.Connection) -> None:
            sc_k = None
            _cr = conn.execute(
                """SELECT current_script_id FROM story_segments
                   WHERE user_id=? AND seq=?""",
                (user_id, data.rewrite_from),
            ).fetchone()
            if _cr is not None:
                _m = _parse_cur_script_id(_cr["current_script_id"])
                if _m is not None:
                    sc_k = _m[0]
            if sc_k is None:
                # 无法定位所在小说（异常态）：不再按旧数据规则整体截断，仅记录并跳过
                logger.warning(
                    "时间树重写定位不到脚本号 seq=%s（跳过截断）", data.rewrite_from
                )
            else:
                # 删除更晚小说的全部条目（script_no > sc_k）
                conn.execute(
                    """DELETE FROM story_segments
                       WHERE user_id=?
                         AND TRIM(COALESCE(current_script_id,'')) <> ''
                         AND CAST(substr(current_script_id, 1,
                                         instr(current_script_id,'-')-1) AS INTEGER) > ?""",
                    (user_id, sc_k),
                )
                # 同小说内 seq > K：只清正文，保留大纲
                conn.execute(
                    """UPDATE story_segments
                          SET content=''
                        WHERE user_id=? AND seq > ?
                          AND TRIM(COALESCE(current_script_id,'')) <> ''
                          AND CAST(substr(current_script_id, 1,
                                          instr(current_script_id,'-')-1) AS INTEGER) = ?""",
                    (user_id, data.rewrite_from, sc_k),
                )
            # RAG 同步删除：seq > rewrite_from 的向量/人名/提纯
            _purge_rag_for_user(user_id, conn, min_seq=data.rewrite_from)

        try:
            _run_write_unit(user_id, device_id, login_ts, _rewrite_truncate)
        except StoryWriteConflict:
            logger.warning("GEN 时间树重写口令不符（被顶掉），拒绝开始生成")
            raise HTTPException(status_code=409, detail="multi_client")
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
            # ---- 目标章解析（2026-09 大纲化）----
            # 全新故事 / 无下一章占位行 → 开新小说（大纲流并发，ch1 就绪即写）；
            # 续写 → 读最新已写正文行，找下一章大纲占位行作为本次目标。
            sessions: list = []           # 本次请求里启动过的新小说大纲会话
            cur_session: Optional[OutlineSession] = None   # 当前正在写的小说所属会话（若本次开）

            async def _open_novel_events(script_no: int):
                """开第 script_no 本新小说：起大纲会话；用"大纲活动心跳"等 ch1 就绪。

                全程不落库（金标准：整本大纲+check+第1章正文齐后由收尾一次性原子落库）。
                成功把 pre_case_meta 置为第 1 章目标；失败保持 None（调用方静默关闭）。
                """
                nonlocal pre_case_meta, cur_session
                # 每次开新小说：先把机密框架抽签组合成 the_script 底稿。
                # 组合只做一次，弹窗预览与实际发送共用同一份（所见即所得）。
                o_script = _compose_the_script()
                if o_script:
                    logger.warning(
                        "OUTLINE the_script composed script_no=%s len=%d",
                        script_no, len(o_script),
                    )
                # 【调试】申请大纲前：把将要发给 Dify 的全部变量发回 App 弹窗确认
                # （outline_debug_payload），弹窗期间每 15s 发 heartbeat 续命，避免 App
                # 30s 空闲误判超时；用户确认（POST /api/generate-story/confirm）后才真正
                # 调大纲流；确认后其余逻辑与原来完全一致。
                if OUTLINE_DEBUG_PREVIEW:
                    o_inputs = _outline_inputs(
                        settings, user_id, script_no, the_script=o_script)
                    o_payload = {
                        "inputs": o_inputs,
                        "response_mode": "streaming",
                        "user": user_id,
                    }
                    o_request_id = secrets.token_hex(16)
                    o_confirm_ev = asyncio.Event()
                    _pending_payload_confirm[o_request_id] = o_confirm_ev
                    try:
                        logger.warning("DBG outline debug_payload sent id=%s", o_request_id)
                        yield {"event": "outline_debug_payload",
                               "request_id": o_request_id,
                               "payload": o_payload}
                        o_waited = 0.0
                        while not o_confirm_ev.is_set():
                            if _conn_state["client_gone"]:
                                break
                            if o_waited >= DEBUG_PAYLOAD_CONFIRM_TIMEOUT:
                                yield {"event": "error",
                                       "message": "等待大纲确认超时，已取消本次生成"}
                                return
                            try:
                                await asyncio.wait_for(o_confirm_ev.wait(), timeout=15)
                            except asyncio.TimeoutError:
                                o_waited += 15
                                yield {"event": "heartbeat",
                                       "message": "等待确认后生成大纲"}
                        if o_confirm_ev.is_set():
                            logger.warning("DBG outline confirmed id=%s", o_request_id)
                        else:
                            logger.warning("DBG outline wait exited unconfirmed (client_gone) id=%s", o_request_id)
                    finally:
                        _pending_payload_confirm.pop(o_request_id, None)
                session = OutlineSession(
                    user_id, script_no, settings, the_script=o_script)
                sessions.append(session)
                cur_session = session
                asyncio.get_running_loop().create_task(session.run())
                async for _ev in _outline_activity_events(session, session.ch1_event):
                    yield _ev
                if session.error is not None:
                    logger.warning(
                        "OUTLINE 开新小说失败（静默关闭）script_no=%s err=%s",
                        script_no, session.error,
                    )
                    return
                if not session.ch1:
                    logger.warning(
                        "OUTLINE 未产出第 1 章（静默关闭）script_no=%s", script_no
                    )
                    return
                pre_case_meta = {
                    "script_id": script_no,
                    "chapter": 1,
                    "chapter_text": session.ch1,
                    "choice_2": "",
                    "choice_3": "",
                }

            _latest = _latest_written_segment(user_id)
            if _latest is None:
                # 全新故事 → 新小说 #1（静默失败则本请求结束 → App 断网弹窗重启）
                async for _ev in _open_novel_events(1):
                    yield _sse(_ev)
                logger.warning(
                    "DBG fresh novel #1 post-outline pre_case_meta=%s",
                    "SET" if pre_case_meta is not None else "None",
                )
                if pre_case_meta is None:
                    return
            else:
                _parsed = _parse_cur_script_id(_latest["current_script_id"])
                _target = None
                if _parsed is not None:
                    _pl = _find_placeholder(user_id, _parsed[0], _parsed[1] + 1)
                    if _pl is not None and (_pl["outline"] or "").strip():
                        _target = {
                            "script_id": _parsed[0],
                            "chapter": _parsed[1] + 1,
                            "chapter_text": (_pl["outline"] or "").strip(),
                            "choice_2": "",
                            "choice_3": "",
                        }
                if _target is not None:
                    pre_case_meta = _target
                else:
                    # 防御性：无下一章占位行 → 开新小说（script_no = 最新小说号 + 1）
                    _new_no = (_parsed[0] + 1) if _parsed is not None else 1
                    async for _ev in _open_novel_events(_new_no):
                        yield _sse(_ev)
                    if pre_case_meta is None:
                        return

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
                                settings.get("player_name") or "",
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
                    "corrent_case_all_content": corrent_case_all_content,
                    "user_choice": chosen_choice,
                    "chapter_script": (pre_case_meta or {}).get("chapter_text") or "",
                    # RAG：之前脚本的整章记忆（无命中为空串）
                    "rag_context": rag_context or "",
                },
                "response_mode": "streaming",
                "user": user_id,
            }

            # 【调试】生成前确认：调 Dify 之前先把 payload 发回 App 弹窗，
            # 等 App 用户点击确认后（POST /api/generate-story/confirm）才真正调 Dify。
            # 等待期间每 15s 发一个 heartbeat（与 revise_confirm 弹窗同一套机制），
            # 让 App 重置其 30s 滚动计时，避免 payload 弹窗一直开着时被误判"网络超时"。
            if DEBUG_PAYLOAD_PREVIEW:
                request_id = secrets.token_hex(16)
                confirm_ev = asyncio.Event()
                _pending_payload_confirm[request_id] = confirm_ev
                try:
                    logger.warning("DBG story debug_payload sent id=%s", request_id)
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
                            # heartbeat：与审核确认弹窗同款维持心跳，重置 App 30s 计时
                            yield _sse({"event": "heartbeat",
                                        "message": "等待确认后发送 payload"})
                    if confirm_ev.is_set():
                        logger.warning("DBG story confirmed id=%s", request_id)
                    else:
                        logger.warning("DBG story wait exited unconfirmed (client_gone) id=%s", request_id)
                finally:
                    _pending_payload_confirm.pop(request_id, None)

            # 当前累计的案件正文（每段落库后更新，作为下一段 Dify 的续写上下文）
            current_case_content = corrent_case_all_content
            # 连续换脚本的护栏：避免脚本全无 choice2/3 时无限循环
            switch_guard = 0
            # 换脚本场景的"暂存段"：脚本耗尽生成的段先不落库，待下一段成功后再一起原子落库
            pending_segments: list = []
            # "跨小说原子边界"暂存：老小说末章正文先不单章落库，暂存为 lead，
            # 待同一条 worker 内新小说(ch1+大纲)完整后，与它同一条写事务原子落库
            # （否则两个提交之间被新设备顶掉 → 老结尾已落、新小说被拒 → 死胡同）。
            _defer_lead: Optional[dict] = None

            # 同一请求内可能连续生成多"段"（如老小说末章自动续 → 新小说第一章）。
            # 自第 2 段起，每开启新的一段先向 App 发 segment_begin，让 App 另起一个
            # 新的文本框显示（并在段间插入"新小说"分隔线），避免两本小说的正文
            # 被拼进同一个文本框里、贴在一起造成阅读混乱。
            seg_iter = 0

            # 段落生成循环：脚本当前章节 choice2/3 为空（脚本耗尽/无选择）时，
            # 先落库本段、更新 completed_script_ids、选出"最少使用"的新脚本，
            # 再像首段一样生成下一段……直到有可用选择才发送 done。
            while True:
                seg_iter += 1
                if seg_iter > 1:
                    # 开启新的一段（跨小说第一章等）：通知 App 拆分文本框。
                    # 放在任何正文 chunk/reveal 之前，保证 App 先收到段边界再收文本。
                    yield _sse({"event": "segment_begin"})
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
                        # 续写上下文：当前正文原文
                        "corrent_case_all_content": current_case_content,
                        "user_choice": chosen_choice,
                        # 当前章节大纲（续写轮无新选取则为空）
                        "chapter_script": (pre_case_meta or {}).get("chapter_text") or "",
                        # RAG：之前脚本的整章记忆（无命中为空串）
                        "rag_context": rag_context or "",
                    },
                    "response_mode": "streaming",
                    "user": user_id,
                }

                # 【调试】同一请求内“老小说完本→自动开新小说”时，新小说第一章也是
                # 一次独立的 Dify 小说流调用——首段 debug_payload（循环外的唯一一次）
                # 只覆盖了老小说末章，新小说第一章在这里再弹一次“发给 Dify 的 JSON”，
                # 让用户确认后才真正调用。仅对“本请求内新开、尚未整本落库的会话”的第 1 章生效；
                # 正常续写（seg_iter==1）由循环外那次覆盖，不重复弹。
                if (DEBUG_PAYLOAD_PREVIEW and seg_iter > 1
                        and pre_case_meta is not None):
                    _need_story_debug = False
                    for _s in sessions:
                        if (not _s.persisted
                                and _s.script_no
                                == int(pre_case_meta.get("script_id") or 0)
                                and int(pre_case_meta.get("chapter") or 0) == 1):
                            _need_story_debug = True
                            break
                    if _need_story_debug:
                        _req_id = secrets.token_hex(16)
                        _ev2 = asyncio.Event()
                        _pending_payload_confirm[_req_id] = _ev2
                        try:
                            logger.warning(
                                "DBG story(new-novel ch1) debug_payload sent id=%s",
                                _req_id)
                            yield _sse({
                                "event": "debug_payload",
                                "request_id": _req_id,
                                "payload": seg_payload,
                            })
                            _w2 = 0.0
                            while not _ev2.is_set():
                                if _conn_state["client_gone"]:
                                    break
                                if _w2 >= DEBUG_PAYLOAD_CONFIRM_TIMEOUT:
                                    yield _sse({
                                        "event": "error",
                                        "message": "等待 App 确认超时，已取消本次生成",
                                    })
                                    return
                                try:
                                    await asyncio.wait_for(_ev2.wait(), timeout=15)
                                except asyncio.TimeoutError:
                                    _w2 += 15
                                    yield _sse({
                                        "event": "heartbeat",
                                        "message": "等待确认后发送新小说正文 payload",
                                    })
                            if _ev2.is_set():
                                logger.warning(
                                    "DBG story(new-novel ch1) confirmed id=%s", _req_id)
                            else:
                                logger.warning(
                                    "DBG story(new-novel ch1) unconfirmed (client_gone) id=%s",
                                    _req_id)
                        finally:
                            _pending_payload_confirm.pop(_req_id, None)

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
                          已满 REVISE_MAX_ATTEMPTS 轮仍不过 → 【放行】直接送出（不再中止）；
                          修正失败 / 未配置 / 用户确认超时 → 回退 yield abort（弹窗"重新输入"）；
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
                            已满 cap 轮仍不过 → 【放行】（直接送出当前修正稿，audit_aborted=False）；
                            修正失败/未配置/用户确认超时 → 已 yield abort 并置 audit_aborted=True。
                            （async generator 不能 return 值，用 audit_aborted 作成功/失败信号。）
                            """
                            nonlocal text_arg, full_text, displayed_len, audit_no, sent_first, audit_aborted, _audit_base
                            attempts = 0
                            cur_text = audit_text
                            cur_verdict = verdict
                            while True:
                                attempts += 1
                                logger.warning(
                                    "STREAM audit REJECT → 修正第 %d 轮 win=[%d,%d) text_len=%d",
                                    attempts, win_start, win_end, len(cur_text or ""),
                                )
                                # REVISE_MAX_ATTEMPTS<=0 = 不限修正轮数（实验用）。
                                # 已尝试满 cap 轮仍不过 → 【放行】：不再中止/不再弹窗/不再无限循环，
                                # 直接把当前修正稿 cur_text 按"审核通过"送出，继续后续流程。
                                if REVISE_MAX_ATTEMPTS > 0 and attempts > REVISE_MAX_ATTEMPTS:
                                    logger.warning(
                                        "STREAM audit 已尝试 %d 轮修正仍不过 → 放行 "
                                        "（不再中止）win=[%d,%d) len=%d",
                                        attempts, win_start, win_end, len(cur_text or ""),
                                    )
                                    audit_aborted = False
                                    if win_start > 0:
                                        yield {
                                            "event": "reveal",
                                            "text": cur_text,
                                            "outputs": {},
                                        }
                                    else:
                                        yield {"event": "chunk", "text": cur_text}
                                    displayed_len = len(text_arg)
                                    sent_first = True
                                    _audit_base = len(text_arg)
                                    audit_no = 1
                                    return
                                # 修正前先请用户确认：把待修正文本 + 违规判定 JSON 发回 App 弹窗，
                                # 用户点击"送 Dify 修正"（POST /api/generate-story/revise-confirm）后
                                # 才真正调用修正工作流；超时/客户端断联则回退 abort 弹窗。
                                request_id = secrets.token_hex(16)
                                confirm_ev = asyncio.Event()
                                _pending_revise_confirm[request_id] = confirm_ev
                                try:
                                    logger.warning(
                                        "STREAM 发出 revise_confirm request_id=%s text_len=%d",
                                        request_id, len(cur_text or ""),
                                    )
                                    yield {
                                        "event": "revise_confirm",
                                        "request_id": request_id,
                                        "text": cur_text,
                                        "verdict": cur_verdict,
                                    }
                                    waited = 0.0
                                    while not confirm_ev.is_set():
                                        if _conn_state["client_gone"]:
                                            logger.info("STREAM 客户端已断联，跳过修正确认直接继续")
                                            break
                                        if waited >= REVISE_CONFIRM_TIMEOUT:
                                            audit_aborted = True
                                            yield _moderation_failure_sse(
                                                ModerationOutcome.REJECT, cur_text
                                            )
                                            return
                                        try:
                                            await asyncio.wait_for(
                                                confirm_ev.wait(), timeout=15
                                            )
                                        except asyncio.TimeoutError:
                                            waited += 15
                                            logger.warning(
                                                "STREAM 等修正确认 15s 未确认 request_id=%s waited=%.0f/%s",
                                                request_id, waited, REVISE_CONFIRM_TIMEOUT,
                                            )
                                            # 弹窗仍开着、用户还没点：持续发心跳，让 App 30s 空闲不误断
                                            yield {"event": "heartbeat",
                                                    "message": "等待修正确认中"}
                                    if confirm_ev.is_set():
                                        # 用户点了"送 Dify 修正"：补一次心跳，重置 App 30s 倒计时
                                        logger.warning(
                                            "STREAM 收到修正确认 request_id=%s", request_id)
                                        yield {"event": "heartbeat",
                                                "message": "修正确认已收到"}
                                finally:
                                    _pending_revise_confirm.pop(request_id, None)
                                # 等修正工作流（阻塞式 Dify，30s 读超时兜底；不再发心跳）
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
                                if not revised or not revised.strip():
                                    # 修正失败 / 未配置修正工作流：回退现有 abort 弹窗
                                    audit_aborted = True
                                    yield _moderation_failure_sse(
                                        ModerationOutcome.REJECT, cur_text
                                    )
                                    return
                                # 覆盖违规段（text_arg 与 full_text 同步更新，后续 text_chunk 沿用修正后正文）。
                                # 第 1 轮 cur_text 只覆盖原违规窗口 [win_start, win_end) → 替换后保留 win_end 之后原尾部；
                                # 第 2 轮起 cur_text = remainder = text_arg[win_start:]（覆盖到当前文本末尾，
                                # 且 text_arg 长度已在上一轮替换后改变）：若仍按旧的 win_end 保留"尾部"
                                # 会截进已修正文本、造成重复/丢字 → 改为整体替换 win_start 之后全部内容
                                # （revised 已把 remainder 整体重写，无需再留尾部）。
                                text_arg = (
                                    text_arg[:win_start]
                                    + revised
                                    + (text_arg[win_end:] if attempts == 1 else "")
                                )
                                full_text = text_arg
                                # 让客户端把当前段回滚到违规窗口起点，避免重叠区重复。
                                # 关键：仅当本段【已经 reveal 过内容】（displayed_len>0）才需要回滚；
                                # 若首窗即违规（displayed_len==0），客户端还没有本段的文本框，
                                # 此刻发 truncate 会把上一段（如跨小说时"老小说末章"那个已完成的文本框）
                                # 误清空 → 造成"老小说文本消失"。displayed_len==0 时跳过 truncate，
                                # 修正后的整段会由下方 chunk/reveal 全新建立文本框，无需回滚。
                                if displayed_len > 0:
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
                    # 不再发"纯粹心跳"：直接迭代 Dify 流式行；真实挂起由 httpx 读超时
                    # （STORY_DIFY_STREAM_TIMEOUT=30）兜底关闭，App 只在收到实质内容时重置其 30s。
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
                            if pre_case_meta is None:
                                yield _sse({"event": "error", "message": "缺少目标章信息，已终止本次生成"})
                                return
                            _sn = int(pre_case_meta.get("script_id"))
                            _ch = int(pre_case_meta.get("chapter"))
                            # 是否"本请求刚开的、尚未整本落库的新小说"
                            _pending_sess = next(
                                (s for s in sessions
                                 if s.script_no == _sn and not s.persisted),
                                None,
                            )
                            if _pending_sess is not None:
                                # ---- 新小说：两线都齐才一次性原子落库 ----
                                # 等大纲(1..N + check)收尾（期间按 Dify 实质内容发活动心跳）
                                if not _pending_sess.done_event.is_set():
                                    async for _ev in _outline_activity_events(
                                        _pending_sess, _pending_sess.done_event
                                    ):
                                        yield _sse(_ev)
                                if _pending_sess.error is not None:
                                    logger.warning(
                                        "STREAM outline 会话失败（静默关闭，未落库）s=%d err=%s",
                                        _sn, _pending_sess.error,
                                    )
                                    return
                                if (_pending_sess.rejected
                                        or _pending_sess.check is not True):
                                    # 合规不过：未落库 → 专属"大纲尺度过大"弹窗 → 重新开始
                                    logger.warning(
                                        "STREAM outline_rejected s=%d（未落库）", _sn)
                                    yield _sse({"event": "outline_rejected"})
                                    return
                                _chapters = (_pending_sess.chapters
                                             or {1: _pending_sess.ch1})
                                _n_max = (max(int(k) for k in _chapters)
                                          if _chapters else 1)
                                _new_is_last = _n_max <= 1
                                _c1 = meta.get("choice_1") or ""
                                _c2 = (meta.get("action_a") or "") if not _new_is_last else ""
                                _c3 = (meta.get("action_b") or "") if not _new_is_last else ""
                                fmeta = dict(meta)
                                fmeta["choice_1"] = _c1
                                fmeta["choice_2"] = _c2
                                fmeta["choice_3"] = _c3
                                _merged_lead = _defer_lead
                                _st = _persist_new_novel_atomic(
                                    user_id, device_id, login_ts, _sn,
                                    settings, fmeta,
                                    _pending_sess.ch1 or "",
                                    final_segment,
                                    _chapters,
                                    choice_1=_c1, choice_2=_c2, choice_3=_c3,
                                    lead=_merged_lead,
                                )
                                if _st == "conflict":
                                    logger.warning(
                                        "STREAM 落库口令不符（被顶掉）→ conflict s=%d", _sn)
                                    yield _sse({"event": "conflict",
                                                "reason": "multi_client"})
                                    return
                                if _st != "ok":
                                    logger.warning(
                                        "STREAM 整本原子落库失败（静默关闭）s=%d", _sn)
                                    return
                                _pending_sess.persisted = True
                                segment_ended = True
                                _defer_lead = None
                                logger.warning(
                                    "STREAM 整本原子落库 ok s=%d chs=%d is_last=%s lead=%s",
                                    _sn, len(_chapters), _new_is_last,
                                    _merged_lead is not None)
                                # RAG：新小说第 1 章正文已落库 → 人名登记 + 原文切块嵌入
                                _schedule_rag_after_persist(
                                    user_id, _sn, 1, final_segment,
                                    meta.get("characters") or [])
                                # RAG：合并进来的"老小说末章"正文同样已落库 → 一并触发 RAG
                                if _merged_lead is not None:
                                    _schedule_rag_after_persist(
                                        user_id,
                                        int(_merged_lead["script_no"]),
                                        int(_merged_lead["chapter"]),
                                        _merged_lead.get("content") or "",
                                        (_merged_lead.get("meta") or {}).get("characters") or [])
                                if not _new_is_last:
                                    yield _sse({"event": "done",
                                                "outputs": {**outputs, **fmeta}})
                                    return
                                # 仅一章：视为"末章" → 自动开新小说
                                switch_guard += 1
                                if switch_guard >= 5:
                                    yield _sse({"event": "done",
                                                "outputs": {**outputs, **fmeta}})
                                    return
                                logger.warning("STREAM 单章小说收尾，自动开新小说 s=%d", _sn)
                                current_case_content = ""
                                async for _ev in _open_novel_events(_sn + 1):
                                    yield _sse(_ev)
                                if pre_case_meta is None:
                                    return
                                break
                            # ---- 已落库小说的后续章节 ----
                            _next_pl = _find_placeholder(user_id, _sn, _ch + 1)
                            _is_last = _next_pl is None
                            _c1 = meta.get("choice_1") or ""
                            _c2 = (meta.get("action_a") or "") if not _is_last else ""
                            _c3 = (meta.get("action_b") or "") if not _is_last else ""
                            fmeta = dict(meta)
                            fmeta["choice_1"] = _c1
                            fmeta["choice_2"] = _c2
                            fmeta["choice_3"] = _c3

                            if _is_last:
                                # 本段是老小说"末章"（大纲耗尽），流程会在同一条 worker 内
                                # 自动开新小说 → 不立刻单章落库；把"老小说结尾"暂存为 lead，
                                # 待新小说(ch1+大纲)完整后由整本原子落库与它【同一条写事务】提交，
                                # 保证"老结尾 + 新小说"同生共死：要么都在、要么都不在。
                                # （否则两个提交之间被新设备顶掉 → 老结尾已落、新小说被拒，
                                #   数据库停留在"末章有正文却无下一章占位"的无输入框死胡同。）
                                logger.warning(
                                    "STREAM 老小说末章 s=%d ch=%d 暂存 lead，待与新小说原子落库",
                                    _sn, _ch)
                                _defer_lead = {
                                    "script_no": _sn,
                                    "chapter": _ch,
                                    "content": final_segment,
                                    "settings": settings,
                                    "meta": dict(meta),
                                    "choice_1": _c1,
                                    "choice_2": _c2,
                                    "choice_3": _c3,
                                }
                                switch_guard += 1
                                if switch_guard >= 5:
                                    # 连续自动开新小说已达护栏上限，不再开下一本：
                                    # 老小说到此确实收尾 → 把暂存的末章单独落库并收尾。
                                    _st2 = _fill_content_row(
                                        user_id, device_id, login_ts,
                                        _defer_lead["script_no"],
                                        _defer_lead["chapter"],
                                        _defer_lead["content"],
                                        _defer_lead["settings"],
                                        _defer_lead["meta"],
                                        choice_1=_defer_lead["choice_1"],
                                        choice_2=_defer_lead["choice_2"],
                                        choice_3=_defer_lead["choice_3"],
                                    )
                                    if _st2 == "conflict":
                                        logger.warning(
                                            "STREAM fill 口令不符（被顶掉）→ conflict s=%d ch=%d",
                                            _sn, _ch)
                                        yield _sse({"event": "conflict",
                                                    "reason": "multi_client"})
                                        return
                                    if _st2 == "ok":
                                        logger.warning(
                                            "STREAM 末章单独落库 ok s=%d ch=%d len=%d",
                                            _sn, _ch, len(final_segment))
                                        # RAG：末章正文已落库 → 人名登记 + 原文切块嵌入
                                        _schedule_rag_after_persist(
                                            user_id, _sn, _ch, final_segment,
                                            meta.get("characters") or [])
                                    else:
                                        logger.warning(
                                            "STREAM 末章单独落库失败 s=%d ch=%d", _sn, _ch)
                                    _defer_lead = None
                                    yield _sse({"event": "done",
                                                "outputs": {**outputs, **fmeta}})
                                    return
                                logger.warning(
                                    "STREAM 大纲耗尽（末章暂存），自动开新小说 s=%d", _sn)
                                current_case_content = ""
                                async for _ev in _open_novel_events(_sn + 1):
                                    yield _sse(_ev)
                                if pre_case_meta is None:
                                    # 新小说没能开起来：守"同生共死"，暂存末章一并放弃（不落库）。
                                    # 本请求无 done → App 走网络异常重启 → 以数据库为准回退到
                                    # chN-1 + chN 占位 → 用户可重续 chN，不丢故事也不留半截状态。
                                    logger.warning(
                                        "STREAM 开新小说失败，暂存末章一并放弃（原子）s=%d", _sn)
                                    _defer_lead = None
                                    return
                                segment_ended = True
                                break

                            # 非末章（大纲还有下一章占位）：本段单章落库，返回选项给用户
                            _st2 = _fill_content_row(
                                user_id, device_id, login_ts, _sn, _ch,
                                final_segment, settings, meta,
                                choice_1=_c1, choice_2=_c2, choice_3=_c3,
                            )
                            if _st2 == "conflict":
                                logger.warning(
                                    "STREAM fill 口令不符（被顶掉）→ conflict s=%d ch=%d",
                                    _sn, _ch)
                                yield _sse({"event": "conflict",
                                            "reason": "multi_client"})
                                return
                            if _st2 != "ok":
                                logger.warning(
                                    "STREAM fill 失败 s=%d ch=%d", _sn, _ch)
                            else:
                                logger.warning(
                                    "STREAM fill ok s=%d ch=%d len=%d is_last=%s",
                                    _sn, _ch, len(final_segment), _is_last,
                                )
                                # RAG：本章正文已落库 → 异步人名登记 + 原文切块嵌入（恢复原逻辑）
                                _schedule_rag_after_persist(
                                    user_id, _sn, _ch, final_segment,
                                    meta.get("characters") or [])
                            segment_ended = True
                            logger.warning("STREAM done (options) s=%d ch=%d", _sn, _ch)
                            yield _sse({"event": "done", "outputs": {**outputs, **fmeta}})
                            return

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
                            # 兜底：本次 Dify 流未走到 workflow_finished → 按既定规则本就不落库
                            # （新小说不会产生任何 DB 行）。若此刻仍挂着延迟的"老小说末章"lead
                            # （末章暂存后开新小说、新小说流却意外结束），为守"同生共死"，把末章
                            # 一并放弃（不落库）：DB 停在上一章 + 末章大纲占位，重启同步后用户
                            # 可重续末章再试新小说——绝不留下"末章已落、下一本没有"的半截状态。
                            if _defer_lead is not None:
                                logger.warning(
                                    "STREAM fallback 无收尾输出：暂存末章一并放弃（原子）s=%d",
                                    _defer_lead["script_no"])
                                _defer_lead = None
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
            # 与 Dify 通信异常：静默关闭（不推送报警；App 按流结束自行处理）
            logger.warning("STREAM RequestError（静默关闭）: %s", exc, exc_info=True)
            return
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
                # worker 真正跑完（收尾/落库之后）才释放注册，且按身份匹配，
                # 避免被"新登入顶替"的旧 worker 结束时误清新 worker 的注册。
                # 绝不在客户端断联处释放——否则旧 worker 未结束就放行同一会话的新请求，
                # 两个同口令 worker 会并发改写该用户的时间线。
                _gen_release(user_id, device_id, login_ts)

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
        logger.warning("DBG confirm 404 unknown request_id=%s user=%s", data.request_id, user_id)
        raise HTTPException(status_code=404, detail="待确认请求不存在或已超时")
    ev.set()
    logger.warning("DBG confirm found & released request_id=%s user=%s", data.request_id, user_id)
    return {"ok": True}


@app.post("/api/generate-story/revise-confirm")
async def generate_story_revise_confirm(data: PayloadConfirmData, request: Request):
    """违规修正前确认：App 用户点击"送 Dify 修正"后调用本接口，
    用 request_id 匹配正在等待的 /api/generate-story 流式请求，set 其 asyncio.Event，
    使服务器继续调用"违规修正"工作流。"""
    token = _extract_token(data, request)
    claims = validate_token(token)
    user_id = claims["user_id"]
    device_id = claims["device_id"]
    _enforce_active_device(user_id, device_id)

    ev = _pending_revise_confirm.get(data.request_id)
    if ev is None:
        raise HTTPException(status_code=404, detail="待修正确认请求不存在或已超时")
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
    """App 每次启动【第一件事】调用：上传硬件公钥 + 用户 id。

    服务器校验后：更新该设备硬件公钥，并【覆盖该用户的最新登入口令】(login_ts=now)，
    再签发一枚携带新 login_ts 的令牌返回——App 必须存下这枚新令牌用于后续请求。
    语义：每次启动 = 一次最新登入，旧的其它设备在下一次写口令校验时被判定非最新。
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
        conn.execute(
            "UPDATE devices SET public_key=?, last_seen_at=? WHERE device_id=?",
            (data.public_key, now, device_id),
        )
        # 覆盖为最新登入：写口令
        _guard_upsert(conn, user_id, device_id, now)
        conn.commit()
    finally:
        conn.close()

    expires_at = now + TOKEN_EXPIRY_DAYS * 86400
    new_token = create_token(user_id, device_id, expires_at, login_ts=now)
    return {
        "status": "ok",
        "token": new_token,
        "token_type": "bearer",
        "user_id": user_id,
        "device_id": device_id,
        "login_ts": now,
        "expires_at": expires_at,
    }


# ================= 小说正文云存储（每段一行，与客户端 List<String> 数组对应） =================
def _dedup_story_segments_by_script(user_id: str, rows: list) -> list:
    """按脚本号（current_script_id）对【本次拉取到的 rows】做"近距"去重——纯读。

    读端点绝不写库（2026-09 冻结规格：重复清理由写侧受口令保护的原子单元负责；
    本函数只做展示层过滤）。判定规则：
      - 同一脚本号相邻两次出现 seq 差 ≤ 3 → 较老的视为重复，从本次返回中剔除；
      - seq 差 ≥ 4 → 视为合法复用，两个都保留。
    返回去重后的 rows（类型、顺序与传入一致）。
    """
    conn = _db()
    try:
        sids = []
        for r in rows:
            sid = r["current_script_id"]
            if isinstance(sid, str) and sid and sid not in sids:
                sids.append(sid)
        if not sids:
            return rows
        lo = min(r["seq"] for r in rows) - 3
        hi = max(r["seq"] for r in rows) + 3
        dup_seqs: set = set()  # 判定为"较老重复章"的 seq（仅用于展示过滤）
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
            for i in range(1, len(occ)):
                if occ[i] - occ[i - 1] <= 3:
                    dup_seqs.add(occ[i - 1])
        if dup_seqs:
            logger.warning("STORY 近距去重（展示过滤，不删库）seqs=%s", sorted(dup_seqs))
        return [r for r in rows if r["seq"] not in dup_seqs]
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
                          current_script_id
                   FROM story_segments
                   WHERE user_id=? AND seq < ?
                     AND TRIM(COALESCE(content,'')) <> ''
                   ORDER BY seq DESC LIMIT ?""",
                (user_id, before_seq, limit),
            ).fetchall()
            rows = list(reversed(rows))
        elif limit > 0:
            rows = conn.execute(
                """SELECT seq, content, choice_1, choice_2, choice_3, user_choice,
                          current_script_id
                   FROM story_segments
                   WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''
                   ORDER BY seq DESC LIMIT ?""",
                (user_id, limit),
            ).fetchall()
            rows = list(reversed(rows))
        else:
            rows = conn.execute(
                """SELECT seq, content, choice_1, choice_2, choice_3, user_choice,
                          current_script_id
                   FROM story_segments
                   WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''
                   ORDER BY seq ASC""",
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
               WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''
               ORDER BY seq DESC LIMIT 1""",
            (user_id,),
        ).fetchone()
        # DB 语言列存"规范全名"，回传给 App 时还原成语言代码（App 本地化用代码）
        language = (_language_code(lang_row["language"] or "") if lang_row else "")
        total = None
        if limit <= 0:
            total = conn.execute(
                """SELECT COUNT(*) AS c FROM story_segments
                   WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''""",
                (user_id,),
            ).fetchone()["c"]
    finally:
        conn.close()
    segments = []
    choices = []
    user_choices = []
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
        # 与 segments 一一对应的脚本序号（"脚本id-章节"，如 "2-5"；无则为空串）。
        # App 据此判断某段是否为一个脚本的最后一章（下一段脚本 id 不同即切换点）
        "current_script_ids": current_script_ids,
        "start_seq": start_seq,
        "updated_at": updated_at,
        # 用户的金标准语言（最新一段的语言快照；老用户换新设备时 App 用它覆盖本地语言）
        "language": language,
        # 启动自愈标记：最新正文行所在小说是否已写满且数据库没有更新的小说 →
        # App 打开同步后应【自动开始生成下一本新小说】（true），否则正常等待用户续写（false）。
        "next_needed": _story_needs_next_novel(user_id),
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
        # 只返回"最新已生成正文"的那一行（正文非空）：占位模型下若按 MAX(seq) 取，
        # 会拿到当前小说末尾那行空占位章（正文/设定全空、id/seq 偏大），误导调试。
        row = conn.execute(
            """SELECT id, seq, content, created_at,
                      choice_1, choice_2, choice_3, user_choice,
                      music_style,
                      location, era, player_name, player_traits, language
               FROM story_segments
               WHERE user_id=? AND TRIM(COALESCE(content,'')) <> ''
               ORDER BY seq DESC, id DESC
               LIMIT 1""",
            (user_id,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return {"latest": None}
    return {"latest": dict(row)}


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
    login_ts = claims.get("login_ts")
    _st = _reset_story(user_id, device_id, login_ts)
    if _st == "conflict":
        raise HTTPException(status_code=409, detail="multi_client")
    if _st != "ok":
        raise HTTPException(status_code=500, detail="清空失败")
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
