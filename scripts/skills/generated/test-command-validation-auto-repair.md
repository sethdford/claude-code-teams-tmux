## Test Command Validation and Auto-Repair Engine

### Purpose
Before the build loop starts, validate the test command works in the current environment. If validation fails, attempt automatic repairs for common issues (missing dependencies, path problems, broken scripts), then re-validate. Abort early with clear diagnostics if repair fails.

### Validation Strategy

**Phase 1: Dependency Detection**
- Read `package.json`, `Gemfile`, `pyproject.toml`, `go.mod`, `Cargo.toml`, etc. to detect project type
- Check if package manager is installed: `npm list`, `bundle list`, `pip list`, `go mod graph`, `cargo list`
- Parse lockfile age and check for stale dependencies

**Phase 2: Test Command Check**
- Parse test command from config (daemon-config.json `test_cmd` or `.claude/settings.json`)
- Run with `--help` or `--version` to verify command exists and responds
- Capture stderr/stdout to diagnose permission errors, not-found errors, syntax errors

**Phase 3: Dry Run**
- Run test command with `--collect-only` (pytest), `--list` (jest), `--list-tests` (vitest), or similar without execution
- If unavailable, run with timeout (2s) to confirm it starts without hanging

### Auto-Repair Decision Tree

```
IF no package manager installed
  → error: "Install <npm|bundle|python|go|cargo> first"
  → abort (not auto-repairable)

IF package manager installed but dependencies missing
  → attempt: `npm install` / `bundle install` / `pip install -r requirements.txt` / `go mod download` / `cargo fetch`
  → re-validate

IF test command not found in PATH
  → check if in node_modules/.bin or similar
  → if found, update PATH and re-validate
  → else: error (command doesn't exist, cannot repair)

IF test command syntax error (parse error in test file)
  → error (cannot repair, user must fix)

IF test command times out or hangs
  → error (likely infinite loop or blocking I/O, cannot auto-repair)
```

### Integration with Pipeline State

Add validation result to `.claude/pipeline-state.md` under a `## Test Validation` section:

```markdown
## Test Validation

Status: PASS | FAIL
Command: npm test
Package Manager: npm@9.2.0
Dependencies Installed: yes
Repairs Attempted: npm install (success)
Diagnostics: "All checks passed. Ready for build loop."
Duration: 2.3s
```

If FAIL, inject diagnostics into next build loop iteration as structured error context:

```json
{
  "validation_failed": true,
  "command": "npm test",
  "error": "Test command returned exit code 1 after repair attempts",
  "diagnostics": [
    "Missing dependency: @babel/core (not in node_modules)",
    "npm install completed but test still fails"
  ]
}
```

### Common Repair Patterns by Language

| Language | Package Manager | Repair Command | Validation |
|----------|-----------------|---|---|
| Node.js | npm | `npm install` | `npm test --help` |
| Node.js | yarn | `yarn install` | `yarn test --help` |
| Node.js | pnpm | `pnpm install` | `pnpm test --help` |
| Ruby | bundler | `bundle install` | `bundle exec rake -T` |
| Python | pip | `pip install -r requirements.txt` | `python -m pytest --collect-only` |
| Python | poetry | `poetry install` | `poetry run pytest --collect-only` |
| Go | mod | `go mod download` | `go test -list .` |
| Rust | cargo | `cargo fetch` | `cargo test --no-run` |

### Error Handling & Abortion

If validation fails after all repair attempts:
1. Write detailed error to stderr (command, repairs attempted, final error)
2. Write structured JSON to `.claude/pipeline-artifacts/validation-error.json`
3. **Abort pipeline** — do not proceed to build loop
4. Set pipeline state to `blocked:validation_failed`
5. Surface error to intelligence layer for pattern capture

Never mask real validation failures with "hope it works in the build loop."

### Performance & Idempotency

- **Target**: Validation completes in <5 seconds
- **Idempotency**: Safe to run validation multiple times (e.g., on pipeline resume). Only re-repair if state has changed (e.g., new lockfile).
- **Cache**: If validation passed in last 1 hour and no files changed, skip re-validation

### Metrics for Intelligence Layer

Capture these metrics in pipeline state for DORA analysis:
- `validation_pass_rate`: % of pipelines that pass validation
- `repair_success_rate`: % of failed validations fixed by auto-repair
- `common_failures`: Top 5 validation failure reasons
- `validation_duration_ms`: Time spent in validation

Use these metrics to detect systemic environment issues (e.g., "60% of runs fail on missing @babel/core") for team visibility.
