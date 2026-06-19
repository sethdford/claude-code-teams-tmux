# Implementation Plan: Semantic Issue Clustering Engine

**Issue**: #672  
**Goal**: Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines  
**Status**: PLAN PHASE  
**Created**: 2026-06-19  
**Complexity**: Standard (but data-pipeline heavy)

---

## Requirements Analysis

### Explicit Requirements (from Issue)

✓ **Clustering Algorithm**: TF-IDF + cosine similarity on issues from `events.jsonl`  
✓ **Storage**: Clusters in `~/.shipwright/issue-clusters.json` with success rate per cluster  
✓ **Pattern Matching**: Match new issues to nearest cluster, recommend proven approach  
✓ **Continuous Learning**: Re-cluster weekly to adapt  
✓ **Metrics**: Track cluster match rate and success rate improvement

### Implicit Requirements (derived from context)

1. **Graceful degradation**: System works with any number of historical issues (including zero)
2. **No external package bloat**: Prefer Node.js `npm` packages; keep bash/shell utilities minimal
3. **Atomic writes**: Cluster file writes must be transactional (temp file + `mv`) to avoid corruption
4. **Bash 3.2 compatibility**: Shell orchestrator must follow Shipwright conventions
5. **Integration points**: Must connect to daemon patrol (for proactive recommendations) and memory system
6. **Configuration**: Clustering behavior controlled via `daemon-config.json`
7. **Observability**: All operations logged to events.jsonl with success/failure markers
8. **Performance**: Re-clustering < 5 seconds for typical repos (< 1000 issues)

---

## Design Alternatives Considered

### Alternative A: Pure Bash Implementation

- **Approach**: Implement TF-IDF and cosine similarity using bash + awk/sed
- **Pros**: No external dependencies, single language
- **Cons**:
  - Complex implementation (10+ functions just for vectorization)
  - Fragile (edge cases with special characters, large numbers)
  - Maintenance nightmare (hard to debug)
  - Performance: O(n²) even for 100 issues
- **Blast radius**: Medium (contained to new script, no changes to existing code)
- **Recommendation**: ❌ Not chosen — maintenance burden outweighs benefits

### Alternative B: Bash Orchestrator + Node.js Algorithm (CHOSEN)

- **Approach**:
  - Bash wrapper (`sw-issue-clustering.sh`) handles orchestration, cron scheduling, atomicity
  - Node.js module (`src/issue-clustering.js`) implements TF-IDF, clustering, scoring
  - Integration into daemon patrol via existing `lib/daemon-patrol.sh`
- **Pros**:
  - TF-IDF and cosine similarity leverage existing npm packages (no reinvention)
  - Separation of concerns (orchestration vs. algorithm)
  - Easy to test (unit tests in Jest/vitest)
  - Maintainable (algorithm logic in JS, integration in bash)
  - Consistent with existing Shipwright architecture
- **Cons**:
  - Two languages (bash + Node.js)
  - Need to bridge bash ↔ Node.js via JSON stdin/stdout
- **Blast radius**: Low (new files, small changes to daemon-patrol.sh)
- **Recommendation**: ✅ Chosen — best balance of simplicity, maintainability, performance

### Alternative C: K-NN On-Demand Matching (No Clustering)

- **Approach**: When new issue arrives, find K nearest neighbors from all historical issues; recommend their successful approaches
- **Pros**:
  - Simpler than clustering (no need to partition issues)
  - Always up-to-date (no weekly re-clustering)
  - Lower memory (no cluster storage)
- **Cons**:
  - O(n) similarity computation per match (vs. O(1) with pre-computed clusters)
  - Doesn't fulfill issue requirement for "cluster storage"
  - Can't track "cluster success rate" (no clusters)
- **Blast radius**: Very low (single module, no integration changes)
- **Recommendation**: ❌ Not chosen — doesn't meet acceptance criteria for cluster storage

---

## Architecture Design

### Data Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ events.jsonl (INGESTION)                                         │
│ ├─ issue_created (title, description, labels, repo, files)      │
│ ├─ issue_processed (root_cause, fix_applied)                    │
│ ├─ pipeline_completed (success/failure, duration)                │
│ └─ pattern_matched (cluster_id, similarity_score)                │
└────────────────┬─────────────────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────────────────┐
│ sw-issue-clustering.sh (ORCHESTRATOR)                            │
│ ├─ Read events.jsonl (last N events)                             │
│ ├─ Call node src/issue-clustering.js cluster                     │
│ ├─ Atomic write to issue-clusters.json                           │
│ └─ Log completion event                                          │
└────────────────┬─────────────────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────────────────┐
│ src/issue-clustering.js (ALGORITHM)                              │
│ ├─ Parse events JSON                                             │
│ ├─ Extract title + description + error for each issue            │
│ ├─ TF-IDF vectorization (using npm package)                      │
│ ├─ Compute cosine similarity matrix                              │
│ ├─ Hierarchical clustering (linkage) OR K-means                  │
│ ├─ Compute cluster metadata (size, success_rate)                 │
│ └─ Output clusters JSON to stdout                                │
└────────────────┬─────────────────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────────────────┐
│ ~/.shipwright/issue-clusters.json (STORAGE)                      │
│ {                                                                │
│   "generated_at": "2026-06-19T01:30:00Z",                        │
│   "algorithm_version": "1",                                      │
│   "total_issues": 42,                                            │
│   "clusters": [                                                  │
│     {                                                            │
│       "id": "cluster-001",                                       │
│       "size": 5,                                                 │
│       "success_rate": 0.8,                                       │
│       "representative_title": "API timeout in auth module",      │
│       "issue_ids": ["issue-1", "issue-5", ...],                  │
│       "common_files": ["scripts/sw-daemon.sh", ...],             │
│       "common_error_signature": "SIGKILL, timeout",              │
│       "recommended_template": { /* config */ }                   │
│     },                                                           │
│     ...                                                          │
│   ]                                                              │
│ }                                                                │
└──────────────────────────────────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────────────────┐
│ lib/daemon-patrol.sh (INTEGRATION)                               │
│ ├─ On new issue spawn: load issue-clusters.json                  │
│ ├─ Match new issue to cluster (similarity score)                 │
│ ├─ If similarity >= threshold: inject cluster pattern            │
│ │  ├─ Recommended config
│ │  ├─ Past successful approaches
│ │  └─ Confidence tag
│ │
│ ├─ Log pattern injection event
│ └─ Track match outcome (prevention, failure, ignored)
└──────────────────────────────────────────────────────────────────┘
```

### Schema Design

**events.jsonl** (new event types):

```json
{
  "type": "issue_clustering_started",
  "ts": "2026-06-19T01:30:00Z",
  "repository": "sethdford/shipwright",
  "event_count": 42
}

{
  "type": "issue_clustering_completed",
  "ts": "2026-06-19T01:30:05Z",
  "cluster_count": 7,
  "avg_cluster_size": 6,
  "success": true,
  "duration_s": 5.2
}

{
  "type": "pattern_matched",
  "ts": "2026-06-19T01:31:00Z",
  "issue_id": "issue-43",
  "cluster_id": "cluster-002",
  "similarity_score": 0.87,
  "confidence_tier": "high",
  "recommendation_applied": true
}
```

**issue-clusters.json** schema:

```json
{
  "version": "1",
  "generated_at": "2026-06-19T01:30:05Z",
  "metadata": {
    "algorithm": "hierarchical-clustering",
    "distance_metric": "cosine",
    "vectorization": "tf-idf",
    "total_issues_processed": 42,
    "min_cluster_size": 2
  },
  "clusters": [
    {
      "id": "cluster-001",
      "centroid_vector": [0.15, 0.23, ...],
      "size": 5,
      "silhouette_score": 0.72,
      "success_metrics": {
        "success_count": 4,
        "total_count": 5,
        "success_rate": 0.8,
        "avg_resolution_time_hours": 2.3
      },
      "representative": {
        "issue_id": "issue-1",
        "title": "API timeout in auth daemon",
        "description": "Daemon crashes with SIGKILL after 2 hours"
      },
      "issue_ids": ["issue-1", "issue-5", "issue-12", "issue-18", "issue-33"],
      "common_files": [
        "scripts/sw-daemon.sh",
        "scripts/lib/daemon-dispatch.sh"
      ],
      "common_error_signature": {
        "patterns": ["SIGKILL", "timeout", "OOM"],
        "frequency": [5, 4, 3]
      },
      "recommended_approach": {
        "root_cause": "Memory leak in event loop under load",
        "applied_fixes": [
          "Add memory profiling checkpoint",
          "Implement garbage collection trigger",
          "Reduce event batch size"
        ],
        "config_override": {
          "poll_interval": 120,
          "max_parallel": 1,
          "gc_interval_minutes": 5
        }
      }
    }
  ],
  "metadata_v2": {
    "clustering_time_s": 5.2,
    "last_re_cluster": "2026-06-19T01:30:05Z",
    "next_re_cluster": "2026-06-26T01:30:05Z",
    "notes": "Weekly clustering enabled; manual trigger via 'shipwright clustering --now'"
  }
}
```

---

## Implementation Tasks

### Task 1: Research & Select Dependencies

**Depends on**: Nothing  
**Blocks**: Tasks 2-3  
**Effort**: 1-2 hours

Select npm packages for TF-IDF and clustering:

- **TF-IDF**: `natural` (popular, well-maintained) OR `tfidf-vectorizer` (minimal)
- **Clustering**: `ml-hclust` (hierarchical) OR `ml-kmeans` (k-means)
- **Distance**: `ml-distance` (cosine similarity included)

Decision: Use `natural` for TF-IDF (battle-tested, includes stemming for better text analysis).

### Task 2: Create src/issue-clustering.js (Core Algorithm)

**Depends on**: Task 1  
**Blocks**: Tasks 4, 5  
**Effort**: 4-6 hours

Implement the clustering module:

```javascript
// src/issue-clustering.js
module.exports = {
  // Parse events from stdin, return clusters
  clusterIssues(events, options),

  // Match a new issue to nearest cluster
  matchIssueToCluster(issue, clusters, threshold),

  // Score similarity between two issues
  computeSimilarity(issue1, issue2),

  // Extract issue vector from text
  vectorizeIssue(title, description, errorMessage)
}
```

Key implementations:

- **Vectorization**: Combine title + description + error message; use `natural`'s TF-IDF
- **Clustering**: Use hierarchical agglomerative clustering (linkage = "average")
- **Similarity scoring**: Cosine similarity (0.0-1.0 scale)
- **Cluster metadata**: Compute success rate from events, pick representative issue
- **Error handling**: Validate JSON input, graceful degradation on empty input

### Task 3: Create scripts/sw-issue-clustering.sh (Orchestrator)

**Depends on**: Task 1  
**Blocks**: Task 6  
**Effort**: 2-3 hours

Implement bash wrapper:

```bash
#!/bin/bash
VERSION="3.3.0"
set -euo pipefail
source scripts/lib/compat.sh

_clustering_run() {
  local events_file="$HOME/.shipwright/events.jsonl"
  local output_file="$HOME/.shipwright/issue-clusters.json"
  local temp_file="${output_file}.tmp.$$"

  # Validate events file exists and is readable
  if [[ ! -f "$events_file" ]]; then
    warn "No events.jsonl found at $events_file"
    return 1
  fi

  # Read last N events (configurable, default 500)
  local max_events=$(_smart_int "clustering" "max_events" 500)
  tail -n "$max_events" "$events_file" | jq -s '.' > /tmp/events-batch.$$.json

  # Run clustering algorithm (Node.js)
  if ! node src/issue-clustering.js < /tmp/events-batch.$$.json > "$temp_file" 2>/dev/null; then
    error "Clustering algorithm failed"
    rm -f "$temp_file" /tmp/events-batch.$$.json
    return 1
  fi

  # Atomic write (move temp to real file)
  mv "$temp_file" "$output_file"

  # Emit success event
  emit_event "issue_clustering_completed" \
    "cluster_count=$(jq '.clusters | length' "$output_file")" \
    "duration_s=$SECONDS"

  success "Clustering complete"
}

# Subcommands
case "${1:-}" in
  run) _clustering_run ;;
  match) _clustering_match "$2" "$3" ;;  # issue_id, cluster_file
  show) jq '.' ~/.shipwright/issue-clusters.json ;;
  *) echo "Usage: $0 {run|match|show}" ;;
esac
```

Key features:

- Load config from `daemon-config.json` (clustering enabled/disabled, max events, threshold)
- Atomic writes (write to temp, then `mv`)
- Lock file to prevent concurrent runs
- Emit events to events.jsonl for observability
- Validation of output JSON before commit

### Task 4: Create src/issue-clustering.test.js (Unit Tests)

**Depends on**: Task 2  
**Blocks**: Task 5  
**Effort**: 3-4 hours

Test cases (using vitest):

```javascript
// TF-IDF vectorization
describe("vectorizeIssue", () => {
  test("creates vector from title, description, error", () => {...})
  test("handles empty input gracefully", () => {...})
  test("normalizes text (lowercase, punctuation)", () => {...})
})

// Similarity scoring
describe("computeSimilarity", () => {
  test("returns 1.0 for identical issues", () => {...})
  test("returns 0.0 for completely different issues", () => {...})
  test("returns 0.5-0.8 for similar issues", () => {...})
})

// Clustering
describe("clusterIssues", () => {
  test("creates at least 1 cluster for N issues", () => {...})
  test("respects min_cluster_size config", () => {...})
  test("computes cluster success_rate correctly", () => {...})
  test("returns empty clusters for empty input", () => {...})
  test("handles issues with missing fields", () => {...})
})

// Matching
describe("matchIssueToCluster", () => {
  test("finds nearest cluster with high similarity", () => {...})
  test("returns null if no cluster exceeds threshold", () => {...})
  test("includes confidence_tier (high/medium/low)", () => {...})
})
```

### Task 5: Create scripts/sw-issue-clustering-test.sh (Integration Tests)

**Depends on**: Tasks 2, 3  
**Blocks**: Task 6  
**Effort**: 2-3 hours

Test orchestration:

```bash
test_clustering_reads_events() {
  # Create fake events.jsonl
  # Run clustering
  # Verify clusters.json produced
  # Verify event was logged
}

test_clustering_atomic_writes() {
  # Start clustering
  # Kill midway (simulate crash)
  # Verify no partial writes (temp file cleaned up)
}

test_clustering_respects_config() {
  # Set daemon-config.json clustering threshold
  # Run clustering with specific threshold
  # Verify threshold applied
}

test_clustering_graceful_empty() {
  # Empty events.jsonl
  # Run clustering
  # Verify doesn't crash, returns empty clusters
}
```

### Task 6: Integrate into Daemon Patrol

**Depends on**: Tasks 3, 5  
**Blocks**: Task 8  
**Effort**: 2-3 hours

Modify `scripts/lib/daemon-patrol.sh`:

```bash
_patrol_pattern_matching() {
  local issue_id="$1"
  local clusters_file="$HOME/.shipwright/issue-clusters.json"

  # Skip if clustering disabled
  if [[ "$(_smart_int "clustering" "enabled" 0)" != "1" ]]; then
    return 0
  fi

  # Skip if clusters stale (> 10 days)
  local generated_at=$(jq -r '.generated_at' "$clusters_file")
  local age_days=$(( ($(date +%s) - $(date -d "$generated_at" +%s)) / 86400 ))
  if (( age_days > 10 )); then
    warn "Clusters > 10 days old, skipping pattern matching"
    return 0
  fi

  # Match issue to cluster
  local match=$(node src/issue-clustering.js match "$issue_id" < "$clusters_file")
  if [[ -z "$match" ]]; then
    return 0  # No match
  fi

  # Extract cluster_id, similarity_score, recommendations
  local cluster_id=$(echo "$match" | jq -r '.cluster_id')
  local similarity=$(echo "$match" | jq -r '.similarity_score')

  # Inject recommendations into context
  local recommendations=$(echo "$match" | jq -r '.recommended_approach')
  emit_event "pattern_matched" \
    "issue_id=$issue_id" \
    "cluster_id=$cluster_id" \
    "similarity_score=$similarity"

  # Return recommendations (caller injects into pipeline context)
  echo "$recommendations"
}
```

### Task 7: Add Weekly Re-Clustering Schedule

**Depends on**: Task 3  
**Blocks**: Nothing  
**Effort**: 1 hour

Modify `scripts/sw-daemon.sh` to add cron-like scheduling:

```bash
_daemon_check_clustering_schedule() {
  local last_cluster=$(<~/.shipwright/.clustering-last-run || echo "0")
  local now=$(date +%s)
  local interval=$((7 * 24 * 60 * 60))  # 7 days in seconds

  if (( now - last_cluster > interval )); then
    info "Re-clustering due (last run: $((now - last_cluster))s ago)"
    scripts/sw-issue-clustering.sh run
    echo "$now" > ~/.shipwright/.clustering-last-run
  fi
}
```

Call `_daemon_check_clustering_schedule` once per daemon poll cycle.

### Task 8: Add Clustering Configuration to daemon-config.json

**Depends on**: Task 6  
**Blocks**: Task 9  
**Effort**: 0.5 hours

Add schema:

```json
{
  "clustering": {
    "enabled": true,
    "max_events": 500,
    "min_cluster_size": 2,
    "similarity_threshold": 0.7,
    "confidence_tiers": {
      "high": 0.85,
      "medium": 0.7,
      "low": 0.5
    },
    "algorithm": "hierarchical",
    "re_cluster_interval_days": 7,
    "max_clusters": 50
  }
}
```

### Task 9: Documentation & Observability

**Depends on**: Task 8  
**Blocks**: Task 10  
**Effort**: 1-2 hours

Add to `.claude/CLAUDE.md`:

```markdown
## Issue Clustering Engine

### Commands

- `shipwright clustering run` — Trigger immediate re-clustering
- `shipwright clustering show` — Display current clusters
- `shipwright clustering match <issue>` — Match issue to cluster

### Integration

The clustering engine runs weekly (configurable in `daemon-config.json` → `clustering.re_cluster_interval_days`). When a new issue arrives during pipeline spawn, the daemon patrol automatically matches it to the nearest cluster and injects recommended approaches into the pipeline context.

### Metrics

- **cluster_match_rate**: % of new issues matched to clusters (goal: > 60%)
- **cluster_success_rate**: % of recommendations that prevented/reduced failures (goal: > 50%)
- **clustering_time_s**: Time to re-cluster (goal: < 5s for < 1000 issues)

### Configuration

Threshold (`similarity_threshold`) controls match sensitivity:

- **< 0.50**: Too low, many false matches
- **0.60-0.75**: Recommended, balanced sensitivity
- **> 0.85**: Too high, few matches

Monitor `false_positive_rate` in daemon logs. If > 15%, lower threshold gradually.
```

### Task 10: Manual Testing (Smoke Test)

**Depends on**: Task 9  
**Blocks**: Task 11  
**Effort**: 1 hour

Test scenario:

1. Ensure `~/.shipwright/events.jsonl` has 10+ events
2. Run `shipwright clustering run`
3. Verify `issue-clusters.json` created with valid JSON
4. Verify events logged (`issue_clustering_completed`, `pattern_matched`)
5. Manually test matching: create fake issue, run matching logic, verify cluster recommended

### Task 11: End-to-End Test with Daemon

**Depends on**: Task 10  
**Blocks**: Task 12  
**Effort**: 2-3 hours

Full integration test:

1. Start daemon with clustering enabled
2. Create 3 similar issues in memory (simulated)
3. Verify daemon picks one issue, clusters run
4. Verify new issue matched to cluster
5. Verify recommendations injected into pipeline context
6. Verify pipeline completes and outcome logged

### Task 12: Code Review & Simplification

**Depends on**: Task 11  
**Blocks**: Task 13  
**Effort**: 1-2 hours

- Simplify bash orchestrator (fewer edge cases)
- Remove over-engineering (unused config options)
- Add JSDoc comments to Node.js functions
- Verify bash 3.2 compatibility (no `declare -A`, no `readarray`)
- Check all jq calls use `--arg` for escaping

### Task 13: Merge & Deploy

**Depends on**: Task 12  
**Blocks**: Nothing  
**Effort**: 1 hour

- [ ] Open PR with description and metrics
- [ ] Pass all tests
- [ ] Code review approval
- [ ] Merge to main
- [ ] Update version in package.json (minor bump)

---

## Testing Approach

### Unit Tests

- **Framework**: vitest (existing)
- **Coverage target**: 85% for src/issue-clustering.js
- **Test data**: Mocked events with known clustering outcome
- **Run**: `npm test` includes `src/issue-clustering.test.js`

### Integration Tests

- **Framework**: bash test harness (existing pattern)
- **File**: `scripts/sw-issue-clustering-test.sh`
- **Mock data**: Temporary events.jsonl with 50 sample issues
- **Validates**: Clustering produces valid JSON, meets performance targets, handles errors
- **Run**: `bash scripts/sw-issue-clustering-test.sh`

### E2E Test with Daemon

- **File**: Part of `scripts/sw-daemon-test.sh`
- **Scenario**: Full daemon cycle with clustering enabled
- **Validates**: Clustering runs on schedule, pattern matching works, recommendations injected
- **Run**: Already part of `npm test` pipeline

### Performance Benchmarks

- 100 issues: < 1s
- 500 issues: < 3s
- 1000 issues: < 5s
- 5000 issues: < 15s (acceptable degradation)

---

## Definition of Done

### Functional Requirements

- [ ] Clusters generated from events.jsonl using TF-IDF + cosine similarity ✓
- [ ] Clusters stored in ~/.shipwright/issue-clusters.json ✓
- [ ] Cluster schema includes: id, size, success_rate, representative_issue, common_files, recommended_approach ✓
- [ ] New issues matched to nearest cluster with similarity score >= threshold ✓
- [ ] Cluster-based recommendations injected into pipeline context ✓
- [ ] Re-clustering triggered weekly (or manual via CLI) ✓
- [ ] Metrics tracked: cluster_match_rate, cluster_success_rate, clustering_time_s ✓
- [ ] Configuration exposed in daemon-config.json ✓

### Non-Functional Requirements

- [ ] Zero regressions: All existing tests pass ✓
- [ ] Performance: Re-clustering < 5s for 1000 issues ✓
- [ ] Reliability: Atomic writes (no partial/corrupted files) ✓
- [ ] Bash 3.2 compatible (no associative arrays, no readarray) ✓
- [ ] Code review passed (simplicity, maintainability, security) ✓
- [ ] Unit test coverage > 85% ✓
- [ ] Integration tests passing ✓
- [ ] E2E daemon test passing ✓

### Documentation

- [ ] Auto-sync section in CLAUDE.md ✓
- [ ] README updated with `shipwright clustering` commands ✓
- [ ] JSDoc comments on Node.js functions ✓
- [ ] Bash script header with VERSION and purpose ✓
- [ ] Configuration schema documented in daemon-config.json ✓

### Observability

- [ ] Events logged: issue_clustering_started, issue_clustering_completed, pattern_matched ✓
- [ ] Error logs include: reason, input_size, retry_count ✓
- [ ] Metrics dashboard updated (cluster_match_rate, success_rate) ✓
- [ ] Memory usage < 512MB for 5000 issues ✓

---

## Failure Mode Analysis

### Critical Failure 1: Race Condition on Cluster File Write

**What breaks**: Two daemon workers run clustering simultaneously (e.g., via cron on different machines or staggered polling). Both write to `~/.shipwright/issue-clusters.json`. The second write overwrites the first's clusters. If another process reads the file mid-write, it gets partial/corrupted JSON.

**How this manifests**:

- Daemon 1 finishes clustering, starts writing 100KB file
- Daemon 2 starts clustering, also writes to same file
- File ends up 50KB (truncated), invalid JSON
- Next pattern matching call fails with jq error or uses stale data
- Silent failure: pipeline proceeds without cluster recommendations

**Mitigation**:

1. **Atomic writes**: Always write to temp file (`issue-clusters.json.tmp.$$`), then `mv` (atomic on POSIX)
   ```bash
   node src/issue-clustering.js > "$temp_file"
   mv "$temp_file" "$output_file"  # Atomic
   ```
2. **Lock file**: Check for lock before starting clustering
   ```bash
   if [[ -f ~/.shipwright/.clustering.lock ]]; then
     sleep 5 && retry  # Simple retry
   fi
   echo $$ > ~/.shipwright/.clustering.lock
   trap 'rm -f ~/.shipwright/.clustering.lock' EXIT
   ```
3. **Versioning**: Keep multiple cluster versions (clusters-v1.json, clusters-v2.json), use symlink to active
   ```bash
   version=$(($(cat ~/.shipwright/.cluster-version || echo 0) + 1))
   mv "$temp_file" "issue-clusters-v$version.json"
   ln -sf "issue-clusters-v$version.json" "issue-clusters.json"
   ```

**Most critical**: Atomic write (mv) is sufficient for single-machine daemon. For multi-machine daemon, add lock file + retry.

---

### Critical Failure 2: TF-IDF Vectorization Memory Explosion

**What breaks**: With 5000+ issues, TF-IDF vectorization creates a dense matrix (5000 × 10000 vocabulary). Node.js heap explodes (typical limit 2GB). Clustering never completes; heap OOM crash. Stale clusters remain. New issues get no recommendations.

**How this manifests**:

- Daemon calls clustering with 5000 events
- TF-IDF builds vocabulary (10,000+ unique terms)
- Creates vectors × 5000 matrix in memory
- Node runs out of memory (E_NOMEM or heap limit exceeded)
- Process exits 137 (SIGKILL), no output
- Clustering marked as failed; next re-cluster attempt also fails

**Mitigation**:

1. **Stream processing**: Process in chunks of 500 issues, keep only recent issues
   ```javascript
   const recentEvents = events.slice(Math.max(0, events.length - MAX_EVENTS));
   ```
2. **Sparse vectors**: Only store non-zero TF-IDF values, not full dense matrix
3. **Memory limit**: Run Node with cgroup limit: `node --max-old-space-size=512 src/issue-clustering.js`
4. **Monitoring**: Check memory before vectorization
   ```bash
   available_mb=$(free | awk 'NR==2 {print $7}')
   if (( available_mb < 256 )); then
     error "Insufficient memory for clustering (available: ${available_mb}MB)"
     return 1
   fi
   ```
5. **Graceful degradation**: If memory low, fall back to K-NN matching instead of re-clustering

**Most critical**: Limit to recent 500 issues (config `max_events`). Monitor memory. If < 256MB available, skip clustering.

---

### Critical Failure 3: Incorrect Similarity Threshold Leading to Bad Recommendations

**What breaks**: Threshold set too low (0.40), or too high (0.95). Either way, clusters don't help:

- **Too low (0.40)**: Every new issue matches every cluster (false positives). Recommendations are noisy, wrong approaches applied, builds fail.
- **Too high (0.95)**: No issues ever match (false negatives). Clustering unused, no benefit.

**How this manifests**:

- **Low threshold**: 80% of new issues matched, but recommendations wrong → build failure rate increases instead of decreases
- **High threshold**: 5% of new issues matched → "clustering not helping" conclusion, feature disabled
- **Outcome**: Either wasted recommendations (low) or no value (high)
- **Metric impact**: false_positive_rate > 15% OR cluster_match_rate < 10%

**Mitigation**:

1. **Configurable threshold**: `daemon-config.json` → `clustering.similarity_threshold` (default 0.70)
   ```json
   "clustering": { "similarity_threshold": 0.70 }
   ```
2. **Confidence tiers**: Match with confidence score
   ```json
   "confidence_tiers": {
     "high": 0.85,      // Apply immediately
     "medium": 0.70,    // Optional (human decides)
     "low": 0.50        // Skip (too uncertain)
   }
   ```
3. **Metrics tracking**: Log false_positive_rate
   - Track: "recommended approach applied" + "outcome = failure" → false positive
   - Alert if > 15%
4. **A/B testing**: Daemon can test different thresholds on subset of issues
   ```bash
   if (( RANDOM % 100 < AB_TEST_RATIO )); then
     use_threshold=0.65  # Test threshold
   fi
   ```
5. **Adaptive tuning**: `sw-self-optimize.sh` can adjust threshold based on CFR (change failure rate)

**Most critical**: Start conservative (threshold 0.75). Track false_positive_rate. Lower if > 80% of recommendations succeed.

---

### Secondary Failure 4: events.jsonl Parsing Failure

**What breaks**: If events.jsonl is corrupted (truncated write, invalid JSON), `jq` silently fails or produces incomplete results. Clustering runs on partial data, produces clusters from wrong events. Or clustering fails silently, no error logged.

**How this manifests**:

- Pipeline crash, daemon writes partial event to events.jsonl (file descriptor not flushed)
- `jq` can't parse last line (incomplete JSON)
- Clustering gets 99 events instead of 100 (silent data loss)
- Clusters computed from wrong subset
- Pattern matching recommends wrong approaches

**Mitigation**:

1. **Validate before processing**:
   ```bash
   jq empty < "$events_file" || {
     error "events.jsonl is invalid JSON"
     return 1
   }
   ```
2. **Keep backup**: Copy last known-good state
   ```bash
   cp "$clusters_file" "$clusters_file.backup"
   ```
3. **Fallback on error**: If clustering fails, use backup from 24h ago
4. **Skip malformed lines**: Instead of failing, log and skip
   ```javascript
   const events = lines
     .map((line) => {
       try {
         return JSON.parse(line);
       } catch {
         console.warn(`Skipped invalid line: ${line}`);
         return null;
       }
     })
     .filter(Boolean);
   ```
5. **Checksum validation**: Store SHA256 of last processed events.jsonl; on next run, verify no truncation

**Most critical**: Validate with `jq empty` before processing. Fallback to backup if clustering fails.

---

### Secondary Failure 5: Stale Clusters Not Refreshed

**What breaks**: Weekly re-clustering schedule misses (daemon not running, network outage, clustering disabled by mistake). Clusters become 10+ days old. New issues matched to outdated patterns. Success rate inflated (old patterns don't capture recent patterns).

**How this manifests**:

- Last re-cluster: 2026-06-12
- Today: 2026-06-19
- 20 new issues arrived since last cluster
- New issues matched to old clusters (missing context)
- Recommendations based on old patterns, don't apply to recent issues
- Surprise failures 2 weeks later when old pattern finally breaks

**Mitigation**:

1. **Timestamp clusters**:
   ```json
   {
     "generated_at": "2026-06-19T01:30:00Z",
     "next_re_cluster": "2026-06-26T01:30:00Z"
   }
   ```
2. **Age check before matching**: If > 10 days old, skip pattern matching
   ```bash
   age_days=$(( ($(date +%s) - $(date -d "$generated_at" +%s)) / 86400 ))
   if (( age_days > 10 )); then
     warn "Clusters stale, skipping pattern matching"
     return 0
   fi
   ```
3. **On-demand re-cluster**: If clusters stale, trigger immediate re-cluster
   ```bash
   if (( age_days > 10 )); then
     scripts/sw-issue-clustering.sh run &  # Background
   fi
   ```
4. **Health check in daemon**: Patrol checks cluster age; if stale, alert
5. **Keep historical versions**: Store clusters-YYYY-MM-DD.json for debugging

**Most critical**: Check cluster age before matching. If > 10 days, skip or trigger immediate re-cluster.

---

## Alternative Approaches (Rejected)

### Approach: K-NN Only (No Clustering)

_Rejected because issue requires cluster storage and cluster-level success rates_

### Approach: Pre-computed Similarity Cache

_Rejected because O(n²) space (50k issues = 2.5B similarities); better to recompute on demand_

### Approach: Elasticsearch + Kibana

_Rejected because over-engineered for Shipwright's scale; local JSON sufficient_

### Approach: Manual Cluster Definitions

_Rejected because defeats "continuous learning"; patterns must adapt weekly_

---

## Task Dependencies Graph

```
Task 1 (Dependencies)
  ├─→ Task 2 (Algorithm)
  │    ├─→ Task 4 (Unit Tests)
  │    │    └─→ Task 5 (Integration Tests)
  │    │         └─→ Task 6 (Daemon Patrol)
  │    │              └─→ Task 11 (E2E Daemon)
  │    └─→ Task 3 (Orchestrator)
  │         └─→ Task 5 (Integration Tests)
  │              └─→ Task 6 (Daemon Patrol)
  │                   └─→ Task 11 (E2E Daemon)
  └─→ Task 3 (Orchestrator)
       └─→ Task 7 (Re-clustering Schedule)
            └─→ Task 11 (E2E Daemon)
       └─→ Task 3 (Orchestrator)
            └─→ Task 8 (Config Schema)
                 └─→ Task 9 (Documentation)
                      └─→ Task 10 (Smoke Test)
                           └─→ Task 11 (E2E Daemon)
                                └─→ Task 12 (Code Review)
                                     └─→ Task 13 (Merge)
```

**Critical path**: Task 1 → Task 2 → Task 4 → Task 5 → Task 6 → Task 11 → Task 12 → Task 13  
**Estimated duration**: 20-25 hours  
**Parallelizable**: Task 3 and Task 2 can run in parallel after Task 1

---

## Data Migration & Rollback

### Forward Migration (Deployment)

1. Create `issue-clusters.json` with empty clusters (backward compatible)
2. Enable clustering in `daemon-config.json` → `clustering.enabled = true`
3. First daemon poll triggers `sw-issue-clustering.sh run`
4. Clusters populate over 5-30s
5. Pattern matching begins automatically

### Rollback Strategy

If clustering causes issues:

1. `shipwright clustering show` to verify current clusters
2. `daemon-config.json` → `clustering.enabled = false` (disables all matching)
3. Delete `~/.shipwright/issue-clusters.json` (falls back to no clusters)
4. No data loss (events.jsonl unchanged)
5. Daemon continues without pattern matching (no regression to existing behavior)

---

## Success Metrics & Monitoring

### Primary Metrics

| Metric                   | Goal  | How to Measure                                   |
| ------------------------ | ----- | ------------------------------------------------ |
| **cluster_match_rate**   | > 60% | (new_issues_matched / new_issues_total)          |
| **cluster_success_rate** | > 50% | (recommendations_worked / recommendations_tried) |
| **clustering_time_s**    | < 5s  | Time for `sw-issue-clustering.sh run`            |
| **false_positive_rate**  | < 15% | (wrong_recommendations / total_recommendations)  |

### Secondary Metrics

- **cluster_count**: Expected 5-15 for typical repos
- **avg_cluster_size**: Expected 3-10 issues
- **coverage**: % of total issues in any cluster (goal: > 80%)

### Dashboard

Add section to `shipwright status` or `shipwright dora`:

```
Clustering
├─ Match rate: 72% (1245 / 1729 new issues)
├─ Success rate: 68% (856 / 1245 matched)
├─ False positive rate: 8%
└─ Clusters: 12 (avg size 8.5, coverage 91%)
```

---

## Files Modified / Created

### New Files

1. **src/issue-clustering.js** — Core algorithm (TF-IDF, cosine, clustering)
2. **src/issue-clustering.test.js** — Unit tests (vitest)
3. **scripts/sw-issue-clustering.sh** — Bash orchestrator
4. **scripts/sw-issue-clustering-test.sh** — Integration tests

### Modified Files

1. **.claude/daemon-config.json** — Add clustering config section
2. **scripts/lib/daemon-patrol.sh** — Add `_patrol_pattern_matching()` function
3. **scripts/sw-daemon.sh** — Add `_daemon_check_clustering_schedule()` call
4. **.claude/CLAUDE.md** — Add clustering commands and configuration docs
5. **package.json** — Add dependencies (`natural`, `ml-distance`) and test script

### No Breaking Changes

- All existing functionality preserved
- Clustering disabled by default (opt-in via daemon-config.json)
- Zero impact on builds when disabled

---

## Risk Summary

| Risk                                      | Severity   | Mitigation                               | Owner              |
| ----------------------------------------- | ---------- | ---------------------------------------- | ------------------ |
| Race condition on cluster file            | **High**   | Atomic write + lock file                 | Implementation     |
| Memory explosion on large datasets        | **High**   | Stream processing, memory monitor        | Implementation     |
| Incorrect threshold → bad recommendations | **High**   | Configurable, A/B test, metrics tracking | Ops (post-launch)  |
| events.jsonl corruption                   | **Medium** | Validate + backup + fallback             | Implementation     |
| Stale clusters (re-cluster misses)        | **Medium** | Age check, on-demand trigger             | Daemon maintenance |
| Noisy recommendations (false positives)   | **Medium** | Confidence tiers, gradual rollout        | Ops (post-launch)  |

---

## Appendix: Configuration Defaults

```json
{
  "clustering": {
    "enabled": false,
    "max_events": 500,
    "min_cluster_size": 2,
    "similarity_threshold": 0.7,
    "confidence_tiers": {
      "high": 0.85,
      "medium": 0.7,
      "low": 0.5
    },
    "algorithm": "hierarchical",
    "linkage": "average",
    "re_cluster_interval_days": 7,
    "max_clusters": 50,
    "memory_limit_mb": 512,
    "timeout_s": 30
  }
}
```

Start with clustering **disabled** to avoid surprises. Enable via:

```bash
jq '.clustering.enabled = true' ~/.claude/daemon-config.json | sponge ~/.claude/daemon-config.json
```

---

**End of Plan**
