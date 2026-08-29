## Monolith Extraction & Refactoring Verification

When splitting a large script into lib modules, use this approach to ensure correctness and reduce review burden:

### Pre-Extraction Mapping
1. **Identify extraction units** — Group related functions by concern (cost-tracking, discovery, core memory). Document which functions move to which new module.
2. **Map dependency graph** — For each function being moved, list every function/variable it depends on and every function/variable that depends on it.
3. **Identify cross-module dependencies** — Flag functions that depend on both cost-tracking AND discovery logic; these should stay in the main file or become a shared util.

### Extraction Execution
1. **Extract in dependency order** — Move functions with fewest dependencies first (leaf functions). Verify no circular imports.
2. **Update all references** — Use `grep -rn` to find and verify all call sites are updated with new source paths.
3. **Test one module at a time** — After each module extraction, run tests to catch import issues early.

### Verification Checklist
- [ ] All functions referenced in new modules are either: defined in that module, sourced from another module, or passed as parameters
- [ ] `grep -rn 'function_name'` returns no orphaned references
- [ ] No circular sourcing: module A sources B, B sources A
- [ ] New modules start with `set -euo pipefail` and VERSION variable
- [ ] All existing tests pass without modification (behavior-preserving extraction)
- [ ] Each new module has at least one test file covering its exported functions

### Review Template
In PR description, provide a matrix:
```
| Function | Old Location | New Location | Dependencies | Tested |
|----------|--------------|--------------|--------------|--------|
| ...      | sw-memory.sh | memory-cost  | ...          | ✓      |
```

This makes verification mechanical for reviewers.
