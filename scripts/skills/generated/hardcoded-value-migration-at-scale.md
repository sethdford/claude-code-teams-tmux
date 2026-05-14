## Hardcoded Value Migration at Scale

When extracting 48+ scattered hardcoded values (timeouts, limits, thresholds, retry counts) across a large bash codebase into a centralized `config/policy.json`, use this four-phase approach to ensure completeness and prevent regressions.

### Phase 1: Systematic Identification

1. **Run platform health scan** — Use the existing scan that identified 48 hardcoded values; capture its methodology (grep patterns, AST analysis, or manual audit).
2. **Map by category** — Group findings into: timeouts (sleep, wait, deadlines), limits (max iterations, queue size, retry count), thresholds (cost triggers, percentage checks), quality gates (coverage %, score cutoffs), and cost policies.
3. **Grep validation** — For each identified value, write a grep pattern that finds it and all similar values. Example: `grep -rn '30' scripts/ | grep -i timeout` to find potential timeout values.
4. **Create extraction checklist** — One row per hardcoded value: location, current value, category, rationale, proposed default in policy.json.

### Phase 2: Safe Extraction with Validation

1. **Add validation layer first** — Implement `validate_policy()` function before refactoring any callers. Test that it rejects invalid schema.
2. **Migrate by category, not by file** — Update all timeout usages together, then all retry limits, etc. This reduces the risk of partial migrations.
3. **Use intermediate markers** — In scripts, add a comment `# POLICY: category.key` above every `get_policy()` call so auditors can grep for migration completeness: `grep -r '# POLICY:' scripts/ | wc -l` should match your checklist size.
4. **Validate each batch** — After migrating one category, run tests specific to that category before moving to the next.

### Phase 3: Prevent New Hardcoded Values

1. **Pre-commit hook** — Add a grep that flags numeric literals in scripts (with whitelist for line numbers, exit codes, etc.).
2. **Code review checklist** — Reviewers specifically audit for new magic numbers; make it a required approval criterion.
3. **Platform health scan in CI** — Run the original scan on each PR to ensure hardcoded count doesn't increase.

### Phase 4: Validation and Documentation

1. **Completeness audit** — After migration, re-run the original health scan. It must report 0 new hardcoded policy values.
2. **Spot-check 10% of migrations** — Manually verify that 5 random scripts now call `get_policy()` instead of using hardcoded values.
3. **Migration guide** — Document every key extracted: current default, category, rationale, and how to override via environment variable.
4. **Before/after test** — Show a real example: "Old: `sleep 30` → New: `get_policy 'timeouts.poll_interval' || sleep 30`".

### Common Pitfalls

- **Incomplete grep patterns**: `grep '30'` finds false positives (line 30, exit code 30). Use word boundaries and context.
- **Missing fallbacks**: When a policy is new/missing, scripts should fall back to the old hardcoded value, not error. Use `get_policy 'key' || fallback_value`.
- **Silent failures**: If policy validation fails, the error must bubble up (not silently use a default). Developers need to know their policies are broken.
- **Scope creep**: Don't extract values that aren't policies (magic numbers in algorithms, formatting constants). Only extract runtime configuration.
