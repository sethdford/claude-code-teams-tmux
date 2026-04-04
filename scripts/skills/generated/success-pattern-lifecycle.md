## Success Pattern Lifecycle Management

### Pattern Capture
When a pipeline succeeds, extract and store a canonical pattern snapshot:
- **Approach**: Brief description of strategy taken (e.g., 'iterative refactoring with incremental tests')
- **Iteration count**: How many build loop iterations to success
- **File patterns**: Changed file paths grouped by semantic role (tests, impl, docs)
- **Test strategy**: Which tests drove the build (unit, integration, e2e suite composition)
- **Commit structure**: Atomic commits vs squashed, message pattern (imperative vs descriptive)
- **Model/effort**: Claude model used, effort level setting
- **Duration**: Total time from intake to success
- **Metadata**: Issue type, complexity score, codebase domain (frontend/backend/infra)

### Indexing & Storage
- Store patterns in `.claude/memory/<repo-hash>/success-patterns.json` as an array of pattern objects
- Index by (issue_type, complexity_band, codebase_domain) for O(1) retrieval
- Maintain a secondary index: (pattern_hash) → timestamp for deduplication
- Keep a rolling window of 200 patterns per repo (rotate by LRU, preserve high-value patterns)

### Pattern Versioning
- Capture pattern_version=YYYYMMDD_SEQUENCE at capture time
- Include codebase_snapshot: git commit SHA when pattern was captured
- When querying patterns for injection, filter by age: prefer patterns < 90 days old, warn if pattern is stale
- Allowlist mechanism: certain patterns (golden paths) are marked keep_forever=true

### Pattern Expiration & Cleanup
- Patterns older than 180 days are automatically archived (not deleted; moved to `.claude/memory/<repo>/archive/`)
- Patterns matching failed builds within 7 days are demoted (success_weight -= 1, min 0)
- Patterns from refactored/deleted code paths are invalidated via `git log --follow` on files in the pattern

### Audit Trail
- Each pattern capture logs: (pattern_id, issue_id, timestamp, success_build_sha, injected_count_since_capture)
- Audit log stored in `.claude/memory/<repo-hash>/pattern-audit.jsonl`
- Monthly archival: compress audit logs older than 60 days to `.claude/memory/<repo-hash>/archive/audit-YYYY-MM.jsonl.gz`

### Injection Safety
- Validate pattern before injection: ensure all fields are JSON-safe, no embedded nulls, description < 200 chars
- If validation fails, log to error-log.jsonl and skip injection (don't fail the build)
- Pattern injection is read-only: patterns are never modified during injection, only metadata updated

### Monitoring & Quality
- Dashboard metric: pattern_reuse_rate = (builds_with_injection) / (total_builds)
- Dashboard metric: pattern_success_delta = (success_rate_with_injection) - (success_rate_baseline)
- Metric: stale_pattern_ratio = (patterns > 120 days old) / (total patterns)
- Alert if stale_pattern_ratio > 0.3 (indicates insufficient pattern refresh)

### API
- `capture_pattern(approach, iteration_count, files_changed, test_strategy, commits, metadata)` → pattern_id
- `query_patterns(issue_type, complexity_band, limit=3)` → [pattern1, pattern2, ...]
- `inject_pattern(pattern_id, build_prompt) → enriched_prompt
- `invalidate_pattern(pattern_id, reason)` (soft-delete)
- `pattern_audit_log(pattern_id)` → [(issue_id, timestamp, result), ...]
