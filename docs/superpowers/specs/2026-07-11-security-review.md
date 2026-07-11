# ScreenCP Security Review — 2026-07-11

Full server-side review (Express/TS/Postgres + client auth). **No Critical findings.**
Perimeter sound for the single-user tool it is: all SQL parameterized (no injection),
all bodies zod-validated, secrets not in git/history/logs, bearer auth (no CSRF surface),
health check clean, MCP session-fixation-safe (fresh server per request).

## Fixed now (committed 404e70b)
- **Timing-safe token comparison** (`src/auth.ts`, both MCP + device auth) — was `===`.
- **Nudge rate limit** — 10/min cap on the push-fan-out spam vector.
- **apnsToken bounds** — length+charset validation (was `min(1)`, allowed oversized junk rows).
- **Batched event insert** — one multi-row insert vs 500 sequential round-trips against a `max:5` pool.

## Accepted / documented (NOT fixed — gated on distribution)
These are safe *only* because this is a single-user, single-owner tool. They are the
**hard blockers for the Phase-4 "ship to others" path** and must be built then:

- **I-1 — Zero per-user isolation (THE distribution blocker).** Every row is `user_id='default'`;
  no query filters by user. One shared `DEVICE_BEARER_TOKEN` is baked into every app binary =
  a master key. A second device with the token would read/control ALL data and cross-contaminate
  push fan-out. Fix for shipping: per-device credential minted at registration bound to a real
  `user_id`, thread `user_id` through every `repo.ts` query, per-user MCP identity.
- **I-3 — Client-trusted earn/quota economy.** `/device/events` trusts `meta.seconds`, so a crafted
  batch forges "focused minutes" → earned grants. Client `startsAt` on `/grants` can evade daily
  quota. Impact today = the user cheating their own commitment device (the thing the product resists);
  becomes a real integrity hole once multi-user ships. Fix: sanity-cap seconds/day, tally quota by
  server creation time not client `startsAt`.

## Minor (optional, low value at current scale)
- M-3 quota check-then-insert TOCTOU (needs concurrent callers; one user won't hit it).
- MCP secret-in-URL logs on Fly's router — prefer header; rotate if suspected. Path form required
  because ChatGPT connectors can't send custom headers. Consider a separate rotatable path token.
- DNS-rebinding protection off on the MCP transport (bearer is the real gate for a public deploy).

**Priority for shipping:** I-1 is the gate. Everything else is either done or only matters alongside I-1.
