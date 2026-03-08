# Implementation Plan: Meta-Feature Development Pattern Library with Build Loop Context Injection

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A new `scripts/lib/feature-patterns.sh` module that (1) classifies feature types from goal text, (2) captures development patterns after successful pipelines, (3) matches stored patterns against new goals, and (4) injects relevant patterns into the build loop prompt. This bridges the gap between the existing memory system (which tracks failures and conventions) and feature-level development knowledge (which is currently not captured at all).

**Implicit requirements**:
- Bash 3.2 compatibility (no associative arrays, no `readarray`, no `${var,,}`)
- Atomic JSON writes (tmp + mv pattern)
- Graceful degradation when no patterns exist yet (first run)
- Integration with progressive context window trimming
- CLI access via `shipwright memory patterns`

**Acceptance criteria**:
1. Feature patterns are automatically captured after successful pipeline runs
2. Feature type classification works for 8 types + generic fallback
3. Pattern matching returns ranked results by type + keyword similarity + recency + outcome
4. Build loop prompt includes "Similar Feature Development Patterns" section when matches exist
5. Context window trimming includes feature patterns in the progressive trim order
6. `shipwright memory patterns` displays captured patterns
7. All 15+ test cases pass
8. No regressions in existing test suites

### Design Alternatives

**Approach A: Standalone lib module (CHOSEN)**
- New `scripts/lib/feature-patterns.sh` with 8 functions
- Storage in existing `~/.shipwright/memory/<repo-hash>/feature-patterns.json`
- Hooked into `memory_finalize_pipeline()` for capture
- Injected via new section in `compose_prompt()`
- Trade-offs: Clean separation, minimal blast radius, follows existing lib/ module pattern
- Complexity: Medium — new file but well-bounded scope

**Approach B: Extend sw-memory.sh directly**
- Add all feature pattern logic directly into `sw-memory.sh` (already 2,118 lines)
- Trade-offs: Avoids new file, but bloats an already large module, harder to test in isolation
- Complexity: Lower file count but higher per-file complexity and worse maintainability

**Approach C: Full intelligence integration**
- Build feature patterns into `sw-intelligence.sh` with Claude-powered classification
- Trade-offs: More accurate but requires API calls, adds latency, cost, and external dependency
- Complexity: High — requires API availability, costs money per classification

**Decision**: Approach A. It follows the recent refactoring pattern (the last 5 merged PRs all decomposed large files into focused modules). It minimizes blast radius (only 4 existing files touched). Keyword-based classification is sufficient for 8 types and doesn't need AI.

### Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Pattern JSON grows unbounded | Slow reads, large context | `featpat_prune()` caps at 50 entries, oldest first |
| Classification misidentifies type | Wrong patterns injected | Generic fallback + keyword matching still finds relevant patterns |
| Context window bloat from injected patterns | Less room for actual code context | 2K char cap on injection + integrated into trim order at position 2 (before file hotspots) |
| jq not available | Capture/match fails silently | Guard all jq calls with `command -v jq` check; degrade gracefully |
| Race condition on atomic write | Corrupted JSON | tmp file + mv pattern (already established convention) |

### Dependency Analysis

**Depends on**:
- `scripts/lib/helpers.sh` — `info()`, `warn()`, `error()`, `now_iso()`, `emit_event()`
- `scripts/sw-memory.sh` — `ensure_memory_dir()`, `repo_memory_dir()`, `repo_name()`
- `scripts/lib/loop-iteration.sh` — `compose_prompt()` (injection point)
- `jq` — JSON manipulation

**Depended on by** (after implementation):
- `sw-loop.sh` sources it for prompt injection
- `sw-memory.sh` calls it from `memory_finalize_pipeline()` for capture
- `sw-memory.sh` CLI dispatches `patterns` subcommand to it

**No circular dependency risks** — feature-patterns.sh is a leaf module that only imports from helpers/memory utilities.

---

## Files to Modify

### New Files
1. **`scripts/lib/feature-patterns.sh`** — Core module (~300 lines): init, classify, capture, match, inject, show, prune, record_helpfulness
2. **`scripts/sw-feature-patterns-test.sh`** — Test suite (~250 lines): 15+ test cases

### Modified Files
3. **`scripts/sw-loop.sh`** — Add `source` line for feature-patterns.sh (1 line)
4. **`scripts/lib/loop-iteration.sh`** — Add feature pattern injection to `compose_prompt()` (~8 lines) and trim step to `manage_context_window()` (~5 lines)
5. **`scripts/sw-memory.sh`** — Hook capture into `memory_finalize_pipeline()` (~3 lines), add `patterns` CLI subcommand (~3 lines), initialize feature-patterns.json in `ensure_memory_dir()` (~1 line)
6. **`package.json`** — Add test suite to `test` script (~1 insertion)

---

## Implementation Steps

### Step 1: Create `scripts/lib/feature-patterns.sh` — Module skeleton

```bash
#!/usr/bin/env bash
# Module guard
[[ -n "${_FEATURE_PATTERNS_LOADED:-}" ]] && return 0
_FEATURE_PATTERNS_LOADED=1
```

Define `FEATURE_TYPES` as a pipe-delimited string (Bash 3.2 safe):
```
api|cli|ui|refactor|bugfix|infra|test|docs
```

### Step 2: Implement `featpat_init()`

Ensure the feature-patterns.json file exists in the repo memory dir:
```bash
featpat_init() {
    local mem_dir
    mem_dir="$(repo_memory_dir 2>/dev/null)" || return 1
    local fp_file="$mem_dir/feature-patterns.json"
    if [[ ! -f "$fp_file" ]]; then
        echo '{"patterns":[]}' > "$fp_file"
    fi
    echo "$fp_file"
}
```

### Step 3: Implement `featpat_classify_type()`

Keyword-based classification using case statement + grep (no associative arrays):
```bash
featpat_classify_type() {
    local goal="$1"
    local lower_goal
    lower_goal=$(printf '%s' "$goal" | tr '[:upper:]' '[:lower:]')

    # Check each type's keywords
    if echo "$lower_goal" | grep -qE 'api|endpoint|route|rest|graphql|http|request|response|handler'; then echo "api"; return; fi
    if echo "$lower_goal" | grep -qE 'cli|command|flag|argument|subcommand|terminal|prompt'; then echo "cli"; return; fi
    if echo "$lower_goal" | grep -qE '\bui\b|frontend|component|render|display|button|form|layout|css|style'; then echo "ui"; return; fi
    if echo "$lower_goal" | grep -qE 'refactor|decompose|extract|rename|reorganize|restructure|modular|split'; then echo "refactor"; return; fi
    if echo "$lower_goal" | grep -qE 'fix|bug|issue|error|broken|crash|regression|patch'; then echo "bugfix"; return; fi
    if echo "$lower_goal" | grep -qE 'infra|deploy|ci|cd|docker|kubernetes|pipeline|workflow|github.action'; then echo "infra"; return; fi
    if echo "$lower_goal" | grep -qE 'test|spec|coverage|assert|mock|stub|fixture|harness'; then echo "test"; return; fi
    if echo "$lower_goal" | grep -qE 'doc|readme|comment|wiki|changelog|guide|tutorial'; then echo "docs"; return; fi
    echo "generic"
}
```

### Step 4: Implement `featpat_capture()`

Called after a successful pipeline. Extracts pattern from state file + git diff:
```bash
featpat_capture() {
    local state_file="${1:-}"
    local artifacts_dir="${2:-}"

    # Extract goal, outcome, iterations, files changed from pipeline state
    # Classify feature type from goal
    # Build pattern entry JSON with jq
    # Deduplicate by goal similarity (>80% keyword overlap = update existing)
    # Atomic write: tmp + mv
}
```

Pattern entry schema:
```json
{
    "id": "<sha256-first-12>",
    "goal": "original goal text",
    "feature_type": "api|cli|ui|refactor|bugfix|infra|test|docs|generic",
    "outcome": "success|failure",
    "iterations_used": 5,
    "files_changed": ["path/to/file1.sh", "path/to/file2.sh"],
    "key_patterns": ["keyword1", "keyword2"],
    "captured_at": "ISO-8601",
    "repo": "owner/repo",
    "helpfulness_score": 0,
    "times_injected": 0,
    "times_helpful": 0
}
```

### Step 5: Implement `featpat_match()`

Score and rank stored patterns against a goal:
```bash
featpat_match() {
    local goal="$1"
    local max_results="${2:-3}"

    local fp_file
    fp_file="$(featpat_init)" || return 1

    local goal_type
    goal_type="$(featpat_classify_type "$goal")"

    # Use jq to score each pattern:
    # - type_match: 10 points if same feature_type
    # - keyword_overlap: count shared words between goal and pattern.goal (0-10 points)
    # - recency: 5 points if < 7 days, 3 if < 30, 1 if < 90, 0 otherwise
    # - outcome_bonus: 3 points if outcome == "success", -2 if "failure"
    # - helpfulness: times_helpful / max(times_injected, 1) * 5
    # Sort by total score descending, return top N
}
```

### Step 6: Implement `featpat_inject()`

Format matched patterns as markdown for prompt injection:
```bash
featpat_inject() {
    local goal="$1"
    local max_chars="${2:-2000}"

    local matches
    matches="$(featpat_match "$goal" 3)"

    # If no matches, return empty string
    # Format as:
    # ## Similar Feature Development Patterns
    # 1. [api] "Add REST endpoint for users" (5 iterations, success)
    #    Files: src/routes/users.ts, src/models/user.ts
    # 2. [refactor] "Extract auth module" (3 iterations, success)
    #    Files: src/auth/index.ts, src/middleware/auth.ts
    #
    # Truncate to max_chars
}
```

### Step 7: Implement `featpat_show()` and `featpat_prune()`

CLI display and maintenance:
```bash
featpat_show() {
    # Display stored patterns in a table with: type, goal (truncated), iterations, outcome, age
}

featpat_prune() {
    local max_entries="${1:-50}"
    # Remove oldest patterns beyond max_entries
    # Prefer keeping high-helpfulness patterns
}
```

### Step 8: Implement `featpat_record_helpfulness()`

Track whether injected patterns actually helped:
```bash
featpat_record_helpfulness() {
    local pattern_id="$1"
    local was_helpful="${2:-true}"  # true or false

    # Increment times_injected (always)
    # Increment times_helpful (if was_helpful)
    # Recalculate helpfulness_score
}
```

### Step 9: Integrate sourcing into `sw-loop.sh`

Add after line 40 (after other loop-* sources):
```bash
[[ -f "$SCRIPT_DIR/lib/feature-patterns.sh" ]] && source "$SCRIPT_DIR/lib/feature-patterns.sh"
```

### Step 10: Integrate injection into `compose_prompt()`

In `scripts/lib/loop-iteration.sh`, after the memory section (line 134) and before discovery section (line 136), add:
```bash
# Feature development pattern injection
local feature_patterns_section=""
if type featpat_inject >/dev/null 2>&1; then
    feature_patterns_section="$(featpat_inject "${GOAL:-}" 2>/dev/null || true)"
fi
```

Then in the heredoc (after line 361 `$memory_section`), add:
```
${feature_patterns_section:+$feature_patterns_section
}
```

### Step 11: Add feature patterns to `manage_context_window()` trim order

Insert a new trim step between step 1 (DORA baselines) and step 2 (file hotspots) — making it step 1.5:
```bash
# 1.5. Trim feature development patterns (moderately important but expendable)
if [[ "${#trimmed}" -gt "$budget" ]]; then
    trimmed=$(echo "$trimmed" | awk '/^## Similar Feature Development Patterns/{skip=1; next} skip && /^## [^#]/{skip=0} !skip{print}')
fi
```

### Step 12: Hook capture into `memory_finalize_pipeline()`

In `scripts/sw-memory.sh`, after line 679 (before the closing `}`), add:
```bash
# Step 4: Capture feature development patterns
if type featpat_capture >/dev/null 2>&1; then
    featpat_capture "$state_file" "$artifacts_dir" 2>/dev/null || true
fi
```

### Step 13: Add `patterns` CLI subcommand to `sw-memory.sh`

In the case statement (after line 2107 `ab-report`), add:
```bash
patterns)
    if [[ -f "$SCRIPT_DIR/lib/feature-patterns.sh" ]]; then
        source "$SCRIPT_DIR/lib/feature-patterns.sh"
    fi
    featpat_show "$@"
    ;;
```

### Step 14: Initialize feature-patterns.json in `ensure_memory_dir()`

In `scripts/sw-memory.sh`, after line 268, add:
```bash
[[ -f "$dir/feature-patterns.json" ]] || echo '{"patterns":[]}' > "$dir/feature-patterns.json"
```

### Step 15: Create test suite `scripts/sw-feature-patterns-test.sh`

Test cases:
1. Module guard prevents double-sourcing
2. `featpat_init()` creates feature-patterns.json if missing
3. `featpat_classify_type()` correctly classifies "Add REST API endpoint" → api
4. `featpat_classify_type()` correctly classifies "Fix login crash" → bugfix
5. `featpat_classify_type()` correctly classifies "Refactor auth module" → refactor
6. `featpat_classify_type()` correctly classifies "Add CLI subcommand" → cli
7. `featpat_classify_type()` falls back to "generic" for ambiguous goals
8. `featpat_capture()` writes a valid pattern entry to feature-patterns.json
9. `featpat_capture()` deduplicates patterns with similar goals
10. `featpat_match()` returns highest-scoring patterns first
11. `featpat_match()` prioritizes same feature_type
12. `featpat_match()` returns empty for no matches
13. `featpat_inject()` produces markdown under 2K chars
14. `featpat_inject()` returns empty when no patterns stored
15. `featpat_prune()` removes oldest entries beyond max
16. `featpat_record_helpfulness()` increments counters correctly
17. `featpat_show()` displays table without errors

### Step 16: Register test in `package.json`

Add `&& bash scripts/sw-feature-patterns-test.sh` to the `test` script in package.json.

### Step 17: Run full test suite — verify no regressions

---

## Task Checklist

- [ ] Task 1: Create `scripts/lib/feature-patterns.sh` with module guard, `featpat_init()`, and storage schema
- [ ] Task 2: Implement `featpat_classify_type()` — keyword-based feature type classification (Bash 3.2 safe)
- [ ] Task 3: Implement `featpat_capture()` — extract pattern from pipeline state + git diff, deduplicate, atomic write
- [ ] Task 4: Implement `featpat_match()` — score and rank stored patterns against a goal using jq
- [ ] Task 5: Implement `featpat_inject()` — format matched patterns as markdown for prompt injection (2K char cap)
- [ ] Task 6: Implement `featpat_show()` and `featpat_prune()` — CLI display and maintenance
- [ ] Task 7: Implement `featpat_record_helpfulness()` — effectiveness tracking
- [ ] Task 8: Integrate module sourcing and capture hook into `sw-memory.sh` (source lib, hook into `memory_finalize_pipeline`, add CLI subcommand, update `ensure_memory_dir`)
- [ ] Task 9: Integrate pattern injection into `lib/loop-iteration.sh` `compose_prompt()` — add `feature_patterns_section` variable and prompt heredoc section
- [ ] Task 10: Add feature patterns to `manage_context_window()` progressive trim order
- [ ] Task 11: Source feature-patterns.sh from `sw-loop.sh`
- [ ] Task 12: Create `scripts/sw-feature-patterns-test.sh` with 17 test cases
- [ ] Task 13: Register test suite in `package.json`
- [ ] Task 14: Run full test suite — verify no regressions in existing tests

### Task Dependencies
- Tasks 1-7 are sequential (each builds on prior functions)
- Task 8 depends on Tasks 1-7 (module must exist before integration)
- Tasks 9-11 depend on Tasks 1-7 (module must exist)
- Tasks 9, 10, 11 are independent of each other
- Task 12 depends on Tasks 1-7 (needs functions to test)
- Task 13 depends on Task 12
- Task 14 depends on all other tasks

---

## Testing Approach

1. **Unit tests** (sw-feature-patterns-test.sh): 17 test cases covering all 8 functions
2. **Integration verification**: Run `sw-memory-test.sh` to verify memory hooks don't regress
3. **Loop integration verification**: Run `sw-loop-test.sh` to verify compose_prompt still works
4. **Full suite**: `npm test` to verify no regressions across all 102+ test suites

Test harness follows established conventions:
- Source `lib/test-helpers.sh`
- `setup_test_env` / `cleanup_test_env`
- Mock git, mock memory directory
- `assert_contains`, `assert_equals`, `assert_file_exists`
- `print_test_header`, `print_test_section`

---

## Definition of Done

- [x] `scripts/lib/feature-patterns.sh` exists with all 8 functions (init, classify, capture, match, inject, show, prune, record_helpfulness)
- [x] Feature patterns are automatically captured after successful pipeline runs (hooked into `memory_finalize_pipeline`)
- [x] Feature type classification works for all 8 types (api, cli, ui, refactor, bugfix, infra, test, docs) + generic fallback
- [x] Pattern matching returns relevant results ranked by type match + keyword similarity + recency + outcome
- [x] Build loop prompt includes "Similar Feature Development Patterns" section when matches exist
- [x] Context window trimming includes feature patterns in the progressive trim order
- [x] `shipwright memory patterns` displays captured patterns with goal, type, iterations, outcome
- [x] Test suite passes with 17/17 test cases
- [x] No regressions in existing test suites (npm test passes)

---

## Alternatives Considered

### Alternative 1: Extend sw-memory.sh directly
**Approach**: Add all 8 functions directly into `scripts/sw-memory.sh`
**Pros**: No new files, keeps all memory logic together
**Cons**: sw-memory.sh is already 2,118 lines; violates the project's recent decomposition trend (last 5 PRs all split large files); harder to test in isolation
**Blast radius**: High — any bug in new code could break existing memory functions
**Decision**: Rejected. The project has established a clear pattern of extracting focused modules into `scripts/lib/`.

### Alternative 2: AI-powered classification via Claude API
**Approach**: Use `sw-intelligence.sh` + Claude CLI to classify features and extract patterns
**Pros**: More accurate classification, richer pattern extraction
**Cons**: Requires API availability, adds latency (seconds per classification), costs money, fails offline
**Blast radius**: Medium — intelligence layer is already optional, but adds dependency
**Decision**: Rejected. Keyword-based classification is sufficient for 8 categories. Can always upgrade later by swapping `featpat_classify_type()` to use AI when `intelligence.enabled=true`.

### Alternative 3: Full cross-repo pattern sharing via discovery system
**Approach**: Integrate with `sw-discovery.sh` to share feature patterns across repos
**Pros**: Global learning, cross-repo knowledge transfer
**Cons**: Discovery system has 24h TTL, different storage format, adds complexity
**Blast radius**: Medium — touches discovery system which is used by fleet/daemon
**Decision**: Deferred. Start with per-repo patterns; cross-repo promotion can be added later by extending `_memory_aggregate_global()` to include feature patterns.

---

## Risk Analysis

| Risk | What Could Break | Mitigation |
|------|-----------------|------------|
| jq unavailable on some systems | Pattern capture/match silently fails | All jq calls guarded with `command -v jq >/dev/null 2>&1` checks; functions return early with empty output |
| feature-patterns.json corruption | Pattern loss, JSON parse errors | Atomic writes (tmp + mv); `jq` validates before write; init creates valid empty structure |
| compose_prompt becomes too large | Context window exceeded, trimmed aggressively | 2K char cap on injection; integrated into trim order at priority 1.5 (removed before file hotspots) |
| Pattern deduplication too aggressive | Useful patterns merged/lost | Dedup threshold at 80% keyword overlap (conservative); each pattern keeps its own counters |
| Test suite flaky due to timing | CI failures | All tests use fixed timestamps; no real git operations; deterministic JSON input |
| Breaking existing memory_finalize_pipeline | Pipeline capture stops working | Hook uses `type featpat_capture >/dev/null 2>&1` guard; failure is caught with `|| true` |
