# Claude Code Feature Integration into Shipwright

**Date:** 2026-03-07
**Status:** Approved
**Goal:** Integrate all new Claude Code features into Shipwright infrastructure and documentation

## Problem

Shipwright documents many Claude Code features in its global CLAUDE.md but doesn't actually leverage them in its pipeline, daemon, or agent infrastructure. Key gaps include effort-level routing, fallback models, structured output schemas, HTTP/prompt/agent hooks, lifecycle hooks, and MCP configuration.

## Design

### 1. CLI Flags Integration

#### `--effort-level` (low/medium/high)

Add `--effort` flag to `sw-loop.sh`, `sw-pipeline.sh`, and `sw-fix.sh`.

Default routing by stage:

- `low`: intake, formatting, audit/haiku agents
- `medium`: standard builds, test execution
- `high`: design, review, compound_quality

Extend `select_adaptive_model()` to return effort level alongside model. The intelligence engine and self-optimizer can learn optimal effort levels per stage.

Pass through to Claude CLI as `--effort-level` on all `claude -p` invocations.

#### `--fallback-model`

Add `--fallback-model` flag to `sw-loop.sh` and `sw-pipeline.sh`, default `sonnet`.

Every `claude -p` invocation gets `--fallback-model` so agents auto-recover from rate limits without pipeline failure.

New `fallback_model` field in `daemon-config.json`, injected into spawned pipelines.

#### `--json-schema` for Structured Output

Create `schemas/` directory with reusable JSON Schema files:

| Schema                  | Purpose                        |
| ----------------------- | ------------------------------ |
| `iteration-result.json` | Loop iteration progress report |
| `audit-result.json`     | Audit agent pass/fail/findings |
| `quality-gate.json`     | Quality gate evaluation result |
| `stage-handoff.json`    | Pipeline stage context handoff |

Use `--json-schema <file>` on Claude CLI invocations where structured output replaces free-text parsing (audit agents, quality gates, loop progress detection).

### 2. Hook System Expansion

#### HTTP Hooks

Register HTTP hooks in `settings.json` that POST pipeline events to:

- Dashboard server (`http://localhost:PORT/api/events`) when running
- Configurable webhook URLs from `daemon-config.json` -> `webhooks[]`

Format: Same JSON payload as `events.jsonl`, sent as POST body.

Support `headers` with env var interpolation:

```json
{
  "type": "http",
  "url": "https://hooks.slack.com/services/...",
  "headers": {
    "Authorization": "Bearer $SLACK_TOKEN"
  }
}
```

#### Prompt Hooks (LLM-evaluated gates)

Add prompt hooks for quality-sensitive events:

- `PostToolUse` on `Bash`: "Did the tests pass based on this output?"
- PR stage: "Is this PR description complete and accurate?"
- Uses Haiku by default (cheap, fast)

#### Agent Hooks (multi-turn verification)

For `compound_quality` stage: agent hook with tool access verifies codebase state matches claimed changes. Configure with `maxTurns: 10`, `timeout: 60`.

For deploy stage: agent hook runs smoke tests and verifies deployment.

#### Lifecycle Hooks

| Hook                                        | Use                                                                          |
| ------------------------------------------- | ---------------------------------------------------------------------------- |
| `WorktreeCreate`                            | Auto-copy `.claude/settings.json` and `daemon-config.json` into new worktree |
| `WorktreeRemove`                            | Clean up heartbeat files and stale state for removed worktree agents         |
| `InstructionsLoaded` (matcher: `"compact"`) | Reload project rules after auto-compaction                                   |
| `ConfigChange`                              | Daemon reacts to config changes without restart                              |

#### PreToolUse Input Modification

- Auto-inject `set -euo pipefail` reminder into Bash tool commands targeting `.sh` files (existing behavior, now also modifies input)
- Block `git push --no-verify` via exit code 2

### 3. Environment & MCP Configuration

#### New env vars in settings.json

```json
{
  "env": {
    "ENABLE_TOOL_SEARCH": "auto",
    "MAX_MCP_OUTPUT_TOKENS": "50000",
    "CLAUDE_CODE_EFFORT_LEVEL": "medium"
  }
}
```

`sw-init.sh` and `sw-prep.sh` set these during project setup. Pipeline stages override effort level per-stage via env.

#### Managed MCP (managed-mcp.json)

Generate template during `shipwright prep`:

- Allow project-relevant MCP servers
- Deny potentially dangerous servers in pipeline agents
- Configure `allowedMcpServers` / `deniedMcpServers` patterns
- Useful for fleet/daemon mode where agents shouldn't have unrestricted MCP access

#### File Suggestion (fileSuggestion)

Create `scripts/shipwright-file-suggest.sh` for custom `@` autocomplete:

- `pipeline-state.md`, `daemon-config.json`, `fleet-config.json`
- Agent definitions (`.claude/agents/*.md`)
- Loop state, schemas, pipeline artifacts

Register via `"fileSuggestion": "./scripts/shipwright-file-suggest.sh"` in settings.

### 4. Documentation Updates

- `.claude/CLAUDE.md`: New sections for CLI flags, expanded hooks, MCP config, env vars
- `sw-init.sh`: Setup output mentions new features
- `sw-doctor.sh`: Validate new settings (effort level, fallback model, webhook URLs)
- `schemas/README.md`: Schema documentation

## Implementation Order

1. **PR 1: CLI Flags** — `--effort`, `--fallback-model`, `--json-schema` + schemas directory
2. **PR 2: Hook System** — HTTP hooks, prompt/agent hooks, lifecycle hooks, input modification
3. **PR 3: Environment & MCP** — env vars, managed-mcp.json, fileSuggestion
4. **PR 4: Documentation** — CLAUDE.md updates, doctor checks, init output

## Files Changed (by PR)

### PR 1: CLI Flags

- `scripts/sw-loop.sh` — flag parsing, pass-through
- `scripts/sw-pipeline.sh` — per-stage effort routing
- `scripts/sw-fix.sh` — flag pass-through
- `scripts/lib/pipeline-stages-*.sh` — effort level in stage dispatch
- `scripts/lib/loop-iteration.sh` — structured output for iteration results
- New: `schemas/iteration-result.json`
- New: `schemas/audit-result.json`
- New: `schemas/quality-gate.json`
- New: `schemas/stage-handoff.json`
- `scripts/sw-loop-test.sh` — test new flags
- `scripts/sw-pipeline-test.sh` — test effort routing

### PR 2: Hook System

- `.claude/settings.json` — register new hooks
- `scripts/sw-init.sh` — generate hook config
- `scripts/sw-prep.sh` — generate hook config
- New: `.claude/hooks/worktree-create.sh`
- New: `.claude/hooks/worktree-remove.sh`
- New: `.claude/hooks/instructions-reloaded.sh`
- New: `.claude/hooks/config-change.sh`
- `dashboard/server.ts` — accept HTTP hook POSTs on `/api/events`

### PR 3: Environment & MCP

- `.claude/settings.json` — new env vars
- `scripts/sw-init.sh` — set env vars during setup
- `scripts/sw-prep.sh` — generate managed-mcp.json
- `scripts/sw-doctor.sh` — validate new settings
- New: `scripts/shipwright-file-suggest.sh`
- New: `.claude/managed-mcp.json` (template)

### PR 4: Documentation

- `.claude/CLAUDE.md` — all new sections
- `README.md` — feature mentions
