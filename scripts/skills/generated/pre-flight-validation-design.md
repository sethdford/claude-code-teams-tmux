## Pre-Flight Validation System Design

Pre-flight validation runs before expensive operations (build loop, deployment) to catch obvious failures in seconds. Design for extensibility, fail-fast semantics, and observability.

### Check Plugin Architecture

- Each check is a standalone function/script: syntax validator, import checker, file existence validator, smoke test runner
- Checks return structured output: `{status: "pass|fail|skip", message: string, duration_ms: number}`
- New checks can be added via configuration without code changes — register in `daemon-config.json` under `validation.checks`
- Order matters: run fast checks first (file existence < syntax < imports < tests), stop on first critical failure
- Timeouts: each check has a timeout; exceed it and mark as `timeout` (not failure — suggests performance issue, not code issue)

### Configuration Schema

```json
{
  "validation": {
    "enabled": true,
    "timeout_seconds": 60,
    "checks": [
      {"type": "syntax", "enabled": true, "patterns": ["**/*.js", "**/*.ts"]},
      {"type": "imports", "enabled": true},
      {"type": "required_files", "enabled": true, "files": ["package.json"]},
      {"type": "smoke_test", "enabled": true, "cmd": "npm run test:smoke"}
    ],
    "on_failure": "skip_build_loop"
  }
}
```

Allow runtime override: `VALIDATION_TIMEOUT=120 VALIDATION_CHECKS=syntax,imports`

### Error Reporting

Structured error report written to `.claude/validation-report.json`:
```json
{
  "timestamp": "2026-06-11T13:36:37Z",
  "status": "failed",
  "checks_run": 4,
  "checks_passed": 2,
  "checks_failed": 1,
  "checks_skipped": 1,
  "total_duration_ms": 3200,
  "failed_checks": [
    {"type": "imports", "message": "Missing import: ./utils (line 42)", "file": "src/main.js"}
  ],
  "time_saved": "~420 seconds (7 wasted loop iterations avoided)"
}
```

Log to `events.jsonl`: `{type: "validation", status: "failed", check: "imports", message: "...", duration_ms: 1200}`

### Fail-Fast Semantics

- **Critical failure** (syntax, missing required files): Stop immediately, skip build loop
- **Soft failure** (failed smoke test, import warning): Log and proceed if `on_failure: "continue"`, otherwise skip
- **Timeout**: Mark as degraded (validation infrastructure issue, not code issue); proceed to build loop
- Skip build loop only on critical failure by default; respect `on_failure` config

### Metrics & Cost Tracking

- Track: checks run, passed, failed; total validation time; matches with build loop failures (did validation catch it?)
- Calculate: "time saved per early catch" = (avg build loop time) × (prevented iterations)
- Emit metric: `validation.time_saved_minutes` per pipeline run
- Hourly rollup: `validation_success_rate`, `avg_validation_time_ms`, `issues_caught_early_count`

### Test Harness Pattern

For each check type:
1. **Positive case**: valid code passes the check
2. **Negative case**: known failure mode fails the check
3. **Edge case**: boundary conditions (empty files, deeply nested imports, circular dependencies)
4. **Performance**: validate check completes within timeout
5. **Integration**: validation report written correctly, metrics emitted

Use mock project directories (temp repos with known issues) to avoid test interdependencies.
