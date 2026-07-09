# ScreenCP iOS Enforcer Implementation Plan (Plan 2 of 3)

**Goal:** Native iOS app holding the Family Controls entitlement that enforces policy from the live backend (https://screencp.fly.dev) and reports events up.

**Approach:** Milestone-based, not task-TDD — Screen Time APIs are not unit-testable and every milestone ends with an on-device manual verification the user performs. Project generated with XcodeGen (`ios/project.yml`), built/installed via `xcodebuild` + `devicectl` from the CLI. Executed inline (device interaction requires the main session), spikes first — they gate the design.

**Facts:** Device: Vishnu's iPhone 16 Pro (CoreDevice `BFF43CC1-15BF-5069-A9F2-92CECB0E3C5F`). Team: `T594B6TR5Y` (paid). Bundle id root: `com.vishnukchitti.screencp`. iOS floor: 16.0. Backend device API: `https://screencp.fly.dev/device/*` with `Authorization: Bearer <DEVICE_BEARER_TOKEN>` (in `server/.env`).

## Milestones

### M0 — Spike 1: entitlement → picker → shield loop (GATE)
Minimal app: request `.individual` FamilyControls authorization, show `FamilyActivityPicker`, toggle a shield on the selection via `ManagedSettingsStore`. **Pass:** a picked app shows Apple's shield when launched; toggling off restores it. Proves: entitlement works on this account/device, the core enforcement primitive works. If this fails, everything stops.

### M1 — Spike 2: no-tap remote apply (Notification Service Extension)
Add an NSE target; send a `mutable-content` push (via `fly` server or direct APNs script) while the app is backgrounded AND force-quit; NSE attempts to write the shield. **Answers:** can a visible push apply enforcement with zero taps? Result recorded in the plan; either outcome is fine (fallback = tap-to-apply notification + reconcile-on-open).
Requires: APNs key (.p8) created in the developer portal (user, ~2 min), `APNS_*` secrets set on Fly, device registration wired (M2 does it properly; spike uses a hardcoded token log).

### M2 — App skeleton + backend sync
Real app structure: groups screen (create local mapping name→`FamilyActivitySelection` via picker, persisted in App Group storage), sync engine (pull `/device/sync?since=`, ack `/device/ack`, upload `/device/events`, register APNs token `/device/register`), settings screen (paste DEVICE_BEARER_TOKEN once — personal-use auth). Reconcile on foreground. `has_selection` reported via `/device/groups/:id/selection`.

### M3 — Enforcement engine
Translate synced policy → OS primitives: `block` → immediate shield; `schedule` → `DeviceActivitySchedule` + DeviceActivityMonitor extension applying/clearing shields at boundaries; `limit` → `DeviceActivityEvent` thresholds (50/80/100%) with shield at 100%; `grant` → lift shield + one-shot re-block schedule + reconcile backstop. Precedence: grant > block > schedule/limit. Events logged to App Group, uploaded by main app.

### M4 — Push + polish
Silent-push triggered sync; visible tap-to-apply fallback path; Time-Sensitive handling; on-device `DeviceActivityReport` usage view (display-only). Golden-path E2E from ChatGPT: create schedule → shield on phone; grant 15 min → unshield → auto re-block; `get_status` shows `applied`; summary shows real events.

## Verification
Each milestone ends with a scripted manual checklist run by the user on the device. M4 ends with the full ChatGPT golden path (Plan 1 Task 9 list, now with `device_connected: true`).

## Reference
`CoffeeNaeriRei/ScreenTime_Barebones` (target structure), `christianp-622/ScreenBreak` (shields+timers), Apple WWDC21 10123 / WWDC22 110336. Backend contract: `server/src/deviceApi.ts`, `server/src/types.ts`.
