## Success Pattern Extraction & Mining for Build Loop Learning

When a pipeline succeeds, capture the decisions and approach that led to success so they can be replayed in similar situations.

### What to Extract

**Structural patterns**:
- File change clusters (which files were modified together, in what order)
- Dependency chains (did test A need to pass before test B to unlock subsequent passes?)
- Tool/model sequencing (which LLMs or tools were invoked, in what order)
- Iteration depth (how many build iterations until success; when did it converge?)

**Semantic patterns**:
- Problem decomposition strategy (how was the issue broken down?)
- Constraint satisfaction order (tackle tests first? linting? types?)
- Fallback strategy (when approach 1 failed, what triggered approach 2?)
- Context key decisions (did injecting a specific insight unlock progress?)

**Temporal patterns**:
- Early wins (which 30% of work unblocked the remaining 70%?)
- Rework signatures (were the same files edited multiple times? Why?)
- Learning curve (did the loop build increasingly sophisticated mental models?)

### How to Extract Without Overfitting

1. **Aggregate across successes, not single runs**: Look for patterns appearing in >2 successful runs on different issues. Single-run oddities are noise.
2. **Separate issue-specific from general patterns**: File names are specific; "test failures block linting" is general. Keep both, tag separately.
3. **Capture NOT just success but the path**: A successful run where 80% of work was wasted rework is different from one that converged quickly. Include iteration count, rework ratio, and key inflection points.
4. **Version patterns by issue type**: Patterns for "add API endpoint" differ from "fix race condition." Tag with issue labels/intent.
5. **Track pattern effectiveness**: When a pattern is injected, measure if it reduced iterations, rework, or improved first-pass success. Deprecate patterns that consistently underperform.

### Storage & Retrieval

**Index schema** (in memory system):
```
pattern {
  id: sha256(canonical_pattern),
  issue_type: "api-endpoint" | "bug-fix" | ...,
  file_patterns: ["src/api/*.ts", "tests/api/*.test.ts"],
  approach: "string describing high-level strategy",
  iterations_typical: 2-4,
  success_count: 12,
  injection_count: 18,
  effectiveness: 0.67,
  last_seen: timestamp,
  examples: [issue_id_1, issue_id_2],
  source_runs: [run_id_1, run_id_2]
}
```

**Deprecation rule**: Patterns with `effectiveness < 0.5` (success rate when injected < 50%) should be deprioritized in matching; at `< 0.2`, remove entirely.

### Anti-Patterns to Avoid

- **Cargo-cult patterns**: "We always run tests in this order because one successful run did." Validate with >1 run.
- **Context-dependent recipes**: "Add debugging import then solve" only works if debugging isn't already done. Tag prerequisites.
- **Brittle orderings**: "File A before File B" is fragile; "type-safe changes before behavior changes" is robust. Prefer semantic patterns.
- **Success bias**: A pattern that worked once might work for 10% of similar issues. Track base rate.

### Integration with Pattern Matching

Similarity matching finds candidate issues; pattern extraction ranks and formats the success recipes for injection. High-confidence patterns (effectiveness > 0.75, seen in >5 runs) should be injected first; lower-confidence patterns offered as alternatives.
