---
name: unfocus
description: Work session over — lift the ScreenCP focus blocks on the user's iPhone. Use when the user ends a work session, says "done working", "unfocus", or "unlock my phone".
---

# Unfocus — release the phone

Counterpart to /focus. Read the secret (never print it), list groups, and
`unblock` each currently-blocked group:

```bash
source <(grep MCP_BEARER_TOKEN /Users/vk/VKDEV/screencp/server/.env | sed 's/^/export /')
curl -s -X POST "https://screencp.fly.dev/mcp/${MCP_BEARER_TOKEN}" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_status","arguments":{}}}'
```

For each group with an active `block` policy:

```bash
curl -s -X POST "https://screencp.fly.dev/mcp/${MCP_BEARER_TOKEN}" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"unblock","arguments":{"group":"<NAME>"}}}'
```

Report what was unblocked and what still applies (schedules/limits stay active).
