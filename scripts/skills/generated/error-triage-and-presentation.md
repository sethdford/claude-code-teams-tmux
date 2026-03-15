## Error Triage & Intelligent Presentation

When dealing with high-volume error output, successful systems triage by impact and communicate only what matters most. Apply these patterns:

### Categorization Framework
**Syntax/Parse Errors** (highest priority): Block downstream tests—fix first.
**Logic Errors** (high priority): Test intent failures—critical path code.
**Edge Case Failures** (medium): Boundary condition tests—lower risk if skipped temporarily.
**Integration Failures** (medium): Multi-component interaction—may be cascading from logic errors.
**Environmental Failures** (lowest): Setup/teardown, missing test fixtures—often false negatives.

### Impact Prioritization
1. **Blocking analysis**: Errors that prevent other tests from running (e.g., initialization failures) rank above isolated test failures.
2. **Dependency chains**: If test A fails due to test B's side effect, fix B first—flag the dependency in output.
3. **Failure clustering**: Group by root cause, not symptom. "5 auth failures → 1 bug" vs. "5 separate issues."

### Focused Prompt Generation
After triage, generate structured output for decision-making:
- Top 3-5 critical failures with root causes
- Suggested fix order (respecting dependencies)
- Grouped failures ("cluster of 7 timeout errors") vs. listing all 7
- Brief context: "Test A blocks B, C, D; fix A first"

### Implementation Guidance
- Use regex-based pattern matching for error signature extraction (syntax error locations, assertion failures, stack traces).
- Build a failure dependency graph—if error X prevents test Y from running, mark it as a blocker.
- Cluster by error message similarity (fuzzy matching) or inferred root cause (shared module, configuration).
- Cap output to 50-100 lines for context efficiency—summarize beyond that.
- Preserve line numbers and stack traces for human debugging when needed.

### Testing
Mock scenarios: 10 errors (simple), 50 errors (medium noise), 100+ errors (stress test). Validate that priorities make sense and clustering reduces cognitive load.
