## Memory-Driven Auto-Remediation Pattern

When building systems that detect failure patterns and auto-inject fixes, follow these principles:

### Pattern Matching Design
- **Signature specificity**: Extract error signatures with enough specificity to avoid false matches, but general enough to apply across similar contexts. Test both: what % of errors does the pattern match? Of matched errors, how many did the fix solve?
- **Semantic vs. regex**: Consider regex matching on error messages vs. semantic matching (stack trace structure, error type). Regex is faster but fragile; semantic is robust but adds latency. Measure both in staging.
- **Recency weighting**: Recent patterns (from last 100 builds) have higher priority than historical patterns; failure modes shift as code evolves.

### Fix Eligibility & Safety
- **Success threshold**: >80% is aggressive; validate in staging that false positives don't outweigh true fixes. Track precision (fix actually helped / injected count) separately from recall.
- **Context isolation**: A fix proven in context A (e.g., Node test failure) may not apply in context B (Python integration test). Store fix metadata: file patterns, failure types, test categories it applies to.
- **Injection safety**: Inject fix *suggestions* into loop context, not auto-apply to code. Let the agent decide whether to use it. Track agent acceptance rate separately from fix success rate.

### Metrics & Observability
- **Mitigation hit rate**: % of failures matched by patterns. High hit rate = good pattern coverage; low = incomplete patterns.
- **Success lift**: Actual success rate improvement. If baseline is 77%, measure whether mitigation engine drives it to 85%. Account for confounding factors (code quality improvements, env changes).
- **False positives**: Injected fixes that made things worse. Track separately; signal systemic issues with pattern matching or fix quality.
- **Pattern ROI**: Some patterns may match rarely; disable patterns with <5% hit rate after 100 builds to reduce noise.

### Failure Mode Recovery
- **Recursive loops**: If injected fix causes new failure matching another pattern, that fix could loop infinitely. Detect: track injected fix history per iteration, reject fixes if they cause regression.
- **Pattern conflicts**: If two patterns match, prioritize by recency and success rate. Document tie-breaking logic.
- **Graceful degradation**: If pattern matching hangs (malformed error-summary.json), timeout and continue without mitigation. Never block the loop.

### Testing Strategy
- Unit: pattern matching on synthetic error signatures (edge cases: truncated stack traces, locale-dependent messages, multiline errors).
- Integration: loop harness integration + fix injection context isolation.
- Scenario: recursive failures, conflicting patterns, fix causing new errors.
- Staging validation: run with both mitigation enabled and disabled, measure both success rate and false-positive rate.
