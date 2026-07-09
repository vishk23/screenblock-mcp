# ScreenCP Round 2: The Moment at the Wall

Design settled in conversation 2026-07-09. Executed inline (device testing requires the user).

## 1. Unlock modes (per group)
- `groups.mode`: `strict` (no device unlock — chat only) | `quota` (default: N self-serve unlocks/day, fixed minutes, reason required) | `open` (unblock freely from device).
- New columns: `mode` ('quota'), `quota_per_day` (2), `quota_minutes` (10). `grants.source`: 'chat' | 'device_quota'.
- New MCP tool `set_group_mode(group, mode, quota_per_day?, quota_minutes?)` — ChatGPT legislates the rules in advance; device enforces instantly.
- New device endpoint `POST /device/grants {groupId, minutes?, reason}` — validates mode + today's quota server-side; quota mode forces `quota_minutes`; strict always 403.
- iOS: unlock sheet in group detail (reason REQUIRED — canned options + free text; friction is a feature). Applies the grant locally immediately, then syncs. Quota status shown ("1 of 2 left today"). Strict mode shows "ask your coach" instead. Designed so the reason sheet can later be swapped for the API-judge micro-negotiation ("moment at the wall" upgrade).
- Shield secondary button "Request time" → ShieldAction extension posts a local notification → tap opens the app straight into the unlock sheet (iOS forbids the shield opening apps directly).

## 2. Grant punch-through
- `EnforcementEngine`: when shielding group G, subtract the union of app tokens belonging to groups with active grants. A grant on "Instagram" now punches through "Social"'s block for Instagram only.
- Limitation (Apple): category tokens cannot be subtracted — punch-through works only for app-token selections. Server instructions updated so the AI knows the nuance is gone for app-picked groups.
- Grant activation/expiry re-applies ALL groups (monitor extension + NSE + app all route through reconcile).

## 3. Setup nudge + starter groups
- Visible pushes carry `groupId`; create_group's push becomes "Choose apps for 'X' — tap to set up"; tapping deep-links to the group with the picker auto-opened.
- First-run: if no group has a selection, app offers one-tap creation of starter groups (Social, Games, Entertainment) then walks through each picker (individual-app picks recommended in UI copy).

## Deferred (explicitly)
- API-judge at the wall (behind reason-sheet proving insufficient), Phase 2 contexts, Mac companion, distribution/OAuth.
