---
goal: "Build Loop Per-Iteration Adaptive Model Selection with Auto-Escalation

## Plan Summary
I now have a complete picture of the architecture. Here's the implementation plan.

---

## Implementation Plan: Build Loop Per-Iteration Adaptive Model Selection

### Socratic Design Refinement

**Minimum viable change**: Add `lib/loop-model-selection.sh` with position-based routing + stuck detection, source it in `sw-loop.sh`, call it before each `run_claude_iteration()` to update `MODEL`. The existing `lib/adaptive-model.sh` (reactive signal-based) stays untouched — the new module is a separate layer.

**Alternatives Considered**:

1. **Extend existing `lib/adaptive-model.sh`** — Add position-based routing to the existing `adaptive_model_select()`. Rejected: mixes two concerns (reactive signals vs. position-based routing), makes the function harder to test, and the issue explicitly asks for a NEW function in `lib/loop-model-selection.sh`.

2. **New `lib/loop-model-selection.sh` (chosen)** — Separate module that composes position-based routing with stuck detection. Calls into `adaptive-model.sh` for recording. Minimal blast radius: only `sw-loop.sh` needs a small integration patch. Trade-off: two model-selection modules to maintain, but each has a clear single responsibility.

3. **Integrate into `sw-model-router.sh`** — Use the existing router with a `--loop-tier` flag. Rejected: router is stage-level (called once per pipeline stage), not iteration-level. Would conflate two very different granularities.

### Component Diagram
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Build Loop Per-Iteration Adaptive Model Selection with Auto-Escalation
## Context
## Decision
### Component Diagram
### Interface Contracts
# loop_model_init(strategy?)
# Input:  optional strategy string ("default"|"aggressive"|"conservative")
#         Falls back to _config_get "loop.model_strategy" "default"
# Output: none
# Side effects: sets LOOP_MODEL_STRATEGY, LOOP_COST_HAIKU=0,
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 55,
      "summary": "Contains 5 documented failure patterns from previous builds (cleanup, feedback tests, mktemp, sed issues) with root causes. Critical for understanding when/how to escalate model selection and what types of failures recur."
    },
    {
      "file": "patterns.json",
      "relevance": 45,
      "summary": "Project configuration (Node.js, vitest, CommonJS imports, .test.js pattern) defines the test environment and command structure needed to inform per-iteration model selection decisions."
    },
    {
      "file": "decisions.json",
      "relevance": 18,
      "summary": "Would track previous model escalation decisions and auto-escalation triggers to inform future iterations, but currently empty. High potential value if populated."
    },
    {
      "file": "metrics.json",
      "relevance": 15,
      "summary": "Would provide baseline performance metrics for comparing model effectiveness across iterations, but currently empty. Relevant for escalation threshold decisions."
    },
    {
      "file": "global.json",
      "relevance": 8,
      "summary": "Would contain cross-repo patterns about model selection and escalation strategies, but is currently empty. Could be relevant if populated with insights from parallel builds."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Per-Iteration Adaptive Model Selection with Auto-Escalation — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Per-Iteration Adaptive Model Selection with Auto-Escalation

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/loop-model-selection.sh` with `loop_model_init`, `loop_model_for_position`, `loop_model_detect_stuck`, `loop_model_select`, `loop_model_track_cost`, `loop_model_summary`
- [ ] Task 2: Source `loop-model-selection.sh` in `sw-loop.sh` (line ~56)
- [ ] Task 3: Call `loop_model_init()` in `run_single_agent_loop()` initialization
- [ ] Task 4: Call `loop_model_select()` before `run_claude_iteration()` in the main loop, update `MODEL`
- [ ] Task 5: Call `loop_model_track_cost()` inside `accumulate_loop_tokens()`
- [ ] Task 6: Call `loop_model_summary()` in `show_summary()`
- [ ] Task 7: Add `loop.model_strategy` config to `.claude/daemon-config.json`
- [ ] Task 8: Add 12 new tests (21-32) to `sw-adaptive-model-test.sh`
- [ ] Task 9: Run existing test suite (`sw-adaptive-model-test.sh`) to verify no regressions
- [ ] Task 10: Run full `npm test` to verify no broader regressions

## Context
- Pipeline: standard
- Branch: feat/build-loop-per-iteration-adaptive-model-274
- Issue: #274
- Generated: 2026-03-15T01:04:46Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **cost-optimized-model-selection**: Core skill for implementing per-iteration model routing algorithm, stuck detection escalation logic, and cost tracking per model tier—directly addresses the issue's acceptance criteria.

## Cost-Optimized Model Selection Patterns

When implementing cost-aware model routing in agent loops, follow these patterns:

### 1. Per-Iteration Routing Decision Table

Define routing as a function of iteration count and total iterations, not just arbitrary logic. Example:

```
Iteration  | % of Loop | Model  | Rationale
1-2        | 0-20%     | haiku  | Planning + initial draft (fast feedback)
3 to N-20% | 20-80%    | sonnet | Main development work (good balance)
Final 20%  | 80-100%   | opus   | Edge cases + bug fixes (most capable)
```

Store in configuration as `loop_model_strategy` (e.g., "default", "aggressive", "conservative") rather than hardcoding, allowing tuning without code changes.

### 2. Cost Accounting Within the Loop

Track cost at two levels:
- **Per-tier**: Count tokens + cost for each model tier; write to a structured log (JSON) after each iteration
- **Per-loop**: Aggregate tier costs into a loop-level cost summary in the loop completion artifact

This enables post-hoc analysis: "Haiku iterations cost $0.02, Sonnet cost $0.15, Opus cost $0.30; total $0.47 for this loop."

### 3. Stuck Detection & Escalation

Implement as a heuristic scoring function:
1. Track convergence score from the loop's existing progress metrics (test pass rate, error count, etc.)
2. Detect no progress if the score hasn't improved for N consecutive iterations (default N=3)
3. Escalate to the next model tier: haiku→sonnet, sonnet→opus
4. Log escalations with reason (iteration count + convergence score) for debugging

Risk: False positives (escalate when not stuck) waste budget. Tune the window size and score threshold based on production data.

### 4. Graceful Fallback

If escalation tries to use a model that hits rate limits or is unavailable, fall back to the current tier (don't fail the loop). Log the fallback attempt.

### 5. Configuration Schema

Add to daemon-config.json under a `loop` object:

```json
{
  "loop": {
    "model_strategy": "default",
    "stuck_detection_window": 3,
    "cost_tracking_enabled": true
  }
}
```

Enable cost tracking by default; allow opt-out for cost-sensitive environments.

### 6. Integration with Existing Model Router

sw-model-router.sh handles global model selection (which model for which stage). This feature is more granular: which model for which iteration within the build stage. Call sw-model-router.sh with a new flag `--loop-tier` to get the model name for the current tier, allowing the two systems to compose cleanly.

### 7. Test Coverage

- **Unit tests**: Routing function returns correct model for (iteration_count, total_iterations, strategy) tuple
- **Integration tests**: Loop respects routing decisions; cost is tracked correctly
- **Scenario tests**: Stuck detection fires at the right time; false positives are rare

### 8. Observability

Emit structured events (via the event bus) for each routing decision and escalation:
- Event type: `loop_model_selected` or `loop_model_escalated`
- Payload: iteration, model, reason, cost_so_far

This enables dashboards to show "cost per model tier" and detect runaway escalations.
"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-15T01:18:22Z
last_iteration_at: 2026-03-15T01:18:22Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-15T01:18:22Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":341798,"duration_api_ms":317488,"num_turns":32,"resu

