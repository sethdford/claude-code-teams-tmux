# Fleet-Wide Pattern Mining & Knowledge Transfer Architecture

## Design Considerations

### Pattern Representation
- Store successful pipeline configurations as structured patterns: `{template, effort_levels, model_routing, iteration_count, success_rate, complexity_score, cost, applied_count}`
- Include metadata: repo context, issue characteristics (issue_type, complexity, domain), timestamp, success metrics
- Pattern should be repo-agnostic but include hints about applicability (complexity range, domains it worked for)

### Pattern Extraction
- Mine after each successful pipeline: extract the composed configuration, outcome metrics, and issue characteristics
- Use aggregation: similar successful runs should be deduplicated or merged (not one pattern per run)
- Include negative examples: unsuccessful patterns with root cause info prevent bad recommendations

### Similarity & Clustering
- Score new incoming issues against known patterns by: issue_type match, complexity range overlap, domain similarity
- Use clustering to group related patterns (e.g., all fast Go CLI builds, all complex React feature work)
- Rank recommendations by success rate, applicable success count, and cost efficiency

### Cross-Repo Knowledge Transfer
- Daemon checks pattern library before `sw-pipeline-composer` runs
- If incoming issue matches a pattern with >70% success rate and >5 applications, recommend it
- Fall back to composition if no high-confidence pattern exists
- Track pattern application: does recommended pattern lead to success?

### Storage & Performance
- Store in `~/.shipwright/fleet-patterns.json` (single file, ~1-10MB initially)
- Load once at daemon startup, cache in memory
- Pattern lookups should be O(1) or O(n) with n<1000 patterns
- No blocking I/O during pattern recommendation

### Metrics & Feedback Loop
- Track: pattern reuse count, success rate when applied, cost reduction vs. baseline
- Report: which patterns are most effective, where knowledge transfer succeeded across repos
- Self-tuning: deprecate patterns with <50% success rate after 10+ applications
- Monitor recommendation accuracy: what % of recommendations led to successful pipelines?

### Risk Mitigation
- Validate extracted patterns don't contain secrets or repo-specific paths
- Atomic writes to pattern library (tmp + mv)
- Schema versioning for forward compatibility
- Pattern library corruption detection (CRC or hash check)
- Graceful fallback if pattern library is missing or corrupted

### Integration Points
- `sw-daemon.sh`: check pattern library before issue triage
- `sw-pipeline-composer.sh`: accept recommended pattern as a starting point
- `sw-pipeline.sh`: record outcome after pipeline completion
- `sw-intelligence.sh`: feed successful patterns to predictive and adaptive modules
- `sw-memory.sh`: tie pattern effectiveness to repo-specific learnings
