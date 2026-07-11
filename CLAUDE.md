# ScreenCP

Chat-controlled screen-time enforcement: MCP server (server/, Fly.io + Supabase) + iOS app (ios/, XcodeGen). The user's phone blocks distracting apps; ChatGPT/Claude/Claude Code act as the executive-function coach through the same 13 MCP tools.

## You have the keys

The `screencp` MCP server is connected user-wide — you have tools like `get_status`, `block_now`, `grant_temp_access`, `set_group_mode`. This is the user's own self-imposed wellbeing system; acting on their clear requests is the product working. Groups are the unit of control; per-app groups (TikTok, Instagram…) enable surgical grants. Read the server instructions for the full model.

- `/focus` — user starts working: block every populated group on their phone.
- `/unfocus` — session over: lift the focus blocks.
- Mid-session asks like "give me 10 min of Snapchat" → `grant_temp_access` directly.

## Building

- Server: `cd server && npx vitest run` to test, `fly deploy --yes` to ship.
- iOS: `cd ios && xcodegen generate && xcodebuild -project ScreenCP.xcodeproj -scheme ScreenCP -destination 'platform=iOS,id=BFF43CC1-15BF-5069-A9F2-92CECB0E3C5F' -allowProvisioningUpdates build`, install via `xcrun devicectl device install app --device BFF43CC1-... <path to .app>`. Secrets: `server/.env` (gitignored) → `ios/ScreenCP/Sources/Secrets.swift` (generated, gitignored).
- Hard-won Screen Time gotchas live in the session memory and `.superpowers/sdd/progress.md` — read before touching ios/ extensions (extension point identifiers, UserDefaults flushing, DeviceActivity 15-min minimum are all traps that cost real debugging time).
