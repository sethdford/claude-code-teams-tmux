## Setup Recovery Resilience

When adding recovery capabilities to setup scripts, idempotency and safe state management are non-negotiable. This skill guides design and testing of resumable setup workflows.

### Idempotency Contracts

Each setup step must be idempotent: running it twice produces the same result as running it once, regardless of the step's prior state.

**Idempotent patterns**:
- File creation: Check if file exists before creating; use atomic writes (temp file + mv)
- Permission changes: chmod/chown are idempotent; verify target state, not change
- Directory creation: mkdir -p is idempotent
- Config appends: Check for key before appending; use grep -q with && || pattern
- Environment setup (tmux, GitHub): Idempotent if tool validates state before modifying

**Non-idempotent patterns to avoid**:
- git clone into existing dir (fails if dir exists)
- npm install into uncleaned node_modules (may conflict with existing packages)
- Version updates without checking current version first
- Direct file overwrites without backup

**Testing idempotency**: Run the step twice in the same session (simulating recovery) and verify the second run succeeds with no-op or identical result.

### Safe State Management

Checkpoint files hold the recovery state; they must be:
1. **Atomic**: Write to temp file, then mv atomically. Prevent partial writes.
2. **Versioned**: Include checkpoint schema version so old checkpoints don't break on upgrades.
3. **Scoped**: Each checkpoint is per-invocation; don't persist across users or environments.
4. **Filterable**: Never store secrets, tokens, or PII; store only step name, timestamp, and error context.

Checkpoint JSON structure:
```json
{
  "schema_version": "1.0",
  "started_at": "2026-03-08T10:30:45Z",
  "last_completed_step": "prerequisites_check",
  "steps_completed": ["prerequisites_check", "file_installation"],
  "steps_failed": [],
  "error_context": {
    "failed_step": null,
    "error_type": null,
    "recovery_suggestion": null
  }
}
```

### Synthetic Failure Injection for Testing

Recovery paths cannot be tested with real failures (30min setup cycles are too expensive). Instead:

1. **Mock failures**: Define a test mode where setup steps can be force-failed via env var (e.g., `TEST_FAIL_AT=prerequisites_check` makes that step fail)
2. **Checkpoint-only testing**: Create a checkpoint as if setup reached step N, then invoke recovery and verify it skips N and runs N+1 onward
3. **State validation**: After recovery completes, verify the final state is identical to a fresh full run
4. **Error injection**: Corrupt the checkpoint file and verify recovery fails gracefully with a clear error message

### Graceful Failure Handling

When recovery fails:
1. Preserve the original checkpoint (don't overwrite it)
2. Emit a detailed error to stderr with the failed step and a recovery suggestion
3. Log the error to events.jsonl with error_type (idempotency_violation, file_corruption, etc.)
4. Exit with a non-zero code but provide a next-step (e.g., "run `shipwright setup --reset` to start fresh")

### Integration with Telemetry

Every step (both initial run and recovery) must emit:
- `step_name`: identifier (e.g., "prerequisites_check")
- `duration_ms`: elapsed time
- `success`: boolean
- `error_type`: null or error classification (permissions, not_found, validation_failed, etc.)
- `is_recovery`: boolean (true if running as part of recovery)

This allows the dashboard to distinguish setup failures from recovery attempts and identify systemic issues.
