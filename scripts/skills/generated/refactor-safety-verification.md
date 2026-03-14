## Refactor Safety Verification for Complex Script Decomposition

When decomposing a large, critical script (like sw-loop.sh at 2,527 lines) into modular components, the primary risk is subtle behavioral drift. This skill provides verification techniques to ensure module extraction preserves 100% behavioral compatibility.

### Module Extraction Patterns

1. **Cohesion Analysis**: Group functions that work on the same data structures or implement a single responsibility (convergence detection, iteration management, etc.). Avoid splitting functions with tight variable coupling.

2. **Dependency Mapping**: Before extracting, enumerate:
   - Global variables each function reads/writes
   - Functions called by each function
   - Order of side effects (logging, file writes, state mutations)
   Map these to module boundaries—functions in the same module should have higher coupling than cross-module calls.

3. **Interface Design**: Define what each module exports (functions and required globals) and imports (parameters and sourced variables). Minimize cross-module state sharing.

### Behavioral Verification Techniques

1. **Differential Testing**: Run existing test suite against BOTH original and refactored code in the same environment. Compare output byte-for-byte (stdout, exit codes, side effects like files created). Any diff is a regression.

2. **Function-Level Behavior Assertions**: For extracted functions, write micro-tests that verify:
   - Return values are identical
   - Side effects (variable mutations, file writes) match
   - Error paths trigger identically
   - Exit codes are preserved

3. **Regression Detection Strategy**:
   - Run existing test suite on original script → capture baseline output
   - Run existing test suite on refactored script → compare output
   - If diffs exist, isolate to the module(s) responsible
   - Verify diffs are cosmetic (e.g., log timestamps) or code quality improvements, not behavioral

### Dependency Validation

1. **Circular Import Detection**: Verify no module sources itself directly or transitively. Use `grep -l "source.*lib/loop" lib/loop-*.sh` to find cycles.

2. **Variable Scope Audits**: Functions that relied on global scope must have globals explicitly declared in their module (e.g., `declare -g LOOP_STATE` at module top). Verify no accidental shadowing of globals across modules.

3. **Function Call Sequencing**: If the refactoring changes the order in which functions are sourced or called, verify that initialization dependencies are met (e.g., if `initialize_loop_state()` must run before `detect_convergence()`, ensure modules load in correct order).

### Test Coverage Parity

1. **Coverage Mapping**: For each new lib/loop-*.sh module, identify which existing tests exercise it. Ensure coverage is equivalent before and after refactoring.

2. **Integration Points**: Write new tests specifically for module boundaries—test that modules work correctly when composed by the orchestrator (main sw-loop.sh).

3. **Edge Case Preservation**: Verify that error paths, signal handling, and timeout logic are tested in both old and new structures.

### Validation Checklist

- [ ] All existing tests pass with refactored code
- [ ] Differential output check: no unexpected diffs in stdout/stderr
- [ ] No new global variable leaks across module boundaries
- [ ] Module load order is explicit and consistent
- [ ] Circular import check passes
- [ ] Function call sequences preserve initialization order
- [ ] New modular tests achieve feature parity with old tests
- [ ] Performance profile unchanged (no additional process overhead)
- [ ] All modules source correctly without syntax errors
