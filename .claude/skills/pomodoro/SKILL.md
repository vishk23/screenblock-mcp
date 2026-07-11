---
name: pomodoro
description: Start a Pomodoro focus sprint — block all distraction groups on the user's iPhone and Mac for N minutes, auto-lifting after. Args like "25" or "45". Use when the user says "pomodoro", "focus sprint", or "lock me in for 25 minutes".
---

# Pomodoro — timed everything-block, auto-lifting

ScreenCP enforces on both the iPhone (push) and the Mac (30s poll). A pomodoro
is just `block_now` with an `until` timestamp on every populated group — the
server pokes devices when it ends, so blocks lift on their own.

1. Parse the sprint length from the args (default 25 minutes). Compute
   `until` = now + N minutes as ISO-8601 UTC.
2. Use the screencp MCP tools directly (they are connected user-wide):
   `list_groups`, then for each group with `hasSelection: true`:
   `block_now(group, until)`.
3. If the user asked for a reward break ("with 5 minutes of TikTok after"),
   do NOT grant it now — tell them the blocks lift automatically at sprint end,
   and offer a recurring earn rule (`set_earn_rule`) if they want rewards tied
   to focused time instead.
4. Report: which groups are locked, on which devices ("iPhone applies in
   seconds; Mac within 30s"), and when they lift. Optionally `set_goal` with
   the sprint's intent.

Fallback if the MCP tools are unavailable in this session: curl the server as
/focus does (same URL + MCP_BEARER_TOKEN from /Users/vk/VKDEV/screencp/server/.env),
passing `until` in block_now's arguments.
