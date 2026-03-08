## Pattern Injection Safety

When injecting patterns into the build loop context, prioritize safety, relevance, and observability.

### 1. Detection Confidence Scoring
- Assign confidence score (0.0–1.0) to each detected feature type based on keywords in the issue description
- Only inject patterns if confidence ≥ 0.7; avoid low-confidence false positives
- Log detection reasoning in `.claude/pattern-detection.log` for debugging
- Include the score in the injected context so the agent understands confidence level

### 2. Context Window Budget
- Measure pattern size: typical pattern = 300–500 tokens (overview + code + checklist)
- For 1–3 patterns: ~900–1500 tokens injected
- Compare against remaining context budget allocated to the build loop
- If < 20% context remains, truncate patterns or defer to next iteration
- Never allow pattern injection to cause mid-loop context exhaustion

### 3. Relevance Validation & Feedback
- Track which patterns the agent uses (via diffs in generated code) versus ignores
- If a pattern is consistently ignored, mark it for deprioritization in detection
- Add a relevance check: "Did the injected pattern appear in the agent's solution?"
- Use this signal to improve the detection algorithm iteratively

### 4. Graceful Degradation
- Patterns are optional, not blocking—loop continues normally if detection fails
- If patterns confuse the agent, error output should guide pattern refinement
- Provide an escape hatch: agent can request "no patterns this iteration" if unhelpful
- Default behavior: loop works identically with or without patterns

### 5. Testing Strategy
- **Unit test**: Detection confidence scores for diverse issue descriptions
- **Integration test**: Run loop with and without patterns, compare iteration count and error rates
- **Regression test**: Existing builds produce same results regardless of patterns
- **A/B test**: In daemon mode, measure whether pattern-injected builds converge faster

### 6. Observability & Debugging
- Write pattern detection info to `progress.md` so next iteration knows what was selected
- Log selected patterns and confidence scores to build artifacts
- Include "patterns used" signal in final build report (helps measure effectiveness)
- Make it easy to replay a failed build with patterns disabled to isolate root cause

### 7. Common Pitfalls to Avoid
- **Over-injection**: 3 patterns every time → bloats context; inject only when high confidence
- **False positives**: Detect "new command" pattern for unrelated issues → confuses agent
- **Stale examples**: Pattern code uses old APIs → agent copies broken code
- **Circular references**: Patterns reference other patterns → maintenance complexity
- **No feedback loop**: Never measure effectiveness → keep injecting irrelevant patterns forever
