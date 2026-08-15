# AI SAGA

**AI SAGA** (AI 傳奇 / AI サーガ / AI 사가) is a multilingual, iOS‑style interactive fiction game for Android, iOS, macOS and Web. It lets players build a character and partner, choose a location and era, and then generate an adventure detective–romance story, with every piece of player input **moderated by an AI audit gateway** before it is accepted.

> This document records the project’s current state, every major improvement made so far, and the reasoning behind each design decision — based on our collaboration history. A dedicated section at the end documents the **AI fiction generation pipeline** (Dify streaming + two-phase moderation + typewriter) and the full Q&A that led to it.
>
> **⚠️ 2026-08-08 update**: the fiction pipeline, story storage, quotas, input limits, and sync strategy were significantly revised. Read the **[Architecture Update (2026-08-08)](#architecture-update-2026-08-08)** section at the bottom first — several earlier sections below are **superseded** and kept only for history (see the *superseded* note there).
>
> **⚠️ 2026-08-08 (content moderation)**: guardrail auditing was consolidated onto the final setup confirmation page and the audit result parsing was hardened from a fragile `action: none` substring regex to **strict structured JSON verdicts** (server-authoritative, fail-closed). Read the **[Content Moderation & Guardrail Hardening (2026-08-08)](#content-moderation--guardrail-hardening-2026-08-08)** section at the bottom.
>
> **⚠️ 2026-08-09 update**: fixed the guardrail `guardrail_return_json` parsing when Dify returns a JSON **array**, added **localized empty-output quota warnings** (no “LLM” wording) for both new and existing users, several story-page UI refinements, and a **flash-free earlier-content loading** UX built on a layout-phase scroll compensation. Read the **[Session Update (2026-08-09)](#session-update-2026-08-09)** section at the bottom.
>
> **⚠️ 2026-08-09 (settings-in-story)**: the dedicated `user_settings` table was **removed** — the seven user settings now travel with each story segment and are stored as per-row snapshot columns on `story_segments`; a new `language` column makes the stored value the authoritative base for all language handling, and the redundant per-request language upload on continuation was removed. The debug database was **rebuilt from scratch** (old data cleared). Read the **[Settings-in-Story Refactor & Language-as-Authority (2026-08-09)](#settings-in-story-refactor--language-as-authority-2026-08-09)** section at the bottom.
>
> **⚠️ 2026-08-12 (generation architecture & cost)**: a design session covered **DeepSeek V4 Pro vs Flash cost modelling**, why post-stream variables cannot live in the streamed `text`, the **single-module JSON** option (Option A), Dify **Workflow vs Chatflow** for the streaming-novel pipeline, the **two-round Chatflow** replacement for the two-LLM graph, **prompt-caching (cache-hit) discount** mechanics, `max_tokens` as a hard cap, token↔character conversion, and **context strategies** (full text vs outline vs two-stage planning). Read the **[Design Session: Novel-Generation Cost, Prompt Caching & Workflow/Chatflow Architecture (2026-08-12)](#design-session-novel-generation-cost-prompt-caching--workflowchatflow-architecture-2026-08-12)** section at the bottom.
>
> **⚠️ 2026-08-13 (setup wizard polish & countdown removal)**: the setup wizard's buttons were unified (fixed at 75% of the page height and relabelled to localized "Next"), the final-confirmation button was moved to the bottom of its scrollable content, the language-selection box was aligned with the location/era input boxes (the missing navigation bar was the root cause), and the 5-second countdown display was removed so the previously-delayed action runs immediately after moderation passes. Read the **[Setup Wizard UI Polish & Countdown Removal (2026-08-13)](#setup-wizard-ui-polish--countdown-removal-2026-08-13)** section at the bottom.
>
> **⚠️ 2026-08-13 (story-page UX & localization hardening)**: eliminated the display jump when the typewriter starts typing, made the "Generating new content…" indicator disappear once typing begins, stabilized the typewriter so it never re-types from a wrong position, kept historical input cards populated with the choice values saved at the moment of the user's choice, kept every popup and error string in the current app language, made the language-selection picker default to the user's language (stored → system → English), and preserved the language preference across the "Restart" reset. Read the **[Story-Page UX Hardening & Full-Language Localization (2026-08-13)](#story-page-ux-hardening--full-language-localization-2026-08-13)** section at the bottom.
>
> **⚠️ 2026-08-13 (full chatflow summary)**: a consolidated, English, desensitized summary of the whole 2026-08-13 chatflow — setup-wizard polish & countdown removal, continuation-button copy, disabled-button visuals, blank-input guards, and the story-page UX hardening (jump-free typewriter, stable layout, full localization). Read the **[Full Chatflow Summary — Setup & Story-Page UX Hardening (2026-08-13)](#full-chatflow-summary--setup--story-page-ux-hardening-2026-08-13)** section at the bottom.

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
6. **Confirmation page** → server moderation passes → enter the main story page.
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

**Final typewriter scheme (Flutter)** — [`TypewriterText`](AI-SAGA/lib/widgets/character_text.dart:48) with dynamic speed ([`_currentCharsPerTick()`](AI-SAGA/lib/widgets/character_text.dart:134)):

> This is the exact scheme we settled on after iterating on the cadence. It deliberately starts **from the very first character at the slowest possible speed** and steps up by the **minimum allowed acceleration increment** every 20 characters.

**Parameters:**

| Parameter | Value | Meaning |
|---|---|---|
| `tickInterval` | **150 ms** | one timer tick per 150 ms |
| `charsPerTick` | **1** (start) | slowest possible speed — 1 char per tick ≈ **6.7 chars/s** |
| `speedUpEvery` | **20** | every 20 chars typed within the current segment, speed increases |
| acceleration step | **+1 char/tick** | the minimum allowed increment (no finer granularity exists with integer char/tick) |
| `segmentStart` | per segment | speed is computed from **in-segment progress** (`visibleLen − segmentStart`), so every new segment restarts from the slowest speed |

**Speed curve (per segment, 150 ms/tick):**

| Progress within segment | char/tick | ≈ chars/s |
|---|---|---|
| chars 1–20 | 1 (slowest) | ≈ 6.7 |
| chars 21–40 | 2 | ≈ 13.3 |
| chars 41–60 | 3 | ≈ 20 |
| chars 61–80 | 4 | ≈ 26.7 |
| chars 81–100 | 5 | ≈ 33.3 |
| … every +20 chars | +1 | steadily increasing |

**Behavior:**
- **First generation**: types from char 1 at the slowest speed (≈6.7 chars/s), then accelerates one notch every 20 chars.
- **Every continuation input** (one of the three input boxes): the new segment **restarts from the slowest speed** and accelerates again from its own start — it never inherits the already-fast speed of the previous segment.
- **No reveal-all**: the remainder is **not** dumped at once (`revealAll` is no longer used); the whole story types out with a continuously increasing speed, which is exactly the “不断加速” (keep accelerating) feel requested.
- A blank line (`\n\n`) separates each new segment, so the reader sees each continuation go through its own slow → fast arc.

**Key Q&A that shaped this**:
- *“打字要结合 Dify 和服务器修改，还要兼容审核。两端都要做什么？”* → **Dify**: enable streaming response mode; **FastAPI**: SSE bridge + two-phase audit; **Flutter**: SSE client + typewriter widget.
- *“将文章输出一半的时候进行审核，会如何影响打字机效果？”* → Auditing mid-stream before the first visible character keeps the typewriter from ever showing unaudited content; the phase-2 audit happens after generation completes, so there is no interruption to the ongoing typewriter.
- *“400 字中断在 Dify 实现还是 FastAPI 实现？”* → **FastAPI**. Dify streams tokens; the 450-char split is a server-side buffering decision, so we can also change the threshold without touching the Dify canvas.
- *“小说数据流全部结束后，还要接收几个后续的变量，可行吗？”* → Yes — the `workflow_finished` event carries `outputs`, which the server forwards in the `reveal`/`done` events for any downstream variables.
- *“400 字打字机效果能顶几秒？四百字读者阅读时间？”* → We estimated the typing/reading cadence to choose a comfortable first-batch length; 450 chars keeps the opening dramatic without dragging.
- *“生成一段文字就审核一段、通过再传输，技术上难度？”* → Segment-by-segment moderation is possible but doubles audit calls and complexity; the chosen two-phase design gets most of the safety with only two audits per story.
- *“有一种一百字强制审核一次的方法，怎么实现的？”* → Forced per-100-char audits were discussed as a stricter variant; the 450 + overlap design was adopted instead to balance safety, latency, and cost.
- *“加快打字速度的最小字数单位极限是几个字？”* → The code allows a hard floor of **1 char** (the `speedUpEvery` divisor can be 1), but the *meaningful* minimum at 30 ms/tick is ≈10–20 chars — below that the +1 char/tick increments compound so fast the text finishes in a few ticks, with no visible ramp. We chose **20 chars**, then slowed the base tick to **150 ms** so the slowest start is ~6.7 chars/s.
- *“初始打字速度能更慢吗？”* → Yes. Because 1 char/tick is already the integer floor, the only way to slow the start further is to **lengthen the tick interval** (30 ms → 150 ms), which is exactly what we did while keeping the +1 char per 20 chars acceleration.

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

---

# Architecture Update (2026-08-08)

> Session covering: story **storage model**, **server-authoritative generation**, **tail-only startup sync with index alignment**, **quota simplification**, **weighted input limits**, **DB-based continue/reset detection**, and a **completeness-gap analysis** for persistence. Written in English for other developers. **Desensitized** — no secrets, credentials, emails, or real user/device identifiers appear anywhere in this document.

## 1. Story storage: from one JSON blob per user to one row per segment

**Before.** The `stories` table stored the whole novel as one JSON array string (`segments`) in a single cell. Every continuation did a full read–modify–write of the entire cell, so write cost grew linearly with novel length; WAL churned; there was no indexed random access by segment index.

**Now (implemented).** A normalized table stores **each generated segment as its own row**; `seq` is the integer array index and matches the app’s `List<String>` index exactly.

```sql
CREATE TABLE IF NOT EXISTS story_segments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    TEXT NOT NULL,
    seq        INTEGER NOT NULL,   -- 0,1,2,... = array index
    content    TEXT NOT NULL,      -- one generated segment only
    created_at INTEGER NOT NULL,
    UNIQUE(user_id, seq)
);
CREATE INDEX idx_segments_user_seq ON story_segments(user_id, seq);
```

**Consequences**
- Appending one segment = one `INSERT` with `seq = MAX(seq)+1` — **O(1), never rewrites old rows** ([`_persist_story_segment`](AI-SAGA/server/main.py:1169)).
- Indexed lookup by `seq` is O(log n) and touches only the target row.
- `previous_story` (context for the next generation) is read with `ORDER BY seq DESC LIMIT 1` + a `COUNT(*)` only when needed ([`_get_story_tail`](AI-SAGA/server/main.py:1150)).
- The old `stories` table and its JSON logic were removed (project is pre-release, no data migration needed).

**Scale notes (for planning):** a ~10 000-character Chinese novel ≈ 30 KB raw (UTF-8 3 bytes/char) and ≈ 32–40 KB stored. Local SSD read of that is ~0.1–1 ms; one `INSERT` is ~0.05–0.2 ms regardless of length. SQLite is comfortable to ~100 GB–1 TB; the real constraint is *per-user* blob size, which the per-row model removes. (This is the fix for the old “whole-array rewrite” concern.)

## 2. Server-authoritative generation pipeline

The app is deliberately a thin client: it uploads **only the user’s latest instruction**; the server derives everything else from its own database.

```
Flutter setup confirmed → generateStoryStream(user_input: "", location, era, player...)
  ▼ POST /api/generate-story  (Authorization: Bearer <token>)
server:
  settings   = _resolve_story_settings(user_id, data)  # 第一轮用请求上传，续写读最新一段快照
  previous_story, counter = _get_story_tail(user_id)   # from story_segments
  dify_payload = { ...settings..., previous_story, user_input, counter, max_tokens }
  → Dify fiction workflow (streaming)
  → two-phase moderation → SSE chunk/reveal → done
  → _persist_story_segment(user_id, final_text, settings, choices)  # single row INSERT
```

- **Settings + language travel with the story, no separate table**: there is **no `user_settings` table**. After the setup the app only keeps settings locally; on the **first** generation it uploads them in the `/api/generate-story` request, and the server writes them into that segment’s snapshot columns (`location/era/player_*/partner_*/language`) alongside the story body ([`_persist_story_segment`](AI-SAGA/server/main.py:1183)). Later rounds send no settings; the server reuses the latest segment’s snapshot (including `language`) ([`_resolve_story_settings`](AI-SAGA/server/main.py:1228)). The stored `language` is the authoritative base for all language-related generation.
- **Previous-segment context comes from the server array**, passed to Dify as `previous_story` — the LLM now actually sees the prior story (previously the payload had no story context at all).
- **Persistence is server-authoritative**: as soon as the server has the complete text (and it passes moderation) it writes the new row, **regardless of whether the app received the stream**. The old `POST /api/story` whole-array push from the app was removed.

> **Dify integration note**: for `previous_story` to reach the LLM, the Dify **fiction** workflow’s Start node must bind a `previous_story` input variable and use it in the prompt. If the workflow uses a different variable name, update [`dify_payload`](AI-SAGA/server/main.py:1241) accordingly.

## 3. Tail-only startup sync + index alignment (no full download)

**Before.** Cold start downloaded the entire novel (`GET /api/story` → full array) into local storage, so list index == server index trivially.

**Now.** Cold start downloads **only the last 3 segments**; earlier segments are lazily fetched when the user scrolls to the top. Because indices are load-bearing (choice markers, the time-tree placeholder), the app tracks a **base offset** so the local list index maps exactly to the server `seq`.

- `GET /api/story` supports `?limit=N` (tail) and `?before_seq=X&limit=N` (older batch), and returns `start_seq` (index of `segments[0]`) plus `total` only for full pulls ([`story_get`](AI-SAGA/server/main.py:1584)). For tail/lazy pulls the `COUNT(*)` is skipped to save DB work.
- App `SyncService` returns a `StorySnapshot{segments, startSeq, total}`; startup pulls `tailLimit = 3`; scrolling up fetches `previousBatchLimit = 10` at a time ([`fetchPreviousSegments`](AI-SAGA/lib/logic/sync_service.dart:70)).
- `home_content` keeps `_storyStartIndex` such that `_storyTexts[i]` has absolute index `_storyStartIndex + i` ([`home_content.dart`](AI-SAGA/lib/logic/home_content.dart:95)). Lazy-load **prepends** a batch, shifts `_storyStartIndex`/`_visibleStartIndex`/`_sessionStreamStartIndex`, and compensates the scroll so the viewport does not jump ([`_loadPreviousSegment`](AI-SAGA/lib/logic/home_content.dart:210)).
- Choice records store the **absolute** segment index (created/deduped/rendered as `_storyStartIndex + localIndex`), so indices stay aligned no matter how much is lazily loaded.

**Performance impact.** Returning 3 segments instead of N cuts bandwidth and JSON serialization by ~90–97%; DB work for the tail query is now just a `LIMIT` read (no `COUNT`). Estimate for 100k cold starts/day, ~100 segments each: ~3.2 GB/day → ~100 MB/day transfer.

## 4. Quota & cost simplification

Per-user trial/paid quotas were removed in favour of **two global rolling 24 h budgets** (simplified logic; paid personal quotas to be reintroduced later with the payment feature):

| Budget | Default | Where enforced |
|---|---|---|
| Audit Dify workflow | **2000 calls / day** (all users) | [`_check_audit_quota`](AI-SAGA/server/main.py:1028), counted in `/api/audit-and-chat` and `_moderate_story` |
| Fiction generation workflow | **1000 calls / day** (all users) | [`_check_story_quota`](AI-SAGA/server/main.py:1002) |

- Removed: `trials` table, `_grant_trial_if_due`, `_consume_trial`, `TRIAL_QUOTA`, `TRIAL_COOLDOWN_SECONDS`, `PAID_DAILY_QUOTA`/`PAID_RATE_PER_MINUTE` enforcement (constants kept, unused, for the future paid feature).
- Input hard-gate: `MAX_INPUT_CHARS = 4000`, `MAX_INPUT_TOKENS = 5000` (settings + user instruction, checked before any spend).
- Whole-novel cap: `MAX_STORY_TOTAL_CHARS = 100 000 000` (≈ unlimited; only enforced on the dormant whole-array push endpoint).

> **Superseded sections**: README §6 (input caps), §7 (trial/paid model), §17 (`STORY_DAILY_LIMIT=500`), and the roadmap item “SQL story persistence” — the values/design changed today.

## 5. Weighted character-count input limits

Both the story input boxes and the four setup pages enforce limits by **display width**: wide characters (Han/Kana/Hangul/full-width) count **2**, narrow characters (Latin/digits/ASCII) count **1** — implemented in the shared helper [`text_width.dart`](AI-SAGA/lib/logic/text_width.dart:9).

| Surface | Limit (weighted) | Behaviour |
|---|---|---|
| Story input boxes (3) | **200** | soft limit: text turns **red** and the confirm button is **grey/disabled** when over; input is not truncated ([`text_input_panel.dart`](AI-SAGA/lib/widgets/text_input_panel.dart:6)) |
| Setup pages (location, era, player, partner) | **20** | same soft-limit treatment; button text is no longer swapped to an “over limit” message ([`location_setup_page.dart`](AI-SAGA/lib/widgets/location_setup_page.dart:38), etc.) |

Example: 100 Chinese characters ≈ weighted 200 → exactly at the story-box limit; 200 Latin letters ≈ 200. The character-count helper is shared by the panel and all four setup pages.

## 6. Continue-vs-fresh is decided by the database (not the app)

The server no longer infers “new story” from an empty `user_input` (that was an app-trusted heuristic). Instead:

- **Continuation** is decided purely by whether `story_segments` has rows: if it does, the server reads the last segment as context and appends; if the table is empty, it starts from `seq = 0` with no previous context ([`_get_story_tail`](AI-SAGA/server/main.py:1150)).
- A dedicated **reset** (“start a new story”) is intentionally **not** part of the generation endpoint — it is an explicit app-side feature (recommended UX below), so a malformed/empty input can never wipe a stored story.

**Recommended app-side reset UX** (not yet implemented): add a destructive **“New Story”** action to the existing menu sheet ([`_showMenuSheet`](AI-SAGA/lib/main.dart:466)) with a confirm dialog mirroring [`_showConfirmRestartDialog`](AI-SAGA/lib/main.dart:898). On confirm: call a new `DELETE /api/story` (server runs [`_reset_story`](AI-SAGA/server/main.py:1203), i.e. `DELETE FROM story_segments WHERE user_id=?`), clear local story + `main_text_start_index`, then rebuild `HomeContent`. Because the generation path is DB-driven, the next generation naturally restarts at `seq = 0`.

## 7. Persistence completeness — known gap & mitigation plan (IMPORTANT)

**Current guarantee.** A new segment is written to the DB **only once the server has the complete text**, and only if moderation passes. `_persist_story_segment` is called in exactly three mutually-exclusive places, all of which persist the *whole* segment:

1. On Dify’s explicit `workflow_finished` event (normal path) — the definitive “all text delivered” signal ([`server/main.py:1363`](AI-SAGA/server/main.py:1363));
2. Fallback when the stream ends cleanly but no `workflow_finished` arrived and the first chunk was never sent — persists the accumulated `full_text` ([`server/main.py:1375`](AI-SAGA/server/main.py:1375));
3. Fallback when the stream ends cleanly, the first chunk was already sent and the rest arrived — persists `full_text` ([`server/main.py:1383`](AI-SAGA/server/main.py:1383)).

The 450-char “first chunk” is only **transmitted** to the app (typewriter display) after its own audit — it is **never persisted separately**, and there is no “insert then delete if it fails” anywhere.

**Known gap.** A genuine mid-stream network failure raises inside the `async for` and is caught by `except httpx.RequestError`/`except Exception`, so the fallback is **not** reached and no partial text is persisted. However, the fallback treats **“SSE stream closed cleanly without `workflow_finished`”** as *complete*. If a proxy or Dify closes the stream gracefully before all text is delivered, the server cannot distinguish “done” from “aborted early” and would persist a possibly-truncated segment.

**Recommended fix (agreed direction, not yet implemented).** Make an explicit end marker the **only** completeness signal:
- Only persist when the workflow emits an explicit finish marker (e.g., `workflow_finished`, or a dedicated `story_complete: true` field, or a custom event);
- Treat a clean close **without** the marker as incomplete → discard + error, never persist;
- Optionally include a checksum/`char_count` in the marker so the server can verify `len(full_text)` matches before writing (defense in depth).

Trade-off: generations from a Dify workflow that never emits the marker would be judged incomplete — this is the intended “rather lose a generation than store truncated text” trade-off. Implement once the Dify-side marker format is finalised.

## 8. Account & hardware security restrictions (reference)

The login/registration surface enforces, in order:

1. `device_id` whitelist regex (`^[A-Za-z0-9._:-]{1,128}$`).
2. IP rate limit (20 register-challenges/hour/IP, persisted).
3. One-time signed challenge (replay protection).
4. Official JWKS verification of the Apple/Google ID token; the server takes `sub` as the real `user_id`.
5. Hardware proof-of-possession: ECDSA P-256 signature over the challenge.
6. `public_key UNIQUE` — one hardware ↔ one device binding.
7. **Same-hardware account-switch cap**: max **2 distinct accounts per hardware per 24 h** (`HARDWARE_ACCOUNTS_PER_DAY`, default 2); switch-back to an account seen in the last 24 h is allowed; otherwise `409 hardware_account_limit`.
8. Same-hardware same-account re-registration allowed (reinstall recovery).
9. HMAC-signed token, 7-day expiry, binds `{user_id, device_id}`.
10. Single active device per account (`409 device_conflict`) → app shows an English warning and gracefully restarts.

App-side handling: `hardware_account_limit` → English “Too Many Account Switches” dialog with an **Exit App** button ([`account_limit_warning.dart`](AI-SAGA/lib/widgets/account_limit_warning.dart:10)); `device_conflict` → restart via `RestartWidget`; token expiry → one-tap re-authorization via `LightAuthPage` (sync gate, generation, and audit paths).

## 9. Verification

After the changes: `python3 -m py_compile server/main.py` → OK, and `flutter analyze` → no issues. Run both after touching the server or the Dart sources.

---

# Content Moderation & Guardrail Hardening (2026-08-08)

> Session covering: moving every guardrail audit onto the **final setup confirmation page**, replacing the fragile `action: none` **substring regex** with **strict, server-authoritative JSON verdict parsing** (fail-closed), localized **network-error handling** when no verdict can be obtained, and the **Dify (AWS Bedrock Guardrails)** integration notes (including the `Array` output shape). Written in English for other developers. **Desensitized** — no secrets, credentials, emails, or real identifiers appear anywhere.

## 1. Moderation consolidated onto a single confirmation point

**Before.** Each of the four setup pages — location ([`location_setup_page.dart`](AI-SAGA/lib/widgets/location_setup_page.dart:305)), era ([`era_setup_page.dart`](AI-SAGA/lib/widgets/era_setup_page.dart:243)), player ([`player_setup_page.dart`](AI-SAGA/lib/widgets/player_setup_page.dart:180)) and partner ([`character_setup_page.dart`](AI-SAGA/lib/widgets/character_setup_page.dart:212)) — opened an `AuditDialog` on its own Confirm button, sending **only that page’s field** to the server. That meant up to four separate guardrail calls per onboarding and no holistic check of the combined settings.

**Now (implemented).** The four pages’ buttons only validate, play a sound, write their value to `SetupDraft`, and advance. **Only the final setup confirmation page** triggers the guardrail: its Confirm button runs [`_onConfirmPressed`](AI-SAGA/lib/widgets/setup_confirmation_page.dart:479), which builds one audit text from **all** user settings (location, era, player gender/name, partner gender/name/traits) via [`_buildAuditText`](AI-SAGA/lib/widgets/setup_confirmation_page.dart:490), opens the `AuditDialog`, and only on approval starts the 5-second countdown that enters the main page.

- **Pass** → countdown → main page.
- **Fail** → the dialog shows the localized rejection message: “Your settings may contain sensitive information. Please review and set them again. Sorry.” (translated across all 10 supported languages in [`audit_dialog.dart`](AI-SAGA/lib/widgets/audit_dialog.dart:289)); the user stays on the confirmation page and can tap “Edit” on any card to revise.

This is a deliberate UX + compliance change: one audit for the whole profile, a single clear rejection point, and no wasted guardrail calls on intermediate steps.

## 2. Strict JSON verdicts replace the `action: none` substring regex

**The fragility being fixed.** Both the server ([`_moderate_story`](AI-SAGA/server/main.py:1118)) and Flutter ([`_isApproved`](AI-SAGA/lib/widgets/audit_dialog.dart:136), since removed) used `re.search(r'action\s*[:=]\s*none', rawText)` over the entire audit response. Any occurrence of `action: none` **anywhere** — including inside a `reason`, `assessments`, or `actionReasons` field — counted as “approved”. This is a false-pass risk and a fragile contract on free text.

**Now (implemented).** The server is the single authority and parses the guardrail result as **structured JSON**, reading only the **top-level `action` field**:

| Function ([`server/main.py`](AI-SAGA/server/main.py:1008)) | Role |
|---|---|
| [`_extract_first_object`](AI-SAGA/server/main.py:1008) | From the decoded JSON, get one object (dict): accept a dict directly, the first dict element of an array, an array of JSON-encoded strings (double-serialization), or a top-level JSON string. Returns `None` otherwise (fail-closed). |
| [`_parse_audit_output`](AI-SAGA/server/main.py:1042) | Strip markdown code fences if present, `json.loads`, then delegate to `_extract_first_object`. |
| [`_parse_audit_json`](AI-SAGA/server/main.py:1066) | Read the **exact** top-level key `action` (case-insensitive key lookup, value trimmed + lowercased). Does **not** recurse into nested fields. Missing / non-string → `None`. |
| [`_moderate_story`](AI-SAGA/server/main.py:1202) | Story-generation moderation gate returning a **tri-state** [`ModerationOutcome`](AI-SAGA/server/main.py:1169): `PASS` (`action=="none"`), `REJECT` (definitive non-none verdict → `abort`), `UNAVAILABLE` (quota / network / no-verdict → retryable `error`, **not** a violation). |
| [`_build_audit_verdict`](AI-SAGA/server/main.py:1090) | Produces the clean verdict returned to the client: `{action, category, confidence, reason}`; unparseable → `action="block"`. |

- **Dify audit output variable renamed** from `text` to **`guardrail_return_json`** in both consumers ([`/api/audit-and-chat`](AI-SAGA/server/main.py:942) and [`_moderate_story`](AI-SAGA/server/main.py:1144)). The story-generation workflow’s `outputs.text` (the generated story) is unaffected.
- **`/api/audit-and-chat` now returns a structured verdict** (`{"action":"none"|"block",...}`) instead of forwarding the raw Dify text.
- **Flutter** [`_parseAction`](AI-SAGA/lib/widgets/audit_dialog.dart:167) reads the verdict’s top-level `action` field strictly (`none` → approved, anything else → rejected). The old regex and all legacy “compatibility with the old plain-string + `action: none` substring” code were **removed** (verified: zero matches across the repo).

**Why this is strictly safer.** Because only the real top-level `action` field counts, text like `"the model says action: none here"` buried inside `assessments`/`actionReasons`/`reason` can no longer cause a false pass — and a genuine `NONE` top-level value is no longer blocked by unrelated `action: block` text elsewhere. Verified with adversarial tests (see §5).

## 3. Network / no-verdict handling

Per requirement: if the app **cannot obtain a valid verdict for any reason** (network exception, timeout, server unreachable, or a 2xx response whose body is not a usable verdict), it must **not** guess pass/fail — instead it shows a localized network message.

- Added [`getNetworkErrorMessage`](AI-SAGA/lib/widgets/audit_dialog.dart:271): “It seems your network connection is having issues. Please check your connection and try again.” (translated across all 10 languages).
- In [`_callAuditServer`](AI-SAGA/lib/widgets/audit_dialog.dart:40): transport errors/timeouts and an invalid verdict body all set this message; a valid `action` value is the **only** thing that drives pass/fail.
- **Non-2xx business errors** (e.g. 403 trial exhausted, 429 rate-limited) still surface the server’s own error message — those are “a response was received”, distinct from “no response at all”. This can be changed to the network message too if desired.
- **Story-generation stream** ([`_stream`](AI-SAGA/server/main.py:1618)): [`_moderate_story`](AI-SAGA/server/main.py:1202) now returns the tri-state [`ModerationOutcome`](AI-SAGA/server/main.py:1169). Only a **definitive rejection** (`REJECT`) emits the `abort` event → app shows the “内容违规” dialog; quota exhaustion, transport failures, non-200, or an unparseable verdict (`UNAVAILABLE`) emit an `error` event → app shows the retryable network-style warning instead. This prevents weak network / audit-service hiccups from being misreported as user content violations.
- **App generation-error dialog** ([`_showGenerateError`](AI-SAGA/lib/logic/home_content.dart:2083)): now offers a **single “restart” action** (no “skip”/“retry”). Restarting re-runs startup sync, which pulls server-persisted segments back so local and server stay aligned — preventing both the old history wipe (retry routed to `_onSetupConfirmed`) and the “local shows one fewer segment” drift that skip/retry could leave behind until a restart.

## 4. Dify canvas requirement (one-time manual step)

The server now reads `outputs.guardrail_return_json` and expects it to be JSON containing a top-level `action` field. Configure the **audit workflow**:

1. **Final LLM node** prompt — output strict JSON only, for example:
   ```text
   Audit the following text and output a single JSON object with exactly these fields:
   {"action":"NONE|BLOCK","category":"<category>","confidence":"<0..1>","reason":"<short reason>"}
   Rules: action=NONE when the content has no significant issue (fictional religious/historical/cultural
   backgrounds are allowed); action=BLOCK for denigration, hate, incitement, attacks on real people/groups,
   private information, violence, or sexual content. category ∈ none|religion|politics|ethnicity|violence|sexual|pii|other.
   Text: {text_to_screen}
   ```
2. **End node** must expose this JSON as the output variable **`guardrail_return_json`** (not `text`).
3. If the guardrail node is backed by **AWS Bedrock Guardrails**, its response is `{action, actionReasons, assessments, outputs, processedOutputs, warnings}` and Dify often wraps it in an **Array** — the parser handles direct objects, arrays of objects, arrays of JSON-encoded strings, and double-serialized strings, so no extra wiring is needed.

## 5. Verified behaviors

Tested server-side parser against representative inputs (`pass` column = would approve):

| Input shape | Result |
|---|---|
| Direct object `{"action":"NONE",...}` | ✅ pass |
| Array of objects `[{"action":"NONE",...}]` (Bedrock/Dify Array) | ✅ pass |
| Array of JSON-encoded strings `["{\"action\":\"NONE\",...}"]` | ✅ pass |
| Double-serialized top-level string `"[{...}]"` | ✅ pass |
| Array with `action:"GUARDRAIL_INTERVENED"` | ❌ block |
| Empty array / array of non-objects / non-JSON | ❌ block (fail-closed) |
| Top-level `BLOCK` + nested `"action: none"` text | ❌ **block** (old regex wrongly passed) |
| Top-level `NONE` + nested `"action: block"` text | ✅ **pass** (old regex wrongly blocked) |

`python3 -m py_compile server/main.py` → OK; `flutter analyze` → no issues.

## 6. Design discussion recap (Q&A)

- **Dual-side moderation**: guard both **input** (prompt/settings) and **output** (generated story). A “clean” prompt can still yield a flagged output, so both directions should go through the same guardrail (`role: input|output`).
- **Layered pipeline**: deterministic NFKC/keyword filter (cheap, hard blocks only) → classifier/moderation model → **LLM judge returning structured JSON**. For humanities/religious content, keywords alone cause false positives on benign cultural references, so the judge does the nuanced “benign background vs. denigration” call.
- **What category/confidence unlock**: per-category localized messaging, locating the offending setting card on the confirmation page, low-confidence → soft-block/human review instead of a hard binary, and (output side) category-aware regenerate/crop instead of aborting the whole story.
- **Looser vs. tighter is a policy knob, not a property of structured parsing**: strict parsing + fail-closed can make the net *tighter* (low-confidence never auto-passes); relaxing benign cultural references reduces false positives but must be guarded against adversarial “historical/cultural framing” bypasses.
- **Guardrail sensitivity ≠ parsing robustness**: maxing the guardrail’s sensitivity setting minimizes false negatives within that judge, but does not fix a fragile text-regex interpretation layer — hence the strict JSON parsing work here is complementary, not redundant.
- **AWS Bedrock `action` values**: only `NONE` (pass) and `GUARDRAIL_INTERVENED` (blocked), which maps cleanly onto the `action == "none"` check.

---

# Session Update (2026-08-09)

> Session covering: fixing the audit gateway when Dify returns `guardrail_return_json` as a JSON **array**, adding a localized **empty-output quota warning** (without the word “LLM”) for both new and existing users, several **story-page UI refinements**, and the **flash-free earlier-content loading** UX with a layout-phase scroll compensation. Written in English for other developers. **Desensitized** — no secrets, credentials, emails, or real identifiers appear anywhere.

## 1. Guardrail extraction hardened for Dify's array output

**The failure.** The app surfaced *“网关内部解析异常: 500: Dify 未返回有效的 guardrail_return_json 字段”*. Two distinct causes were found and fixed in [`/api/audit-and-chat`](server/main.py:968) and [`_moderate_story`](server/main.py:1208):

1. **Double-wrapped `HTTPException`**: an exception raised inside the `try` was caught by the broad `except Exception` and re-wrapped, turning a clean 400/429 into a confusing 500. Fixed with an explicit `except HTTPException: raise` plus a status-failed check.
2. **Dify returns an array, not a string**: once the workflow was re-published, Dify delivered `guardrail_return_json` as a JSON **array** (e.g. Bedrock-style `[{...}]`), which the old string-only parser rejected. The new [`_extract_guardrail_output`](server/main.py:309) accepts a string, a dict, a list, an array of JSON-encoded strings, and double-serialized strings, then normalises the verdict back to a single JSON string via an inner `_coerce`. Both consumers now use it, so the app consistently receives `{"action":"none"|"block",...}`.

## 2. Localized "empty output" quota warning

When the server/Dify returns **blank story text** (e.g. the operator's LLM quota is exhausted), the streaming endpoint now emits an SSE error event `{"event":"error","code":"empty_output", ...}` in three places (before the first chunk was sent, after it was sent, and at stream-end fallback). See [`generate_story`](server/main.py:1372).

- [`story_service.dart`](lib/logic/story_service.dart:32) changed `onError` to `void Function(String message, {String? code})` and forwards `code`.
- [`home_content.dart`](lib/logic/home_content.dart) treats `code == 'empty_output'` (and a stream that ended without any content) as a **quota warning** and shows a localized dialog — for **both** brand-new and existing users, and never exposes the string “LLM”. Example (default/zh): *“服务器未返回有效的小说正文，请检查额度是否已用尽，或稍后重试”*, translated across all 10 supported languages via `_getQuotaWarningText()`.

## 3. Story-page UI refinements

- **Continue button stays visible while generating** — it is only greyed-out/disabled (via a new `disabled` parameter on `TextInputPanel`) instead of disappearing.
- **Generating prompt & button labels are localized** per the user's language.
- **The “generating…” indicator moved below the buttons**.
- **Removed the extra leading blank line** that used to precede each newly displayed continuation segment.

## 4. Earlier-content lazy loading (the deep topic)

### 4.1 Cursor model

The app never keeps the whole novel in memory. Three integer cursors drive everything ([`home_content.dart`](lib/logic/home_content.dart)):

| Cursor | Meaning |
|---|---|
| `_storyStartIndex` | server `seq` of the **first** local segment. `> 0` ⇒ earlier content still exists remotely. |
| `_visibleStartIndex` | index of the **first rendered** segment. Restart loads only a tail; older in-memory segments are revealed one at a time as the user scrolls up. |
| `_sessionStreamStartIndex` | index at which current-session **typewriter** segments begin (older history is rendered fully, not typed). |

Choice markers store **absolute** indices (`_storyStartIndex + localIndex`) so alignment is preserved no matter how much is lazily prepended.

### 4.2 Fetch policy

Scrolling to the top triggers [`_loadPreviousSegment()`](lib/logic/home_content.dart:303): if `_visibleStartIndex > 0` it reveals one in-memory segment (branch 1); otherwise it fetches one remote batch of `previousBatchLimit = 10` segments (branch 2) via `fetchPreviousSegments(beforeSeq)`. A **cooldown** (`_lastServerLoad`, 800 ms) prevents a single fling from firing multiple batches, and each trigger fetches **exactly one** batch — this fixed a previous ~10–15 s stall caused by chained loading.

### 4.3 Top pull-area UX

Only when `_storyStartIndex > 0` does the scroll content begin with a blank band of `_earlierPullHeight` (~1/4 screen, clamped 80–280 px) with a centered `CupertinoActivityIndicator` while `_downloadingEarlier` is true. New users with no older content see **no** blank area. When new segments arrive they are inserted at the top of `_storyTexts` (below the band) and rendered immediately (`_visibleStartIndex = 0`), so the band is “filled from the bottom upward” and the reader can keep scrolling to older batches.

### 4.4 Flash-free same-frame compensation (the centerpiece)

**The bug being fixed.** The original code inserted the new segments via `setState` and then compensated in `addPostFrameCallback` with `jumpTo(oldOffset + added)`. Post-frame callbacks run **after paint**, so for one frame the viewport rendered the new content at the old (wrong) offset and the visible text shifted down by the full inserted height — a flash/jump the user could clearly see.

**The fix — compensate during layout, in the same frame, before paint.** Two small classes were added to [`home_content.dart`](lib/logic/home_content.dart):

- [`_CompensatingScrollController`](lib/logic/home_content.dart:29) extends `ScrollController`, adds a one-shot `armCompensation()` / `consumeCompensation()` / `disarmCompensation()` flag, and overrides `createScrollPosition` to return the custom position.
- [`_CompensatingScrollPosition`](lib/logic/home_content.dart:69) extends `ScrollPositionWithSingleContext` and overrides `correctForNewDimensions(oldMetrics, newMetrics)` — a hook the framework calls inside `applyContentDimensions()` **during layout**, before anything is painted. When the armed flag is consumed and `newMetrics.maxScrollExtent > oldMetrics.maxScrollExtent`, it computes

  ```dart
  final delta = newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
  correctPixels(pixels + delta);
  return false; // request one more layout pass in this same frame
  ```

  and otherwise defers to `super.correctForNewDimensions`.

Because `delta` is the difference of the **real rendered** `maxScrollExtent` before/after the insert, it exactly equals the height of everything that was prepended (text, choice markers, the per-segment “restart here” cards) — no TextPainter estimation, and therefore robust to **any future element types**. Compensating relative to the **current** `pixels` also keeps the view static even if the user reversed direction (scrolled down) while the batch was downloading.

The flow in [`_loadPreviousSegment`](lib/logic/home_content.dart:303): capture nothing up front → `_scrollController.armCompensation()` → `setState(insert…)` → the very same frame's layout applies the exact correction → post-frame `disarmCompensation()` (safety net if no layout occurred, preventing a stray later compensation) + hide the spinner.

### 4.5 Why not measure with TextPainter?

The naive “measure first” plan estimates the text height with `TextPainter`, but each history segment is followed by a large `StoryChoiceCard` (3 inputs + 3 buttons) — replicating that by hand is error-prone, and any error resurfaces as a flash. The layout-phase hook sidesteps measurement entirely because the framework hands us the true height.

### 4.6 Scope & caveats

- The compensation is **armed** only inside `_loadPreviousSegment` for top-insertions. Any future feature that inserts content above the current viewport must call `armCompensation()` before its `setState`, or it will fall back to the default (flashing) behavior. Reuse the same controller type.
- The formula is exact only when the insert is at the **top** of the scroll content. Inserting into the middle would not keep both the above and below content static.
- Typewriter growth (content growing **below** the viewport) is intentionally **not** compensated — the flag is not armed on that path, and the view correctly stays put.

## 5. Verification

`flutter analyze` → no issues (including the new `ScrollPosition` subclass — `correctPixels`/`correctForNewDimensions` are `@protected`, called only from within the subclass). **Important for testing**: because the scroll controller's *type* changed, verify with **Hot Restart (↻/R)**, not Hot Reload (⚡/r) — Hot Reload keeps the old plain `ScrollController` instance, which lacks `armCompensation()`.

---

# Time-Tree Choice Cards & Story-Storage Deep-Dive (2026-08-09)

> Session covering: a deep-dive into the **SQLite story-segment storage model** and its read/write paths, and the **time-tree choice-card UI** — a persistent block of three input boxes + three buttons under every historical paragraph, with a button-below layout and two new localized button labels. Written in English for other developers. **Desensitized** — no secrets, credentials, emails, or real identifiers appear anywhere.

## 1. Story storage model (deep-dive)

### 1.1 Schema — one row per generated segment

The novel is stored in SQLite as one row per generated segment ([`story_segments`](server/main.py:156)):

| Column | Meaning |
|---|---|
| `user_id` | owning account (stable platform `sub`) |
| `seq` | segment index (`0,1,2,…`), identical to the app's `List<String>` index; `UNIQUE(user_id, seq)` |
| `content` | this segment's text |
| `created_at` | write timestamp |
| `choice_1` / `choice_2` / `choice_3` | the three choice inputs offered that round (per-row snapshot) |
| `location`, `era`, `player_*`, `partner_*`, `language` | the user's settings snapshot at the moment this segment was generated |

The database runs in **WAL mode** and carries the composite index `idx_segments_user_seq ON story_segments(user_id, seq)` ([`server/main.py:177`](server/main.py:177)).

### 1.2 Write path (append-only)

- [`/api/generate-story`](server/main.py:1286) streams from Dify over SSE, moderates the output in two phases, then appends a single row via [`_persist_story_segment`](server/main.py:1174) with `seq = MAX(seq)+1` — **O(1) and never rewrites old rows**. Persistence happens the moment the server holds the complete, approved text, independent of whether the app ever received the stream.
- Continuation context comes from the DB, not the app: only the last segment is read (`ORDER BY seq DESC LIMIT 1` plus a `COUNT(*)`) in [`_get_story_tail`](server/main.py:1155); for later rounds the settings are re-read from the latest segment's snapshot columns in [`_resolve_story_settings`](server/main.py:1231).

### 1.3 Read path (lazy, index-aligned)

[`GET /api/story`](server/main.py:1642) supports a full pull, `?limit=N` (tail-only, no `COUNT`), and `?before_seq=X&limit=N` (older batch). It returns `start_seq` so the app can map each local list index onto the server `seq` exactly. On the app, `_storyStartIndex` keeps `_storyTexts[i]` aligned to the absolute index `_storyStartIndex + i` ([`home_content.dart`](lib/logic/home_content.dart)).

## 2. Time-tree choice cards (UI)

**Goal.** Under every already-generated historical paragraph, keep a persistent block of **three input boxes + three buttons** — the "time-tree" affordance. The three buttons are placeholders for a future branch/restart feature. This session is scoped strictly to **UI structure + localized copy**: no server-side `choice_1/2/3` fetching, and no real branching yet.

### 2.1 New widget: `StoryChoiceCard`

[`story_choice_card.dart`](lib/widgets/story_choice_card.dart:1) renders three `[input box + full-width button below]` rows. The input boxes are plain editable fields styled like `TextInputPanel`; the buttons are greyed out while the typewriter is still streaming (`enabled`) and play a click sound on tap, but their action is a no-op placeholder.

### 2.2 `TextInputPanel.buttonBelow`

[`text_input_panel.dart`](lib/widgets/text_input_panel.dart:38) gained a `buttonBelow` flag (default `false` preserves the original input-left / button-right row). When `true`, the confirm button moves **below** the input box and stretches to full width.

### 2.3 `StoryChoiceMarker` simplified

[`story_choice_marker.dart`](lib/widgets/story_choice_marker.dart:1) is now a text-only "Your choice: …" marker. Its previous "tap to continue the story from here" button was removed, because the time-tree buttons now live in the per-paragraph `StoryChoiceCard`.

### 2.4 Wiring in `home_content.dart`

- [`_buildStoryBody`](lib/logic/home_content.dart:555) inserts a `StoryChoiceCard` under every **historical** segment (not the newest one). The newest paragraph is instead followed by the page-bottom continuation inputs.
- The three **latest** (bottom) input boxes now use `buttonBelow: true`; their confirm buttons read **"Continue the story following the guidance above"** and keep the existing continue logic.
- Historical card buttons read **"Restart from here"** and call the placeholder [`_onRestartHerePressed`](lib/logic/home_content.dart) (TODO — future time-tree return/restart).
- Two new localizers were added across all 10 languages: [`_getLatestContinueButtonText()`](lib/logic/home_content.dart) and [`_getRestartHereButtonText()`](lib/logic/home_content.dart). The now-unused `_getInputConfirmText` and `_getContinueHereButtonText` were removed.

### 2.5 Final layout

| Position | Contents |
|---|---|
| Newest paragraph | three continuation inputs, button below each → "Continue the story following the guidance above" |
| Historical paragraph | `StoryChoiceCard`: three inputs + three "Restart from here" buttons (placeholder) |
| In-text | "Your choice: …" marker only (no button) |

## 3. Verification

`flutter analyze` → no issues across the whole project.

---

# Settings-in-Story Refactor & Language-as-Authority (2026-08-09)

> Session covering: eliminating the dedicated `user_settings` table so that every user setting travels with the story body into per-segment snapshot columns on `story_segments`; adding a `language` column that becomes the authoritative base for all language-related operations; and a debug-mode **fresh rebuild** of the production database (old data fully cleared). Written in English for other developers. **Desensitized** — no secrets, credentials, emails, or real identifiers appear anywhere.

## 1. No more `user_settings` table — settings ride along with the story

**Before.** The app uploaded the seven user settings (`location`, `era`, `player_gender/name`, `partner_gender/name/traits`) to a dedicated `user_settings` table right after setup confirmation (`POST /api/settings`); every generation then read them back from that table.

**Now (implemented).**
- The `user_settings` table, the `POST /api/settings` endpoint, the `SettingsData` model and `_get_user_settings` were **removed** from the server ([`server/main.py`](AI-SAGA/server/main.py:99) schema no longer contains it).
- After setup the app only keeps settings **locally** (no immediate server upload).
- On the **first** generation the app uploads the settings inside the `/api/generate-story` request ([`StoryInputData`](AI-SAGA/server/main.py:440)); the server writes them into that segment’s snapshot columns and uses them for the Dify payload.
- On later (continuation) rounds the app sends no settings; the server re-reads them from the **latest segment’s snapshot** via [`_resolve_story_settings`](AI-SAGA/server/main.py:1317).

```sql
-- story_segments now carries the full per-round context
CREATE TABLE IF NOT EXISTS story_segments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    TEXT NOT NULL,
    seq        INTEGER NOT NULL,
    content    TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    choice_1   TEXT DEFAULT '',
    choice_2   TEXT DEFAULT '',
    choice_3   TEXT DEFAULT '',
    location       TEXT DEFAULT '',
    era            TEXT DEFAULT '',
    player_gender  TEXT DEFAULT '',
    player_name    TEXT DEFAULT '',
    partner_gender TEXT DEFAULT '',
    partner_name   TEXT DEFAULT '',
    partner_traits TEXT DEFAULT '',
    language       TEXT DEFAULT '',
    UNIQUE(user_id, seq)
);
```

## 2. `language` is now the authoritative base

- A `language` column was added to `story_segments` and is persisted on every segment write via [`_persist_story_segment`](AI-SAGA/server/main.py:1260).
- [`_resolve_story_settings`](AI-SAGA/server/main.py:1317) reads `language` from the request on the first generation and from the latest segment snapshot on continuations — the stored value is the single source of truth for language.
- The redundant per-request `language` upload on continuation was **removed** from the app ([`home_content.dart`](AI-SAGA/lib/logic/home_content.dart:437)); only the first generation sends it (to seed the snapshot).

## 3. Three choice inputs are snapshotted too

The three on-page input boxes (`choice_1/2/3`) are tracked live via the new `onChanged` callback on [`TextInputPanel`](AI-SAGA/lib/widgets/text_input_panel.dart:12) and uploaded with the request ([`StoryService.generateStoryStream`](AI-SAGA/lib/logic/story_service.dart:38)), so every segment records the exact choices offered that round.

## 4. Debug-mode fresh rebuild (old data cleared)

Because the schema changed and `CREATE TABLE IF NOT EXISTS` never alters an existing database, the production database was **deleted and rebuilt from scratch** in debug mode:

1. Removed `<server-data-dir>/ai_saga.db` (plus WAL/SHM) on the server (path placeholder — actual path is only in local `.env` / deploy helper, both git-ignored).
2. Uploaded the new [`server/main.py`](AI-SAGA/server/main.py:1) (bind-mounted; uvicorn `--reload` auto-restarted the container).
3. Verified: `user_settings` no longer exists, `story_segments` now has the `language` column, and `/api/health` returns `{"status":"ok","registered_users":0,"registered_devices":0}`.

## 5. Verification

- `python3 -m py_compile AI-SAGA/server/main.py` → OK
- `flutter analyze` → no issues across the whole project
- Server container reloaded cleanly (`StatReload detected changes in 'main.py'. Reloading...` → `Application startup complete.`) and `/api/health` is healthy on a fresh, empty database.

---

# Session Update (2026-08-10)

> Session covering: the **Dify fiction workflow redesign** (story text streams first, structured metadata arrives afterwards), the **`<think>`-block stripping & unwrap** hardening on the server, **metadata persistence with guaranteed fallbacks**, the **recommended-action input boxes** on the story page, **per-segment choice display** pulled from `/api/story`, and the **time-tree "restart from here" rewrite** that reuses the standard continuation pipeline. Written in English for other developers. **Desensitized** — no secrets, credentials, API keys, server addresses, or real identifiers appear anywhere.

## 1. Dify fiction workflow: story-first streaming + metadata-after

### 1.1 The core constraint

The server consumes the Dify stream as follows: every `text_chunk` is accumulated into the story, and `workflow_finished.outputs.text` is the authoritative full story (used for two-phase moderation and persistence). Therefore the LLM's `text` output must be **pure novel prose only** — a model that appends JSON/metadata to its `text` would pollute the typewriter, the moderation, and the stored story.

### 1.2 Two-LLM graph, one streamed, one structural

- **LLM① (fiction)** — outputs ONLY the pure story text; this is what streams as `text_chunk` from the start.
- **LLM② (metadata)** — placed **downstream** of LLM① (its input references LLM①'s `text`), so it only runs after the story has fully streamed. It returns a strict JSON object via Dify **structured output (JSON schema)** with `title`, `summary`, and the three recommended next actions `choice_1`/`choice_2`/`choice_3`. Dify auto-splits the schema into separate node outputs, and the **End node** maps them (plus `text = LLM①.text`) — so the metadata arrive in `workflow_finished.outputs` exactly when the story stream ends, and the server forwards them (with `outline`/`music_style`) to the client in the `reveal`/`done` events.

This is the "story text first, variables after" design. The full prompt templates live in [`dify/PROMPT_TEMPLATE.md`](AI-SAGA/dify/PROMPT_TEMPLATE.md) and a copy-paste test prompt (with every Dify variable resolved to realistic values) in [`dify/TEST_PROMPT_LLM1.md`](AI-SAGA/dify/TEST_PROMPT_LLM1.md).

### 1.3 Model selection & the thinking-mode gotcha

- **Model**: a non-reasoning generation tier (DeepSeek `v4 flash` was selected) — cheap, strong multilingual prose, and it does not emit reasoning by default.
- **Cost/quality notes**: at ~650 input + ~450 output tokens per round, the cost difference between the flagship and the flash tier over 40 rounds is negligible (< a few cents), so the choice is purely about prose quality; the metadata LLM is a short call (~150 output tokens).
- **Dify UI gotcha**: the "Thinking mode" switch is *"whether to explicitly send the `thinking` param"*, not *"whether the model thinks"*. If the switch is **off**, Dify omits the param and the model defaults to thinking ON (re-emitting `<think>`). To actually disable thinking you must set the switch **ON + value False** (sending `thinking: false`). This was the root cause of the recurring `<think>` pollution.
- The story LLM node uses **Text** reply format (never JSON); the metadata LLM node uses **structured output / JSON schema** with all four fields required, temperature ~0.3, `max_tokens` 500–600, thinking off.

## 2. Server hardening: `<think>` stripping + unwrap

Reasoning models can still leak `<<think>>...<<think>>` into `text` even when thinking is nominally off. Two malformed shapes were observed: a thinking prefix before the story, and (worse) the **whole story wrapped inside `<think>`**. Three helpers in [`server/main.py`](AI-SAGA/server/main.py) handle both:

| Function | Role |
|---|---|
| [`_strip_think`](AI-SAGA/server/main.py:1371) | Strips `<think>...</think>` from each streamed `text_chunk`, buffering across chunk boundaries (a block split over multiple `text_chunk`s is held until `</think>` and then dropped). |
| [`_unwrap_wrapped`](AI-SAGA/server/main.py:1405) | If the whole text is wrapped in `<think>…</think>` and/or backticks, unwrap it and return the inner content — provided its "content weight" is ≥ 1000 (CJK char = 1, ASCII letter/digit = 0.5, so ≈ 1000 Chinese chars or ≈ 2000 English letters; below that it is treated as empty, fail-closed). |
| [`_clean_story_text`](AI-SAGA/server/main.py:1421) | Runs `_strip_think` first; if the result is empty but the raw text had substantial content, falls back to `_unwrap_wrapped`. Used for `workflow_finished.outputs.text`. |

Result: whether the model leaks a thinking prefix, a whole-story wrapper, or backtick code fences, the server never displays, audits, or persists reasoning content.

## 3. Metadata persistence with guaranteed fallbacks

- **Schema**: `story_segments` stores per segment `choice_1/2/3` (LLM②'s recommended next actions, TEXT DEFAULT ''), plus `outline`/`music_style` and the settings snapshot. Development stage: the DB is created fresh from the `CREATE TABLE` (no migration code, no legacy action columns).
- [`_extract_story_meta`](AI-SAGA/server/main.py:1271): pulls `choice_1/2/3` (plus `outline`/`music_style`) from `outputs`; any missing / empty / non-string field, or a `music_style` not in the 9-value whitelist (`MUSIC_STYLE_VALUES`), falls back to [`META_DEFAULTS`](AI-SAGA/server/main.py:1260).
- [`_finalize_meta`](AI-SAGA/server/main.py:1287): `outline` has **no static default** — when the LLM outline is missing, it falls back to **the segment's own story text** (accepted trade-off: the outline column duplicates content in the fallback path only).
- [`_persist_story_segment`](AI-SAGA/server/main.py:1292) stores the values per segment (re-running the defaulting internally, belt-and-suspenders). The `reveal`/`done` SSE events forward `{...outputs, ...meta}` so the client always receives all of them (defaulted if needed).
- **Quota-exhaustion safety**: the "overwrite latest segment's `choice_1/2/3` with the three current input-box values" UPDATE runs **before** `_check_story_quota`. So when a user is out of quota, they can still edit and confirm the three boxes, the server saves their latest choices to the DB, and the request is rejected at the quota gate **without any LLM call** — the user's state is preserved at zero cost.

## 4. Flutter: recommended-action input boxes

- [`TextInputPanel`](AI-SAGA/lib/widgets/text_input_panel.dart:11) gained an optional external `TextEditingController` (falls back to the internal one).
- On `reveal`/`done`, [`_applyRecommendedActions`](AI-SAGA/lib/logic/home_content.dart:530) fills the **1st/2nd/3rd** boxes with `choice_1`/`choice_2`/`choice_3`. The three box values are sent as `choice_1/2/3` on confirm.
- A new [`_hasRecommendedActions`](AI-SAGA/lib/logic/home_content.dart:221) flag gates input-box visibility: the boxes only appear after recommendations arrive; if a round completes without them, the app reuses the same "network issue — please restart" flow ([`_onStreamStalled`](AI-SAGA/lib/logic/home_content.dart:1773), 30s stall already handled by `onStalled`) so the user restarts and re-pulls the persisted metadata.

## 5. Per-segment choices pulled with the text

- `/api/story` GET now returns a `choices` array parallel to `segments` (each entry `[choice_1, choice_2, choice_3]`).
- [`sync_service.dart`](AI-SAGA/lib/logic/sync_service.dart:11): `StorySnapshot` now carries `List<List<String>> choices`; `_parseStory` reads them (padded to 3 strings).
- [`home_content.dart`](AI-SAGA/lib/logic/home_content.dart:211): a `Map<int, List<String>> _segmentChoices` keyed by absolute seq is populated during startup sync and scroll-up loading, and each historical segment's [`StoryChoiceCard`](AI-SAGA/lib/widgets/story_choice_card.dart:11) receives its three values as `initialValues`, prefilled into its three input boxes.
- `StoryChoiceCard` now carries `segmentIndex` (= server seq) so every button/input row is bound to the exact DB row (button → seq → row), which underpins the rewrite feature.

## 6. Time-tree rewrite ("Restart from here")

Tapping the rewrite button under a historical segment shows a **localized confirmation dialog** (no title; body warns the story will be rewritten from this point and all later content will be **permanently discarded**; buttons **Rewrite / Cancel**, translated across all supported languages). On confirm:

1. [`_truncateStoryFrom`](AI-SAGA/lib/logic/home_content.dart:1651) removes the in-memory story segments after the chosen point, prunes choice records/segment-choices after it, and saves the truncated list to local storage.
2. The flow then calls the **standard** [`_continueStory`](AI-SAGA/lib/logic/home_content.dart:550) with `rewriteFrom: segmentIndex` — every subsequent step (waiting, streaming, two-phase moderation, typewriter, `chunk/reveal/done`, stall/quota errors) is the **exact same continuation code path**. If the user typed nothing in the historical box, a localized default continuation prompt is used.
3. Server: `StoryInputData.rewrite_from` (`-1` = no rewrite); [`generate_story`](AI-SAGA/server/main.py:1551) runs `DELETE FROM story_segments WHERE user_id=? AND seq > ?` after the quota check, then continues the unmodified pipeline (settings/tail are re-resolved from the now-latest segment, `previous_story` = the chosen segment, and the new segment becomes `seq = rewrite_from + 1`).

Net effect: deleting abandoned content happens in three places (display page, app local storage, server DB) and then the old continuation pipeline is reused unchanged — one code path for both normal continuation and rewrites, so future changes stay consistent.

## 7. Deployment & tooling notes

- **Server deploy**: the updated `server/main.py` is written into the running container's writable layer (`docker cp` to a temp name then `cat > /code/main.py`, because `uvicorn --reload` holds the file open and a direct `docker cp` over it fails with "device or resource busy"); uvicorn's `StatReload` then reloads cleanly. **This copy lives in the container's writable layer — a container recreate/image rebuild discards it.** For durable deployment the image must be rebuilt from the updated source (the build directory's `main.py` is kept current by the normal sync, so rebuilding bakes in the new code).
- **Dev data seeding**: [`server/seed_choices.py`](AI-SAGA/server/seed_choices.py) fills every row's `choice_1/2/3` with random ≤70-char action directives and leaves a few rows fully blank, for visually testing the per-segment buttons (run against the server DB path).
- **Verification**: `python3 -m py_compile server/main.py` OK; `flutter analyze` no issues; server `StatReload` → `Application startup complete.` with no tracebacks.

---

# Session Update (2026-08-12)

> Session covering a **reliability & UX hardening pass** on the story page and the generation pipeline: a **retry-routing bug** that could wipe story history, **tri-state moderation** (no more false "violation" on weak networks), **unified restart-only error dialogs**, **full 10-language localization** of every button/dialog (app + server-side default actions), **per-segment "user choice" persistence** (new `user_choice` column), and a **unified choice-ownership model** shared by normal continuation and the time-tree rewrite. Written in English for other developers. **Desensitized** — no secrets, credentials, server addresses, or real identifiers appear anywhere.

## 1. Retry-routing fix — retrying a continuation no longer wipes history

**The bug.** [`_showGenerateError`](AI-SAGA/lib/logic/home_content.dart) always routed its "retry" action to [`_onSetupConfirmed`](AI-SAGA/lib/logic/home_content.dart) — the **fresh-start** path that clears all `_storyTexts`, resets `_storyStartIndex`, calls `SyncService.resetStory()` (server wipe), and regenerates from scratch. On a weak network, retrying a **continuation** failure therefore erased the whole novel and started over. The "content may violate guidelines" dialog that appeared right after retry was a downstream symptom of the same accidental fresh restart.

**The fix.** Retry re-runs the **same** [`_continueStory`](AI-SAGA/lib/logic/home_content.dart) with the original `userInput` / `rewriteFrom` / `choice1/2/3`, preserving history. (The dialog was later simplified to a single restart action — see §3.)

## 2. Tri-state moderation — no false "violation" on weak networks

[`_moderate_story`](AI-SAGA/server/main.py) was **fail-closed**: any quota/network/non-200/parse failure returned `False`, which the stream turned into an `abort` event → the app showed a false "content is suspected to violate" dialog **at the same time** as the connection-error dialog. The root cause was the audit Dify call failing under bad network, not the user's content.

Now the server returns a three-state [`ModerationOutcome`](AI-SAGA/server/main.py):
- `PASS` — `action == "none"` → keep streaming.
- `REJECT` — audit **definitively** returned a non-none action → `abort` (the real "violation" dialog).
- `UNAVAILABLE` — quota, transport failure, non-200, or unparseable verdict → `error` event (retryable network-style warning), **never** a violation.

[`_moderation_failure_sse`](AI-SAGA/server/main.py) maps REJECT→`abort` and UNAVAILABLE→`error`; all five moderation call sites in [`_stream`](AI-SAGA/server/main.py) use it. The removed `_audit_passed` helper is gone.

## 3. Unified "restart only" error dialogs

- **Generation failure** ([`_showGenerateError`](AI-SAGA/lib/logic/home_content.dart)): now a single **Restart** action (no Skip/Retry). Restarting re-runs startup sync, which pulls server-persisted segments back so local and server re-align — preventing both the old history wipe and the "local shows one fewer segment" drift.
- **Cold-start sync failure**: changed from a full-screen error page to a dialog shown over the loading page, single **Restart** button (restart → sync re-pull → auto-align).
- **Stream stall** and **device conflict** already restarted; the security/account-limit dialogs keep their intentional single "Exit" action.
- Removed the now-dead `_getSkipText` / `_getRetryText` helpers.

## 4. Full 10-language localization (every button & dialog)

- **App**: completed the missing `es/fr/de/pt/ja/ko` (plus some `zh-TW`/`yue`) branches in ~10 [`_getXxxText()`](AI-SAGA/lib/logic/home_content.dart) helpers (reauth, device conflict, syncing, sync error, stall title/message/restart, rewrite default, etc.); rewrote [`account_limit_warning.dart`](AI-SAGA/lib/widgets/account_limit_warning.dart) and [`security_warning_page.dart`](AI-SAGA/lib/widgets/security_warning_page.dart) from hardcoded English to full localization; completed 4 helpers in [`audit_dialog.dart`](AI-SAGA/lib/widgets/audit_dialog.dart).
- Everything resolves through [`StorageService.getLanguage()`](AI-SAGA/lib/logic/storage_service.dart) — the user's chosen language first, the system language as fallback.
- **Server**: the default recommended actions (`choice_1/2/3`, used when Dify returns none) became [`META_DEFAULTS_BY_LANG`](AI-SAGA/server/main.py) — 10 languages. [`_extract_story_meta(outputs, language)`](AI-SAGA/server/main.py) picks per-language defaults via `_meta_defaults(language)` (unknown → Simplified Chinese). The language source is **unchanged**: first round = request `data.language`; continuation = the latest segment's `story_segments.language` snapshot. `music_style` deliberately stays on the Chinese whitelist (`MUSIC_STYLE_VALUES`) for Dify-canvas compatibility.

## 5. Per-segment "user choice" persistence — new `user_choice` column

`story_segments` gained a `user_choice TEXT` column holding **the text the user actually entered/chose** in the three input boxes (distinct from `choice_1/2/3`, which are the LLM-recommended actions for that segment):
- **Empty on creation**: a new segment is persisted with `user_choice` empty (the user hasn't chosen the next round yet).
- **Overwrite on selection**: the `generate_story` overwrite-save UPDATE (latest segment or time-tree `rewrite_from`) sets `user_choice = data.user_input` — the operated segment's value is overwritten with the user's actual input.
- **Read**: `/api/story` returns a `user_choices` array parallel to `segments`; the app's `StorySnapshot` carries it, and startup sync / scroll-up loading rebuild the `_choices` list from it (cross-restart persistence).

## 6. "This round's choice" shown instantly above the pending area

When the user taps **Continue**, the generation placeholder ([`_buildGeneratingPlaceholder`](AI-SAGA/lib/logic/home_content.dart)) now renders, at its very top and in the user's language, `User choice: <picked text>` (prefix from [`_getChoicePrefixText`](AI-SAGA/lib/logic/home_content.dart)), above the "generating new content…" row and the half-screen blank. After the new segment arrives, the same marker is rendered at the unified in-body position, so the line persists without flicker or duplication.

## 7. Unified choice-ownership model (normal continuation + time tree)

A choice belongs to **the segment the user operated on**, and its value is **the text entered this round** — it **overwrites** that segment's previous choice:

| Scenario | Operated segment | Effect |
|---|---|---|
| Normal continuation (latest segment n) | n | overwrite segment n's choice |
| Time tree rewrite (segment k) | k | overwrite segment k's choice; **delete choices > k** |

- **App**: [`_continueStory`](AI-SAGA/lib/logic/home_content.dart) records `segmentIndex = _storyStartIndex + _storyTexts.length - 1` and replaces any existing record for that segment (`removeWhere` + add). [`_buildStoryBody`](AI-SAGA/lib/logic/home_content.dart) renders each segment uniformly as: **segment text → input/button card (historical) → its choice marker** — the same position as the placeholder top when generating.
- **Time tree**: [`_truncateStoryFrom`](AI-SAGA/lib/logic/home_content.dart) removes future content (`_storyTexts`, `_choices > k`, `_segmentChoices > k`); segment k's choice is left in place and then overwritten by the new input via the normal continuation path.
- **Server**: `DELETE ... WHERE seq > rewrite_from` + overwrite-save `UPDATE ... SET choice_1/2/3, user_choice = data.user_input WHERE seq = rewrite_from` (or `MAX(seq)` for normal continuation).
- **No duplication while generating**: while a new segment is pending (`_storyStreaming` and `_storyTexts.length <= _generationStartLen`), the placeholder shows the current round's choice and the body skips the latest segment's marker.

## 8. Deployment

- Deployed the updated `server/main.py` with the deployment helper (`upload` → **in-place write into the running container's `/code/main.py`** → health check), then restarted the container.
- The existing database (pre-`user_choice`) was patched with a one-off `ALTER TABLE story_segments ADD COLUMN user_choice TEXT` (development stage: no migration code in the server; the CREATE TABLE in `SCHEMA` is the source of truth and new DBs get the column automatically).
- `/api/health` returns 200 after restart. The app-side changes require a client rebuild to take effect.

---

# Design Session: Novel-Generation Cost, Prompt Caching & Workflow/Chatflow Architecture (2026-08-12)

> Session covering: cost modelling for the streaming-novel pipeline (DeepSeek V4 Pro vs Flash), why post-stream variables must be separated from the streamed `text`, a **single-module JSON** alternative (Option A) with prompt + free Code node + server-side stripping, Dify **Workflow vs Chatflow** (memory, multi-user, cost), the **two-round Chatflow** replacement for the two-LLM graph, **prompt caching** (cache-hit discount) mechanics across users/turns, `max_tokens` as a hard cap vs natural length, token↔character conversion, and **context strategy** (full text vs outline vs two-stage planning). Written in English for other developers. **Desensitized** — no secrets, credentials, server addresses, or real identifiers appear anywhere.

## 1. Cost of “5000-char input / 1500-char output × 40”

Working estimate (see §8 for the token↔character conversion): **1 Chinese character ≈ 1 token**.

- Per call: input ≈ 5000 tokens, output ≈ 1500 tokens.
- 40 calls: input ≈ **200 000 tokens (0.2M)**, output ≈ **60 000 tokens (0.06M)**.
- **Formula**: `cost = 0.2 × P_in + 0.06 × P_out` (prices per 1M tokens).
- **Reference prices** (DeepSeek V3; substitute V4 Pro/Flash actuals): input cache-miss ¥2/M (≈ $0.27/M), input cache-hit ¥0.5/M (≈ $0.07/M), output ¥8/M (≈ $1.10/M).
- The **Pro vs Flash** gap is dominated by the difference in `P_out` (output is never discounted) and in `P_in`; both are plugged into the same formula.

## 2. Why post-stream variables cannot live in the streamed `text`

The LLM node’s `text` output is: split into `text_chunk` events → typed out by the typewriter ([`story_service.dart`](lib/logic/story_service.dart:141)); persisted verbatim into `story_segments.content`; and run through the first-450-char audit. Appending JSON/variables to `text` pollutes all three. The constraint and the two-LLM graph (`LLM①` streams prose, `LLM②` downstream emits structured JSON, End node maps `text` + variables) are documented in [`dify/PROMPT_TEMPLATE.md`](dify/PROMPT_TEMPLATE.md:31). Variables arrive in `workflow_finished.outputs`; the server forwards them in the `reveal`/`done` SSE events ([`server/main.py`](server/main.py:1668)); Flutter applies them to the input boxes ([`home_content.dart`](lib/logic/home_content.dart:530)).

## 3. Option A — single LLM node with a trailing JSON block

**Motivation**: cut the input-token waste of `LLM②`, which re-reads the entire generated text (~1500–5000 tokens/round extra; over 40 rounds ≈ 60k–200k wasted input tokens).

**Design**: one LLM node outputs **pure prose first**, then a dedicated delimiter line `<<<META>>>`, then a **compact single-line JSON** `{"outline", "action_a", "action_b", "music_style"}` (music_style constrained to the 9-value whitelist in [`META_DEFAULTS`](server/main.py:1276)). A **free Code node** (zero tokens) splits at the first `<<<META>>>` and parses the JSON robustly (tolerating ```json fences, trailing commentary, and a “last `{…}`” fallback when the delimiter is missing); the End node maps `text` ← Code output plus the 4 variables. Server-side hardening: a `_cut_meta` helper strips `<<<META>>>…` from the raw fallback path so the typewriter, audit, and persistence never see the JSON even if `workflow_finished` is missed.

**Trade-off**: cheaper input than the two-LLM graph, but the JSON sits at the tail of a long generation → higher truncation and format-drift risk; the model’s output-format compliance is the main fragility.

## 4. Workflow vs Chatflow

- **Workflow** ([/workflows/run](server/main.py)): stateless — every call re-sends its own context (`previous_story` is pulled from the DB and re-sent each round). No built-in memory. Multi-user is already handled: each request carries a per-end-user `"user": user_id` ([`server/main.py`](server/main.py:1620)), so attribution/logging are per-user.
- **Chatflow** ([/chat-messages](server/main.py)): stateful — Dify keeps the conversation and injects history via the memory node, so the LLM “remembers” the whole dialogue. **This does not reduce cost by itself**: the memory re-sends the *full* accumulated history every turn, so input tokens grow with each turn (roughly quadratic over a long book) unless you cap it (memory window / summary).
- **Multi-user** (important): the **LLM is stateless** — it never “thinks it is one user”; “user” is a Dify/app concept. Distinguish users with (a) a per-end-user `user` (already done) and (b) for chatflow, a **per-user per-story `conversation_id`** stored in the DB. Sharing one global `conversation_id` makes every user share one conversation/memory — the failure mode to avoid. Each user’s conversation is isolated as long as `conversation_id` is per user.

## 5. Two-round Chatflow (replaces the two-LLM graph)

- **Round 1**: user message = the story request → LLM **streams pure prose** (typewriter).
- **Round 2**: same conversation, a second message (“output the metadata JSON”) → LLM outputs `outline / action_a / action_b / music_style`; the chatflow memory automatically carries round 1’s prose into round 2’s context, replacing `LLM②`’s manual “input references LLM①.text” wiring.

**Why it is cleaner than Option A**: the prose stream stays 100% pure (no trailing JSON), and the metadata is a tiny dedicated turn that can use Dify **structured output (JSON schema)** with schema validation → far lower JSON-error risk (§7).

**Cost reality**: round 2 re-reads round 1’s prose at **cache-miss** price (the prose never appeared in any earlier request prompt, so it cannot be a cache hit); only round 1’s request prefix is a hit. So it is **not cheaper** than the workflow’s `LLM②` — roughly equal or slightly more tokens — but it is simpler and cleaner.

**Hard requirement**: “at most two rounds per segment” must be enforced by **a fresh `conversation_id` per segment** (recommended) or a memory window of 1 exchange. Otherwise history accumulates across segments and the quadratic cost returns.

## 6. Prompt caching (cache-hit discount)

- DeepSeek bills input tokens that exactly match a previously-sent prompt prefix at **~1/4 the cache-miss price** (hit); TTL ≈ 5 minutes, refreshed on each hit. **Output tokens are never discounted.**
- The cache is **keyed on the exact token prefix in a global pool — not per user, not per conversation**. Interleaving another user’s completely different request does **not** invalidate your entry (different content = different cache key). So user A’s second request still gets the discount on its repeated prefix even if user B sent something different in between — the only conditions are a **byte-identical prefix** and being **within TTL** (theoretical LRU eviction only under extreme load).
- **Assistant replies**: an LLM’s own reply is a cache **miss** in the immediately following round (it appears in a prompt for the first time) and only becomes a **hit from the round after that**. In a two-round chatflow the prose therefore never reaches hit status.
- **Workflow equivalence**: the cache does not care where the prefix came from. If a workflow keeps its prompt prefix byte-stable (fixed field order, no timestamps/random IDs, new content appended at the end), it earns the **exact same discount as chatflow** for the same re-sent bytes. The discount amount equals however many identical bytes you actually re-send — chatflow has no cheaper cache, it just automates re-sending (and by default re-sends more).

## 7. JSON reliability

The drop in JSON-error probability comes from **separating the JSON into its own tiny step** (short dedicated generation + optional structured-output schema validation) — not from “chatflow” per se; the workflow’s dedicated `LLM②` gets the same benefit. Option A’s trailing JSON is the riskiest form (truncation at the tail + long-generation drift). Keep the fallback defaults in [`_extract_story_meta`](server/main.py:1288) either way.

## 8. `max_tokens` is a hard cap, not a soft target

- `max_tokens` mechanically truncates at N output tokens (`finish_reason: "length"`); it can cut mid-sentence/JSON and never helps reach a lower bound. The model “approaching” a target is soft prompt-driven behavior (paragraph/sentence anchors, few-shot examples) and is inherently imprecise.
- **Actual length = min(natural stop, max_tokens)**. Set `max_tokens` with headroom so the model finishes before the cap; detect `finish_reason == "length"` and validate/regenerate server-side for the lower bound.
- **Weighted-width ↔ tokens**: the “Chinese = 2, ASCII = 1” width metric equals 2× the server’s [`_content_weight`](server/main.py:1470) (CJK=1, half-width=0.5). For mostly-Chinese prose, 1300–1700 weighted ≈ 650–850 Chinese chars ≈ 650–850 tokens (so a safe cap is ~1000–1100). LLMs cannot self-count custom character metrics — use structural anchors + server-side validation instead of prompt numbers. For budgeting, 1 汉字 ≈ 0.6–1.5 tokens depending on tokenizer; use ~1:1.

## 9. 8000-char vs 30 000-char input over 20 rounds

- Tokens: 8000 × 20 = **160k**; 30 000 × 20 = **600k**; difference **440k tokens (0.44M)**.
- **Cost difference = 0.44 × P_in** (per 1M). V3 reference: all-miss ≈ **¥0.88 (≈ $0.12)**; all-hit ≈ **¥0.22 (≈ $0.03)**.
- If the “30 000 chars” is a **growing full-history** context instead of fixed per-round input, the 20-round total is 30 000 × (1+2+…+20) ≈ **6.3M tokens** → difference ≈ `4.62 × P_in` — a different order of magnitude (quadratic growth).

## 10. Context strategy: full text vs outline

- **Full 30k text**: perfect detail/style fidelity, but models exhibit **“lost in the middle”** — a long context’s middle is weakly attended, so you effectively use the start + the recent tail. You pay for 30k but use ~5k of it.
- **4k outline**: high signal density, keeps the story on-track, cheap; loses detail and style fidelity.
- **Recommendation — hierarchical context**: (1) a bounded compressed **summary** of the older plot, (2) the **last 1–2 segments in full**, (3) optionally the **next-beat outline**. This keeps context bounded (~5–8k tokens) and is a natural extension of the current “send the last segment” design ([`server/main.py`](server/main.py:1410)).

## 11. Direct generation vs two-stage (outline-first)

- **Two-stage (Plan-and-Write)**: generate the next-beat outline first, then write prose against it → better plot coherence, fewer dead-ends, and controllable length; costs ~2× (two calls, extra small output) and adds latency, and risks formulaic prose if the outline is too rigid.
- **Direct**: one call, cheaper, more fluid prose, but implicit planning → more drift on long/multi-scene segments.
- **Natural upgrade for this app**: the existing `outline` metadata is currently generated **after** the prose (descriptive). Flipping it to be generated **before** the prose and rolled into the next round’s context (prescriptive) is exactly the two-stage approach and fills the “direction layer” of the hierarchical context from §10.

---

# Full Chatflow Summary — Fiction Pipeline, Metadata & Time-Tree Rewrite

> A consolidated English summary of the whole design-and-implementation chatflow: the Dify fiction workflow redesign, model selection, `<<think>>`-block hardening, metadata persistence with guaranteed fallbacks, the recommended-action input boxes, per-segment choice display, the time-tree "restart from here" rewrite, deployment/ops, and the design Q&A that drove every decision. **Desensitized** — no secrets, credentials, API keys, server addresses, or real identifiers appear anywhere.

## 1. The central problem: "story text first, structured variables after"

The product requirement is that a generated story segment must arrive as a **pure text stream** (the typewriter), and only **after** the stream ends should a handful of structured variables (next-round actions, plot outline, background-music mood) be delivered to the server/client.

- The server treats every `text_chunk` as story text and `workflow_finished.outputs.text` as the authoritative full story (used for two-phase moderation and persistence). Therefore the model must **never append JSON/metadata to its `text`** — that would pollute the typewriter, the moderation, and the stored story.
- The correct Dify shape is a **two-LLM graph**: **LLM①** streams pure prose; **LLM②** sits downstream (its input references LLM①'s `text`), so it only runs after the story has fully streamed and returns strict JSON via Dify **structured output (JSON schema)**. The **End node** maps `text = LLM①.text` plus the four metadata fields (`outline`, `action_a`, `action_b`, `music_style`), so they land in `workflow_finished.outputs` exactly when the story ends and are forwarded to the client in `reveal`/`done`.
- Prompt templates: [`dify/PROMPT_TEMPLATE.md`](AI-SAGA/dify/PROMPT_TEMPLATE.md) (the node design + both prompts) and [`dify/TEST_PROMPT_LLM1.md`](AI-SAGA/dify/TEST_PROMPT_LLM1.md) (a copy-paste test prompt with every Dify variable resolved to realistic values, plus a compliance checklist).

## 2. Cost-driven architecture decisions

- **Two LLMs at once?** A second LLM call for metadata was a cost concern. Analysis showed the metadata call is tiny (~150 output tokens, a few cents per 1000 rounds), so the two-LLM shape is affordable — but the **story** path must stay single-model (no duplicated generation).
- **"Retry after a restart improves correctness"?** Discussed and rejected as a premise: LLMs have no memory and are not correlated with wall-clock time; a retry only helps by **re-sampling randomness** (temperature), and systematic defects would loop forever. The design therefore relies on **server-side defaults** for any missing/invalid metadata rather than forcing users to restart.
- **Model choice**: a non-reasoning tier (DeepSeek `v4 flash`) was selected for multilingual prose + cost. At ~650 input / ~450 output tokens per round, the flagship-vs-flash cost gap over 40 rounds is negligible; the choice is purely about prose quality. Full cost/quality comparisons were documented in-session.

## 3. The thinking-mode gotcha and `<<think>>`-block hardening

- **Dify UI trap**: the "Thinking mode" switch means *"whether to explicitly send the `thinking` param"*, not *"whether the model thinks"*. Switch **off** ⇒ Dify omits the param ⇒ the model defaults to thinking ON and re-emits `<<think>>`. To actually disable thinking you must set the switch **ON + value False** (sending `thinking: false`).
- **Server hardening** (three helpers in [`server/main.py`](AI-SAGA/server/main.py)):
  - [`_strip_think`](AI-SAGA/server/main.py:1371) — strips `<<think>>…<<think>>` from each streamed `text_chunk`, buffering across chunk boundaries (a block split over several chunks is held until `<<think>>` then dropped).
  - [`_unwrap_wrapped`](AI-SAGA/server/main.py:1405) — if the whole text is wrapped in `<<think>>…<<think>>` and/or backticks, unwraps it, gated by a "content weight" threshold of ≥ 1000 (CJK char = 1, ASCII = 0.5, i.e. ≈ 1000 Chinese chars or ≈ 2000 English letters; below that, treated as empty, fail-closed).
  - [`_clean_story_text`](AI-SAGA/server/main.py:1421) — `_strip_think` first; if empty but the raw text had substantial content, falls back to `_unwrap_wrapped`. Used for `outputs.text`.
- The story LLM node uses **Text** reply format; the metadata LLM node uses **structured output / JSON schema** (all fields required, temperature ~0.3, `max_tokens` 500–600, thinking off).

## 4. Metadata persistence with guaranteed fallbacks

- `story_segments` gained `outline`, `action_a`, `action_b`, `music_style` (TEXT DEFAULT ''), added both to the `CREATE TABLE` and to the idempotent [`_migrate_schema`](AI-SAGA/server/main.py:243) (`ALTER TABLE ... ADD COLUMN` when missing) — safe for existing databases.
- [`_extract_story_meta`](AI-SAGA/server/main.py:1271) — pulls the four fields from `outputs`; any missing/empty/non-string field, or a `music_style` outside the 9-value whitelist [`MUSIC_STYLE_VALUES`](AI-SAGA/server/main.py:1267), falls back to [`META_DEFAULTS`](AI-SAGA/server/main.py:1260).
- [`_finalize_meta`](AI-SAGA/server/main.py:1287) — `outline` has **no static default**: when the LLM outline is missing, it falls back to **the segment's own story text** (accepted trade-off: outline duplicates content only in the fallback path).
- [`_persist_story_segment`](AI-SAGA/server/main.py:1292) stores all four per segment; `reveal`/`done` forward `{...outputs, ...meta}` so the client always receives all four (defaulted if needed).
- **Quota-exhaustion safety**: the "overwrite the latest segment's `choice_1/2/3` with the three input-box values" UPDATE runs **before** `_check_story_quota`, so an out-of-quota user can still edit + confirm the three boxes, the server saves their latest choices at zero LLM cost, and the request is then rejected at the quota gate.

## 5. Flutter: recommended-action input boxes

- [`TextInputPanel`](AI-SAGA/lib/widgets/text_input_panel.dart:11) gained an optional external `TextEditingController` (falls back to the internal one), enabling programmatic prefill.
- On `reveal`/`done`, [`_applyRecommendedActions`](AI-SAGA/lib/logic/home_content.dart:530) fills the **2nd** box with `action_a` and the **3rd** with `action_b`; box 1 remains free text. The three values are sent as `choice_1/2/3` on confirm.
- A new [`_hasRecommendedActions`](AI-SAGA/lib/logic/home_content.dart:221) flag gates input-box visibility: boxes appear only after recommendations arrive; if a round completes without them, the app reuses the same "network issue — please restart" flow ([`_onStreamStalled`](AI-SAGA/lib/logic/home_content.dart:1773); the 30s stall is handled by `onStalled`).

## 6. Per-segment choices pulled with the text

- `/api/story` GET returns a `choices` array parallel to `segments` (each entry `[choice_1, choice_2, choice_3]`).
- [`sync_service.dart`](AI-SAGA/lib/logic/sync_service.dart:11) `StorySnapshot` carries `List<List<String>> choices`; `_parseStory` reads them (padded to 3).
- [`home_content.dart`](AI-SAGA/lib/logic/home_content.dart:211) keeps a `Map<int, List<String>> _segmentChoices` keyed by absolute seq, populated during startup sync and scroll-up loading; each historical segment's [`StoryChoiceCard`](AI-SAGA/lib/widgets/story_choice_card.dart:11) receives its three values as `initialValues`.
- `StoryChoiceCard` carries `segmentIndex` (= server seq), so every button/input row is bound to the exact DB row (button → seq → row), which underpins the rewrite feature.

## 7. Time-tree rewrite ("Restart from here")

Tapping the rewrite button under a historical segment shows a **localized confirmation dialog** (no title; body warns the story will be rewritten from this point and all later content will be **permanently discarded**; buttons **Rewrite / Cancel**, in every supported language). On confirm:

1. [`_truncateStoryFrom`](AI-SAGA/lib/logic/home_content.dart:1651) removes the in-memory segments after the chosen point, prunes choice records / segment-choices after it, and saves the truncated list to local storage.
2. The flow then calls the **standard** [`_continueStory`](AI-SAGA/lib/logic/home_content.dart:550) with `rewriteFrom: segmentIndex` — every subsequent step (waiting, streaming, two-phase moderation, typewriter, `chunk/reveal/done`, stall/quota errors) is the **exact same continuation code path**. An empty historical input falls back to a localized default continuation prompt.
3. Server: `StoryInputData.rewrite_from` (`-1` = no rewrite); [`generate_story`](AI-SAGA/server/main.py:1551) runs `DELETE FROM story_segments WHERE user_id=? AND seq > ?` after the quota check, then continues the unmodified pipeline (settings/tail re-resolved from the now-latest segment, `previous_story` = the chosen segment, new segment becomes `seq = rewrite_from + 1`).

Net effect: abandoned content is removed in three places (display page, app local storage, server DB) and then the old continuation pipeline is reused unchanged — one code path for both normal continuation and rewrites.

## 8. Deployment & ops

- **Server deploy**: `server/main.py` is written into the running container's writable layer (`docker cp` to a temp name then `cat > /code/main.py`, because `uvicorn --reload` holds the file open and a direct `docker cp` over it fails with "device or resource busy"); uvicorn `StatReload` reloads cleanly. **This copy is lost on container recreate / image rebuild** — for durable deployment the image must be rebuilt from the updated source (the build directory's `main.py` is kept current by the normal sync, so a rebuild bakes in the new code).
- **Dev data seeding**: [`server/seed_choices.py`](AI-SAGA/server/seed_choices.py) fills every row's `choice_1/2/3` with random ≤70-char action directives and leaves a few rows blank, for visually testing the per-segment buttons.
- **Verification**: `python3 -m py_compile server/main.py` OK; `flutter analyze` no issues; server `StatReload` → `Application startup complete.` with no tracebacks.
- **Source control**: the change set was committed locally (`feat: fiction pipeline hardening + time-tree rewrite`). A push to the GitHub remote was attempted but the build/terminal network could not reach `github.com:443` ("Empty reply from server" / connect timeout) — the commit is ready locally and a single `git push origin main` from an environment with GitHub access completes the upload. All sensitive files (`server/.env`, the app `.env`, `server/data/*.db`, `dify/*.yml`) are covered by `.gitignore`, and a scan of tracked files found no embedded secrets.

## 9. Design Q&A recap (why decisions were made)

- **Why two LLMs instead of one "text + trailing JSON" output?** Dify streams a single `text`; a JSON tail would be streamed, audited, and persisted as story. Separating concerns keeps the stream clean and moves the variables to `workflow_finished.outputs`.
- **Why structured output for LLM② instead of `json_object` + a parse Code node?** Structured output hard-constrains field names/types/required at the model API level (Dify parses the schema into separate node outputs) — more reliable than prompt-following plus defensive parsing, at negligible extra cost.
- **Why not force a user restart on bad metadata?** Restarting only re-samples randomness; it is not a reliable fix and can loop. Server-side defaults (with the outline falling back to the segment text) guarantee usable data every time.
- **Why put the choice-overwrite before the quota gate?** So an out-of-quota user can still persist their latest three action choices without spending any LLM tokens — state is saved, generation is blocked.
- **Why reuse `_continueStory` for rewrites?** One code path for both normal continuation and time-tree rewrites keeps behavior consistent and makes future changes single-point (only an optional `rewrite_from` field is added).

---

# Session Update (2026-08-13)

> Session covering: renaming the latest-continuation button copy to **"Continue the story following the guidance above"** across all 10 languages, reworking the **disabled-button visual state** (opacity fade instead of a bordered grey block, so a disabled button stays distinct from the input field above it), and hardening the **time-tree "Restart from here"** flow so that **blank input can never trigger a rewrite / generation** — enforced at the UI, handler, core, and server layers. Written in English for other developers. **Desensitized** — no secrets, credentials, server addresses, or real identifiers appear anywhere.

## 1. Continuation button copy: "Continue the story following the guidance above"

The button under the three latest input boxes was renamed in [`_getLatestContinueButtonText()`](AI-SAGA/lib/logic/home_content.dart:1846):

- **Before**: "按照上面输入指引继续故事选择" — *"Continue the story **choice** following the **input** guidance above"*.
- **After**: "按照上面指引继续故事" — *"Continue the story following the guidance above"* (the "input" and "choice" wording is removed).

All 10 languages were adapted to match: zh-CN / zh-TW / yue / ja / ko had the "input"/"choice" wording stripped (e.g. 上記の**入力**ガイド → 上記のガイド, 위 **입력** 안내 → 위 안내); en / es / fr / de / pt already read as "…following the guidance above" and were left unchanged.

## 2. Disabled-button visual state: opacity fade (not a border)

**The problem.** While input/generation is disabled the buttons grey out; the original design kept them recognizable by adding a 1 px border, but that made a disabled button look almost identical to the input field directly above it (both grey fill + border) → visual confusion.

**The fix (implemented).** Keep the button's **blue fill and rounded shape** and simply fade the whole button via an `Opacity` widget — `1.0` when clickable, **`0.4` when disabled**. Because the fill stays blue (not grey) and the text stays white, a disabled button remains unmistakably a button and clearly distinct from the grey bordered input field.

- [`text_input_panel.dart`](AI-SAGA/lib/widgets/text_input_panel.dart:124) — the three bottom confirm buttons (`canConfirm == false`: generating / over-limit / empty).
- [`story_choice_card.dart`](AI-SAGA/lib/widgets/story_choice_card.dart:212) — the historical "Restart from here" buttons (`canPress == false`: typing / over-limit / empty).
- Both set `disabledColor` to the same blue fill (`AppTheme.buttonFillDark/Light`) and let the outer `Opacity` do the "greyed out" work; button text is always `AppTheme.buttonText` (white).

## 3. Time-tree blank-input guard (three client layers + server)

The concern: the "Restart from here" button could be pressed while its input box was empty, letting the time tree generate new novel content **without any user guidance**. This must be impossible.

### 3.1 UI layer — button disabled when blank
[`StoryChoiceCard`](AI-SAGA/lib/widgets/story_choice_card.dart:163) `canPress` now requires `hasText` (`controller.text.trim().isNotEmpty`): when the corresponding input box is blank the button is disabled (`onPressed == null`), so it cannot even be pressed — no sound, no press feedback, nothing.

### 3.2 Handler layer — return before any story mutation
[`_onRestartHerePressed()`](AI-SAGA/lib/logic/home_content.dart:1900) now checks `userInput.trim().isEmpty` and returns **before** `_truncateStoryFrom(segmentIndex)`. Blank input can therefore never truncate the story, never reach the server, and never delete later content. The former fallback that auto-filled a localized default prompt ("继续" / "Continue the story") for blank rewrite input was **removed**, along with its now-unused helper `_getRewriteDefaultInputText()`.

### 3.3 Core layer — final safety net
[`_continueStory()`](AI-SAGA/lib/logic/home_content.dart:705) already returned on blank input at its very first line (`if (!mounted || userInput.trim().isEmpty) return;`) — before any `setState`, scroll, network call, or choice recording. This covers every entry point (bottom boxes, time-tree rewrite, and the re-auth retry path).

### 3.4 Server layer — reject crafted/blank continuation requests
[`generate_story()`](AI-SAGA/server/main.py:1609) now rejects a blank `user_input` for any **continuation or rewrite** with `HTTP 400 "续写需要用户输入指引，请先填写内容再继续"` — placed **before any database write or truncation**. Only a genuine **first generation** (empty `story_segments` for the user and no `rewrite_from`) may carry an empty `user_input`, so creating a brand-new story is unaffected.

## 4. Behaviour with blank input (analysis)

Traced end-to-end:

- **Normal app usage**: blank input is stopped at the UI layer — the button is disabled, so the tap is not even registered (no sound, no dialog, no scroll, no network, no DB change). The story and the screen are completely unchanged; it is as if the instruction never happened.
- **If the UI were bypassed**: the handler returns before truncation, and `_continueStory` returns at its first line — still no state change, no network, no truncation.
- **Crafted API request**: the server returns `400` before any write/truncate, so the stored story is untouched and Dify is never called.
- Note: the only caller of `_onRestartHerePressed` is the `StoryChoiceCard` button, which is gated by `hasText` — the "bypassed" path is not reachable in the current code; the handler/core/server guards are defense-in-depth.

## 5. Verification

- `flutter analyze` → no issues (including `text_input_panel.dart` and `story_choice_card.dart`).
- `python3 -m py_compile server/main.py` → Syntax OK.
- The unused `_getRewriteDefaultInputText()` helper was deleted to keep the analyzer clean.

---

# Setup Wizard UI Polish & Countdown Removal (2026-08-13)

> Session covering: unifying the confirm/Next button placement across the setup wizard (fixed at 75% of the page height), moving the final-confirmation button to the bottom of its scrollable content, localizing the setup-page buttons to "Next" across all 10 languages, aligning the language-selection box with the location/era input boxes (root cause: the language page had no navigation bar), and removing the 5-second countdown display so the previously-delayed action runs immediately after moderation passes. All logic (server moderation, per-item edit shortcuts, back navigation, localization) is preserved. Written in English for other developers. **Desensitized** — no secrets, credentials, server addresses, or real identifiers appear anywhere.

## 1. Unified button placement on the setup pages (fixed at 75% height)

**The problem.** The four setup pages (location, era, player, partner) placed their confirm/Next button at the end of a scrolling `Column`. Depending on content length the button could sit at different heights or be pushed off-screen, so the flow did not feel consistent.

**The fix (implemented).** Each page now uses a `LayoutBuilder + Stack` layout:

- The content scrolls inside a `Positioned.fill → SingleChildScrollView` (with extra bottom padding so the last field can scroll above the button).
- The button is fixed with `Positioned(top: constraints.maxHeight * 0.75, left: 16, right: 16)` — always visible at 75% of the page height, regardless of how much content there is.

Files: [`location_setup_page.dart`](AI-SAGA/lib/widgets/location_setup_page.dart:475), [`era_setup_page.dart`](AI-SAGA/lib/widgets/era_setup_page.dart:459), [`player_setup_page.dart`](AI-SAGA/lib/widgets/player_setup_page.dart:551), [`character_setup_page.dart`](AI-SAGA/lib/widgets/character_setup_page.dart:555). The language page ([`initialization_page.dart`](AI-SAGA/lib/widgets/initialization_page.dart:230)) received the same 75%-height button placement.

## 2. Confirmation-page button moved to the bottom of the content

On the final confirmation page ([`setup_confirmation_page.dart`](AI-SAGA/lib/widgets/setup_confirmation_page.dart)), the button is deliberately **not** fixed. It is the last item inside the scrollable summary column, so the player naturally scrolls through the full list of settings before reaching it — preventing them from missing any setting.

## 3. Setup-page buttons renamed to localized "Next"

The button labels on the language, location, era, and partner pages were changed from "Confirm / 完成设定 / 确认…" to **"Next / 下一步"**, localized across all 10 languages (zh-CN / zh-TW / yue / en / es / fr / de / pt / ja / ko). This makes the multi-step wizard's forward progression unambiguous on every step.

## 4. Language-selection box aligned with the location/era input boxes

Two distinct issues were addressed:

- **Physical height.** The language dropdown was converted from a `Container + Row` into the same `CupertinoTextField` structure used by the location/era input fields (identical padding, fixed 50 px height, suffix chevron), so all three boxes render at the same physical height.
- **Screen position.** The location/era pages carry a `CupertinoNavigationBar` (with a back button) that pushes their body down; the language page had **no navigation bar**, so its selection box appeared higher on screen. Adding the same navigation bar to the language page aligned the body start position. In addition, the header (title + subtitle) block height was fixed on the language/location/era pages so the boxes stay aligned regardless of how the localized title/subtitle wrap across languages.

## 5. 5-second countdown removed — action runs immediately after moderation

**Before.** Tapping "确定" on the confirmation page ran the server moderation dialog, then showed a 5-second countdown display, and only after the countdown ended called `onConfirmed()` (which triggers story generation in [`home_content.dart`](AI-SAGA/lib/logic/home_content.dart:1417)).

**Now.** The countdown display is removed entirely — the `_counting`/`_countdown` state, the `Timer`, the `_buildCountdown()` UI, and the "entering a brand-new world" copy were all deleted. When the server moderation approves (`action == "none"`), the new `_onAuditApproved()` calls `widget.onConfirmed()` immediately.

**All other logic is preserved:** the server audit dialog (token, timeout, device-conflict and account-limit handling), the per-item "Edit" shortcuts (`widget.onEdit(index)`), the back button (`widget.onBack()`), and every localization helper.

## 6. Verification

- `dart format` on all modified widgets → clean.
- `flutter analyze` on all modified widgets → no issues.

---

# Story-Page UX Hardening & Full-Language Localization (2026-08-13)

> Session covering: eliminating the display jump when the typewriter starts typing, making the "Generating new content…" indicator disappear once typing begins, stabilizing the typewriter so it never re-types from a wrong position, keeping historical input cards populated with the choice values saved at the moment of the user's choice, keeping a constant one-line gap between the input boxes and the "Your choice" marker, keeping the page stable behind error/violation dialogs, making earlier in-memory segments reveal smoothly on up-scroll, and forcing **every popup and error string to follow the current app language** (no more mixed-language warnings). Also: the language-selection picker now defaults to the user's language (stored first, then system if supported, else English), and the language preference survives the "Restart" reset. Written in English for other developers. **Desensitized** — no secrets, credentials, server addresses, or real identifiers appear anywhere.

## 1. Jump-free typewriter reveal (total height stays constant)

**The problem.** When the first content chunk arrived, the placeholder (a "Generating new content…" row + a half-screen reserved blank) was removed all at once while the previous segment gained its time-tree card and the new segment began typing — the total layout height collapsed and the view "jumped".

**The fix.** A bottom "generation area" now stays visible for the whole stream:

- Before the first chunk it shows the prompt + a half-screen reserved blank.
- Once typing starts, the prompt disappears and its height is folded into the blank; the blank then shrinks 1:1 as the streaming segment grows (the segment's height is measured by a small custom size-reporting render object), so **the total height never changes** — no jump at the start of typing and none while it types.
- The just-continued segment's time-tree card appears without a layout shift: its height is measured off-screen during the waiting phase and absorbed by the reserved blank when it appears, so no extra card "pops in".

## 2. Stable typewriter state (never re-types from a wrong position)

Each typewriter segment is wrapped in a **stable** size-reporting widget (applied unconditionally, with no moving `GlobalKey`). Because the wrapper never moves between segments at hand-off, a segment's element/state is never destroyed mid-typing — previously the moving wrapper caused the typewriter to lose all typed text and restart from a wrong position. Only the current streaming (last) segment's height is tracked, to shrink the reserved blank.

## 3. Consistent layout around the "Your choice" marker

- Historical input cards now display the **choice_1/2/3 values saved at the moment of the user's choice** (kept in sync with the server); previously they were blank for segments generated in the current session.
- The three input boxes of a historical card use the **same placeholders** as the bottom input boxes.
- A **constant one-line gap** is kept between the input boxes and the "Your choice" marker in both the waiting and the typing states, so the marker never shifts when typing starts.

## 4. Stable page behind error / violation dialogs

When generation fails or is aborted, the "generation area" (user choice + reserved blank) is kept visible while the dialog is up, so the page behind the popup does not jump. The error dialog forces a restart (which resets state); the violation dialog transitions to the idle state only after it is dismissed. The error details produced by the client services and OS network exceptions are localized too (see §5).

## 5. Full popup localization (no mixed languages)

A shared [`StorageService.localizedText()`](AI-SAGA/lib/logic/storage_service.dart) helper returns text per the current app language. All client-side error messages in the story / sync / auth services and raw OS network exceptions (socket / client / timeout) are localized, so a popup shown in any language (e.g. Portuguese) is entirely in that language — no more "Portuguese title + Chinese detail".

- First-use popups follow the **system language** when no language has been selected (existing `getLanguage()` fallback).

## 6. Language-selection default + persistence across reset

- The language picker's default gear position follows: **stored language** (old users) → **system language if supported** (new users) → **English** otherwise.
- The language preference is **preserved across the "Restart" reset** — the previously-used language outranks the system language, so after a reset the picker and the app text stay in the user's chosen language instead of falling back to the system language.

## 7. Smooth up-scroll of earlier content

In-memory earlier segments (e.g. the tail loaded at startup) are now revealed **all at once** — matching the server-batch behaviour — and the reveal triggers as soon as the user scrolls into the top pull area, eliminating the previous "scroll to the very top → stop → scroll again" one-at-a-time stops.

## 8. Robustness note: `_onRestartHerePressed` with blank input (the only point worth noting)

If the UI were bypassed and [`_onRestartHerePressed()`](AI-SAGA/lib/logic/home_content.dart) were invoked directly with a **blank** input, the handler returns **before** truncating or generating anything, so existing story content can never be harmed. This is a defense-in-depth guard on top of the UI-level disabled button (blank boxes cannot be pressed). The same blank-input early-return exists at the core entry point ([`_continueStory`](AI-SAGA/lib/logic/home_content.dart)), covering every continuation / rewrite path.

## 9. Verification

- `flutter analyze` → no issues.
- All fixes verified against the waiting → typing → done lifecycle, the error / violation dialog flows, historical-segment scrolling, and the language-selection page (stored / system / unsupported / post-reset).

---

# Full Chatflow Summary — Setup & Story-Page UX Hardening (2026-08-13)

> A consolidated English summary of the whole 2026-08-13 chatflow: eliminating the display jump when the streaming typewriter starts, stabilizing the typewriter so it never re-types from a wrong position, keeping historical input cards populated and the layout constant around the "Your choice" marker, keeping the page stable behind error/violation dialogs, forcing every popup and error string into the current app language, and hardening the setup wizard (unified button placement, countdown removal, localized "Next", blank-input guards). **Desensitized** — no secrets, credentials, API keys, server addresses, or real identifiers appear anywhere.

## 1. The central problem: the display jump when typing starts

After the player taps **Continue** (or a time-tree "Restart from here"), the page shows a placeholder: the user's current choice, a "Generating new content…" row, and a half-screen reserved blank. When the server's first content chunk arrived, the old code removed the whole placeholder in one `setState` while the previous segment gained its time-tree card and the new segment began typing — the total layout height collapsed and the view "jumped" in a single visible frame.

## 2. Jump-free typewriter reveal (total height stays constant)

A bottom "generation area" now stays visible for the whole stream:

- **Before the first chunk** it shows the prompt + a half-screen reserved blank.
- **Once typing starts** the prompt disappears and its measured height is folded into the blank; the blank then shrinks **1:1** as the streaming segment grows, so the total height never changes — no jump at the start of typing and none while it types.
- **Time-tree card appears without a layout shift**: the just-continued segment's card height is measured off-screen during the waiting phase and absorbed by the reserved blank when it appears, so no extra card "pops in".

The mechanics live in [`home_content.dart`](AI-SAGA/lib/logic/home_content.dart):

- [`_SizeReporting`](AI-SAGA/lib/logic/home_content.dart:101) — a `SingleChildRenderObjectWidget` + [`_RenderSizeReporting`](AI-SAGA/lib/logic/home_content.dart:120) (`RenderProxyBox`) that calls back the child's size on every change (including first layout) via `SizeChangedLayoutNotifier`-style semantics but without a `GlobalKey`.
- The wrapper is applied **unconditionally** to every typewriter segment, so the element/state is never destroyed mid-typing at segment hand-off (this was the root cause of the typewriter re-typing from a wrong position).
- Only the current streaming (last) segment's reported height drives the reserved-blank shrink, so historical segments never disturb it.
- The reserved blank is computed as `_streamingPromptHeight + half − _cardMeasureHeight` and rendered through a `ValueListenableBuilder` that clamps the remaining blank to `≥ 0`.

## 3. Consistent layout around the "Your choice" marker

- Historical input cards display the **`choice_1/2/3` values saved at the moment of the user's choice** (kept in sync with the server), not blank values for segments generated in the current session.
- The three input boxes of a historical card use the **same placeholders** as the bottom input boxes.
- A **constant one-line gap** is kept between the input boxes and the "Your choice" marker in both the waiting and the typing states, so the marker never shifts when typing starts.

## 4. Stable page behind error / violation dialogs

When generation fails or is aborted, the generation area (user choice + reserved blank) stays visible while the dialog is up, so the page behind the popup does not jump:

- The **error dialog** keeps `_storyStreaming` true while shown and forces a restart (which resets state).
- The **violation dialog** transitions to the idle state only **after** it is dismissed (`_storyStreaming = false` in the dialog's `.then`).

## 5. Full popup localization (no mixed languages)

A shared [`StorageService.localizedText()`](AI-SAGA/lib/logic/storage_service.dart) helper returns text per the current app language. All client-side error messages in the story / sync / auth services and raw OS network exceptions (socket / client / timeout) are localized, so a popup shown in any language (e.g. Portuguese) is entirely in that language — no more "Portuguese title + Chinese detail". First-use popups follow the **system language** when no language has been selected (existing `getLanguage()` fallback).

## 6. Language-selection default + persistence across reset

- The language picker's default follows: **stored language** (old users) → **system language if supported** (new users) → **English** otherwise.
- The language preference is **preserved across the "Restart" reset** — the previously-used language outranks the system language, so after a reset the picker and the app text stay in the user's chosen language.

## 7. Setup wizard polish & countdown removal

- **Unified button placement**: the confirm/"Next" button on the language, location, era, player, and partner pages is fixed at **75% of the page height** (`LayoutBuilder + Stack`), so it never sits at different heights or falls off-screen. The final-confirmation button is deliberately the last item in its scrollable summary column.
- **Localized "Next"**: setup-page buttons renamed to "Next / 下一步" across all 10 languages.
- **Language box alignment**: the language dropdown now uses the same `CupertinoTextField` structure and navigation bar as the location/era pages, so all boxes render at the same height and screen position.
- **Countdown removed**: the 5-second countdown display is gone — once server moderation approves, `onConfirmed()` runs immediately; all other logic (audit dialog, edit shortcuts, back navigation, localization) is preserved.

## 8. Continuation button copy, disabled visual, and blank-input guards

- **Copy**: the latest-continuation button reads "Continue the story following the guidance above" in all 10 languages (the "input"/"choice" wording was stripped).
- **Disabled visual**: disabled buttons keep their blue fill and rounded shape and simply fade via `Opacity` (1.0 enabled / 0.4 disabled), so a disabled button stays distinct from the grey input field above it ([`text_input_panel.dart`](AI-SAGA/lib/widgets/text_input_panel.dart), [`story_choice_card.dart`](AI-SAGA/lib/widgets/story_choice_card.dart)).
- **Blank-input guards (defense-in-depth)**: the historical "Restart from here" button is disabled when its box is blank; [`_onRestartHerePressed`](AI-SAGA/lib/logic/home_content.dart) returns before any truncation; [`_continueStory`](AI-SAGA/lib/logic/home_content.dart) returns on blank input at its first line; and the server rejects a blank `user_input` for any continuation/rewrite with HTTP 400 **before** any DB write. Only a genuine first generation may carry an empty `user_input`.

## 9. Smooth up-scroll of earlier content

In-memory earlier segments (e.g. the tail loaded at startup) are revealed **all at once** — matching the server-batch behaviour — and the reveal triggers as soon as the user scrolls into the top pull area, eliminating the previous "scroll to the very top → stop → scroll again" one-at-a-time stops.

## 10. Verification

- `flutter analyze` → no issues.
- All fixes verified against the waiting → typing → done lifecycle, the error / violation dialog flows, historical-segment scrolling, and the language-selection page (stored / system / unsupported / post-reset).
- Because the generation area and typewriter wrappers changed in [`home_content.dart`](AI-SAGA/lib/logic/home_content.dart), test the changes with **Hot Restart (↻/R)**, not Hot Reload (⚡/r).

---

# Full Chatflow Summary — Randomized Murder-Case Fiction, Case Lifecycle & Dify Contract (2026-08-15)

> An English, desensitized summary of the 2026-08-15 chatflow. It covers: reworking the interactive-novel generation prompt into a randomized murder-case generator; the Dify code node that picks one case scenario from ten options; the `story_segments` schema extension with `case_type`/`case_core`; a dedicated case-generation Dify workflow (no inputs) returning victim identity / death scene / murder method, which the server concatenates into `case_core`; the exact 15-variable server→Dify story-workflow contract; the LLM2 inference mapping; the "persist only when story text + all four inference values arrive" rule; the 20-round case lifecycle; the `former_content` / `corrent_outlet` context variables (and removal of the unused `previous_story`); recommended DeepSeek V4 Pro LLM-node parameters for JSON structured output; a fresh-deployment (no-migration) server update; and `.gitignore` rules for Dify Python code. **Desensitized** — no secrets, credentials, API keys, server addresses, or real identifiers appear anywhere.

## 1. From interactive novel to randomized murder-case generator

- The original interactive-fiction prompt was reworked into a randomized murder-case generator: it randomly draws a **location × era × industry × background** combination and produces a case that becomes the story's background and final truth.
- Ten case scenarios are defined (e.g. "attempted murder followed by an accidental death", "counter-kill", "pure accident that looks like homicide", "two independent killers", "one-by-one victims among suspects", "four conspirators"). Each scenario pairs a type label with a generation prompt.
- A Dify code node picks one of the ten scenarios uniformly at random and returns `core_type` (label) + `core_content` (prompt); on any failure it returns empty strings (fail-safe, never raises).

## 2. Database: `story_segments` gains case columns

- The novel-text table `story_segments` was extended with two columns:
  - `case_type TEXT DEFAULT ''` — the current case type (e.g. "counter-kill").
  - `case_core TEXT DEFAULT ''` — the current case core (victim identity / death scene / murder method / truth background).
- Total columns: 22 (id, user_id, seq, content, created_at, choice_1/2/3, user_choice, outline, music_style, location, era, player_*, partner_*, language, case_type, case_core).
- Because the project is in the testing phase, the schema is created fresh on every deploy; **no migration/compatibility code** is kept.

## 3. Case-generation Dify workflow

- A dedicated workflow (no input variables, blocking response mode) generates the case content.
- Its LLM node (DeepSeek V4 Pro) is configured with **JSON structured output** (response format `json_object` + JSON Schema + output variable `structured_output`) producing three fields: `victim_identity`, `death_scene`, `murder_method`.
- The server's case caller receives these three fields and **concatenates them (newline-joined) into `case_core`**; `case_type` is read from `case_type`/`core_type`/`type` (aliases tolerated). Missing/empty fields are skipped; total failure returns `("", "")`.
- Recommended LLM-node parameters for this JSON task: temperature ≈ 0.8, max_tokens ≈ 800, top_p ≈ 0.9, **thinking mode off** (keeps the JSON clean — thinking blocks such as `<think>` can otherwise pollute structured output).

## 4. Server → Dify story-workflow contract (exactly 15 inputs)

The server's `dify_payload.inputs` sends only these variables (all legacy inputs removed):
`location, era, player_name, player_gender, partner_name, partner_gender, partner_traits, language, player_traits, seq, former_content, corrent_outlet, user_choice, case_type, case_core`.

- `seq` — the current round number (segment count).
- `former_content` — the latest segment's story text (continuation hook; empty on a brand-new story).
- `corrent_outlet` — the outlines from the most recent 20-multiple round (inclusive) up to the previous round (inclusive), newline-joined; **empty when `seq` is a multiple of 20**.
- `user_choice` — the player's action instruction for this round.
- `case_type` / `case_core` — the current case (from the snapshot on continuation).

## 5. LLM2 (inference) output mapping

The story workflow runs LLM1 (streaming novel text) then LLM2 (structured output `outline` / `action_a` / `action_b` / `music_style`). The server maps them:
- `outlet` or `outline` → `outline`
- `music` or `music_style` → `music_style` (whitelist validated)
- `action_a` → `choice_2`
- `action_b` → `choice_3`
- `choice_1` → left blank (the player can fill it in later, or pick choice_2/3 directly)
- `case_type`/`case_core` (aliases `core_type`/`core_content`) read when present.

## 6. Persistence timing: only persist when everything arrived

- A new story segment is written to the database **only when both** the complete story text **and** the four inference values (`outline/outlet`, `music/music_style`, `action_a`, `action_b`) are present in the workflow outputs.
- A `_has_inference_outputs` guard decides this; if any of the four is missing, the segment is **not** persisted (the text is still streamed to the client).
- The old fallback paths (stream ended without `workflow_finished`) no longer persist, since they can never carry the four values.

## 7. Case lifecycle: one case per 20-round arc

- On `seq % 20 == 0` (including 0, the start of a new arc): call the case-generation workflow and store a **fresh** `case_type`/`case_core`.
- On every other round: **copy the previous round's** `case_type`/`case_core` unchanged, so an arc keeps the same case for 20 consecutive rounds, then regenerates at the next multiple of 20 — repeating cyclically.

## 8. Context variables and removal of `previous_story`

- `former_content` (previous segment's text) replaced the earlier `previous_story` input, which was removed as unused; `_get_story_tail` was simplified to `_get_story_count` (segment count only).
- `corrent_outlet` reads `outline` values for `seq in [(seq//20)*20, seq-1]` and newline-joins them (empty on multiples of 20).

## 9. Deployment (testing phase, no migrations)

- The FastAPI server runs in a Docker container with the code and the SQLite data bind-mounted from the host; updating means uploading `main.py`, restarting the container, and letting the fresh schema be recreated.
- The old database is backed up (renamed) and the container recreates an empty database with the latest schema — intentionally **no migration/compatibility** logic, since the app is pre-release.

## 10. `.gitignore` for Dify assets

- All `*.yml` (Dify workflow DSL) were already ignored. Added:
  - `dify_code_node.py`
  - `dify/*.py`
- These keep Dify code-node / script Python files out of version control.

## 11. Verification

- `python3 -m py_compile` passes after every server change.
- The 20-round case-inheritance, the four-value persistence guard, and the case-core concatenation were each validated with standalone simulation tests.
- The deployed container was verified to serve the new schema (22 columns) and the new functions, and the service responds correctly.
