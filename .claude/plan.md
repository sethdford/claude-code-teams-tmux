# Plan: Interactive First-Run Tutorial Pipeline with Setup Validation

## Overview

Create `shipwright tutorial` — an interactive, resumable tutorial that guides first-time users through Shipwright's core workflows. Unlike `setup` (which validates prerequisites and generates config) and `doctor` (which checks health), the tutorial teaches users _how to use_ Shipwright by walking them through real commands with validation at each step. Progress is persisted to `~/.shipwright/tutorial-state.json` so users can resume where they left off.

## Files to Modify

| File                          | Action     | Purpose                                                                                  |
| ----------------------------- | ---------- | ---------------------------------------------------------------------------------------- |
| `scripts/sw-tutorial.sh`      | **Create** | Main tutorial script (~450 lines)                                                        |
| `scripts/sw-tutorial-test.sh` | **Create** | Test suite (~350 lines)                                                                  |
| `scripts/sw`                  | **Edit**   | Add `tutorial` to CLI router + help text                                                 |
| `package.json`                | **Edit**   | Register test in `test` script                                                           |
| `.claude/CLAUDE.md`           | **Edit**   | Add to core-scripts and test-suites tables (auto-sync will handle, but we add the entry) |

## Architecture

### Tutorial Steps (6 steps, each with validation)

1. **Verify Setup** — Run a lightweight doctor check (prereqs + .claude/ exists). Ensures the user has a working environment before proceeding. _Non-interactive._
2. **Explore the CLI** — Show key command groups, have the user run `shipwright --help` and `shipwright status --json`. Validate that status returns valid JSON. _Light interaction._
3. **Browse Templates** — Show pipeline and team templates. User picks a team template. Validate template exists. _Interactive selection._
4. **Run a Dry-Run Session** — Walk through `shipwright session <name> --dry-run`. Validate the session plan output. _Light interaction._
5. **Explore Observability** — Show `shipwright doctor`, `shipwright cost show`, and `shipwright memory show`. Validate doctor runs clean. _Non-interactive._
6. **Next Steps** — Show contextual "what to do next" based on detected project type (language, framework, test command from `sw-setup.sh` detection logic). Mark tutorial complete. _Summary._

### State Management

```json
{
  "version": "3.2.0",
  "started_at": "2026-02-28T01:00:00Z",
  "completed_at": null,
  "current_step": 1,
  "steps": {
    "1": {
      "name": "verify_setup",
      "status": "completed",
      "completed_at": "..."
    },
    "2": { "name": "explore_cli", "status": "pending", "completed_at": null },
    "3": {
      "name": "browse_templates",
      "status": "pending",
      "completed_at": null
    },
    "4": {
      "name": "dry_run_session",
      "status": "pending",
      "completed_at": null
    },
    "5": {
      "name": "explore_observability",
      "status": "pending",
      "completed_at": null
    },
    "6": { "name": "next_steps", "status": "pending", "completed_at": null }
  }
}
```

File location: `~/.shipwright/tutorial-state.json`

### CLI Flags

```
shipwright tutorial              # Start or resume tutorial
shipwright tutorial --reset      # Reset progress, start fresh
shipwright tutorial --skip       # Mark all steps complete (skip tutorial)
shipwright tutorial --status     # Show current progress
shipwright tutorial --step N     # Jump to specific step
shipwright tutorial --help       # Show usage
```

### Integration Points

1. **CLI Router** (`scripts/sw`): Add `tutorial` case to main dispatch, add to help text under "Getting Started" section.
2. **Welcome message** (`scripts/sw`): After `show_welcome`, add hint: `→ After setup, try: shipwright tutorial`
3. **Post-setup** (`scripts/sw-setup.sh`): NOT modified — keep setup focused. Tutorial is a separate concern.

## Implementation Steps

### Step 1: Create `scripts/sw-tutorial.sh`

Standard script header:

- `#!/usr/bin/env bash`, `set -euo pipefail`, ERR trap
- `VERSION="3.2.0"` at top
- Source `lib/compat.sh` and `lib/helpers.sh` with fallbacks
- Define `TUTORIAL_STATE_FILE="${HOME}/.shipwright/tutorial-state.json"`

### Step 2: State management functions

```bash
init_tutorial_state()      # Create fresh state JSON
load_tutorial_state()      # Read current state, set CURRENT_STEP
save_tutorial_state()      # Atomic write (tmp + mv) updated state
mark_step_complete()       # Update step status, advance CURRENT_STEP
get_step_status()          # Return status for a given step number
```

Use `jq --arg` for all JSON manipulation (never string interpolation).

### Step 3: Argument parsing

Parse `--reset`, `--skip`, `--status`, `--step N`, `--help/-h`, `--noninteractive`.

### Step 4: Welcome banner and progress display

```
╔══════════════════════════════════════╗
║   Shipwright Interactive Tutorial    ║
║   v3.2.0                            ║
╚══════════════════════════════════════╝

Progress: ■■□□□□ 2/6 steps complete
```

Use `show_progress_bar()` function. Progress indicator shows filled/empty squares per step.

### Step 5: Implement Step 1 — Verify Setup

- Check: `.claude/` directory exists
- Check: `claude` CLI available
- Check: `jq` available
- Check: `git` available
- Check: Inside a git repo
- If any fail: show remediation instructions, don't advance
- If all pass: `mark_step_complete 1`, emit `tutorial_step_complete` event

### Step 6: Implement Step 2 — Explore the CLI

- Show the 5 main command groups (core, quality, observe, release, intel)
- Run `shipwright status --json 2>/dev/null` and validate it returns JSON
- If in non-interactive mode: auto-advance
- If interactive: wait for user to press Enter between sections
- Mark complete

### Step 7: Implement Step 3 — Browse Templates

- List available team templates from `tmux/templates/` directory
- List available pipeline templates from `templates/pipelines/`
- Count templates found, validate at least 1 of each exists
- Mark complete

### Step 8: Implement Step 4 — Dry-Run Session

- Explain what `shipwright session` does
- Run `shipwright session tutorial-demo --dry-run 2>&1` (dry-run produces plan without creating tmux panes)
- Show the dry-run output
- If `--dry-run` is not supported or tmux not available: show what the command would do, still pass
- Mark complete

### Step 9: Implement Step 5 — Explore Observability

- Run `shipwright doctor 2>&1 | head -30` (just show first 30 lines)
- Show cost tracking command: `shipwright cost show`
- Show memory system: `shipwright memory show`
- Validate doctor ran (exit code capture)
- Mark complete

### Step 10: Implement Step 6 — Next Steps

- Detect project type (reuse `sw-setup.sh` detection logic: package.json, Cargo.toml, go.mod, pyproject.toml)
- Show contextual next steps based on detected language/framework/test command
- Show the "graduation" box with recommended workflows
- Mark tutorial complete
- Set `completed_at` in state
- Emit `tutorial_completed` event

### Step 11: Add to CLI router

In `scripts/sw`, add to main dispatch:

```bash
tutorial)   exec "$SCRIPT_DIR/sw-tutorial.sh" "$@" ;;
```

Add to `show_help()` under Getting Started:

```
  tutorial    Interactive first-run walkthrough
```

Add tutorial hint to `show_welcome()`:

```
  → After setup, try the tutorial:   shipwright tutorial
```

### Step 12: Create `scripts/sw-tutorial-test.sh`

Following the established test harness pattern:

- Sandboxed TEMP_DIR with mock binaries
- Assert functions (assert_pass, assert_fail, assert_contains, assert_eq)
- Test sections:
  1. **Script Safety** — `set -euo pipefail`, ERR trap, VERSION
  2. **Help** — `--help` exits 0, shows usage
  3. **State Management** — init creates valid JSON, load/save roundtrip
  4. **Tutorial Steps** — each step function exists in source
  5. **Reset** — `--reset` clears state file
  6. **Skip** — `--skip` marks all complete
  7. **Status** — `--status` shows progress
  8. **Non-interactive** — `--noninteractive` runs without prompts
  9. **Event Emission** — tutorial events written to events.jsonl
  10. **Resume** — partial state resumes from correct step

### Step 13: Register test in `package.json`

Add `bash scripts/sw-tutorial-test.sh` to the `"test"` script chain (insert alphabetically between `sw-trace-test.sh` and `sw-triage-test.sh`).

## Task Checklist

- [ ] Task 1: Create `scripts/sw-tutorial.sh` with header, VERSION, helpers, state file path
- [ ] Task 2: Implement state management functions (init, load, save, mark_complete)
- [ ] Task 3: Implement argument parsing (--help, --reset, --skip, --status, --step, --noninteractive)
- [ ] Task 4: Implement welcome banner with progress bar display
- [ ] Task 5: Implement Step 1 — Verify Setup (prerequisite checks with validation)
- [ ] Task 6: Implement Step 2 — Explore the CLI (command groups, status check)
- [ ] Task 7: Implement Step 3 — Browse Templates (list team + pipeline templates)
- [ ] Task 8: Implement Step 4 — Dry-Run Session (session --dry-run walkthrough)
- [ ] Task 9: Implement Step 5 — Explore Observability (doctor, cost, memory)
- [ ] Task 10: Implement Step 6 — Next Steps (project detection, contextual recommendations)
- [ ] Task 11: Add `tutorial` command to CLI router (`scripts/sw`) and help text
- [ ] Task 12: Create `scripts/sw-tutorial-test.sh` with full test coverage
- [ ] Task 13: Register test in `package.json` test script chain
- [ ] Task 14: Run test suite and fix any failures

## Testing Approach

### Unit Tests (`sw-tutorial-test.sh`)

1. **Script safety**: Verify `set -euo pipefail`, ERR trap, VERSION present
2. **Help flag**: `--help` and `-h` exit 0 with usage info
3. **State init**: Creates valid JSON with all 6 steps in `pending` status
4. **State roundtrip**: Load → modify → save → reload preserves data
5. **Reset**: `--reset` removes state file and creates fresh state
6. **Skip**: `--skip` sets all steps to `completed`
7. **Status output**: `--status` shows step count and progress
8. **Non-interactive mode**: `--noninteractive` flag runs all steps without prompts
9. **Event emission**: Tutorial events appear in `events.jsonl`
10. **Resume behavior**: Partial state file → tutorial starts from correct step
11. **Step validation functions**: Each `run_step_N` function exists in source
12. **Atomic writes**: State file uses tmp+mv pattern

### Integration Validation

- `shipwright tutorial --help` returns 0
- `shipwright tutorial --status` works before and after tutorial
- `shipwright tutorial --noninteractive` completes all 6 steps in a mock environment
- `shipwright tutorial --reset` clears progress

### Manual Smoke Test

```bash
# Fresh start
rm -f ~/.shipwright/tutorial-state.json
shipwright tutorial

# Resume after interrupting
# (Ctrl+C mid-tutorial, then re-run)
shipwright tutorial

# Check status
shipwright tutorial --status

# Reset and redo
shipwright tutorial --reset
shipwright tutorial --noninteractive
```

## Definition of Done

- [ ] `scripts/sw-tutorial.sh` exists with all 6 tutorial steps implemented
- [ ] Tutorial state persists to `~/.shipwright/tutorial-state.json` and supports resume
- [ ] `--help`, `--reset`, `--skip`, `--status`, `--step N`, `--noninteractive` flags all work
- [ ] CLI router dispatches `shipwright tutorial` correctly
- [ ] Help text includes tutorial command
- [ ] Welcome message hints at tutorial
- [ ] `scripts/sw-tutorial-test.sh` has 15+ tests covering all paths
- [ ] Test registered in `package.json` and passes
- [ ] All event emissions use `emit_event` for observability
- [ ] Script follows Bash 3.2 compatibility (no associative arrays, no readarray)
- [ ] Atomic file writes for state management
- [ ] No shellcheck warnings
