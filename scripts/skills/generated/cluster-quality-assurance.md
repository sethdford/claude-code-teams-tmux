## Cluster Quality Assurance for Semantic Issue Clustering

Validating clustering quality is empirical, not theoretical. This skill provides validation frameworks for cluster stability, recommendation accuracy, and continuous learning health.

### Cluster Quality Metrics

**Silhouette Score** (per cluster): Measure -1 to 1 where >0.5 indicates cohesive clusters. Track over time—degradation signals clustering drift.

**Recommendation Match Rate**: % of new issues matching an existing cluster within confidence threshold (e.g., cosine similarity > 0.7). Target >70% match rate; <50% indicates poor cluster coverage.

**Success Rate per Cluster**: Track outcomes of issues recommended from each cluster. If cluster A's pattern succeeds 80% of the time, weight its recommendations higher. Update weekly.

**Intra-cluster Variance**: Average pairwise distance within cluster—should stay stable across re-clusterings. High variance = unstable cluster membership.

### Stability Testing

**Temporal Stability**: Re-cluster yesterday's events, compare cluster membership to previous week. >90% membership consistency is healthy. If consistency drops, clustering may be overfitting to recent data.

**Synthetic Perturbation**: Add 10% noise to TF-IDF vectors (randomly flip 10% of term weights), re-cluster, measure membership changes. Clusters should be robust to small input variations.

**Edge Case Coverage**: Track issues that fail to match any cluster (match_rate < 0.5). These are innovation opportunities—if >5% of issues are orphaned, clustering is too strict.

### Recommendation Validation

**A/B Testing**: For sampled new issues, show cluster-recommended config to 50% of agents, manual selection to control 50%. Track success rates, time-to-resolution, outcome quality. If cluster-recommended underperforms by >5%, pause recommendations and re-cluster.

**Offline Validation**: Replay historical issues through clustering, compare recommended configs to what was actually used. If recommendation accuracy is <60%, data quality or algorithm needs investigation.

**Failure Root Cause**: When a cluster-recommended pattern fails, investigate: was it a cluster mismatch (wrong issue matched to cluster) or a pattern failure (matched correct cluster but pattern didn't work for that specific issue)?

### Continuous Learning Health

**Weekly Re-clustering Checklist**:
1. Verify events.jsonl hasn't been corrupted (row count, JSON validity)
2. Run TF-IDF on new events—if vocabulary diverges >20% from previous week, alert (new issue types?)
3. Compare cluster centroids to previous week—if >30% of centroids moved >0.5 cosine distance, flag for manual review
4. Check for cluster merging/splitting—if two clusters converge, investigate why
5. Validate new clusters have >3 members (singletons don't constitute a pattern)

**Metrics Dashboard**: Track silhouette score, match rate, success rate per cluster, orphan rate, vocabulary drift over time. Alert if match rate drops >10% week-over-week or silhouette score declines.

### Implementation Priorities

1. **MVP**: Silhouette score + match rate tracking (1-2 day effort)
2. **Phase 2**: Success rate per cluster, A/B testing framework (3-4 days)
3. **Phase 3**: Temporal stability testing, automated re-clustering health checks (2-3 days)
