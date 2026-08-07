# AI SAGA

**AI SAGA** (AI 傳奇 / AI サーガ / AI 사가) is a multilingual, iOS‑style interactive fiction game for Android, iOS, macOS and Web. It lets players build a character and partner, choose a location and era, and then generate an adventure detective–romance story, with every piece of player input **moderated by an AI audit gateway** before it is accepted.

> This document records the project’s current state, every major improvement made so far, and the reasoning behind each design decision — based on our collaboration history. A dedicated section at the end documents the **AI fiction generation pipeline** (Dify streaming + two-phase moderation + typewriter) and the full Q&A that led to it.

---

## Table of Contents

- [Overview](#overview)
- [Tech Stack](#tech-stack)
- [Major Improvements & Decisions](#major-improvements--decisions)
  1. [From template to a real product](#1-from-template-to-a-real-product)
  2. [Device integrity protection (root / jailbreak detection)](#2-device-integrity-protection)
  3. [Lightweight authorization (Google / Sign in with Apple)](#3-lightweight-authorization)
  4. [Hardware-backed device identity](#4-hardware-backed-device-identity)
  5. [Signed-token audit gateway (server)](#5-signed-token-audit-gateway)
  6. [Cost control (input/output token caps)](#6-cost-control)
  7. [Trial & paid entitlement model](#7-trial--paid-entitlement-model)
  8. [Cloud sync (reserved)](#8-cloud-sync)
  9. [Procedural sound effects (cross-platform)](#9-procedural-sound-effects)
  10. [Apple HIG theming (light / dark)](#10-apple-hig-theming)
  11. [Multi-language on-boarding flow](#11-multi-language-on-boarding-flow)
  12. [In-app privacy policy](#12-in-app-privacy-policy)
  13. [Vendored third-party plugins](#13-vendored-third-party-plugins)
  14. [Secret management & environment configuration](#14-secret-management--environment-configuration)
- [AI Fiction Generation Pipeline (Dify Streaming + Moderation)](#ai-fiction-generation-pipeline)
  - [15. End-to-end generation flow](#15-end-to-end-generation-flow)
  - [16. Two parallel Dify workflows & fail-fast keys](#16-two-parallel-dify-workflows--fail-fast-keys)
  - [17. Daily quota & abuse protection](#17-daily-quota--abuse-protection)
  - [18. Two-phase streaming moderation & progressive typewriter](#18-two-phase-streaming-moderation--progressive-typewriter)
  - [19. Apple App Store compliance & UGC moderation Q&A](#19-apple-app-store-compliance--ugc-moderation-qa)
  - [20. Desensitization / masking / conservative regeneration Q&A](#20-desensitization--masking--conservative-regeneration-qa)
  - [21. User-input continuation (three input boxes)](#21-user-input-continuation-three-input-boxes)
  - [22. RAG & server architecture Q&A](#22-rag--server-architecture-qa)
  - [23. Deployment pipeline (Docker + SSH)](#23-deployment-pipeline-docker--ssh)
- [Project Layout](#project-layout)
- [Backend API Overview](#backend-api-overview)
- [Getting Started (Dev Mode)](#getting-started)
- [Deployment & Configuration](#deployment--configuration)
- [Roadmap](#roadmap)
- [Notes for the Repository](#notes-for-the-repository)

---

## Overview

The app was originally created from the default Flutter template (`flutter_application_1`) and has been progressively turned into a complete interactive-fiction product. The core loop:

1. **Splash screen** → plays a horror sound effect and fades into the app.
2. **Language selection** (new users) → 10 languages.
3. **Lightweight authorization** (first use) → Google on Android, Sign in with Apple on iOS (or a local dev account).
4. **Story setup wizard**: location → era → player character (gender + name) → partner (gender + name + traits).
5. **AI moderation** on every submitted setting (via the audit gateway) before the story is unlocked.
6. **Confirmation page** with a 5‑second countdown → enter the main story page.
7. **Main story page**: reading panel, action buttons, free-text input — all content is persisted locally.
8. **AI fiction generation**: on confirmation, the server calls the Dify **fiction workflow** in streaming mode; the first audited segment is typed out, then the remainder is revealed with progressive acceleration.

---

## Tech Stack

| Layer | Technology |
|---|---|
| App | Flutter (Dart), pure **Cupertino** widgets (no Material) |
| Secure storage | `flutter_secure_storage` (iOS Keychain / Android Keystore) |
| Platform auth | `google_sign_in`, `sign_in_with_apple` |
| Hardware keys | Android Keystore (StrongBox/TEE) & iOS Secure Enclave via a native `MethodChannel` |
| Backend | **FastAPI** + **SQLite** (container `my-audit-app`, port 8000) |
| AI moderation | Server calls a **Dify audit workflow** (blocking response mode) |
| AI fiction generation | Server calls a **Dify fiction workflow** (`response_mode: streaming`, SSE); output is audited in **two phases** before display |
| Streaming | FastAPI `StreamingResponse` (SSE: `chunk` / `reveal` / `abort` / `error` / `done`) → Flutter `http` stream client → `TypewriterText` widget |
| Config | `flutter_dotenv` (`.env`, git‑ignored) |
| Sound | Procedurally generated PCM16/WAV played through a vendored `soundpool` |

---

## Major Improvements & Decisions

### 1. From template to a real product
- **What**: Replaced the default counter template with a full game structure: splash, gated navigation, setup wizard, story page, menu sheet (subscription / dark mode / restart), and a native hardware-key bridge.
- **Decision & rationale**: We chose to build on top of the existing Flutter project rather than start a new one, to keep momentum; the app name and package were kept as `ai_saga` while display titles are localized per language.

### 2. Device integrity protection
- **What**: On startup, the app runs a root/jailbreak check and **silently terminates the process** if the device is compromised — no prompt, no error screen. See [`security_service.dart`](AI-SAGA/lib/logic/security_service.dart:24).
- **Decision & rationale**: We wanted to prevent attackers from using privileged (rooted/jailbroken) devices to bypass moderation and abuse the backend LLM. The detection is **fail-open**: if the check is unavailable (e.g. desktop/Web), the app treats the device as unmodified so legitimate users are never blocked. `terminateProcess()` uses `exit(0)` on IO platforms ([`security_terminate_io.dart`](AI-SAGA/lib/logic/security_terminate_io.dart:5)) and a no-op stub on Web ([`security_terminate_stub.dart`](AI-SAGA/lib/logic/security_terminate_stub.dart:5)) via conditional imports.

### 3. Lightweight authorization
- **What**: A one‑tap "light auth" gate — Google on Android, Sign in with Apple on iOS. The returned ID token and stable `sub` are cached in secure storage, so returning users are seamless. See [`account_service.dart`](AI-SAGA/lib/logic/account_service.dart:76).
- **Decision & rationale**: Full email/password registration was rejected as heavy friction; a single platform sign-in satisfies compliance and moderation requirements while keeping onboarding fast. A **dev mode** (`DEV_MODE=true`) skips real OAuth and uses the device UUID as a test account, so the whole pipeline can be tested end‑to‑end without Apple/Google credentials.

### 4. Hardware-backed device identity
- **What**: Each device generates an **ECDSA P-256 key pair inside secure hardware** (Android Keystore preferring StrongBox, iOS Secure Enclave). The private key never leaves hardware; the app only ever obtains the public key and signed outputs. See [`hardware_key_service.dart`](AI-SAGA/lib/logic/hardware_key_service.dart:11), the Android bridge in [`MainActivity.kt`](AI-SAGA/android/app/src/main/kotlin/com/example/flutter_application_1/MainActivity.kt:25), and the iOS bridge in [`AppDelegate.swift`](AI-SAGA/ios/Runner/AppDelegate.swift:25).
- **Decision & rationale**: Hardware-backed keys give a *cryptographic* binding of “one physical device” instead of a spoofable software ID. The public key is unique on the server, preventing “same hardware, many accounts” abuse (one hardware = one identity = one quota).

### 5. Signed-token audit gateway
- **What**: A FastAPI server issues short-lived, HMAC-signed bearer tokens after a **challenge–signature registration**: the server issues a one-time challenge, the client signs it with its hardware key, and the server verifies the signature plus the ID token (via official JWKS) before binding account + device + public key. See [`server/main.py`](server/main.py:504).
- **Decision & rationale**: We deliberately chose **challenge/response proof of possession** over storing a shared secret in the app, and **server-side JWKS verification** over trusting client-claimed IDs. Token expiry + 60-second early-expiry buffer avoid edge-case failures, and in-flight registration requests are shared to avoid hammering the server (the “request too frequent” rate limit we hit during testing). See [`auth_service.dart`](AI-SAGA/lib/logic/auth_service.dart:33).

### 6. Cost control
- **What**: Input is hard-capped (default 5000 tokens, plus a 40 000 character fallback) before any LLM spend; output is capped via `max_tokens` (default 4000) passed to the Dify workflow. See [`server/main.py`](server/main.py:357).
- **Decision & rationale**: LLM API costs were a real concern, so we enforce limits **before money is spent** (input) and **at generation** (output). The Dify canvas must bind its LLM `max_tokens` to the workflow input variable for the cap to take effect — a documented manual step.

### 7. Trial & paid entitlement model
- **What**: Free users get a trial grant (default **3 uses per 7-day cooldown**) tracked on both `user_id` and `device_id` dimensions to block “same account on another device” and “same device, other accounts” farming. Paid users are governed by daily quota + per-minute rate limits. Entitlements support both subscription (expiry) and quota (purchase count) models. See [`server/main.py`](server/main.py:680).
- **Decision & rationale**: The dual-dimension trial bookkeeping was a direct response to quota-farming exploits we reasoned through together. Purchase verification is reserved server-side (App Store / Google Play receipts + revocation webhooks) so the app cannot forge paid status.

### 8. Cloud sync
- **What**: Incremental sync of story data per `user_id` with optimistic-concurrency writes (`GET/POST /api/sync`). A RAG incremental-index hook is reserved for future retrieval features. See [`server/main.py`](server/main.py:908).
- **Decision & rationale**: Chosen so a player can continue on a new device under the same account. Version-stamped writes prevent older clients from silently overwriting newer data.

### 9. Procedural sound effects
- **What**: All sound effects (click, confirm, cancel, two horror stingers) are **synthesized at runtime as PCM16/WAV** instead of shipping audio assets, then played through the vendored `soundpool`. See [`sound_service.dart`](AI-SAGA/lib/logic/sound_service.dart:12).
- **Decision & rationale**: We originally had a Web Audio implementation, but the app also targets native platforms. Programmatic synthesis keeps the binary small, works identically on Android/iOS/macOS/Web, and the play call **degrades silently** if a platform lacks support so sound never breaks functionality.

### 10. Apple HIG theming
- **What**: A dedicated theme palette matching Apple Human Interface Guidelines colors for light and dark modes, plus a persisted dark-mode toggle. See [`app_theme.dart`](AI-SAGA/lib/logic/app_theme.dart:8).
- **Decision & rationale**: The app is Cupertino-styled for a native iOS feel; using HIG-approved color tokens keeps the UI consistent and accessible in both brightness modes.

### 11. Multi-language on-boarding flow
- **What**: 10 languages (English, 日本語, Español, Français, Deutsch, Português, 简体中文, 繁體中文, 粵語, 한국어) with localized default cities, eras, names, and UI strings.
- **Decision & rationale**: The title is localized per language, and the language choice is made *before* auth so the authorization screen and the whole wizard appear in the player’s language. This ordering (language → auth → setup) was a deliberate UX decision to reduce early friction.

### 12. In-app privacy policy
- **What**: A static, network-independent privacy policy page (works offline, so review environments can always open it) linked from the auth screen, plus a “by continuing you agree” notice. See [`privacy_policy_page.dart`](AI-SAGA/lib/widgets/privacy_policy_page.dart:10).
- **Decision & rationale**: Required for compliance with Apple/Google review; an embedded page guarantees availability and consistency with the account-deletion disclosure.

### 13. Vendored third-party plugins
- **What**: Two plugins are vendored into [`third_party/`](AI-SAGA/third_party/):
  - `flutter_jailbreak_detection`: added the missing Android `namespace` so it builds with modern AGP; `compileSdk`/Java 17 aligned. See [`third_party/flutter_jailbreak_detection/android/build.gradle`](AI-SAGA/third_party/flutter_jailbreak_detection/android/build.gradle:29).
  - `soundpool`: the official package is discontinued and its Android plugin still referenced the removed v1 Registrar API; the obsolete code was stripped so it compiles with the current Flutter.
- **Decision & rationale**: Instead of maintaining our own plugins from scratch, we vendored the source and patched only what was needed to build, keeping the change surface minimal.

### 14. Secret management & environment configuration
- **What**: All secrets move to `.env` (git‑ignored) with a committed `.env.example` template; `.gitignore` explicitly blocks `.env.*`, keys, certs, and provisioning files while keeping the template. See [`.gitignore`](AI-SAGA/.gitignore:47) and [`.env.example`](AI-SAGA/.env.example:1).
- **Decision & rationale**: We agreed that no real credentials, server IPs, or signing keys should ever be pushed to GitHub. The app loads `.env` via `flutter_dotenv` and tolerates a missing file (non-blocking) so development and review builds never crash on absent config.

---

## AI Fiction Generation Pipeline

*This section documents the design session where we wired the whole fiction-generation feature end-to-end: the Flutter confirm button → FastAPI gateway → Dify fiction workflow → back to the app with a two-phase moderation + typewriter display. Every question raised during the session and the decision we agreed on is captured below.*

### 15. End-to-end generation flow

**The question**: *“When the user taps Confirm on the setup-confirmation page, pass the data from Flutter to the server, then to Dify, get the result back to FastAPI, then to Flutter, and display it on the normal text page.”*

**Agreed design (implemented)**:

```
Flutter (SetupConfirmationPage)
  │  tap Confirm → SetupDraft.commit() persists all settings
  ▼
StoryService.generateStoryStream()          // SSE client, lib/logic/story_service.dart:32
  │  POST /api/generate-story  (Authorization: Bearer <token>)
  ▼
FastAPI  /api/generate-story  (server/main.py:955)
  │  validates token → checks global daily quota → builds Dify payload
  │  calls Dify fiction workflow with response_mode: "streaming"
  ▼
Dify fiction workflow (LLM generates the story)
  │  streams text_chunk events → workflow_finished (outputs.text)
  ▼
FastAPI two-phase moderation  (_moderate_story, server/main.py:926)
  │  phase 1: audit first 450 chars → send "chunk"
  │  phase 2: audit from char 400 to end → send "reveal"
  ▼
Flutter TypewriterText  (lib/widgets/character_text.dart:48)
  │  starts typing from the very first character at the slowest speed,
  │  then accelerates (+1 char/tick) every 20 characters;
  │  every continuation segment restarts from the slowest speed
  │  (speed is computed from in-segment progress, segmentStart)
  ▼
_HomeContentState relays the text onto the main story page (lib/logic/home_content.dart:339)
```

**Decisions**:
- The gateway endpoint is `/api/generate-story`; the client URL comes from `STORY_API_URL` (`.env`) or is derived from `AUDIT_API_URL` by replacing `/api/audit-and-chat` with `/api/generate-story`, so server address stays consistent ([`story_service.dart`](AI-SAGA/lib/logic/story_service.dart:15)).
- We read the final story **directly from the `text` output** of the Dify workflow. An earlier design preferred `fiction_context` with a `text` fallback — the user rejected that: *“不要用这样的兜底设计，改成就读取 text”* (no fallback, read `text` only), to avoid ambiguity and surprise behavior.

### 16. Two parallel Dify workflows & fail-fast keys

**The question**: The user originally supplied one Dify key, then corrected us: *“老密钥是另一个工作流，专门用来审核违禁词的，现在的密钥是带 LLM 生成内容的新工作流，他们是并行的关系，不是替代关系”* — the two keys belong to **two parallel workflows**, not a replacement.

**Agreed configuration**:
- `DIFY_API_KEY` → **audit workflow** (moderation only; used by `/api/audit-and-chat` and by `_moderate_story`).
- `STORY_DIFY_API_KEY` → **fiction generation workflow** (used by `/api/generate-story`).
- **Fail-fast, no fallback**: if `STORY_DIFY_API_KEY` is missing, generation fails loudly rather than silently falling back to the audit workflow. The two workflows never substitute for each other.

### 17. Daily quota & abuse protection

**The question**: *“Story-dify-api-key 的每天调用次数改成 500 次，超过后返回报警，禁止继续调用。每 24 小时恢复。方便我测试同时防止被黑。”*

**Agreed design (implemented)**: A global rolling 24-hour quota over all users — `STORY_DAILY_LIMIT = 500` calls per 24 h, tracked in a SQLite `story_usage` table with a rolling window (`_check_story_quota`, [`server/main.py`](server/main.py:899)). When the count reaches the limit, the endpoint returns **HTTP 429** with an alarm message and refuses further generation until the window rolls over. This protects against abuse/DoS while staying convenient for testing. Both the audit path and the story path enforce their own budgets.

### 18. Two-phase streaming moderation & progressive typewriter

This is the core UX. The user asked: *“先审 400 字 → 打字 → 剩余全审 → 一次性显示；看起来输出不断加速。”* Later the first audit was widened to **450 chars** and the second audit was pinned to start at **char 400**, creating a **50-char overlap** so no violating text can slip through the boundary.

**Final algorithm (server, [`/api/generate-story`](AI-SAGA/server/main.py:955))**:

| Stage | Action |
|---|---|
| Stream | Consume Dify `text_chunk` events; accumulate into `first_buf`. |
| Phase 1 | When `first_buf` reaches **`STORY_FIRST_CHUNK = 450`** chars, call `_moderate_story(first_buf)`. If rejected → send `abort` (nothing shown). If approved → send `chunk` with those 450 chars (typewriter starts). |
| Phase 2 | Keep buffering the rest (`rest_buf`). On `workflow_finished`, take `out_text` (the full generated text). Audit **`out_text[400:]`** — i.e. from `STORY_SECOND_AUDIT_START = 400` to the end. The first audit covered `[0, 450)`, so the segment `[400, 450)` is audited **twice** (50-char overlap), eliminating boundary gaps. |
| Reveal | If approved → send `reveal` with `rest = out_text[450:]` (the portion not yet shown) + `outputs`. If rejected → `abort`. |
| Fallback | If the stream ends without `workflow_finished`, the buffered text is audited **before** any reveal — never show unaudited content. |

**Progressive typewriter (Flutter)** — [`TypewriterText`](AI-SAGA/lib/widgets/character_text.dart:48) with dynamic speed ([`_currentCharsPerTick()`](AI-SAGA/lib/widgets/character_text.dart:134)):

| Typing progress | Speed (150 ms/tick) |
|---|---|
| From the very **first** character of each segment | **Slowest speed** (1 char/tick ≈ 6.7 chars/s) |
| Every **20** chars within the segment | **+1 char/tick** (the minimum allowed acceleration step) — continuous acceleration |
| New segment (user continuation input) | **Restarts from the slowest speed** (speed is per-segment, via `segmentStart`) |

So the user sees the first audited segment type out slowly, then the remainder accelerate progressively. **The remainder is no longer revealed all at once** — we removed the `revealAll` jump; the whole story now types out with a steadily increasing speed, which is exactly the “不断加速” feel requested.

**Key Q&A that shaped this**:
- *“打字要结合 Dify 和服务器修改，还要兼容审核。两端都要做什么？”* → **Dify**: enable streaming response mode; **FastAPI**: SSE bridge + two-phase audit; **Flutter**: SSE client + typewriter widget.
- *“将文章输出一半的时候进行审核，会如何影响打字机效果？”* → Auditing mid-stream before the first visible character keeps the typewriter from ever showing unaudited content; the phase-2 audit happens after generation completes, so there is no interruption to the ongoing typewriter.
- *“400 字中断在 Dify 实现还是 FastAPI 实现？”* → **FastAPI**. Dify streams tokens; the 450-char split is a server-side buffering decision, so we can also change the threshold without touching the Dify canvas.
- *“小说数据流全部结束后，还要接收几个后续的变量，可行吗？”* → Yes — the `workflow_finished` event carries `outputs`, which the server forwards in the `reveal`/`done` events for any downstream variables.
- *“400 字打字机效果能顶几秒？四百字读者阅读时间？”* → We estimated the typing/reading cadence to choose a comfortable first-batch length; 450 chars keeps the opening dramatic without dragging.
- *“生成一段文字就审核一段、通过再传输，技术上难度？”* → Segment-by-segment moderation is possible but doubles audit calls and complexity; the chosen two-phase design gets most of the safety with only two audits per story.
- *“有一种一百字强制审核一次的方法，怎么实现的？”* → Forced per-100-char audits were discussed as a stricter variant; the 450 + overlap design was adopted instead to balance safety, latency, and cost.

### 19. Apple App Store compliance & UGC moderation Q&A

**The concern**: *“违规内容显示后才被封，是不是苹果也过不了审核？”* and *“用户举报 app 能看到违规内容后，会怎么样？”*

**Agreed approach**:
- Apple reviews AI-generated content under **Guideline 1.2 / 1.1.2 (UGC)** — any content that could be seen by users needs moderation, an in-app **report** mechanism, and a way to **block** the offending user.
- **Fail-closed**: `_moderate_story` returns `True` only when the audit workflow explicitly outputs `Action: NONE`; any error or unclear result is treated as a violation (nothing is displayed). See [`_moderate_story`](AI-SAGA/server/main.py:926).
- **Two-phase display** is itself the compliance answer: the first 450 chars are moderated *before* any text appears; the rest is moderated *before* it is revealed. No unaudited content is ever rendered.
- **Reporting & blocking**: a “report → immediate suspension (block)” flow is planned (documented in the roadmap). The user asked *“用户举报后，立即就封号吗？”* — we agreed a reported user should be suspended immediately and deterministically on the server, not just flagged, to satisfy the “block” requirement.
- **Age rating**: with LLM-generated content, a **17+** rating is the safe default.
- **Copyright**: *“guardrail 能审核版权侵权内容吗？”* → No — guardrails cannot reliably detect copyright infringement; Apple evaluates copyright on report/review. *“版权侵权苹果怎么审？”* → Apple relies on rightsholder reports and DMCA-style takedowns. *“单个用户自己生成违规内容，我不提供 PDF 下载，他倒不出来，私用，我担责？”* → We agreed that not offering export/download reduces — but does not eliminate — liability; the operator is still responsible for content its service generates, so server-side moderation stays the primary defense.

### 20. Desensitization / masking / conservative regeneration Q&A

**The questions**: *“未审核通过，现在有没有模型能进行文章脱敏？”* *“脱敏成本？”* *“打码成本？”* *“脱敏打码后还不过，推荐怎么办？”* *“脱敏循环可行吗？”* *“重新生成永不成功？”*

**Agreed approach**:
- **脱敏 (desensitization / rewrite)**: an LLM can rewrite flagged text into a compliant version. Cost: an extra LLM call per violation — significant but acceptable for occasional triggers.
- **打码 (masking)**: replace the offending span with `***`/placeholder. Cheapest, deterministic, but reads badly.
- **Loop feasibility**: a pure rewrite loop can oscillate or never converge (“重新生成永不成功”). We rejected an unbounded desensitization loop.
- **Recommended final fallback**: if content is rejected after rewrite/masking, **tell the user to adjust their prompt and regenerate with an extreme conservative model** — i.e. switch to a stricter LLM configuration rather than retrying forever. This bounds cost and guarantees eventual termination.

### 21. User-input continuation (three input boxes)

**The questions**: *“把按钮一按钮二改成输入框，一共三个输入框，每个配一个确认按钮。”* *“任何一个输入框确认后，内容作为 user_input，加上所有设定组成 JSON，传输给 FastAPI 调 LLM 生成新小说，并在屏幕接力显示。”* *“新内容和老内容相隔一行。”* *“用户输入是不是都先接入了审查 API？”* *“不要把用户输入单独先审核，我会在生成模型里添加一个审核模块。”*

**Agreed design (implemented)**:
- Three `TextInputPanel` widgets each with a Confirm button ([`home_content.dart`](AI-SAGA/lib/logic/home_content.dart:363)).
- Any confirm → `_continueStory(userInput)` ([`home_content.dart`](AI-SAGA/lib/logic/home_content.dart:141)) → sends `user_input` + `user_input_counter` (round number) plus all prior settings to `/api/generate-story`.
- New segments are appended with a **blank line (`\n\n`)** separator so the continuation is visually distinct from the previous content.
- **No separate pre-audit of user input**: per the user’s instruction, the Dify generation workflow itself will include an audit module, so user input is moderated inside the generation path (faster, single pipeline) rather than a dedicated pre-check.

### 22. RAG & server architecture Q&A

**The questions**: *“小说生成后还要兼容 RAG 生成和服务器 SQL 存储小说内容，难度？”* *“RAG 摘要和剧情大纲能互相替代吗？”* *“RAG 怎么融合进 Dify？”* *“先做 RAG 还是先做打字机？”* *“RAG 是非阻塞异步、同步，还是另一个程序流？”* *“RAG + SQL + FastAPI 对服务器要求？”*

**Agreed answers**:
- **RAG vs summary/outline**: not interchangeable — a plot outline drives generation; a RAG index answers retrieval queries. Different jobs.
- **RAG in Dify**: via a Dify **knowledge-base / RAG node** (or an external vector store) that injects retrieved context into the LLM prompt, with **per-`user_id` isolation**.
- **Execution model**: RAG indexing should run **asynchronously / as a separate program flow** (background worker), never blocking the synchronous story-generation path.
- **Ordering**: implement the **typewriter/streaming feature first** (it is user-visible and was the priority), then layer RAG + SQL story persistence.
- **Server footprint**: FastAPI + SQLite + RAG + LLM proxy is modest — the dominant cost is LLM API usage, not CPU/RAM; a single small VPS suffices for this scale.

### 23. Deployment pipeline (Docker + SSH)

**The questions**: *“部署到远程服务器，登入密钥就在 VS Code 中，你找一下。”*

**Agreed setup (implemented)**:
- Remote host `<server-ip>`, user `<user>`, SSH key `~/.ssh/<ssh-key>`.
- Docker container **`my-audit-app`** runs the FastAPI server on port 8000 with bind mounts:
  - `/home/<user>/main.py` → `/code/main.py` (hot code mount),
  - `/home/<user>/ai_saga_data` → `/code/data` (SQLite data).
- `uvicorn --reload` is enabled, so **uploading `main.py` auto-reloads the container** — no restart required.
- [`deploy_helper.sh`](deploy_helper.sh:1) wraps the flow:
  - `./deploy_helper.sh upload <local> <remote>` → `scp` upload,
  - `./deploy_helper.sh run "<cmd>"` → `ssh` remote command.
- After each deploy we verify with `docker ps`, `docker logs` (look for `StatReload detected changes … Reloading`), and `curl /api/health`.

---

## Project Layout

```
AI-SAGA/
├── lib/
│   ├── main.dart                 # App entry, splash, gates (language → auth → home), menu/subscription sheets
│   ├── logic/
│   │   ├── app_theme.dart        # Apple HIG light/dark palette
│   │   ├── security_service.dart # Root/jailbreak gate (silent termination)
│   │   ├── security_terminate_io.dart / security_terminate_stub.dart
│   │   ├── account_service.dart  # Light auth (Google / Apple / dev)
│   │   ├── auth_service.dart     # Challenge–signature registration + bearer token
│   │   ├── hardware_key_service.dart  # Hardware key bridge
│   │   ├── storage_service.dart  # SharedPreferences + secure storage
│   │   ├── sound_service.dart    # Procedural WAV sound synthesis
│   │   ├── story_service.dart    # SSE streaming client for fiction generation
│   │   └── home_content.dart     # Setup wizard + story page orchestration
│   └── widgets/                  # Setup pages, audit dialog, typewriter, privacy policy, input/button/character components
├── android/  ios/  macos/  web/  # Platform shells (hardware-key channels, entitlements)
├── third_party/                  # Vendored & patched plugins
├── pubspec.yaml                  # Dependencies (flutter_dotenv, google_sign_in, etc.)
└── .env.example                  # Committed template (copy to .env)
server/
├── main.py                       # FastAPI audit gateway (auth, quota, streaming story generation, sync)
└── DESIGN.md                     # Public architecture & design (English)
deploy_helper.sh                  # SSH/scp deploy helper (key-based, no password)
```

---

## Backend API Overview

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | Service status + registered users/devices |
| `POST /api/register/challenge` | Issue a one-time challenge (replay protection, IP rate-limited) |
| `POST /api/register` | Verify ID token (JWKS) + challenge + hardware signature; bind account/device/public key; return bearer token |
| `POST /api/audit-and-chat` | Moderate/transform player text via Dify; enforces budget, quota, rate limits |
| `POST /api/generate-story` | **Streaming (SSE)** fiction generation: two-phase moderation (first 450 chars, then from char 400 with 50-char overlap), returns `chunk` / `reveal` / `abort` / `error` / `done` events |
| `GET/POST /api/sync` | Incremental cloud sync (optimistic concurrency) |
| `POST /api/verify-purchase` | Purchase verification (reserved) |
| `POST /api/purchase-webhook` | Platform subscription/refund push (reserved) |

---

## Getting Started

### Prerequisites
- Flutter (Dart SDK `^3.12.2`)
- A backend server with `DIFY_API_KEY` (audit) and `STORY_DIFY_API_KEY` (fiction) — see [`server/main.py`](server/main.py:205)

### Client (dev mode, no Apple/Google credentials required)
```bash
cd AI-SAGA
cp .env.example .env
# In .env, set DEV_MODE=true and fill AUDIT_API_URL / REGISTER_API_URL / STORY_API_URL
flutter pub get
flutter run
```

### Server
```bash
export DIFY_API_KEY=xxx            # audit workflow
export STORY_DIFY_API_KEY=xxx      # fiction workflow
export DEV_MODE=1                  # dev only; disable in production
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### Dify canvas (one-time manual step)
1. **Audit workflow**: an End node that returns `Action: NONE` for approved content (used by `_moderate_story`).
2. **Fiction workflow**: Start (all story variables) → Code (optional prompt shaping) → LLM (streaming) → End (`text` output). Bind the LLM node’s `max_tokens` to the workflow input variable `max_tokens` (or hardcode 4000) so the output cap is enforced.

### ⚠️ Do not rely on LLM-generated Dify DSL (`.yml`)
LLM-generated Dify workflow `.yml` files are **unreliable**. Even if the file looks perfect on the surface, the variables inserted into the **LLM node’s prompt can be stored as literal text instead of being registered as real variable references** — the prompt keeps the raw `{{#node_id.variable#}}` token, so the workflow runs but the actual values are never imported and the model never receives them.

During the session we debugged many import/render issues that all trace back to DSL details:
- `missing app data` → the app payload must be wrapped under a top-level `app:` key.
- `missing workflow` → `app` and `workflow` must be **sibling** top-level keys (they are not nested inside each other).
- Blank/empty modules after import → every node needs `type: custom` with the real type in `data.type`, plus node-level layout fields (`height`, `width`, `positionAbsolute`, `selected`, `sourcePosition`, `targetPosition`).
- Start-node render crash → the node `label` must be a **plain string** (a dict crashes the canvas), use `type: text-input`, and drop invalid `max_length`/`min_length` in favour of `hint`/`placeholder`.
- Code-node validation errors → `code_language` must be `python3` (not `python`), and `outputs` must be a **dict** mapping names → `{description, type}` (not a list).
- *“Workflow not published”* → the workflow must be **published** in the Dify console before the API can call it.
- Missing connection lines → node IDs were being parsed as integers; IDs must be quoted strings, and edges need `data`/`selected`/`zIndex`.

**Solution:** build every module in the Dify canvas **manually**:
1. Add the **Start** node and its variables.
2. Add the **Code** node and paste the Python (bind each input variable, declare the `clean_prompt` output as `string`).
3. Add the **LLM** node and insert the prompt variable using the editor’s **“insert variable” `{}` button** (do not type the `{{#...}}` by hand) so Dify registers it.
4. Add the **End** node and map `text` to the LLM `text`.
5. **Connect the nodes by hand** (Start → Code → LLM → End), then publish and test.

---

## Deployment & Configuration

Production requires these environment variables on the server (see [`server/DESIGN.md`](server/DESIGN.md:183) and [`.env.example`](AI-SAGA/.env.example:1)):

| Variable | Purpose | Status |
|---|---|---|
| `GOOGLE_CLIENT_ID` | Google OAuth Web Client ID | ⏳ to be provided |
| `APPLE_SERVICE_ID` | Sign in with Apple Service ID | ⏳ to be provided |
| `APPLE_APP_BUNDLE_ID` | iOS Bundle ID | ⏳ to be provided |
| `DEV_MODE` | must be `0` on release | ⏳ flip on launch |
| `DIFY_API_KEY` | Dify **audit** workflow | ✅ set (parallel to fiction) |
| `STORY_DIFY_API_KEY` | Dify **fiction** generation workflow | ✅ set (parallel to audit) |
| `STORY_DAILY_LIMIT` | fiction calls per 24 h (default 500) | ✅ set |
| `STORY_FIRST_CHUNK` | first audited segment length (default 450) | ✅ set |
| `STORY_SECOND_AUDIT_START` | second audit start char (default 400, 50-char overlap) | ✅ set |
| `STORY_API_URL` | client-side fiction endpoint (optional; derived from `AUDIT_API_URL`) | ✅ set |
| `APPSTORE_SHARED_SECRET` / `GOOGLE_PLAY_SERVICE_ACCOUNT` | purchase verification | reserved |

iOS additionally enables the Sign in with Apple capability via [`Runner.entitlements`](AI-SAGA/ios/Runner/Runner.entitlements:1).

---

## Roadmap

- **Play Integrity (Android) / App Attestation (iOS)** for stronger device attestation.
- **HTTPS** once a domain is configured.
- **Report & block**: in-app report UI → server-side immediate suspension/blocking of offending users (Apple 1.2/1.1.2 UGC requirement).
- **RAG** (sqlite-vec or Dify knowledge base) with per-`user_id` isolation, indexed **asynchronously** by a background worker so it never blocks story generation.
- **SQL story persistence**: store each user’s generated story server-side (currently persisted locally via `StorageService`).
- **Audit module inside the fiction workflow**: user input is moderated within the Dify generation workflow itself (per user decision), removing any separate pre-check.
- **Paid entitlements**: wire App Store Server Notifications V2 and Google RTDN to the reserved webhook; enforce daily quotas server-side.
- **Cloud sync**: surface sync in the UI and trigger incremental RAG indexing.

---

## Notes for the Repository

- `.env` and all real secrets are **never committed**; only `.env.example` is tracked.
- Dify workflows must be built **manually in the Dify canvas**; do not rely on LLM-generated DSL (`.yml`) imports — variable references inside the LLM prompt can be stored as literal text and never resolve to actual values (see the full debugging list in the Dify section above).
- The fiction pipeline is **fail-closed**: any moderation error or unclear result blocks display. Content is shown in two audited phases (first 450 chars, then from char 400 with a 50-char overlap) so no unaudited text ever renders.
- The two Dify keys are **parallel** — the audit workflow never substitutes for the fiction workflow (`fail-fast`, no fallback).
- Vendored plugins live under [`third_party/`](AI-SAGA/third_party/) with minimal patches to keep them buildable against current toolchains.
- Backend architecture, database schema, security principles, API design, and design rationale are documented in the public [`server/DESIGN.md`](server/DESIGN.md:1).
