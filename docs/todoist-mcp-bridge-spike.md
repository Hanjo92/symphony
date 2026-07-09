# Todoist MCP Bridge Spike

## Goal

Evaluate how to integrate Todoist MCP into the Symphony Elixir fork without hardcoding Todoist-only logic into the orchestration layer.

The desired end state is:

- Symphony can expose one or more MCP-backed tools to Codex app-server turns.
- Todoist is the first target, but the design should generalize to other MCP services later.
- The existing `linear_graphql` dynamic tool path remains supported.

## Current State

Symphony currently has a narrow dynamic tool model:

- `SymphonyElixir.Codex.AppServer` intercepts `item/tool/call`.
- It extracts `tool` / `name` and `arguments`.
- It delegates to `tool_executor`.
- The default executor is `SymphonyElixir.Codex.DynamicTool.execute/3`.
- `DynamicTool` currently supports only `linear_graphql`.
- Unsupported tool names are rejected immediately.

Relevant files:

- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `elixir/test/symphony_elixir/app_server_test.exs`
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`

This means Symphony does not yet act as a generic MCP bridge. It exposes an internal tool catalog and executes those tools itself.

## External Todoist MCP Facts

Official references as of July 9, 2026:

- Todoist publishes an official MCP server and tool library:
  - `https://github.com/Doist/todoist-mcp`
- Todoist documents a hosted MCP endpoint:
  - `https://ai.todoist.net/mcp`
- Todoist developer docs describe the MCP as read/create/update access for tasks and projects.
- Todoist help docs for ChatGPT and Claude Code document OAuth-based setup against the hosted MCP.

Operational details that matter for Symphony:

- The hosted endpoint uses Streamable HTTP.
- OAuth is required for end-user authorization.
- Write actions are supported.
- Tool behavior is not purely read-only, so approval and audit behavior matter.
- Todoist recommends batching task creation, with up to 25 tasks per call.
- Rescheduling recurring tasks should use a reschedule-specific tool, not generic date mutation.

## Hosted OAuth Constraints

Todoist's hosted MCP is designed around clients that can complete an interactive OAuth flow.

That matters because Symphony is not currently acting like ChatGPT or Claude Code in this respect:

- it does not open a browser-based account-link flow
- it does not persist OAuth sessions/tokens for MCP servers
- it does not refresh hosted MCP OAuth credentials over time
- it does not yet surface an MCP-specific account-linking UX back through the dashboard

So there are two realistic modes today:

1. Run Symphony with credentials that are already resolved on the host
   - for example a bearer token injected through env/config
2. Build a future hosted-OAuth layer in Symphony
   - persisted token store
   - callback URL / redirect handling
   - refresh-token lifecycle
   - safe operator approval / account-link prompts

This is why the current Todoist provider implementation prefers `auth.env` / `auth.token` style
configuration even though Todoist's hosted docs emphasize OAuth for interactive clients.

## Design Options

### Option A: Todoist-only internal dynamic tools

Add `todoist_*` tools directly to `SymphonyElixir.Codex.DynamicTool`.

Examples:

- `todoist_find_tasks`
- `todoist_add_tasks`
- `todoist_update_task`
- `todoist_list_projects`
- `todoist_reschedule_task`

Pros:

- Smallest change to current architecture.
- Matches the existing `linear_graphql` implementation pattern.
- Straightforward observability and test coverage.
- Easy to gate write actions with current approval flow.

Cons:

- Bakes Todoist semantics directly into Symphony.
- Duplicates functionality already provided by the official MCP.
- Does not help future MCP integrations much.

### Option B: Generic MCP bridge inside Symphony

Add a new layer that allows selected MCP tools to be called through Symphony's dynamic tool path.

High-level behavior:

1. Codex requests a tool by name.
2. Symphony checks whether the tool is:
   - an internal dynamic tool, or
   - an allowed bridged MCP tool.
3. Symphony forwards bridged tool calls to a configured MCP client/server.
4. Symphony normalizes the result back into the current dynamic tool response shape.

Pros:

- General solution for Todoist and future MCP-backed systems.
- Lets Symphony use the official Todoist MCP instead of re-implementing API semantics.
- Keeps Codex-facing behavior consistent across internal tools and bridged tools.

Cons:

- Meaningfully larger architectural change.
- Requires MCP client/session lifecycle management inside Symphony.
- Adds new auth, error, timeout, and observability concerns.

### Recommendation

Use Option B as the architectural target, but implement it in two layers:

1. First introduce a generic bridge abstraction in Symphony.
2. Make Todoist the first concrete MCP-backed integration.

That gives us a real spike path without overcommitting to a full multi-provider system from day one.

## Recommended Architecture

### 1. Split internal tools from bridged tools

Current:

- `DynamicTool.execute(tool, arguments, opts)`

Recommended:

- `DynamicTool.execute(tool, arguments, opts)` becomes a dispatcher
- Internal tools stay in one module
- MCP-backed tools move behind a bridge module

Suggested shape:

- `SymphonyElixir.Codex.DynamicTool`
  - dispatch only
- `SymphonyElixir.Codex.InternalTool`
  - `linear_graphql`
- `SymphonyElixir.Codex.McpBridge`
  - generic MCP-backed tool execution
- `SymphonyElixir.Codex.McpRegistry`
  - config-driven allowlist and tool metadata

### 2. Add config for MCP-backed tools

Symphony needs a workflow-level config block for MCP bridge settings.

Suggested config shape:

```yaml
mcp:
  servers:
    todoist:
      transport: streamable_http
      url: https://ai.todoist.net/mcp
      auth:
        type: oauth
      allowed_tools:
        - todoist_find_tasks
        - todoist_add_tasks
        - todoist_update_task
        - todoist_list_projects
        - todoist_reschedule_task
```

Important note:

Symphony should not blindly expose every upstream MCP tool. It should require an explicit allowlist.

### 3. Normalize tool specs into the existing Codex-facing shape

`DynamicTool.tool_specs/0` currently returns a static list with one spec.

Bridge target:

- internal tool specs
- plus MCP-backed tool specs discovered/configured for enabled servers

This lets Codex see Todoist tools as normal app-server tools, without needing to understand Symphony internals.

### 4. Keep a strict approval model for writes

Todoist supports writes, so Symphony should keep explicit control here.

Recommended policy:

- Read-only tools can follow the normal dynamic tool path.
- Write-capable MCP tools should still surface approval/audit events through Symphony.
- The allowlist should ideally carry mutability metadata:

```yaml
allowed_tools:
  - name: todoist_find_tasks
    mode: read
  - name: todoist_add_tasks
    mode: write
```

This is especially important because Todoist's official docs emphasize that the MCP can create and update tasks/projects.

### 5. Preserve current observability semantics

Today Symphony emits:

- `:tool_call_completed`
- `:tool_call_failed`
- `:unsupported_tool_call`
- MCP-related blocked/input-required events

Bridge target:

- include server name in payload when the tool is MCP-backed
- include bridged tool name
- preserve success/failure semantics
- avoid turning temporary MCP transport failures into silent no-ops

Suggested event metadata additions:

- `server: "todoist"`
- `tool_origin: "mcp_bridge"`
- `tool_mode: "read" | "write"`

## Minimal Spike Implementation Plan

### Phase 1: Architectural slice

Goal: make the current dynamic tool system extensible without changing behavior.

Tasks:

- Extract internal-tool execution from `DynamicTool`.
- Add a registry abstraction for tool metadata.
- Keep `linear_graphql` behavior identical.

Deliverable:

- no new user-facing tools yet
- same test behavior as today

### Phase 2: Stub MCP bridge

Goal: prove the execution path without real Todoist auth.

Tasks:

- Add `McpBridge.execute/3`
- Add config parsing for an MCP server list
- Add one fake/test MCP-backed tool
- Add tests that verify:
  - allowed bridged tool executes
  - unknown tool is rejected
  - MCP transport failure becomes a tool failure payload

Deliverable:

- Symphony can execute a mocked MCP-backed tool through the same app-server tool path

### Phase 3: Todoist integration

Goal: wire Todoist as the first real MCP-backed provider.

Tasks:

- Add Todoist server config
- Map Todoist tool specs into Symphony tool specs
- Start with a curated alias set for common workflows:
  - tasks
  - projects
  - sections
  - comments
  - reminders
  - collaborator lookup
- Keep explicit write-mode metadata on mutating tools
- Defer full hosted-OAuth support to a later phase
- Start with a conservative allowlist:
  - `findTasksByDate` or equivalent read/query tool
  - `addTasks`
  - `updateTask`
  - `listProjects`
  - `rescheduleTask`
- Add transport/auth handling for the hosted endpoint
- Add redaction rules for sensitive auth fields in logs

Deliverable:

- Todoist-backed tools available to Codex turns through Symphony

## Open Questions

1. Where should OAuth state live?
   - Symphony process memory is not enough if the service restarts.
   - We likely need a persisted credential/session model if Symphony itself owns the MCP auth flow.

2. Should Symphony own MCP transport, or shell out to an MCP helper?
   - Owning transport in Elixir gives tighter control.
   - Shelling out may be faster for a spike, but makes observability and lifecycle management worse.

3. How much tool spec mapping is needed?
   - If the Todoist MCP already exposes structured tool schemas, Symphony should reuse them rather than duplicating them.

4. Do we want per-instance MCP config in supervisor?
   - Likely yes, if different Symphony instances should have different MCP servers enabled.

## Suggested First Implementation Target

If we start coding this next, the best first PR is not “Todoist support” directly.

The best first PR is:

- refactor dynamic tool execution into internal-vs-bridge paths
- add MCP bridge config schema
- add a fake/test bridge executor

That gives a stable seam. After that, Todoist becomes “the first adapter” instead of “a pile of one-off conditions inside `DynamicTool`.”

## Files Likely Touched In The First Real PR

- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- `elixir/test/symphony_elixir/app_server_test.exs`
- `elixir/README.md`
- `SPEC.md` if the bridge becomes part of the forked spec

## Bottom Line

Todoist is a good first MCP-backed integration for the fork.

But the clean version is not “add Todoist-specific code beside `linear_graphql`.”

The clean version is:

- build a generic MCP bridge seam first
- then plug Todoist into it as the first real provider
- keep a strict allowlist and explicit write-aware approval posture
