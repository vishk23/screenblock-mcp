# ScreenCP v1 — Chat-Driven Screen Time Control — Design Spec

**Date:** 2026-07-08
**Status:** Approved by user (provisional), pending spec review
**Scope:** Phase 1 only (chat-driven enforcement loop). Later phases sketched for context, not specified.

## 1. Vision

An iOS distraction-control app where ChatGPT (and Claude) acts as an executive-function coach and control surface. The user talks to the AI in the regular consumer chat app ("block Slack till 5", "give me 15 minutes of TikTok, I'm on the bus", "how did I do today?"), and the AI schedules blocks, enforces limits, grants temporary access, and coaches from adherence data — via an MCP server bridging to a native iOS app that holds the Screen Time enforcement permission.

North star (later phases): context-aware policies — the system detects contexts (commuting, at the gym, calendar focus block) and policies react automatically. v1's context is manual (the user asserts context in chat), but the architecture treats *context → policy* as a first-class loop from day one so sensors are additive, not a rewrite.

**Audience:** personal-first (the developer's own devices), with architecture choices that don't preclude shipping as a product later.

## 2. Phased roadmap (context only)

- **Phase 1 (this spec):** chat-driven enforcement, end-to-end. Manual context.
- **Phase 2:** auto-context engine (motion "commuting", geofence "gym mode", calendar-aware focus).
- **Phase 3:** insight layer (adherence trends, richer analytics; Mac companion for rich per-app usage — macOS is far more open than iOS).
- **Phase 4:** consumer distribution — ChatGPT App Directory / Claude connector directory publishing, OAuth polish, one-tap connect; Apple Family Controls *distribution* entitlement request.

Each later phase gets its own spec.

## 3. Hard platform constraints (design axioms)

These are verified against primary sources (Apple docs, MCP spec, Supabase docs) and shape everything:

1. **Raw per-app usage data cannot leave the iPhone.** Apple's `DeviceActivityReport` extension "runs in a sandbox [that] prevents your extension from making network requests or moving sensitive content outside the extension's address space" (Apple docs, verbatim). The app can *display* precise usage on-device but never possesses the numbers as data. Therefore ChatGPT's knowledge of usage is derived exclusively from **data we generate ourselves**: enforcement events and threshold crossings.
2. **Usage awareness is watchlist-based, not omniscient.** Coarse usage knowledge comes from pre-registered `DeviceActivityEvent` thresholds (e.g. ping at 15/30/60/120 min) on monitored apps/categories. Unmonitored apps are invisible. The OS caps active monitoring (~20 activities, each with limited events) — fine for "watch the apps that tempt you," incompatible with "track everything."
3. **App tokens are opaque and picker-only.** Which apps a group contains can only be chosen by the user in the native `FamilyActivityPicker` on-device. Neither the server nor the AI can reference apps by name/bundle-id or mint tokens. Tokens never leave the device. Category selections auto-cover newly installed apps in that category.
4. **Enforcement is OS-owned and local.** Shields set in `ManagedSettingsStore` and schedules registered with `DeviceActivityCenter` are enforced by iOS even when our app is terminated and offline. The cloud is a control plane, never in the enforcement path.
5. **Silent push is best-effort.** Background (`content-available`) pushes are low-priority, may be delayed or dropped, and stop entirely if the user force-quits the app. Visible pushes are reliably delivered. Our push volume (a few/day) is far below Apple's throttle ceiling; the residual risk is timing lag and force-quit, handled by the delivery ladder (§7).
6. **Sub-15-minute schedule precision is unreliable.** Blocking is instant; OS-fired *un*-block/re-block callbacks can lag by a minute or two when the device is locked. Design timed grants defensively: worst case is "re-locked slightly late," never "forgot to re-lock."
7. **Development Family Controls entitlement needs no Apple approval** (personal build, own device). Distribution entitlement (Phase 4) requires a request + review (~3 weeks–1 month anecdotally).
8. **Custom MCP connectors work today in both ChatGPT (Developer Mode, all paid tiers, works on mobile once added on web) and Claude (Settings → Connectors, Pro/Max; cloud-hosted connection).** Remote MCP = Streamable HTTP transport + OAuth 2.1 per the MCP spec.

## 4. Architecture (Phase 1)

```
You (ChatGPT / Claude app, incl. mobile)
        │  MCP tools (Streamable HTTP + auth)
        ▼
┌─────────────────────────────┐
│ FRONT DOOR + BRAIN          │   One Node/TypeScript service (Fly.io or
│ - MCP server (official      │   Railway). Hosting = "Option C".
│   @modelcontextprotocol/sdk)│
│ - REST/sync API for the app │
│ - APNs sender (.p8 token)   │
└─────────────┬───────────────┘
              │
       Supabase (data layer only)
       - Postgres: source of truth (groups, policies, grants, goals, events)
       - Realtime: live policy updates while app foregrounded
       - Auth: Sign in with Apple (native idToken flow)
              │
              ▼
┌─────────────────────────────┐
│ ENFORCER (native iOS app)   │  Swift/SwiftUI, iOS 16+ floor
│ - FamilyControls authz +    │
│   FamilyActivityPicker      │
│ - ManagedSettings shields   │
│ - DeviceActivity schedules  │
│   + threshold events        │
│ - Extensions: Monitor,      │
│   ShieldConfiguration,      │
│   ShieldAction,             │
│   DeviceActivityReport      │
│ - Sync engine (reconcile)   │
└─────────────────────────────┘
              │
        iOS enforces (works offline, app killed)
```

### Component responsibilities

**Enforcer (iOS app).** The only piece Apple requires to be native. Owns: authorization flow; the group picker UI (map group names → tokens, stored on-device); translating synced policy into `ManagedSettingsStore` shields, `DeviceActivitySchedule`s, and `DeviceActivityEvent` thresholds; logging events upward; reconciliation (on foreground, on push, on extension callbacks). The main app UI is minimal in v1: sign-in, group management (picker), current status, and an on-device precise usage view (`DeviceActivityReport` — display only, per axiom 1).

**Brain/Front Door (Node service).** One TypeScript service exposing (a) the MCP endpoint for ChatGPT/Claude and (b) a small authenticated API the iOS app syncs against, plus APNs sending. Stateless per-request MCP (Streamable HTTP); state lives in Postgres. Personal-scale deploy: single small instance.

**Rationale for Option C over alternatives considered:** All-Supabase (Edge Functions MCP) was rejected because MCP auth on Edge Functions isn't first-class yet and edge runtime limits constrain streaming; Cloudflare-split was rejected as two platforms to wire for no v1 gain. One conventional Node service is simplest to reason about, has proper OAuth available via the official SDK/reference implementations from day one, and "the same server grows" is the scaling path.

### Auth

- iOS app ↔ backend: Supabase Auth, native Sign in with Apple (idToken flow).
- ChatGPT/Claude ↔ MCP server: OAuth 2.1 per MCP spec (authorization-code + PKCE, protected-resource metadata). v1 may bootstrap with a single-user bearer token if OAuth wiring stalls, but OAuth is the design target since both clients support it and Phase 4 requires it. Both surfaces resolve to the same user id.

## 5. Data model

Source of truth in Postgres; mirrored to the app via sync. All rows scoped to `user_id`.

- **`groups`** — `id`, `name` ("Social", "Work Distractions"), `created_at`. The *name and id only*. The token mapping (`group_id → {ApplicationToken/CategoryToken set}`) lives exclusively on-device (App Group storage shared with extensions). Server and AI deal in names; the app resolves names → tokens locally. A `has_selection` flag (synced up by the app) tells the AI whether a group is actually populated.
- **`policies`** — `id`, `group_id`, `kind` (`schedule` | `limit` | `block`), `active`, and kind-specific fields:
  - `schedule`: `days_of_week`, `start_time`, `end_time` (block the group during the window, recurring)
  - `limit`: `minutes_per_day` (threshold-enforced daily cap; app derives the OS threshold ladder, e.g. registers interim thresholds at 50%/80%/100% for coaching data + enforcement at 100%)
  - `block`: unconditional shield until removed
- **`grants`** — `id`, `group_id` (or `policy_id`), `minutes`, `starts_at`, `expires_at`, `status` (`pending`→`active`→`expired`). Temporary exceptions; the app lifts the shield and schedules re-block at expiry (one-shot `DeviceActivitySchedule` + reconciliation backstop per axiom 6).
- **`goals`** — `id`, `text`, `target` (freeform + optional numeric), `date`. Lightweight; the AI reads/writes and coaches against them.
- **`events`** — append-only log the app pushes up: `type` (`shield_shown`, `shield_action_tapped`, `threshold_crossed` (with which threshold), `grant_started`, `grant_expired`, `policy_applied`, `session_completed`…), `group_id`, `ts`, `meta` (jsonb). This is the *only* usage signal the AI ever sees (axiom 1/2) and feeds `get_today_summary`.
- **`devices`** — APNs device token, last-seen, sync cursor.
- **Sync/versioning** — monotonic `updated_at`/version on policy-bearing tables; the app asks "changed since X?" and applies idempotently. Cloud is source of truth for *policy*; device is source of truth for *token selections* and emits *events*.

## 6. MCP tool surface (v1)

Designed per Anthropic's tool-writing guidance: few high-value tools, unambiguous params, token-efficient returns, `destructiveHint`/`readOnlyHint` annotations. Groups are addressed by name (fuzzy-matched server-side to the group list).

| Tool | Args | Behavior |
|---|---|---|
| `get_status` | — | Read-only. Current blocks in effect, active grants + remaining time, today's policies, per-group `has_selection`. |
| `list_groups` | — | Read-only. Groups with policies attached and whether populated on device. |
| `create_group` | `name` | Creates an empty named group; returns instruction that the user must open the app to populate it (picker). |
| `set_schedule` | `group`, `days`, `start`, `end` | Create/replace a recurring block window. |
| `set_limit` | `group`, `minutes_per_day` | Create/replace a daily time cap. |
| `block_now` | `group`, optional `until` | Immediate shield (indefinite or until a time). |
| `unblock` | `group` | Remove an active block/limit-shield. Destructive-annotated. |
| `grant_temp_access` | `group`, `minutes`, optional `reason` | The "15 min of TikTok" tool. Creates a grant; auto-re-blocks at expiry. `reason` is logged for coaching. |
| `remove_policy` | `policy_id` or `group`+`kind` | Delete a policy. Destructive-annotated. |
| `set_goal` | `text`, optional `target` | Set/replace today's goal. |
| `get_today_summary` | optional `date` | Read-only. Adherence readout from the event log: blocks held, thresholds crossed (coarse usage), grants used + reasons, shield-hit counts, goal status. |

Every mutating tool's response includes **delivery state**: `applied` (device confirmed) vs `pending` (pushed, awaiting device ack), so the AI can tell the user honestly whether the block is live yet.

## 7. Command delivery ladder (server → phone)

Enforcement never depends on the push channel (axiom 4): schedules and limits run locally once synced. The ladder below exists only for *new/changed* policy reaching the device:

1. **App foregrounded:** Supabase Realtime subscription → applies within ~1s. Also full reconcile on every `didBecomeActive`.
2. **App backgrounded:** silent push (`content-available`, priority 5) → app wakes ~30s, syncs, applies. Best-effort.
3. **No ack within a short window (~10–20s) for a user-initiated "now" command:** visible **Time-Sensitive** notification ("Tap to apply: block Social"). Tap → app opens → applies. Guaranteed path.
4. **Backstop:** next app open reconciles everything regardless.

**Spike (build-time validation task):** test whether a Notification Service Extension (`mutable-content` visible push — runs code on delivery, *without* a tap, and survives force-quit) can legally/reliably apply a `ManagedSettingsStore` shield. Undocumented by Apple. If yes → rung 3 becomes zero-tap. If no → ladder above stands. **The design must not depend on the answer.**

Grant expiry (re-block) is device-local: one-shot `DeviceActivitySchedule` `intervalDidEnd` + shield re-application, with reconciliation catching any missed callback (axiom 6). Server marks grants expired on the clock regardless, so `get_status` never lies for long.

## 8. Error handling & edge cases

- **Unpopulated group:** AI sets a policy on a group with `has_selection=false` → tool succeeds but returns a warning + instruction to open the app and pick apps. Policy activates on population.
- **Device unreachable** (offline, force-quit, dead battery): mutating tools return `pending`; the AI is expected (via tool descriptions) to relay that honestly. Reconcile-on-open guarantees eventual application.
- **Conflicting policies** (grant vs schedule vs block): precedence is **grant > block_now > schedule/limit** while the grant is active; on expiry the strictest applicable policy reasserts. Precedence is computed on-device deterministically from synced state.
- **Extension fragility** (monitor extension memory-killed, callbacks missed): extensions do minimal work (set/clear shields, write an event row to App Group storage); the main app uploads events and reconciles on next run. Every OS callback path has a reconciliation backstop.
- **Clock skew / timezone:** schedules stored with timezone; device applies in local time.
- **AI misuse guardrails:** `unblock`/`remove_policy` carry destructive annotations so clients confirm; grants have a server-side max duration (configurable, e.g. 60 min) so "unblock forever" requires the explicit `unblock` tool, not a grant.

## 9. Testing strategy

- **Node service:** unit tests for tool handlers + policy precedence logic against a test Postgres; MCP contract exercised with the official SDK test client (and MCP Inspector during development).
- **iOS:** unit tests for the sync/reconcile engine and precedence resolution (pure logic, extracted from UI). Screen Time API behavior (shields, schedules, thresholds, grant expiry) is **not unit-testable** — validated via a scripted on-device manual test checklist (block applies with app killed; limit fires; grant expires and re-blocks; force-quit + remote command → notification fallback works).
- **End-to-end smoke:** from ChatGPT (real Developer-Mode connector) run the golden path: create schedule → verify shield on device → grant 15 min → verify unshield → verify auto-re-block → `get_today_summary` reflects it all.
- **Spikes before main build:** (a) Notification Service Extension shield test (§7); (b) minimal FamilyControls hello-world on-device to confirm entitlement + picker + shield loop works on the target iOS version.

## 10. What v1 explicitly does NOT include

- Automatic context (location/motion/calendar) — Phase 2. v1 context is what the user tells the AI.
- Mac companion / rich per-app usage analytics — Phase 3; impossible to export from iPhone regardless (axiom 1).
- Multi-user backend hardening, App Store distribution, directory publishing, distribution entitlement — Phase 4.
- Bypass-resistance hardening (preventing yourself from deleting the app / revoking permission). Commercial apps invest heavily here; v1 relies on friction, not tamper-proofing.
- Precise per-app minute totals in chat. ChatGPT sees thresholds crossed, blocks, grants, adherence — never exact totals (axiom 1).

## 11. Reference material (crib sources, verified)

**Apple / Screen Time:**
- Screen Time API docs hub: https://developer.apple.com/documentation/screentimeapidocumentation
- DeviceActivityReport sandbox constraint: https://developer.apple.com/documentation/deviceactivity/deviceactivityreport
- Entitlement (dev vs distribution): https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement
- WWDC21 "Meet the Screen Time API": https://developer.apple.com/videos/play/wwdc2021/10123/ · WWDC22 update: https://developer.apple.com/videos/play/wwdc2022/110336/
- OSS to crib: `kingstinct/react-native-device-activity` (most complete real-world wrapper; Swift bridge instructive), `CoffeeNaeriRei/ScreenTime_Barebones` (minimal all-targets skeleton — copy structure), `christianp-622/ScreenBreak` (self-imposed shields + timers, closest use case)

**MCP / connectors:**
- MCP TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk
- MCP auth spec + OAuth tutorial: https://modelcontextprotocol.io/specification/latest/basic/authorization · https://modelcontextprotocol.io/docs/tutorials/security/authorization
- ChatGPT Developer Mode: https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt · Apps SDK (Phase 4): https://developers.openai.com/apps-sdk
- Claude custom connectors: https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp
- Tool design: https://www.anthropic.com/engineering/writing-tools-for-agents

**Backend / push:**
- APNs token auth (.p8): https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
- Background push + limits: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app
- Supabase native Sign in with Apple: https://supabase.com/blog/native-mobile-auth · Realtime: https://supabase.com/docs/guides/realtime

**UX prior art (patterns, not code):** Opal (scheduled sessions + hard "deep focus"), one sec (pause interstitial), ScreenZen (configurable delays/open limits), Brick (physical NFC unlock), Clearspace ("earn screen time").

## 12. Open questions deferred to the implementation plan

- Exact OAuth wiring order (full OAuth 2.1 first vs single-user bearer bootstrap → OAuth) — decide when standing up the Node service.
- Threshold-ladder granularity per limit (how many interim thresholds per group given the OS monitoring cap).
- Fly.io vs Railway (equivalent for our needs; pick at deploy time).
