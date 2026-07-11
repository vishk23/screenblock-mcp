---
name: focus
description: Work session starting — block all distraction groups on the user's iPhone via ScreenCP. Use when the user starts a work/coding session, says "focus mode", "starting work", "lock me in", or asks an agent to eliminate distractions.
---

# Focus — lock the phone's distractions

ScreenCP is the user's chat-controlled screen-time enforcer (MCP server + iOS app).
You are an agent with the keys. Blocking every distraction group on the user's
iPhone takes two calls.

1. Read the MCP secret (never print it):

```bash
source <(grep MCP_BEARER_TOKEN /Users/vk/VKDEV/screencp/server/.env | sed 's/^/export /')
```

2. List groups, then block each one that has apps selected (`hasSelection: true`):

```bash
curl -s -X POST "https://screencp.fly.dev/mcp/${MCP_BEARER_TOKEN}" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_groups","arguments":{}}}'
```

For each populated group:

```bash
curl -s -X POST "https://screencp.fly.dev/mcp/${MCP_BEARER_TOKEN}" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"block_now","arguments":{"group":"<NAME>"}}}'
```

3. Optionally set the day's goal so the coach has context:

```bash
... {"name":"set_goal","arguments":{"text":"Deep work session — phone locked by my coding agent"}}
```

4. Tell the user which groups are now blocked on their phone (delivery usually
   applies within ~10s via push). The phone's shields will say
   "Blocked by ScreenCP". Unblocking happens via /unfocus or by asking ChatGPT.
