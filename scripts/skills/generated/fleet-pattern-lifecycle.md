## Fleet Pattern Lifecycle: Cross-Repo Learning Integration

### Pattern Lifecycle Phases

1. **Capture** (daemon completes successful build)
   - Extract: fix strategy, error signature, test approach, success metrics
   - Normalize: repo metadata (language, framework, dependencies)
   - Store: ~/.shipwright/fleet-memory/<pattern-id>.json with schema versioning
   - Index: commit to pattern-index.jsonl with hash for dedup

2. **Similarity Scoring**
   - Incoming issue: analyze error type, keywords, repo language/framework
   - Fleet search: find patterns in similar repos (score threshold configurable, default 0.65)
   - Rank: by recency, success rate, and similarity confidence
   - Return: top 5 patterns with explanations

3. **Injection**
   - Pipeline intake stage: query fleet patterns for similar issues
   - Prompt injection: "Fleet has 3 similar patterns from Go repos; use if applicable"
   - Tracking: log which patterns were considered and applied

4. **Application & Feedback**
   - Agent applies pattern, test results recorded
   - Success: pattern success_count++, update metrics
   - Failure: pattern failure_count++, error signature logged for future debugging

### Privacy Model

- **Opt-in/Opt-out**: Per-repo flag in fleet-config.json (`"share_patterns": true|false`, `"receive_patterns": true|false`)
- **Pattern Sanitization**: Strip repo paths, secrets, and identifying info before sharing
- **Access Control**: Only daemon agents can read fleet patterns; no direct human access
- **Audit Trail**: Pattern application logged in repo's local pipeline artifacts for compliance

### Schema & Storage

```json
{
  "pattern_id": "hash(repo_lang + error_type + fix_strategy)",
  "source_repo": "<hash of repo path>",
  "language": "go|javascript|python|...",
  "framework": "next|express|django|...",
  "error_type": "type mismatch|import not found|...",
  "error_signature": "<normalized error regex>",
  "fix_strategy": "<prose description>",
  "test_approach": "<how it was validated>",
  "success_count": 3,
  "failure_count": 0,
  "success_rate": 1.0,
  "first_seen": "2026-06-10T...",
  "last_applied": "2026-06-11T...",
  "keywords": ["auth", "session", "token"],
  "version": "1"
}
```

### Similarity Scoring Algorithm

Score = (language_match × 0.3) + (framework_match × 0.25) + (error_sig_match × 0.3) + (keyword_overlap × 0.15)

- **language_match**: 1.0 if same, 0.5 if same family (e.g., go/rust), 0.0 otherwise
- **framework_match**: 1.0 if exact, 0.7 if both present, 0.0 if either absent
- **error_sig_match**: Cosine similarity of error tokens normalized
- **keyword_overlap**: Jaccard similarity of issue keywords vs pattern keywords

### Metrics for Learning Impact

- **Application Rate**: % of issues that received relevant fleet patterns
- **Success Rate**: % of applied patterns that led to successful pipeline completion
- **Time Savings**: avg lead time with fleet patterns vs. baseline (tracked per issue)
- **Reach**: % of repos using patterns from outside their primary language/framework
- **Freshness**: % of patterns applied within 30 days of creation

### CLI Integration

```bash
shipwright fleet patterns list [--repo <name>] [--language go] [--framework] [--sort success_rate|last_applied]
shipwright fleet patterns apply <pattern-id>              # Manually trigger pattern application
shipwright fleet patterns remove <pattern-id>             # Prune outdated patterns
shipwright fleet patterns stats                           # Show learning metrics
shipwright fleet patterns config --opt-in|--opt-out       # Toggle sharing for this repo
```

### Implementation Notes

- Pattern index lives in memory for fast similarity queries; persist to events.jsonl on daemon shutdown
- Similarity scoring runs in build loop intake phase (before planning), so agents see relevant patterns early
- Failed patterns still counted (for learning), but success_rate < 0.3 triggers audit (human review before fleet-wide sharing)
- Daemon auto-prunes patterns with success_rate < 0.1 and age > 90 days (configurable)
