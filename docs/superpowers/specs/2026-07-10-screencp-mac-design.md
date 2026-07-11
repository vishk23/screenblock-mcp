# ScreenCP Mac Companion — Design (Plan 4)

**Status:** research complete, design drafted, awaiting user approval.
**Research:** two cited sweeps 2026-07-10 (OSS landscape; Screen Time API viability). Key sources inline.

## The decisive platform fact

Apple's Screen Time stack (FamilyControls / ManagedSettings / DeviceActivity / shields) is **not available on native macOS and broken on Catalyst** — verified against the macOS 26.4 SDK swiftinterfaces (`@available(macOS, unavailable)`, picker absent entirely), Apple docs availability, and unresolved forum failures (`FamilyControlsAgent error 159`). The Family Controls entitlement is not offered for macOS. Every shipping competitor (Opal, Jomo, one sec, Focus) builds **userspace enforcement** on Mac. We do the same — which is fine, because macOS's openness is exactly what buys us the insight iOS forbids.

## Architecture: the Mac is just another device on the existing server

One new Swift menu-bar app (`mac/`, XcodeGen, Developer ID — NOT Mac App Store, so `NSRunningApplication.terminate()` works without sandbox restrictions). Zero server schema changes for enforcement — the Mac registers as a device, syncs the same groups/policies/grants, acks, uploads events. Groups keep one name across devices: "Social" maps to app *tokens* on iPhone and to *bundle IDs + domains* on Mac (Mac-side "picker" = list of `/Applications` + running apps + manual domain entry; stored locally like iOS selections, `has_selection` reported per device — needs a small per-device selection flag, the one server tweak).

### Components (crib list from verified OSS)

| Piece | Mechanism | Crib |
|---|---|---|
| Menu-bar scaffold | SwiftUI `MenuBarExtra` | TomatoBar (MIT — liftable wholesale) |
| Tracking: active app | `NSWorkspace.didActivateApplicationNotification` + frontmost polling | `aw-watcher-window/macos.swift` (MPL-2.0, ~500 lines, near-verbatim) |
| Tracking: window titles/browser URLs | AXUIElement (Accessibility permission); ScriptingBridge per-browser for URLs (Automation permission) | same file |
| Tracking: AFK | `CGEventSourceSecondsSinceLastEventType` — no permission needed | `aw-watcher-afk` (10 lines, port to Swift) |
| App blocking | launch/activate notification → `terminate()` (+ `forceTerminate()` fallback) + branded "shield" overlay window explaining why + unlock button (same quota semantics as iOS shield) | pattern from Focus/heyfocus; Fence (GPL — study only) |
| Website blocking (phase 2) | `/etc/hosts` via `SMAppService` privileged helper; NEFilterDataProvider later if needed (entitlement is self-service) | SelfControl (GPL — study only); LuLu (GPL — study only) |
| Hard mode (later, maybe) | EndpointSecurity AUTH_EXEC = true launch denial; needs Apple-approved entitlement | not v1 |

Known honest limits: kill-on-launch has a ~sub-second race (app flashes open then quits — acceptable for a wellbeing tool; competitors share it); hosts-blocking can be bypassed by DoH browsers; a user can quit the menu-bar app (mitigation later: login item + optional root helper à la SelfControl).

## The insight unlock (impossible on iPhone, easy here)

The Mac agent aggregates real per-app minutes (app, title category, productive/distracting classification, AFK-subtracted) and uploads as events. New event types: `app_usage` (bundle id or friendly name, minutes, bucket), `productive_minutes`. ChatGPT finally gets *actual numbers* for Mac time via the existing summary tools (extended to include them). Classification: per-group distracting sets + a default productive set (IDEs, terminals, docs), user/ChatGPT-tunable via a new `set_classification` tool or group mapping.

## Earned time / Pomodoro (the user's ask — yes, trivially programmable)

All primitives already exist (events, grants, pushes, expiry pokes). Add one concept:

- **`earn_rules`** (server table): `{ watch: "productive", threshold_minutes: 60, reward_group: "TikTok", reward_minutes: 15, max_per_day: 3 }`.
- Mac streams `productive_minutes` events → server accrues → when a rule's threshold fills, server auto-creates a grant (`source: 'earned'`) + push: **"You earned 15 min of TikTok 🎉"** — phone unshields via the proven NSE path, auto-re-locks at expiry.
- New MCP tool `set_earn_rule` so it's legislated conversationally: *"give me 15 minutes of TikTok for every focused hour on the Mac."*
- **Pomodoro mode**: menu-bar timer (TomatoBar UX): focus interval = block-all via existing `block_now`s (Mac + phone together!), break = grant. Also a `/pomodoro 25 5` agent skill. Streak detection (your "it detects you've been productive for an hour") is just the accrual rule with AFK-aware counting — no ML needed, and ChatGPT can coach off the same events.

## Phases

- **M0 spike (½ day):** menu-bar skeleton + frontmost/AFK tracking printing a live feed + kill-on-launch for one hardcoded app. Proves all three mechanics.
- **M1 — enforcement parity:** device registration, group mapping UI (installed-apps picker + domains), sync loop, block/schedule/limit/grant enforcement w/ overlay shield + quota unlock, events up. Mac obeys ChatGPT like the phone does.
- **M2 — insight:** usage aggregation + classification + upload; extend `get_today_summary`/`get_summary_range` with real Mac minutes.
- **M3 — earned time:** `earn_rules` + accrual + auto-grants + `set_earn_rule` + Pomodoro menu-bar mode + `/pomodoro` skill.
- **M4 (optional):** hosts-based website blocking via privileged helper; NEFilter content filter; login-item hardening.

## Non-goals (v1)

Mac App Store distribution (kills terminate()); EndpointSecurity hard mode; multi-Mac; keystroke-level tracking (creepy + unnecessary — app/title/AFK suffices).
