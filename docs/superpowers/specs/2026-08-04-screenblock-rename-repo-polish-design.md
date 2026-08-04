# ScreenBlock MCP — rename + repo polish

**Date:** 2026-08-04
**Status:** Approved by VK (design conversation, this date)

## Goal

Rename the product from **ScreenCP** to **ScreenBlock MCP** and make the repo
public-ready: flagship README, clean root, GitHub publish with license, topics,
and CI. Motivations (all three): open-sourcing/distribution, portfolio quality,
and personal taste. Naming constraint from VK: literal + search-optimized —
people searching "screen time mcp" / "screen block mcp" should understand and
find it instantly.

## Name

- **Repo / GitHub:** `screenblock-mcp` (verified free on GitHub 2026-08-04;
  nearby "screenblock" repos are unrelated zero-star projects; the
  `screentime-mcp` name is taken by AgentDank's read-only query server — our
  differentiator is *control/enforcement*, which the README leads with).
- **Product / MCP server advertised name:** ScreenBlock MCP / `screenblock`.
- **App display name (iOS + Mac):** ScreenBlock.
- **GitHub description:** "Block and unblock apps on iPhone/Mac from Claude,
  ChatGPT, or any MCP client — Screen Time enforcement, temp grants, earned
  time."

## Rename scope — visible surfaces ONLY

### Changes

| Surface | Change |
|---|---|
| `ios/ScreenCP/Shared/Brand.swift` | `name = "ScreenBlock"` |
| `mac/ScreenCPMac/Sources/Brand.swift` | same |
| `server/package.json` | name → `screenblock-mcp-server` |
| MCP server advertised name (`server/src/mcp.ts`) | → `screenblock` |
| Server instructions text read by AI clients | ScreenCP → ScreenBlock |
| Server log strings (`server/src/index.ts`, push/deviceApi copy) | ScreenCP → ScreenBlock where user/AI-visible |
| `CLAUDE.md` | rename + new repo name |
| Claude auto-memory (`screencp-infra.md` etc.) | update product name, note rename |
| Local directory | `~/VKDEV/screencp` → `~/VKDEV/screenblock-mcp` — LAST step (breaks running-session paths) |

### Explicitly NOT renamed (plumbing; breaking-change traps)

- Bundle IDs (`…screencp…`) — changing them resets Screen Time authorization,
  provisioning, and every extension identifier (documented traps).
- Xcode target names / directory names (`ios/ScreenCP*`, `mac/ScreenCPMac`).
- Fly app `screencp`, URL `https://screencp.fly.dev`, volume `screencp_data` —
  Fly cannot rename apps in place; migration would break the phone build, Mac
  app, and connector configs, and risk the SQLite volume. Treated as plumbing.
- The `mcp__screencp__` connector key in VK's client configs — client-side
  config, not repo; VK can re-register the connector as "screenblock" anytime.

## README (new, root `README.md`)

Section order:

1. **Hero** — name, one-line pitch, badges (CI, MIT, platform, MCP).
2. **Chat-transcript demo** — the "give me 10 min of Snapchat" grant flow as a
   rendered markdown conversation. No screenshots required; this is the money
   shot.
3. **How it works** — mermaid diagram: AI client → MCP server (Fly, SQLite) →
   APNs push → iOS shield/DeviceActivity extensions; Mac menu-bar userspace
   enforcement as a second device.
4. **Tool reference** — table of the 13 MCP tools with one-line descriptions.
5. **Self-host quickstart** — fly deploy + secrets, xcodegen iOS build,
   Mac build, connecting Claude/ChatGPT.
6. **Screenshots** — iOS Simulator captures of Today dashboard + onboarding;
   placeholder slot for real-device shield shots (needs VK's phone).
7. **Security model** — bearer tokens, secret-in-URL-path MCP auth, what the
   server can and cannot see (Apple privacy: group contents are opaque).
8. **Platform notes** — honest finding that Apple's Screen Time API is
   unavailable on macOS, hence userspace enforcement like all competitors.
9. License footer.

## Root cleanup

- `git rm` `node_modules/.package-lock.json`,
  `node_modules/.vite/...results.json`, root `package-lock.json`; add
  `node_modules/` to `.gitignore`.
- `scratch/` already gitignored — leave on disk.
- `docs/superpowers/` stays as-is (spec history is portfolio-positive).

## Publish + extras

1. Full-history secret sweep before first push (spot-check already done:
   no `.env` ever tracked; only `.env.example`).
2. `LICENSE` — MIT.
3. `CONTRIBUTING.md` — one paragraph (issues/PRs welcome, run
   `npx vitest` in server/).
4. Create **public** GitHub repo `vishk23/screenblock-mcp`, push `main`.
5. Repo description (above) + topics: `mcp`, `mcp-server`, `screen-time`,
   `screentime`, `ios`, `digital-wellbeing`, `claude`, `chatgpt`,
   `app-blocker`.
6. GitHub Actions: single workflow running `npx vitest run` in `server/` on
   push/PR → CI badge in README.

## Error handling / risks

- **Secret leakage:** the sweep gates the push; if anything is found, stop and
  surface to VK before publishing.
- **Rename regressions:** iOS/Mac apps rebuild + reinstall needed for the new
  display name to appear; server redeploy (`fly deploy`) for the new advertised
  name. Neither is urgent — old builds keep working since all IDs/URLs are
  unchanged.
- **Grep check:** after rename, `grep -ri screencp` should hit only plumbing
  (bundle IDs, target/dir names, Fly config, historical specs/docs).

## Testing

- Server: `npx vitest run` green after rename (69+ tests).
- iOS: `xcodegen generate && xcodebuild … build` compiles.
- Mac: build compiles.
- README mermaid renders on GitHub; links resolve; CI badge goes green after
  first Actions run.
