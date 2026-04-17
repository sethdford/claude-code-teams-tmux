## Fleet Conflict Detection Protocol

File conflict detection must be fast (checked before every pipeline start), accurate (no false negatives that allow conflicts, minimal false positives that block unnecessarily), and distributed (work across daemon and fleet modes).

### File Dependency Discovery

Before a pipeline starts, determine the set of files it will modify. Three approaches:

1. **Static Analysis** (fastest, possible false positives):
   - Parse issue description and PR files from linked issues
   - Scan CODEOWNERS for file→owner mapping
   - Use git blame to identify hotspot files for the feature area
   - Risk: May over-estimate scope

2. **Specification-Based** (medium speed, medium accuracy):
   - If spec.json exists from spec_generation stage, extract file list from spec
   - Parse design docs for architecture changes
   - Risk: Spec may be incomplete

3. **Empirical** (slowest, best accuracy):
   - Run git diff --name-only against base branch for similar issues
   - Build historical database of files touched per issue type
   - Use pattern-matching similarity scoring to find analogous issues
   - Estimate file scope from analogs

Recommendation: Hybrid—start with static + spec, fall back to empirical if confidence is low.

### Conflict Representation

```json
{
  "pipeline_id": "issue-401-uuid",
  "started_at": "2026-04-17T18:37:30Z",
  "ttl_seconds": 3600,
  "file_ownership": {
    "scripts/sw-fleet.sh": { "access": "write", "confidence": 0.95 },
    "scripts/lib/compat.sh": { "access": "read", "confidence": 0.8 },
    ".claude/fleet-config.json": { "access": "write", "confidence": 1.0 }
  },
  "conflict_class": "high"
}
```

### Conflict Queries

When a new pipeline is about to start with its own file set:

```bash
conflict_score() {
  # Score = (files_in_common / union_of_files) * confidence_product
  # Score > 0.3 = likely conflict, queue the pipeline
  # Score > 0.7 = definite conflict, queue immediately
  # Score < 0.15 = safe to run in parallel
}
```

### Shared State Format

File: `~/.shipwright/fleet-lock-state.json` (fleet mode) or `.claude/fleet-lock-state.json` (daemon mode)

Append-only log to prevent race conditions:

```bash
# Thread-safe append (uses flock)
echo '{"action": "acquire", "pipeline_id": "...", "files": [...]}' >> lock-state.json

# On pipeline complete:
echo '{"action": "release", "pipeline_id": "..."}' >> lock-state.json
```

Daemon periodically replays log to compute current state, compacts if log grows > 10MB.

### Queueing Logic

When conflict detected:
1. Add pipeline to queue file with original issue metadata
2. Record `blocked_by: [list of conflicting pipeline IDs]`
3. When blocking pipeline releases, rescan queue and restart first non-blocked pipeline
4. To prevent starvation: prioritize by (original_priority - queue_wait_time), re-evaluate every 30s
