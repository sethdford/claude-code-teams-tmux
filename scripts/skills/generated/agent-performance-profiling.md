## Agent Performance Profiling & Specialization Tuning

### Success Metric Definition
Define "success" explicitly before implementation—this cascades through the entire system. Options:
- **PR merge**: Coarse-grained, subject to human judgment on review
- **Tests passing + review approval**: Compound metric, harder to attribute
- **Code quality impact**: Measure test coverage delta, bug density in merged code (best for learning)
- **Speed + cost**: How fast did the agent complete, how much did it cost?

Recommendation: Use **test passing + review approval** as primary signal, with **code quality delta** as secondary signal for tie-breaking.

### Performance Matrix Schema
```json
{
  "agent_type": {
    "task_type": {
      "success_count": 42,
      "total_count": 50,
      "success_rate": 0.84,
      "avg_duration_seconds": 1245,
      "avg_cost_cents": 87,
      "last_updated": "2026-04-17T12:00:00Z",
      "confidence": 0.92
    }
  }
}
```

### Cold-Start Strategy
New agent types or task types have zero historical data:
1. **Fallback to parent task type** (e.g., "test_fix" → "test")
2. **Fallback to agent role similarity** (e.g., new builder variant → builder base rate)
3. **Decay recent failures**: If an agent type fails on all recent tasks, downweight its recommendations
4. **Confidence scoring**: Include `"confidence"` in matrix; only recommend agents with `confidence >= 0.8`

### Feedback Loop Prevention
- **Metric normalization**: Task complexity varies (some are 10x harder). Normalize success rate by task complexity estimate (from intelligence engine)
- **Distribution drift detection**: Alert if recommendation distribution changes >20% month-over-month
- **Audit trail**: Log every recommendation + outcome to detect systematic bias

### Recommendation Algorithm
1. For incoming task, extract features: task_type, complexity, file_types
2. Query performance matrix: agent_type → task_type → success_rate (with confidence check)
3. If exact match with confidence >= 0.8: return top-3 agents by success_rate
4. If no exact match: use pattern similarity to find similar task types, weight by similarity
5. Break ties by speed/cost efficiency
6. Always include fallback (random selection from available agents)

### Integration with Adaptive Pipeline
- Expose recommendation API: `GET /agent-performance/recommend?task_type=build_fix&complexity=high`
- Adaptive composer calls this API during pipeline generation
- Pass recommended agent type as hint to swarm orchestrator
- Track whether recommendation was accepted/rejected

### Metrics to Track
- Recommendation accuracy: % of recommended agents that succeeded
- Coverage: % of tasks for which confidence >= 0.8 recommendation exists
- Cold-start cost: how many tasks fail before new agent/task type pair gets confidence >= 0.8
- Diversity: ensure recommendations don't always suggest the same agent type
