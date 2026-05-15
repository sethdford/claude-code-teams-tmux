## Pre-Flight Validation Pattern

Pre-flight validation catches fundamentally broken pipelines before they consume resources, time, and quota. This pattern guides implementing a multi-check validator that integrates cleanly with daemon spawn logic and provides actionable rejection feedback.

### Core Checks

**Git State Validation**
- Verify working tree is clean (`git status --porcelain`)
- Check no concurrent pipelines on the same branch
- Validate repo is initialized and has commits
- For monorepos: verify the target package exists

**Issue Clarity Scoring**
- Check issue title is present and >10 characters
- Verify issue body exists and describes actionable scope
- Score clarity as (title_length + body_word_count + criteria_count) / 3
- Reject if score < 20 (too vague to execute reliably)

**Dependency Availability**
- Check `package.json` parse-able; `npm ls` succeeds without errors
- Verify test runner exists (`vitest`, `jest`, `mocha` etc.)
- Check lockfile consistency (`package-lock.json` or `yarn.lock` matches HEAD)
- For compiled languages: verify build tools in PATH

**Test Command Validity**
- Parse test command from package.json `test` script
- Validate test command syntax (no unmatched quotes, pipes)
- Check test runner binary is executable
- Dry-run test command with `--help` or `--list` to verify it's recognized

### Rejection Messages

Every rejection must include:
- What failed (specific check)
- Why it matters (prevents what kind of failure)
- How to fix it (actionable step)

**Example**: 
```
✗ Git working tree is dirty
  Why: Daemon pipeline will fail during commit because there are uncommitted changes.
  Fix: Run 'git status' and commit or stash your changes, then retry.
```

### Memory System Integration

Log rejections with structured data:
```json
{
  "timestamp": "2026-05-15T18:55:10Z",
  "check": "git_state",
  "reason": "working_tree_dirty",
  "issue_id": "488",
  "count": 1
}
```

The memory system aggregates these to detect patterns (e.g., "80% of rejections are dirty git states on Monday mornings" → suggest pre-commit hooks).

### Daemon Spawn Integration

Run validator in daemon spawn path BEFORE creating pipeline:
```bash
# In sw-daemon.sh, before spawn_pipeline:
if ! validate_pre_flight "$issue_id" "$branch"; then
  log_rejection "$issue_id" "$reason"
  update_issue "$issue_id" "Pipeline rejected: $reason. Fix and re-run."
  continue  # Skip to next issue
fi
```

Do NOT block the spawn thread — run validation in parallel and queue the result.

### Edge Cases

- **Monorepos**: Validate target package exists before checking dependencies
- **Conditional dependencies**: If package.json has postinstall/prepare scripts, pre-flight must run them
- **Flaky tests**: Don't reject based on test passing; only validate test command is valid
- **Stale lockfiles**: Allow if lockfile is older than package.json (indicates dev hasn't committed yet)
- **Private packages**: Skip npm registry checks; only validate local availability

### Metrics

Track over time:
- Rejection rate by check type
- False positive rate (rejected pipelines that would have succeeded)
- Time saved by preventing wasted runs
- Convergence: as patterns improve, rejection rate should drop
