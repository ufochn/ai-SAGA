# AI SAGA

**AI SAGA** (AI 傳奇 / AI サーガ / AI 사가) is a multilingual, iOS‑style interactive fiction game for Android, iOS, macOS and Web. It lets players build a character and partner, choose a location and era, and then generate an adventure detective–romance story, with every piece of player input **moderated by an AI audit gateway** before it is accepted.

> This document records the project’s current state, every major improvement made so far, and the reasoning behind each design decision — based on our collaboration history.

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

---

## Tech Stack

| Layer | Technology |
|---|---|
| App | Flutter (Dart), pure **Cupertino** widgets (no Material) |
| Secure storage | `flutter_secure_storage` (iOS Keychain / Android Keystore) |
| Platform auth | `google_sign_in`, `sign_in_with_apple` |
| Hardware keys | Android Keystore (StrongBox/TEE) & iOS Secure Enclave via a native `MethodChannel` |
| Backend | **FastAPI** + **SQLite** (container `my-audit-app`, port 8000) |
| AI moderation | Server calls a **Dify** workflow (with AWS‑style guard / moderation), blocking response mode |
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
│   │   └── home_content.dart     # Setup wizard + story page orchestration
│   └── widgets/                  # Setup pages, audit dialog, privacy policy, input/button/character components
├── android/  ios/  macos/  web/  # Platform shells (hardware-key channels, entitlements)
├── third_party/                  # Vendored & patched plugins
├── pubspec.yaml                  # Dependencies (flutter_dotenv, google_sign_in, etc.)
└── .env.example                  # Committed template (copy to .env)
server/
├── main.py                       # FastAPI audit gateway (auth, quota, sync)
└── DESIGN.md                     # Public architecture & design (English)
```

---

## Backend API Overview

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | Service status + registered users/devices |
| `POST /api/register/challenge` | Issue a one-time challenge (replay protection, IP rate-limited) |
| `POST /api/register` | Verify ID token (JWKS) + challenge + hardware signature; bind account/device/public key; return bearer token |
| `POST /api/audit-and-chat` | Moderate/transform player text via Dify; enforces budget, quota, rate limits |
| `GET/POST /api/sync` | Incremental cloud sync (optimistic concurrency) |
| `POST /api/verify-purchase` | Purchase verification (reserved) |
| `POST /api/purchase-webhook` | Platform subscription/refund push (reserved) |

---

## Getting Started

### Prerequisites
- Flutter (Dart SDK `^3.12.2`)
- A backend server with `DIFY_API_KEY` (see [`server/main.py`](server/main.py:205))

### Client (dev mode, no Apple/Google credentials required)
```bash
cd AI-SAGA
cp .env.example .env
# In .env, set DEV_MODE=true and fill AUDIT_API_URL / REGISTER_API_URL
flutter pub get
flutter run
```

### Server
```bash
export DIFY_API_KEY=xxx
export DEV_MODE=1            # dev only; disable in production
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### Dify canvas (one-time manual step)
Bind the LLM node’s `max_tokens` to the workflow input variable `max_tokens` (or hardcode 4000) so the output cap is enforced.

---

## Deployment & Configuration

Production requires these environment variables on the server (see [`server/DESIGN.md`](server/DESIGN.md:183) and [`.env.example`](AI-SAGA/.env.example:1)):

| Variable | Purpose | Status |
|---|---|---|
| `GOOGLE_CLIENT_ID` | Google OAuth Web Client ID | ⏳ to be provided |
| `APPLE_SERVICE_ID` | Sign in with Apple Service ID | ⏳ to be provided |
| `APPLE_APP_BUNDLE_ID` | iOS Bundle ID | ⏳ to be provided |
| `DEV_MODE` | must be `0` on release | ⏳ flip on launch |
| `APPSTORE_SHARED_SECRET` / `GOOGLE_PLAY_SERVICE_ACCOUNT` | purchase verification | reserved |

iOS additionally enables the Sign in with Apple capability via [`Runner.entitlements`](AI-SAGA/ios/Runner/Runner.entitlements:1).

---

## Roadmap

- **Play Integrity (Android) / App Attestation (iOS)** for stronger device attestation.
- **HTTPS** once a domain is configured.
- **RAG** (sqlite-vec or Dify knowledge base) with per-`user_id` isolation.
- **Paid entitlements**: wire App Store Server Notifications V2 and Google RTDN to the reserved webhook; enforce daily quotas server-side.
- **Cloud sync**: surface sync in the UI and trigger incremental RAG indexing.

---

## Notes for the Repository

- `.env` and all real secrets are **never committed**; only `.env.example` is tracked.
- Vendored plugins live under [`third_party/`](AI-SAGA/third_party/) with minimal patches to keep them buildable against current toolchains.
- Backend architecture, database schema, security principles, API design, and design rationale are documented in the public [`server/DESIGN.md`](server/DESIGN.md:1).
