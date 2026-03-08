## Failure Pattern Analysis & Remediation

Pipeline failures are learning opportunities, but only if you extract actionable intelligence and classify failures for future automation. This skill guides you through failure categorization, diagnostic structure design, and suggestion generation.

### Failure Categories

Define these core categories for your diagnostic system:

1. **test_failure** — Test assertion failures, timeouts in test suite, test setup/teardown errors
2. **build_error** — Compilation failures, syntax errors, dependency resolution failures, link errors
3. **timeout** — Stage exceeded configured duration, infinite loops, process hangs, unresponsive services
4. **context_exhaustion** — AI agent ran out of context window mid-task, unable to complete iteration
5. **integration_error** — External service failures, API errors, permission issues, network timeouts
6. **resource_error** — Out of memory, disk full, file descriptor exhaustion, process limits
7. **deadlock** — Circular dependencies, blocked mutual operations, race conditions, lock contention
8. **user_error** — Invalid input, misconfiguration, user-initiated abort

### Diagnostic Report Structure

Structure reports with these sections to support both human debugging and automated learning:

1. **Failure Summary** — Classification, timestamp, affected stage, duration until failure
2. **Error Details** — Last 100 lines of stage logs, error-log.jsonl entries, stack traces, assertion messages
3. **Context** — Git branch and HEAD commit, git status output, files changed in failed attempt
4. **Timeline** — Duration of each completed stage, wall-clock timestamps, iteration count if in build loop
5. **Reproduction** — Exact command invoked, environment variables, parameters, git state snapshot
6. **Suggestions** — 2-3 context-aware recommendations based on failure classification and error patterns

### Suggestion Generation Rules

Generate targeted recommendations:

- **test_failure**: Suggest running failing test individually, check test isolation (shared state), suggest adding debugging output to test
- **build_error**: Suggest checking dependency versions, clearing build cache, verifying compiler version, running in clean environment
- **timeout**: Suggest increasing timeout threshold if legitimate work, profile the slow operation, check for infinite loops or unresponsive services
- **context_exhaustion**: Suggest resuming with `--max-restarts` enabled, breaking task into smaller chunks, checking for excessive logging or intermediate artifacts
- **integration_error**: Suggest checking service status, verifying credentials and permissions, checking network connectivity, enabling verbose API logging
- **resource_error**: Suggest freeing disk space or memory, increasing system limits, breaking work into batches, reducing parallelism
- **deadlock**: Suggest examining lock ordering and dependencies, breaking circular dependency chains, enabling debug logging for synchronization
- **user_error**: Suggest correcting configuration, validating input, checking documentation

### Event Emission

Emit structured diagnostic events with:
- Type: `pipeline.failure_diagnostic`
- Class: The failure category (test_failure, build_error, etc.)
- Stage: The affected stage name
- Duration: Seconds elapsed before failure
- Attempt: Current retry count (0 if first attempt)
- Suggestion_count: Number of recommendations generated

These events feed the memory system, intelligence layer, and predictive analysis for future optimization.

### Integration Pattern

1. On pipeline failure (any stage fails or loop exhausts iterations)
2. Examine logs, errors, git state
3. Classify failure into a category using patterns in error messages
4. Extract diagnostic context (git diff, last N lines of each log, timeline)
5. Generate 2-3 targeted suggestions based on classification
6. Structure report markdown with sections
7. Write to `.claude/pipeline-artifacts/failure-report-<timestamp>.md`
8. Append summary (classification + suggestions) to pipeline state file
9. Emit diagnostic event with classification and metadata
10. Optional: Sync stale diagnostics to observability backend

### Data Quality

- **Actionability**: Every suggestion should be testable (can user/agent try it?)
- **Brevity**: One-line classification, 2-3 sentences per suggestion
- **Specificity**: Reference actual error messages and git diffs, not generic advice
- **Completeness**: Include all required sections even if some are empty
- **Safety**: Filter logs for secrets (API keys, passwords, tokens)

### Testing Approach

For each failure category, design a test that:
1. Triggers that specific failure type (failing test, bad code, timeout scenario, etc.)
2. Verifies correct classification in diagnostic event
3. Validates expected sections present in generated report
4. Checks that 2-3 suggestions were generated and are relevant
5. Confirms event was emitted with correct class and metadata
6. Spot-check that suggestions are actionable (not vague)
