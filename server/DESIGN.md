# AI SAGA — Backend Architecture & Design

> A public-facing technical overview of the AI SAGA moderation gateway: identity, device binding, quota/entitlements, and cost control.
>
> Status: v2 implemented, end-to-end verified in development mode.

---

## 1. System Overview

```
 User ──light auth──▶ Apple ID / Google (OAuth) ──▶ ID Token (JWT)
                          │
                          ▼
                  Flutter App
        ├─ ① Secure-hardware key pair (private key never leaves the chip)
        ├─ ② Light authorization (one tap; dev mode auto-skips)
        ├─ ③ Register {device_id, public_key, provider, user_id, id_token, challenge, signature}
        └─ ④ Every request carries a signed bearer token
                          │
                          ▼
              FastAPI Gateway (HTTP)
        ├─ SQLite: users / devices / trials / entitlements / usage / sync_data / stories
        ├─ JWKS verification of Apple/Google ID Tokens → stable `sub` = user_id
        ├─ Challenge–signature registration (proof of hardware possession)
        │    + public_key UNIQUE (one hardware = one identity = one quota)
        ├─ Trial: 3 uses per 7-day cooldown (user_id + device_id dimensions)
        ├─ Paid: entitlements table with both expiry & quota models (server-verified)
        └─ Cloud sync: per-user incremental story sync (RAG hook reserved)
```

### Core security principles

1. **Identity = platform account.** Apple/Google stable `sub`, verified server-side with official JWKS — the server never trusts client-claimed IDs.
2. **Device = secure-hardware public key.** The private key never leaves hardware; `public_key UNIQUE` guarantees “one hardware = one identity = one quota”.
3. **Registration = challenge–signature.** The server issues a one-time challenge; the client signs it with its hardware key, proving possession of that device.
4. **Cost control (three layers).** Input ≤ 5,000 tokens (hard reject at the entry), output ≤ 4,000 tokens (Dify `max_tokens`), plus usage quotas (trial 3 / paid daily cap).
5. **Payment verification lives on the server.** Platform receipts are validated server-side and refunds revoke entitlements; the app cannot forge paid status.

---

## 2. Why These Decisions Were Made

| Decision | Rationale |
|---|---|
| Hardware-backed keys instead of a software UUID | A UUID can be spoofed; a hardware key gives a cryptographic, non-transferable proof of a physical device. |
| Challenge–signature registration instead of an app-shared secret | The app never stores a shared secret; the server verifies possession at every registration. |
| Server-side JWKS verification instead of trusting client IDs | Prevents identity spoofing; the platform account `sub` is the source of truth. |
| Signed bearer tokens with expiry + 60 s early-expiry buffer | Short-lived tokens bound to (user, device) reduce replay risk and avoid edge-case failures. |
| Dual-dimension trial accounting (user + device) | Blocks “same account on another device” and “same device, many accounts” quota farming. |
| Enforce input budget before any LLM spend | No money is spent on oversized requests; output is capped at generation time. |
| Versioned (optimistic-concurrency) cloud sync | Older clients can never silently overwrite newer story data. |
| Silent fail-open device-integrity check | Legitimate users are never blocked if the integrity check is unavailable on a platform. |

---

## 3. Database Schema (SQLite)

### users — platform accounts
| Field | Type | Notes |
|---|---|---|
| user_id | TEXT PK | Stable platform `sub` |
| provider | TEXT | `google` / `apple` / `dev` |
| email | TEXT | Platform email (may be empty) |
| active_device_id | TEXT | Currently active hardware device (single-active-device enforcement); set at registration and on every app-launch handshake |
| created_at | INTEGER | Registration timestamp |

### devices — hardware-bound devices
| Field | Type | Notes |
|---|---|---|
| device_id | TEXT PK | Stable client device identifier |
| user_id | TEXT | Owning account |
| public_key | TEXT UNIQUE | Hardware public key; unique constraint prevents multi-ID abuse |
| status | TEXT | `active` |
| created_at / last_seen_at / key_rotated_at | INTEGER | Timestamps |

### trials — trial accounting
| Field | Type | Notes |
|---|---|---|
| id | INTEGER PK | |
| user_id / device_id | TEXT | Dual-dimension cooldown |
| granted_at | INTEGER | Last grant time |
| used_count | INTEGER | Uses consumed |

**Rule:** during the cooldown (default 7 days) either dimension blocks; when the cooldown expires a fresh grant of 3 uses is issued.

### entitlements — paid entitlements (expiry + quota models)
| Field | Type | Notes |
|---|---|---|
| user_id | TEXT PK | |
| plan | TEXT | `free` / `paid` |
| purchased_quota / used_quota | INTEGER | Quota-based entitlement (purchased uses) |
| expires_at | INTEGER | Subscription-based entitlement (expiry) |
| status | TEXT | `active` / `revoked` (refund revocation) |
| provider / provider_purchase_id | TEXT | Platform transaction identifiers |
| subscription_period_days / grace_until / revoked_at | INTEGER | Reserved |

### usage — daily quota & rate limiting
| Field | Type | Notes |
|---|---|---|
| user_id, date | TEXT PK | Per-day |
| count / tokens_used | INTEGER | Usage and token audit |

### sync_data — cloud sync
| Field | Type | Notes |
|---|---|---|
| user_id, key | TEXT PK | e.g. key = `story` |
| content | TEXT | Payload |
| updated_at | INTEGER | Optimistic-concurrency version |

### stories — novel story segments (array storage)
| Field | Type | Notes |
|---|---|---|
| user_id | TEXT PK | Owning account |
| segments | TEXT | JSON array of strings: each generation = one element (`["opening...", "continuation 1...", ...]`) |
| updated_at | INTEGER | Optimistic-concurrency version |

### challenges — one-time registration challenges (replay protection)
| Field | Type | Notes |
|---|---|---|
| challenge_id | TEXT PK | One-time |
| device_id / challenge / expires_at | TEXT / INTEGER | Valid for 5 minutes |

Plus `challenges_guard` (persistent per-IP registration throttling) and `rate` (per-minute per-user rate limiting).

---

## 4. API Design

### Registration (two phases)
```
POST /api/register/challenge  {device_id}
  → {challenge_id, challenge}          # one-time, 5-minute expiry

POST /api/register  {device_id, public_key, provider, user_id, id_token,
                     challenge_id, challenge, signature}
  → verify id_token (JWKS) + challenge match + hardware signature + public_key UNIQUE
  → {token, user_id, device_id, expires_at, ...}
```

### Moderation / generation
```
POST /api/audit-and-chat  Authorization: Bearer <token>
  body {user_id, text}
  → input ≤ 5,000 tokens (hard reject) → entitlement check (paid / trial)
  → quota & rate limits → Dify workflow (with max_tokens cap)
  → returns moderated output text
```

### Cloud sync
```
GET  /api/sync?since=<timestamp>   # incremental pull
POST /api/sync  {key, content, updated_at}   # optimistic-concurrency write
GET  /api/story                    # fetch this user's story segments (array)
POST /api/story  {segments, updated_at}      # save story segments as an array (optimistic-concurrency)
POST /api/device/activate          # app-launch handshake: register this device as the user's active hardware
```

### Purchase (reserved)
```
POST /api/verify-purchase  {provider, receipt, product_id}   # server-verified receipt
POST /api/purchase-webhook                                    # platform push: renew / expire / refund-revoke
```

### Other
```
GET /api/health   # service status + registered users/devices
```

---

## 5. Cost Control Pipeline

1. **Input guard (before spend):** token estimate (CJK ≈ 1 token/char, Latin ≈ 3.5 chars/token) hard-rejects anything over 5,000 tokens, with a 40,000-character absolute fallback.
2. **Output cap (at generation):** `max_tokens` (default 4,000) is passed into the Dify workflow inputs, so generation stops at the cap.
3. **Usage accounting:** paid users are governed by a daily quota and a per-minute rate limit; free users consume from their trial grant.

---

## 6. Cloud Sync & Future RAG

- Sync is keyed by `user_id` so a player can continue on a new device under the same account.
- Writes are version-stamped; a stale version is rejected (optimistic concurrency).
- A reserved post-write hook will later trigger per-chapter incremental chunking + re-embedding for retrieval-augmented generation (RAG), with per-user isolation.
- **Single active device:** on launch, after the root/jailbreak + hardware checks pass, the app calls `POST /api/device/activate` to set `users.active_device_id` to this device (last launch wins). Every authenticated data request is checked against it (`_enforce_active_device`); a mismatch returns HTTP 409 `device_conflict`, and the app shows a "multiple devices signed in" warning and restarts itself (`SecurityService.restartApp`).
- **Launch sync gate (server one-way refresh):** every cold start the app first uploads its hardware public key + user id to `POST /api/device/activate` (server verifies and updates `devices.public_key`), then pulls the user's full story from `GET /api/story` and overwrites local storage — the database unilaterally refreshes the app's data, so the server is authoritative. The app's main features stay locked behind a syncing/retry screen until this completes. After each generation/continuation the app pushes the story via `POST /api/story`.

---

## 7. Deployment Notes

- The service is a containerized FastAPI app (port 8000) with a bind-mounted data directory for SQLite persistence; the token-signing secret is generated once and persisted with restricted permissions.
- Configuration is injected entirely through environment variables; **no secrets are stored in the repository**.
- A `DEV_MODE` flag allows end-to-end testing without real Apple/Google OAuth (uses a local test account); it must be disabled in production.

### Production environment variables
| Variable | Purpose |
|---|---|
| `DIFY_API_KEY` | Moderation workflow API key |
| `DIFY_API_URL` | Dify workflow endpoint |
| `DIFY_MAX_TOKENS` | Output token cap |
| `MAX_INPUT_TOKENS` / `MAX_INPUT_CHARS` | Input budget |
| `GOOGLE_CLIENT_ID` | Google OAuth audience for JWKS verification |
| `APPLE_SERVICE_ID` / `APPLE_APP_BUNDLE_ID` | Apple audience for JWKS verification |
| `APPSTORE_SHARED_SECRET` / `GOOGLE_PLAY_SERVICE_ACCOUNT` | Purchase verification (reserved) |
| `DEV_MODE` | Must be `0` in production |

---

## 8. Roadmap / Security Hardening (Phase 2)

- **Play Integrity (Android) / App Attestation (iOS)** for stronger device attestation.
- **HTTPS** once a domain is configured.
- **RAG** (sqlite-vec or a Dify knowledge base) with per-`user_id` isolation.
- **Paid entitlements**: App Store Server Notifications V2 + Google RTDN push handling (webhook reserved), server-side daily quota enforcement.

---

## 9. Verified End-to-End (Development Mode)

- [x] Registration: challenge → hardware signature → registration → bearer token
- [x] Cloud sync: incremental write/read
- [x] Story cloud storage: story saved/loaded as an array of segments (`/api/story`)
- [x] Same hardware re-binding under a different ID is rejected (409 anti-multi-ID)
- [x] Input token estimation / output `max_tokens` cap
- [x] Trial accounting: 3 uses + 7-day cooldown
