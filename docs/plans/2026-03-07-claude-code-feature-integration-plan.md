# Claude Code Feature Integration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Integrate all new Claude Code features (effort levels, fallback models, structured output, HTTP/prompt/agent hooks, lifecycle hooks, MCP config) into Shipwright's pipeline, daemon, and agent infrastructure.

**Architecture:** Four incremental PRs, each adding one feature category across all relevant scripts. Changes follow the existing pattern: flag parsing in CLI scripts, pass-through to `claude` CLI invocations, config generation in init/prep, validation in doctor.

**Tech Stack:** Bash 3.2, jq, JSON Schema, Claude CLI flags

---

## PR 1: CLI Flags Integration

### Task 1: Add `--effort` and `--fallback-model` defaults to `sw-loop.sh`

**Files:**

- Modify: `scripts/sw-loop.sh:67-87` (defaults section)
- Modify: `scripts/sw-loop.sh:120-159` (help text)
- Modify: `scripts/sw-loop.sh:177-279` (argument parsing)

**Step 1: Add default variables after line 87**

```bash
# After CONTEXT_BUDGET_CHARS line (~117)
EFFORT_LEVEL="${SW_EFFORT_LEVEL:-}"
FALLBACK_MODEL="${SW_FALLBACK_MODEL:-sonnet}"
```

**Step 2: Add help text entries after the `--model` line (134)**

Add these lines in the OPTIONS section of `show_help()`:

```bash
echo -e "  ${CYAN}--effort${RESET} low|medium|high   Effort level for Claude reasoning (default: auto per stage)"
echo -e "  ${CYAN}--fallback-model${RESET} MODEL      Fallback model on rate limits (default: sonnet)"
```

**Step 3: Add argument parsing cases after `--model=*)` (line 207)**

```bash
        --effort)
            EFFORT_LEVEL="${2:-}"
            [[ -z "$EFFORT_LEVEL" ]] && { error "Missing value for --effort"; exit 1; }
            shift 2
            ;;
        --effort=*) EFFORT_LEVEL="${1#--effort=}"; shift ;;
        --fallback-model)
            FALLBACK_MODEL="${2:-}"
            [[ -z "$FALLBACK_MODEL" ]] && { error "Missing value for --fallback-model"; exit 1; }
            shift 2
            ;;
        --fallback-model=*) FALLBACK_MODEL="${1#--fallback-model=}"; shift ;;
```

**Step 4: Add validation after existing validation block (~line 325-335)**

```bash
# Validate effort level
if [[ -n "$EFFORT_LEVEL" ]] && [[ "$EFFORT_LEVEL" != "low" && "$EFFORT_LEVEL" != "medium" && "$EFFORT_LEVEL" != "high" ]]; then
    error "--effort must be low, medium, or high (got: $EFFORT_LEVEL)"
    exit 1
fi
```

**Step 5: Commit**

```bash
git add scripts/sw-loop.sh
git commit -m "feat(loop): add --effort and --fallback-model flag parsing"
```

---

### Task 2: Wire flags into `build_claude_flags()` in `lib/loop-iteration.sh`

**Files:**

- Modify: `scripts/lib/loop-iteration.sh:443-457` (build_claude_flags function)

**Step 1: Write failing test in `sw-loop-test.sh`**

Add after the existing `build_claude_flags` test (~line 218):

```bash
echo -e "${DIM}  effort level flag${RESET}"
if grep -q 'effort-level' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "build_claude_flags supports --effort-level"
else
    assert_fail "build_claude_flags supports --effort-level"
fi

echo -e "${DIM}  fallback model flag${RESET}"
if grep -q 'fallback-model' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "build_claude_flags supports --fallback-model"
else
    assert_fail "build_claude_flags supports --fallback-model"
fi
```

**Step 2: Run test to verify it fails**

Run: `bash scripts/sw-loop-test.sh 2>&1 | grep -A1 'effort-level\|fallback-model'`
Expected: FAIL lines

**Step 3: Add flags to `build_claude_flags()` in `lib/loop-iteration.sh:443-457`**

Replace the function body:

```bash
build_claude_flags() {
    local flags=()
    flags+=("--model" "$MODEL")
    flags+=("--output-format" "json")

    if $SKIP_PERMISSIONS; then
        flags+=("--dangerously-skip-permissions")
    fi

    if [[ -n "$MAX_TURNS" ]]; then
        flags+=("--max-turns" "$MAX_TURNS")
    fi

    if [[ -n "${EFFORT_LEVEL:-}" ]]; then
        flags+=("--effort-level" "$EFFORT_LEVEL")
    fi

    if [[ -n "${FALLBACK_MODEL:-}" ]]; then
        flags+=("--fallback-model" "$FALLBACK_MODEL")
    fi

    echo "${flags[*]}"
}
```

**Step 4: Run test to verify it passes**

Run: `bash scripts/sw-loop-test.sh 2>&1 | grep -A1 'effort-level\|fallback-model'`
Expected: PASS lines

**Step 5: Commit**

```bash
git add scripts/lib/loop-iteration.sh scripts/sw-loop-test.sh
git commit -m "feat(loop): wire --effort-level and --fallback-model into claude flags"
```

---

### Task 3: Add effort routing to pipeline stages

**Files:**

- Modify: `scripts/lib/pipeline-stages-intake.sh:374-385` (plan stage claude invocation)
- Modify: `scripts/lib/pipeline-stages-intake.sh:839-845` (design stage claude invocation)
- Modify: `scripts/lib/pipeline-stages-build.sh:361-374` (build stage loop args)
- Modify: `scripts/lib/pipeline-stages-review.sh` (review stage claude invocation)

**Step 1: Create helper function in `scripts/lib/pipeline-stages-build.sh`**

Add near the top (after sourcing, before first function):

```bash
# Map pipeline stage to effort level (when no explicit --effort override)
_stage_effort_level() {
    local stage="$1"
    case "$stage" in
        intake)              echo "low" ;;
        plan|design)         echo "high" ;;
        build)               echo "medium" ;;
        test)                echo "medium" ;;
        review|compound_quality) echo "high" ;;
        pr|merge)            echo "low" ;;
        deploy|validate|monitor) echo "medium" ;;
        *)                   echo "medium" ;;
    esac
}

# Build common claude flags for pipeline stages
_pipeline_claude_flags() {
    local stage="$1"
    local model="$2"
    local flags=("--model" "$model")

    # Effort level: explicit override > per-stage default
    local effort="${EFFORT_LEVEL_OVERRIDE:-$(_stage_effort_level "$stage")}"
    flags+=("--effort-level" "$effort")

    # Fallback model
    if [[ -n "${FALLBACK_MODEL_OVERRIDE:-}" ]]; then
        flags+=("--fallback-model" "$FALLBACK_MODEL_OVERRIDE")
    elif [[ -n "${PIPELINE_FALLBACK_MODEL:-}" ]]; then
        flags+=("--fallback-model" "$PIPELINE_FALLBACK_MODEL")
    else
        flags+=("--fallback-model" "sonnet")
    fi

    echo "${flags[*]}"
}
```

**Step 2: Update plan stage in `pipeline-stages-intake.sh:384`**

Change:

```bash
claude --print --model "$plan_model" --max-turns 25 --dangerously-skip-permissions \
```

To:

```bash
local _plan_flags
_plan_flags="$(_pipeline_claude_flags "plan" "$plan_model")"
# shellcheck disable=SC2086
claude --print $_plan_flags --max-turns 25 --dangerously-skip-permissions \
```

**Step 3: Update design stage in `pipeline-stages-intake.sh:843`**

Same pattern — replace hardcoded `--model "$design_model"` with `$(_pipeline_claude_flags "design" "$design_model")`.

**Step 4: Pass `--effort` and `--fallback-model` through to loop in build stage**

In `pipeline-stages-build.sh`, after the `--max-restarts` line (~349), add:

```bash
    # Effort level and fallback model
    [[ -n "${EFFORT_LEVEL_OVERRIDE:-}" ]] && loop_args+=(--effort "$EFFORT_LEVEL_OVERRIDE")
    [[ -n "${FALLBACK_MODEL_OVERRIDE:-}" ]] && loop_args+=(--fallback-model "$FALLBACK_MODEL_OVERRIDE")
    [[ -z "${FALLBACK_MODEL_OVERRIDE:-}" && -n "${PIPELINE_FALLBACK_MODEL:-}" ]] && loop_args+=(--fallback-model "$PIPELINE_FALLBACK_MODEL")
```

**Step 5: Add `--effort` and `--fallback-model` parsing to `sw-pipeline.sh`**

Find the argument parsing section and add cases (same pattern as sw-loop.sh).

**Step 6: Commit**

```bash
git add scripts/lib/pipeline-stages-intake.sh scripts/lib/pipeline-stages-build.sh scripts/lib/pipeline-stages-review.sh scripts/sw-pipeline.sh
git commit -m "feat(pipeline): per-stage effort routing and fallback model support"
```

---

### Task 4: Add `--effort` and `--fallback-model` to `sw-fix.sh`

**Files:**

- Modify: `scripts/sw-fix.sh:53-74` (help text)
- Modify: `scripts/sw-fix.sh:79-109` (argument parsing)
- Modify: `scripts/sw-fix.sh:330-345` (command construction)

**Step 1: Add help text**

```bash
echo -e "  ${DIM}--effort level${RESET}              Effort level: low, medium, high"
echo -e "  ${DIM}--fallback-model model${RESET}      Fallback model on rate limits (default: sonnet)"
```

**Step 2: Add argument parsing**

```bash
            --effort)
                EFFORT_LEVEL="$2"
                shift 2
                ;;
            --fallback-model)
                FALLBACK_MODEL="$2"
                shift 2
                ;;
```

**Step 3: Add to command construction (~line 340)**

```bash
            [[ -n "${EFFORT_LEVEL:-}" ]] && cmd+=(--effort "$EFFORT_LEVEL")
            [[ -n "${FALLBACK_MODEL:-}" ]] && cmd+=(--fallback-model "$FALLBACK_MODEL")
```

**Step 4: Commit**

```bash
git add scripts/sw-fix.sh
git commit -m "feat(fix): pass --effort and --fallback-model to pipelines"
```

---

### Task 5: Add `fallback_model` and `effort_level` to daemon config

**Files:**

- Modify: `scripts/sw-daemon.sh` (config reading, spawn pipeline args)

**Step 1: Find where daemon reads config and spawns pipelines**

Search for where `daemon-config.json` fields are read and pipeline is spawned.

**Step 2: Add config reading**

```bash
PIPELINE_FALLBACK_MODEL=$(_config_get "fallback_model" "sonnet" 2>/dev/null || echo "sonnet")
EFFORT_LEVEL_OVERRIDE=$(_config_get "effort_level" "" 2>/dev/null || echo "")
```

**Step 3: Pass to spawned pipelines via env or args**

```bash
export PIPELINE_FALLBACK_MODEL
[[ -n "$EFFORT_LEVEL_OVERRIDE" ]] && export EFFORT_LEVEL_OVERRIDE
```

**Step 4: Commit**

```bash
git add scripts/sw-daemon.sh
git commit -m "feat(daemon): read fallback_model and effort_level from config"
```

---

### Task 6: Create JSON schemas for structured output

**Files:**

- Create: `schemas/iteration-result.json`
- Create: `schemas/audit-result.json`
- Create: `schemas/quality-gate.json`
- Create: `schemas/stage-handoff.json`

**Step 1: Create `schemas/iteration-result.json`**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Loop Iteration Result",
  "type": "object",
  "required": ["iteration", "status", "summary"],
  "properties": {
    "iteration": { "type": "integer" },
    "status": { "enum": ["in_progress", "complete", "blocked", "failed"] },
    "summary": { "type": "string", "maxLength": 500 },
    "files_changed": { "type": "array", "items": { "type": "string" } },
    "tests_passing": { "type": "boolean" },
    "remaining_work": { "type": "array", "items": { "type": "string" } },
    "blockers": { "type": "array", "items": { "type": "string" } }
  }
}
```

**Step 2: Create `schemas/audit-result.json`**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Audit Result",
  "type": "object",
  "required": ["passed", "findings"],
  "properties": {
    "passed": { "type": "boolean" },
    "score": { "type": "integer", "minimum": 0, "maximum": 100 },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["severity", "message"],
        "properties": {
          "severity": { "enum": ["critical", "warning", "info"] },
          "message": { "type": "string" },
          "file": { "type": "string" },
          "line": { "type": "integer" }
        }
      }
    }
  }
}
```

**Step 3: Create `schemas/quality-gate.json`**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Quality Gate Result",
  "type": "object",
  "required": ["gate", "passed", "reason"],
  "properties": {
    "gate": { "type": "string" },
    "passed": { "type": "boolean" },
    "reason": { "type": "string" },
    "metrics": {
      "type": "object",
      "properties": {
        "coverage": { "type": "number" },
        "lint_errors": { "type": "integer" },
        "test_failures": { "type": "integer" }
      }
    }
  }
}
```

**Step 4: Create `schemas/stage-handoff.json`**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Pipeline Stage Handoff",
  "type": "object",
  "required": ["from_stage", "to_stage", "summary"],
  "properties": {
    "from_stage": { "type": "string" },
    "to_stage": { "type": "string" },
    "summary": { "type": "string", "maxLength": 1000 },
    "artifacts": { "type": "array", "items": { "type": "string" } },
    "decisions": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "decision": { "type": "string" },
          "rationale": { "type": "string" }
        }
      }
    },
    "risks": { "type": "array", "items": { "type": "string" } }
  }
}
```

**Step 5: Commit**

```bash
git add schemas/
git commit -m "feat: add JSON schemas for structured agent output"
```

---

### Task 7: Wire `--json-schema` into audit agent invocations

**Files:**

- Modify: `scripts/sw-loop.sh:1140-1170` (run_audit_agent function)
- Modify: `scripts/sw-loop.sh:1270-1300` (DoD evaluation)

**Step 1: Find the audit agent claude invocation (~line 1155-1161)**

Read the exact lines around the `claude -p "$audit_prompt"` call.

**Step 2: Add `--json-schema` flag**

```bash
    # Use structured output for machine-parseable audit results
    local schema_file="${SCRIPT_DIR}/../schemas/audit-result.json"
    if [[ -f "$schema_file" ]]; then
        audit_flags+=("--json-schema" "$schema_file")
    fi
```

**Step 3: Update the result parsing to handle structured JSON**

After the `claude -p` call, parse the structured JSON instead of free-text:

```bash
    # Parse structured audit result
    if [[ -f "$schema_file" ]] && command -v jq >/dev/null 2>&1; then
        local audit_passed
        audit_passed=$(jq -r '.passed // false' "$audit_log" 2>/dev/null || echo "false")
        local audit_score
        audit_score=$(jq -r '.score // 0' "$audit_log" 2>/dev/null || echo "0")
        if [[ "$audit_passed" == "true" ]]; then
            AUDIT_RESULT="pass"
        else
            AUDIT_RESULT="fail"
        fi
    fi
```

**Step 4: Commit**

```bash
git add scripts/sw-loop.sh
git commit -m "feat(loop): use --json-schema for structured audit output"
```

---

## PR 2: Hook System Expansion

### Task 8: Create WorktreeCreate hook

**Files:**

- Create: `claude-code/hooks/worktree-create.sh`

**Step 1: Create the hook script**

```bash
#!/usr/bin/env bash
# Hook: WorktreeCreate — auto-setup worktree for pipeline agents
# Copies essential config into new worktrees so agents inherit settings
set -euo pipefail

# Read hook input from stdin (JSON with worktree path)
input=$(cat)
worktree_path=$(echo "$input" | jq -r '.worktree_path // empty' 2>/dev/null || true)

[[ -z "$worktree_path" ]] && exit 0

# Copy daemon config if it exists
src_config="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/daemon-config.json"
if [[ -f "$src_config" ]]; then
    mkdir -p "$worktree_path/.claude" 2>/dev/null || true
    cp "$src_config" "$worktree_path/.claude/daemon-config.json" 2>/dev/null || true
fi

# Copy pipeline artifacts directory structure
src_artifacts="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/pipeline-artifacts"
if [[ -d "$src_artifacts" ]]; then
    mkdir -p "$worktree_path/.claude/pipeline-artifacts" 2>/dev/null || true
fi
```

**Step 2: Make executable**

```bash
chmod +x claude-code/hooks/worktree-create.sh
```

**Step 3: Commit**

```bash
git add claude-code/hooks/worktree-create.sh
git commit -m "feat(hooks): add WorktreeCreate hook for auto-setup"
```

---

### Task 9: Create WorktreeRemove hook

**Files:**

- Create: `claude-code/hooks/worktree-remove.sh`

**Step 1: Create the hook script**

```bash
#!/usr/bin/env bash
# Hook: WorktreeRemove — clean up state for removed worktree agents
set -euo pipefail

input=$(cat)
worktree_path=$(echo "$input" | jq -r '.worktree_path // empty' 2>/dev/null || true)

[[ -z "$worktree_path" ]] && exit 0

# Clean up heartbeat files associated with this worktree
heartbeat_dir="$HOME/.shipwright/heartbeats"
if [[ -d "$heartbeat_dir" ]]; then
    # Find heartbeats referencing this worktree path
    for hb in "$heartbeat_dir"/*.json; do
        [[ -f "$hb" ]] || continue
        hb_path=$(jq -r '.worktree // empty' "$hb" 2>/dev/null || true)
        if [[ "$hb_path" == "$worktree_path" ]]; then
            rm -f "$hb"
        fi
    done
fi
```

**Step 2: Make executable and commit**

```bash
chmod +x claude-code/hooks/worktree-remove.sh
git add claude-code/hooks/worktree-remove.sh
git commit -m "feat(hooks): add WorktreeRemove hook for cleanup"
```

---

### Task 10: Create InstructionsLoaded hook (post-compaction reload)

**Files:**

- Create: `claude-code/hooks/instructions-reloaded.sh`

**Step 1: Create the hook script**

```bash
#!/usr/bin/env bash
# Hook: InstructionsLoaded (matcher: "compact")
# After auto-compaction, ensure project conventions are re-injected
set -euo pipefail

# Log reload event for observability
mkdir -p "$HOME/.shipwright" 2>/dev/null || true
echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"instructions.reloaded\",\"trigger\":\"compaction\"}" >> "$HOME/.shipwright/events.jsonl" 2>/dev/null || true
```

**Step 2: Commit**

```bash
chmod +x claude-code/hooks/instructions-reloaded.sh
git add claude-code/hooks/instructions-reloaded.sh
git commit -m "feat(hooks): add InstructionsLoaded hook for post-compaction"
```

---

### Task 11: Create ConfigChange hook for daemon

**Files:**

- Create: `claude-code/hooks/config-change.sh`

**Step 1: Create the hook script**

```bash
#!/usr/bin/env bash
# Hook: ConfigChange — notify daemon of config updates
set -euo pipefail

input=$(cat)

# Log config change event
mkdir -p "$HOME/.shipwright" 2>/dev/null || true
echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"config.changed\",\"detail\":$(echo "$input" | jq -c '.' 2>/dev/null || echo '{}')}" >> "$HOME/.shipwright/events.jsonl" 2>/dev/null || true

# Signal running daemon to reload config (if PID file exists)
pid_file="$HOME/.shipwright/daemon.pid"
if [[ -f "$pid_file" ]]; then
    daemon_pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
        kill -USR1 "$daemon_pid" 2>/dev/null || true
    fi
fi
```

**Step 2: Commit**

```bash
chmod +x claude-code/hooks/config-change.sh
git add claude-code/hooks/config-change.sh
git commit -m "feat(hooks): add ConfigChange hook for daemon reload"
```

---

### Task 12: Create PreToolUse hook for `--no-verify` prevention

**Files:**

- Modify: `.claude/hooks/pre-tool-use.sh` (add `--no-verify` check)

**Step 1: Read existing pre-tool-use.sh**

Read the full file to understand current structure.

**Step 2: Add `--no-verify` blocking**

After the existing bash 3.2 reminder logic, add:

```bash
# Block git push --no-verify (exit code 2 = block the action)
if echo "$tool_input" | grep -qE 'git\s+push.*--no-verify'; then
    echo '{"message":"Blocked: git push --no-verify bypasses safety checks. Remove --no-verify flag."}'
    exit 2
fi
```

**Step 3: Commit**

```bash
git add .claude/hooks/pre-tool-use.sh
git commit -m "feat(hooks): block git push --no-verify via PreToolUse exit code 2"
```

---

### Task 13: Register new hooks in settings.json and sw-init.sh

**Files:**

- Modify: `.claude/settings.json` (add new hook registrations)
- Modify: `scripts/sw-init.sh:558-610` (hook wiring section)

**Step 1: Add hook registrations to `.claude/settings.json`**

Add these entries to the `hooks` object:

```json
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/worktree-create.sh",
            "timeout": 15
          }
        ]
      }
    ],
    "WorktreeRemove": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/worktree-remove.sh",
            "timeout": 15
          }
        ]
      }
    ],
    "InstructionsLoaded": [
      {
        "matcher": "compact",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/instructions-reloaded.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "ConfigChange": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/config-change.sh",
            "timeout": 10
          }
        ]
      }
    ]
```

**Step 2: Update sw-init.sh hook wiring to include new hooks**

The init script already iterates `claude-code/hooks/*.sh` and wires them. Verify the new hook filenames are being picked up by the existing loop. If the wiring maps hook filenames to event types, add the new mappings.

**Step 3: Commit**

```bash
git add .claude/settings.json scripts/sw-init.sh
git commit -m "feat(hooks): register lifecycle hooks in settings.json"
```

---

### Task 14: Add HTTP hook support to settings.json

**Files:**

- Modify: `.claude/settings.json`
- Modify: `scripts/sw-init.sh` (webhook URL configuration)

**Step 1: Add HTTP hook example for pipeline events**

In `settings.json`, add to the `PostToolUse` array (or create a new event like a stage completion hook):

```json
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r '.tool_input.file_path' | xargs npx prettier --write 2>/dev/null || true"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/post-tool-use.sh",
            "timeout": 10
          }
        ]
      }
    ]
```

**Step 2: Document webhook configuration in daemon-config.json**

Add to the daemon config template/documentation that users can add:

```json
{
  "webhooks": [
    {
      "url": "http://localhost:3000/api/events",
      "events": ["pipeline.*", "build.*"],
      "headers": {}
    }
  ]
}
```

**Step 3: Update `sw-init.sh` to prompt for webhook URL during setup**

Add after the hook wiring section:

```bash
# ─── Webhook Configuration ─────────────────────────────────────────────────
if [[ "${SHIPWRIGHT_WEBHOOK_URL:-}" != "" ]]; then
    info "Webhook URL configured: $SHIPWRIGHT_WEBHOOK_URL"
fi
```

**Step 4: Commit**

```bash
git add .claude/settings.json scripts/sw-init.sh
git commit -m "feat(hooks): add HTTP hook support and webhook configuration"
```

---

## PR 3: Environment & MCP Configuration

### Task 15: Add new env vars to settings.json and init

**Files:**

- Modify: `.claude/settings.json:129-139` (env section)
- Modify: `scripts/sw-init.sh:519-528` (settings template)

**Step 1: Add env vars to `.claude/settings.json`**

Add to the `env` object:

```json
    "ENABLE_TOOL_SEARCH": "auto",
    "MAX_MCP_OUTPUT_TOKENS": "50000"
```

**Step 2: Add to sw-init.sh settings template**

In the fallback `cat > "$SETTINGS_FILE"` block (~line 519-528), add the new env vars:

```bash
    "ENABLE_TOOL_SEARCH": "auto",
    "MAX_MCP_OUTPUT_TOKENS": "50000"
```

**Step 3: Commit**

```bash
git add .claude/settings.json scripts/sw-init.sh
git commit -m "feat(config): add ENABLE_TOOL_SEARCH and MAX_MCP_OUTPUT_TOKENS env vars"
```

---

### Task 16: Generate managed-mcp.json template in sw-prep.sh

**Files:**

- Modify: `scripts/sw-prep.sh` (add new function after `prep_generate_settings`)
- Create: template content inline

**Step 1: Add function after `prep_generate_settings()` (~line 956)**

```bash
# ─── prep_generate_managed_mcp ─────────────────────────────────────────────

prep_generate_managed_mcp() {
    local filepath="$PROJECT_ROOT/.claude/managed-mcp.json"
    if ! should_write "$filepath"; then return; fi

    info "Generating .claude/managed-mcp.json..."

    jq -n '{
        "allowedMcpServers": ["*"],
        "deniedMcpServers": [],
        "note": "Configure MCP server access policies for pipeline agents"
    }' > "$filepath"

    track_file "$filepath"
    success "Generated .claude/managed-mcp.json"
}
```

**Step 2: Call the function from the main prep flow**

Find where `prep_generate_settings` is called and add `prep_generate_managed_mcp` after it.

**Step 3: Commit**

```bash
git add scripts/sw-prep.sh
git commit -m "feat(prep): generate managed-mcp.json template"
```

---

### Task 17: Create file suggestion script

**Files:**

- Create: `scripts/shipwright-file-suggest.sh`

**Step 1: Create the script**

```bash
#!/usr/bin/env bash
# Custom file suggestion for Claude Code @ autocomplete
# Surfaces Shipwright-specific files for quick access
set -euo pipefail

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# Core config files
for f in \
    ".claude/pipeline-state.md" \
    ".claude/daemon-config.json" \
    ".claude/fleet-config.json" \
    ".claude/loop-state.md" \
    ".claude/managed-mcp.json" \
    ".claude/settings.json" \
    ".claude/CLAUDE.md" \
    "CLAUDE.md" \
    "CHANGELOG.md"; do
    [[ -f "$PROJECT_ROOT/$f" ]] && echo "$f"
done

# Agent definitions
for f in "$PROJECT_ROOT"/.claude/agents/*.md; do
    [[ -f "$f" ]] && echo ".claude/agents/$(basename "$f")"
done

# Schemas
for f in "$PROJECT_ROOT"/schemas/*.json; do
    [[ -f "$f" ]] && echo "schemas/$(basename "$f")"
done

# Pipeline artifacts (most recent)
if [[ -d "$PROJECT_ROOT/.claude/pipeline-artifacts" ]]; then
    for f in plan.md design.md composed-pipeline.json; do
        [[ -f "$PROJECT_ROOT/.claude/pipeline-artifacts/$f" ]] && echo ".claude/pipeline-artifacts/$f"
    done
fi

# Loop logs (latest iteration)
if [[ -d "$PROJECT_ROOT/.claude/loop-logs" ]]; then
    # shellcheck disable=SC2012
    ls -t "$PROJECT_ROOT/.claude/loop-logs"/iteration-*.log 2>/dev/null | head -3 | while read -r f; do
        echo ".claude/loop-logs/$(basename "$f")"
    done
fi
```

**Step 2: Make executable**

```bash
chmod +x scripts/shipwright-file-suggest.sh
```

**Step 3: Commit**

```bash
git add scripts/shipwright-file-suggest.sh
git commit -m "feat: add file suggestion script for @ autocomplete"
```

---

### Task 18: Add doctor checks for new settings

**Files:**

- Modify: `scripts/sw-doctor.sh` (add new validation section)

**Step 1: Find the last numbered check section in sw-doctor.sh**

Search for the pattern to identify where to add a new section.

**Step 2: Add validation section**

```bash
# ─── Check N: Claude Code Feature Configuration ─────────────────────────────
echo ""
section_header "Claude Code Features"

# Check effort level if set
local _effort_val
_effort_val=$(jq -r '.env.CLAUDE_CODE_EFFORT_LEVEL // empty' "$SETTINGS_FILE" 2>/dev/null || true)
if [[ -n "$_effort_val" ]]; then
    case "$_effort_val" in
        low|medium|high) check_pass "Effort level: $_effort_val" ;;
        *) check_fail "Invalid effort level: $_effort_val (must be low/medium/high)" ;;
    esac
fi

# Check ENABLE_TOOL_SEARCH
local _tool_search
_tool_search=$(jq -r '.env.ENABLE_TOOL_SEARCH // empty' "$SETTINGS_FILE" 2>/dev/null || true)
if [[ -n "$_tool_search" ]]; then
    check_pass "Tool search: $_tool_search"
else
    check_warn "ENABLE_TOOL_SEARCH not set (recommend: auto)"
fi

# Check MAX_MCP_OUTPUT_TOKENS
local _mcp_tokens
_mcp_tokens=$(jq -r '.env.MAX_MCP_OUTPUT_TOKENS // empty' "$SETTINGS_FILE" 2>/dev/null || true)
if [[ -n "$_mcp_tokens" ]]; then
    check_pass "MCP output limit: $_mcp_tokens tokens"
else
    check_warn "MAX_MCP_OUTPUT_TOKENS not set (recommend: 50000)"
fi

# Check managed-mcp.json
if [[ -f "$PROJECT_ROOT/.claude/managed-mcp.json" ]]; then
    if jq empty "$PROJECT_ROOT/.claude/managed-mcp.json" 2>/dev/null; then
        check_pass "managed-mcp.json exists and is valid JSON"
    else
        check_fail "managed-mcp.json has invalid JSON"
    fi
fi

# Check schemas directory
if [[ -d "$PROJECT_ROOT/schemas" ]]; then
    local schema_count
    schema_count=$(find "$PROJECT_ROOT/schemas" -name "*.json" 2>/dev/null | wc -l | xargs)
    check_pass "Schemas directory: ${schema_count} schema(s)"
fi
```

**Step 3: Commit**

```bash
git add scripts/sw-doctor.sh
git commit -m "feat(doctor): validate Claude Code feature configuration"
```

---

## PR 4: Documentation Updates

### Task 19: Update .claude/CLAUDE.md with new features

**Files:**

- Modify: `.claude/CLAUDE.md` (multiple sections)

**Step 1: Add CLI Flags section after the "Pipeline Templates" table**

````markdown
## CLI Flags

All `claude` CLI invocations in the pipeline support these flags:

| Flag                   | Default          | Purpose                                                                              |
| ---------------------- | ---------------- | ------------------------------------------------------------------------------------ |
| `--effort-level`       | auto (per stage) | Reasoning depth: `low` (intake, PR), `medium` (build, test), `high` (design, review) |
| `--fallback-model`     | `sonnet`         | Auto-fallback on rate limits — prevents pipeline failures                            |
| `--json-schema <file>` | —                | Structured output matching a schema (audit, quality gates)                           |

### Effort Level Routing

| Stage                                  | Default Effort | Rationale                   |
| -------------------------------------- | -------------- | --------------------------- |
| intake, pr, merge                      | low            | Mechanical/formatting tasks |
| build, test, deploy, validate, monitor | medium         | Standard development work   |
| plan, design, review, compound_quality | high           | Complex reasoning required  |

Override globally: `--effort high` or via `daemon-config.json`:

```json
{ "effort_level": "high", "fallback_model": "sonnet" }
```
````

````

**Step 2: Expand Hooks section with new hook types**

Add subsections for HTTP hooks, prompt hooks, agent hooks, and lifecycle hooks. Document the new hooks in `claude-code/hooks/`.

**Step 3: Add Environment & MCP section**

Document `ENABLE_TOOL_SEARCH`, `MAX_MCP_OUTPUT_TOKENS`, `managed-mcp.json`, and `fileSuggestion`.

**Step 4: Update env vars table**

Add the new env vars to the existing table.

**Step 5: Commit**

```bash
git add .claude/CLAUDE.md
git commit -m "docs: document CLI flags, hooks, and MCP configuration"
````

---

### Task 20: Update settings.json env section and add fileSuggestion

**Files:**

- Modify: `.claude/settings.json`

**Step 1: Add fileSuggestion to settings**

```json
{
  "fileSuggestion": "./scripts/shipwright-file-suggest.sh"
}
```

**Step 2: Verify all env vars are present**

Ensure the `env` block has all documented vars.

**Step 3: Run doctor to validate**

```bash
shipwright doctor
```

**Step 4: Commit**

```bash
git add .claude/settings.json
git commit -m "feat(config): add fileSuggestion and finalize env vars"
```

---

### Task 21: Final integration test

**Step 1: Run the full test suite**

```bash
npm test
```

**Step 2: Run doctor validation**

```bash
shipwright doctor
```

**Step 3: Verify help text shows new flags**

```bash
shipwright loop --help | grep -E 'effort|fallback'
shipwright fix --help | grep -E 'effort|fallback'
```

**Step 4: Final commit and PR**

```bash
git add -A
git commit -m "test: verify Claude Code feature integration"
```
