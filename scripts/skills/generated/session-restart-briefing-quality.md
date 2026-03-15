## Session Restart Briefing Quality

When a Claude session restarts due to context exhaustion, briefing quality determines success rate. A good briefing transfers learned context to the fresh session and positions it to continue effectively.

### Essential Briefing Elements

**1. Change Summary** — What was built since loop start
- Files modified (categorize: source, test, docs, config)
- Functionality added/changed
- Dependencies modified

**2. Error Patterns** — What failed and why
- Top 3-5 errors by frequency from error-summary.json
- Root causes identified in previous session
- Tests that consistently fail
- Known workarounds attempted

**3. Iteration History** — Approaches tried and their outcomes
- Strategies attempted and why they failed
- Approaches that worked (partial or full success)
- Why previous attempts stalled
- Dead ends to avoid

**4. Next-Step Recommendations** — What to try next
- Most promising next step based on error analysis
- Files to focus on first
- Test commands to run
- Risks to watch for

### Quality Metrics for Briefing Effectiveness

- **Completeness**: Did the briefing capture enough context for the fresh session to orient itself?
- **Accuracy**: Are error patterns correctly extracted? Are recommendations sound?
- **Signal-to-Noise**: Could it be shorter without losing critical info?
- **Actionability**: Can the fresh session immediately understand what to do next?
- **Correctness**: Do recommendations address actual blocking issues, not red herrings?

### Testing Strategy for Restart Handoffs

1. **Unit tests**: Verify briefing generation on mock loop state (git diffs, error-summary.json structures)
2. **Integration tests**: Verify briefing format integrates with sw-loop.sh restart, passes as context, parses correctly
3. **Quality tests**: Have human reviewer assess briefing completeness for real failed loop runs
4. **Success metric**: A/B test restart completion rate—measure % of restarts that complete vs abort with and without briefing
5. **Edge cases**: Test on loops with no errors, loops with many rapid errors, loops with no file changes

### Common Failure Modes in Handoffs

1. **Missing error context** → Fresh session hits same error, no progress
2. **Incomplete git diff** → Fresh session unaware of attempted changes
3. **Vague recommendations** → Fresh session doesn't know what to try
4. **Over-summarization** → Critical errors buried in noise
5. **Wrong categorization** → Error marked as "configuration" when it's actually a logic bug
6. **No iteration history** → Fresh session repeats failed approaches
7. **Lost intermediate wins** → Doesn't recognize partial progress from failed iteration

### Briefing Format Principles

- **Structured**: Use clear sections and priorities, not prose narrative
- **Concise**: Target 1-2KB of briefing per loop state (fit in fresh session's early context)
- **Error-first**: Lead with blocking errors and failures, not successes
- **Actionable**: Every section should suggest a next action
- **Timestamped**: Reference when each error occurred and how many iterations ago
