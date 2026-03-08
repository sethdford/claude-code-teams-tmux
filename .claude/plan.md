# Plan: Meta-Feature Development Pattern Library with Build Loop Context Injection

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** A library module (`scripts/lib/feature-patterns.sh`) that captures successful feature development patterns after pipeline completion, stores them in the memory system, and injects matching patterns into build loop prompts so agents learn from prior feature work — not just failures.

**Implicit requirements:**
- Must follow Bash 3.2 compatibility (no associative arrays, no `readarray`, no `${var,,}`)
- Must use atomic file writes (tmp + mv)
- Must integrate with existing memory directory structure (`~/.shipwright/memory/<repo-hash>/`)
- Must respect the context window budget and participate in progressive trimming
- Must not break any of the 102+ existing test suites
- Must use `jq --arg` for JSON construction, never string interpolation

**Acceptance criteria:**
1. `scripts/lib/feature-patterns.sh` exists with 8 functions: `featpat_init`, `featpat_classify_type`, `featpat_capture`, `featpat_match`, `featpat_inject`, `featpat_show`, `featpat_prune`, `featpat_record_helpfulness`
2. Feature patterns auto-captured after successful pipeline runs (hooked into `memory_capture_pipeline`)
3. Feature type classification covers 8 types (api, cli, ui, refactor, bugfix, infra, test, docs) + generic fallback
4. Pattern matching ranks by type match + keyword similarity + recency + outcome
5. Build loop prompt includes "Similar Feature Development Patterns" section when matches exist
6. Context window trimming includes feature patterns in progressive trim order
7. `shipwright memory patterns` CLI subcommand displays captured patterns

### Design Alternatives

**Alternative A: Extend existing `patterns.json` with a `feature_patterns` key**
- Pros: No new file, reuses existing storage infrastructure
- Cons: `patterns.json` is for project metadata (type, framework, conventions) — mixing in feature history would bloat it and complicate existing jq queries. Higher risk of breaking existing memory consumers.

**Alternative B (chosen): Separate `feature-patterns.json` file in memory directory**
- Pros: Clean separation of concerns, independent lifecycle, no risk to existing memory consumers, can grow independently, easy to prune/rotate
- Cons: One more file to manage, need to ensure `ensure_memory_dir` handles it
- Trade-off: Slightly more files but significantly lower blast radius

**Alternative C: Store in SQLite via sw-db.sh**
- Pros: Queryable, handles large volumes well, supports complex queries
- Cons: SQLite is optional (not all installs have it), adds dependency, existing memory system is JSON-file-based — would be inconsistent
- Trade-off: More powerful but breaks the simplicity pattern

**Decision: Alternative B** — separate JSON file, consistent with existing memory architecture (failures.json, decisions.json, patterns.json), minimal blast radius, no new dependencies.

### Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Bloating build loop context | Medium — could waste tokens on irrelevant patterns | Cap injection at 2000 chars; participate in progressive trim; limit to top 3 matches |
| Breaking existing memory injection | High — could break build loop for all pipelines | Module guard prevents double-source; new section is additive only; existing `memory_section` untouched |
| jq parsing errors on malformed JSON | Medium — could crash under pipefail | All jq calls guarded with `2>/dev/null || true`; init creates valid empty structure |
| Feature type misclassification | Low — wrong type means weaker match ranking | Keyword-based classification is simple and deterministic; "generic" fallback prevents crashes |
| Test suite registration breaks npm test chain | High — single `&&` failure stops all tests | Test script follows proven pattern (PASS/FAIL counters, exit 0/1); verify with `npm test` |

### Dependency Analysis

**Depends on:**
- `scripts/sw-memory.sh` — hooks into `memory_capture_pipeline()`, uses `repo_memory_dir()`, `ensure_memory_dir()`, `now_iso()`, `emit_event()`
- `scripts/lib/loop-iteration.sh` — injects into `compose_prompt()` and `manage_context_window()`
- `scripts/lib/helpers.sh` — uses `info()`, `warn()`, `success()`, `error()` output helpers

**Depended on by (after implementation):**
- `scripts/sw-memory.sh` — sources the new lib
- `scripts/lib/loop-iteration.sh` — calls `featpat_inject()`
- CLI router (`scripts/sw`) — via `sw-memory.sh patterns` subcommand

**No circular dependencies:** feature-patterns.sh is a leaf module sourced by memory.sh.

---

## Files to Modify

### New Files
1. **`scripts/lib/feature-patterns.sh`** — Core module with 8 functions (~300 lines)
2. **`scripts/sw-feature-patterns-test.sh`** — Test suite (~350 lines, 15+ test cases)

### Modified Files
3. **`scripts/sw-memory.sh`** — Source lib, hook capture into `memory_capture_pipeline()`, add CLI subcommand `patterns`
4. **`scripts/lib/loop-iteration.sh`** — Add `feature_patterns_section` to `compose_prompt()`, add trim step to `manage_context_window()`
5. **`package.json`** — Register test suite in `test` script

---

## Implementation Steps

### Step 1: Create `scripts/lib/feature-patterns.sh` — Module skeleton

Create the file with:
- Module guard (`_FEATURE_PATTERNS_LOADED`)
- `VERSION` variable matching `package.json` (3.2.4)
- `set -euo pipefail` (inherited from parent, but defensive)
- Storage constants: `FEATPAT_MAX_ENTRIES=50`, `FEATPAT_MAX_INJECT_CHARS=2000`
- Helper: `_featpat_file()` — returns `$(repo_memory_dir)/feature-patterns.json`
- `featpat_init()` — ensures file exists with valid JSON `{"patterns":[]}`

### Step 2: Implement `featpat_classify_type()`

Keyword-based classification function using `grep -qE` against lowercase goal text. Classification order matters — first match wins:

| Type | Keywords |
|------|----------|
| api | api, endpoint, route, rest, graphql, http, handler, middleware |
| cli | cli, command, flag, argument, subcommand, terminal |
| ui | ui, frontend, component, render, button, form, layout, css, style |
| refactor | refactor, decompose, extract, rename, reorganize, restructure, split |
| bugfix | fix, bug, issue, error, broken, crash, regression, patch |
| infra | infra, deploy, ci, cd, docker, kubernetes, workflow, github action |
| test | test, spec, coverage, assert, mock, stub, fixture, harness |
| docs | doc, readme, comment, wiki, changelog, guide, tutorial |
| generic | (fallback) |

Uses `tr '[:upper:]' '[:lower:]'` for Bash 3.2 compatible lowercasing.

### Step 3: Implement `featpat_capture()`

Called after pipeline completion. Parameters: `<state_file> <artifacts_dir>`

Logic:
1. Extract `goal` from state file via `sed -n 's/^goal: *"*\([^"]*\)"*/\1/p'`
2. Extract `pipeline_status` from state file
3. Classify type via `featpat_classify_type "$goal"`
4. Count iterations from stage progress or git log
5. Get changed files via `git diff --name-only` (capped at 20)
6. Deduplicate: check if existing pattern has same goal (exact match)
7. Build JSON entry with `jq --arg`
8. Append to patterns array, cap at `FEATPAT_MAX_ENTRIES`
9. Atomic write: tmp file + `mv`
10. Emit event: `emit_event "feature_pattern.captured" "type=$feat_type" "goal=$goal"`

Pattern entry schema:
```json
{
  "goal": "Add auth module",
  "feature_type": "api",
  "outcome": "success",
  "iterations_used": 5,
  "files_changed": "src/auth.ts,src/middleware.ts",
  "captured_at": "2026-03-08T14:00:00Z",
  "repo": "shipwright",
  "helpfulness_score": 0,
  "times_injected": 0
}
```

### Step 4: Implement `featpat_match()`

Score and rank stored patterns against a goal:
- Parameters: `<goal> [max_results]` (default 3)
- Scoring algorithm (implemented in jq):
  1. **Type match** (+10 if classified type matches pattern's `feature_type`)
  2. **Keyword overlap** — split both goals into words, count shared words, multiply by 2 (capped at 10)
  3. **Recency bonus** (+5 if < 7 days, +3 if < 30 days, +1 if < 90 days)
  4. **Outcome bonus** (+5 for success, 0 for failure)
- Sort by total score descending
- Return JSON array of top N matches
- Pass `goal_type` and `goal_words` as jq args

### Step 5: Implement `featpat_inject()`

Format matched patterns as markdown for prompt injection:
- Parameters: `<goal> [max_chars]` (default 2000)
- Calls `featpat_match()` internally
- If no matches (or empty array), returns empty string
- Formats output as:
  ```
  ## Similar Feature Development Patterns
  Previous pipelines solved similar goals. Learn from these approaches:

  1. **[api] Add auth module** (5 iterations, success)
     Files: src/auth.ts, src/middleware.ts

  2. **[refactor] Split pipeline module** (8 iterations, success)
     Files: scripts/lib/pipeline-*.sh
  ```
- Truncates to `max_chars` limit
- Increments `times_injected` counter on matched patterns

### Step 6: Implement `featpat_show()` and `featpat_prune()`

**`featpat_show()`:**
- Reads `feature-patterns.json`
- Displays formatted table: type, goal (truncated to 40 chars), iterations, outcome, age
- Uses Unicode box-drawing consistent with other Shipwright output

**`featpat_prune()`:**
- Parameters: `[max_age_days]` (default 90)
- Removes entries older than max_age_days
- Removes entries beyond `FEATPAT_MAX_ENTRIES` (oldest first)
- Atomic write

### Step 7: Implement `featpat_record_helpfulness()`

Track whether injected patterns were helpful:
- Parameters: `<goal> <helpful>` (helpful = true/false)
- Finds the most recently injected pattern matching the goal
- If helpful=true: increment `helpfulness_score`
- If helpful=false: decrement `helpfulness_score`
- Atomic write

### Step 8: Integrate into `sw-memory.sh`

Three changes:

**8a. Source the library** — Add near existing lib sources:
```bash
if [[ -f "$SCRIPT_DIR/lib/feature-patterns.sh" ]]; then
    source "$SCRIPT_DIR/lib/feature-patterns.sh"
fi
```

**8b. Hook into `memory_capture_pipeline()`** — After existing capture logic (around line 356), add:
```bash
# Capture feature development pattern on successful pipelines
if [[ "$pipeline_status" == "complete" ]] && type featpat_capture >/dev/null 2>&1; then
    featpat_capture "$state_file" "$artifacts_dir" 2>/dev/null || true
fi
```

**8c. Add CLI subcommand** — In the main CLI dispatch case statement, add:
```bash
patterns)
    shift
    if type featpat_show >/dev/null 2>&1; then
        featpat_show "$@"
    else
        error "Feature patterns module not available"
    fi
    ;;
```

### Step 9: Integrate into `lib/loop-iteration.sh` `compose_prompt()`

After the discovery section injection (line ~144), add:
```bash
# Feature development pattern injection (similar past features)
local feature_patterns_section=""
if type featpat_inject >/dev/null 2>&1; then
    feature_patterns_section="$(featpat_inject "${GOAL:-}" 2>/dev/null || true)"
fi
```

In the heredoc (around line 364, after discovery section), add:
```bash
${feature_patterns_section:+$feature_patterns_section
}
```

### Step 10: Add to `manage_context_window()` progressive trim

Insert a new trim step between step 1 (DORA baselines) and step 2 (file hotspots):
```bash
# 1.5. Trim feature development patterns (less critical than memory/code context)
if [[ "${#trimmed}" -gt "$budget" ]]; then
    trimmed=$(echo "$trimmed" | awk '/^## Similar Feature Development Patterns/{skip=1; next} skip && /^## [^#]/{skip=0} !skip{print}')
fi
```

### Step 11: Create test suite `scripts/sw-feature-patterns-test.sh`

15+ test cases covering:
1. Module guard prevents double-sourcing
2. `featpat_init()` creates valid JSON file
3. `featpat_classify_type()` classifies "add REST endpoint" as "api"
4. `featpat_classify_type()` classifies "fix login crash" as "bugfix"
5. `featpat_classify_type()` classifies "refactor auth module" as "refactor"
6. `featpat_classify_type()` classifies "add React component" as "ui"
7. `featpat_classify_type()` classifies "add CLI subcommand" as "cli"
8. `featpat_classify_type()` classifies unknown goal as "generic"
9. `featpat_capture()` stores pattern with correct schema
10. `featpat_capture()` deduplicates identical goals
11. `featpat_capture()` respects max entries cap
12. `featpat_match()` returns relevant results ranked by score
13. `featpat_match()` returns empty for no matches
14. `featpat_inject()` formats markdown within char limit
15. `featpat_inject()` returns empty string when no patterns exist
16. `featpat_show()` displays formatted output
17. `featpat_prune()` removes old entries
18. `featpat_record_helpfulness()` updates score correctly

Test harness follows existing pattern: `PASS/FAIL` counters, colored output, temp directory for isolation.

### Step 12: Register test in `package.json`

Add `bash scripts/sw-feature-patterns-test.sh &&` to the `test` script chain (alphabetically after sw-feedback-test.sh).

### Step 13: Run full test suite

Execute `npm test` to verify no regressions.

---

## Task Decomposition

1. **Task 1: Create `scripts/lib/feature-patterns.sh` skeleton** — Module guard, constants, `featpat_init()`, `_featpat_file()` helper
2. **Task 2: Implement `featpat_classify_type()`** — Keyword-based classification (depends on Task 1)
3. **Task 3: Implement `featpat_capture()`** — Pattern storage with dedup and atomic write (depends on Task 1)
4. **Task 4: Implement `featpat_match()`** — Scoring and ranking via jq (depends on Task 1)
5. **Task 5: Implement `featpat_inject()`** — Markdown formatting with char cap (depends on Task 4)
6. **Task 6: Implement `featpat_show()` and `featpat_prune()`** — CLI display and maintenance (depends on Task 1)
7. **Task 7: Implement `featpat_record_helpfulness()`** — Effectiveness tracking (depends on Task 1)
8. **Task 8: Integrate into `sw-memory.sh`** — Source lib, capture hook, CLI subcommand (depends on Tasks 1-7). Task 8 blocks Tasks 9-10.
9. **Task 9: Integrate into `compose_prompt()` in `lib/loop-iteration.sh`** — Add injection section (depends on Task 5, Task 8)
10. **Task 10: Add to `manage_context_window()` trim order** — Progressive trimming (depends on Task 9)
11. **Task 11: Create test suite `sw-feature-patterns-test.sh`** — 18 test cases (depends on Tasks 1-7)
12. **Task 12: Register test in `package.json`** — Add to test chain (depends on Task 11)
13. **Task 13: Run full test suite and fix regressions** — Verify everything passes (depends on Tasks 8-12)

**Critical path:** Tasks 1 → 2,3,4 (parallel) → 5 → 8 → 9 → 10 → 13

---

## Risk Analysis

| Risk | What Could Break | Mitigation |
|------|------------------|------------|
| Sourcing feature-patterns.sh fails | All memory operations fail if source errors propagate | Module guard + conditional source with `-f` check |
| jq not available | JSON operations crash | Already handled — existing codebase assumes jq (doctor checks for it) |
| Empty/corrupted feature-patterns.json | jq parse errors crash under pipefail | `featpat_init()` creates valid JSON; all reads use `2>/dev/null \|\| true` |
| Context budget exceeded by patterns | Agent gets truncated context | 2000 char cap + progressive trim step removes section entirely when over budget |
| `memory_capture_pipeline` breaks | No learnings captured from any pipeline | Capture hook wrapped in `2>/dev/null \|\| true`; existing capture logic untouched |
| Test suite fails other tests | CI red, blocks merges | Test uses isolated temp directory; no shared state; follows proven harness pattern |

---

## Testing Approach

1. **Unit tests** (`sw-feature-patterns-test.sh`): 18 test cases covering every public function
2. **Integration verification**: Run `sw-memory-test.sh` to ensure memory system still works
3. **Full regression**: Run `npm test` (102+ test suites) to verify no breakage
4. **Manual smoke test**: Create a feature pattern, verify it shows up in `shipwright memory patterns`, verify `compose_prompt` includes it

---

## Definition of Done

- [ ] `scripts/lib/feature-patterns.sh` exists with all 8 functions (init, classify, capture, match, inject, show, prune, record_helpfulness)
- [ ] Feature patterns are automatically captured after successful pipeline runs (hooked into `memory_capture_pipeline`)
- [ ] Feature type classification works for all 8 types (api, cli, ui, refactor, bugfix, infra, test, docs) + generic fallback
- [ ] Pattern matching returns relevant results ranked by type match + keyword similarity + recency + outcome
- [ ] Build loop prompt includes "Similar Feature Development Patterns" section when matches exist
- [ ] Context window trimming includes feature patterns in the progressive trim order
- [ ] `shipwright memory patterns` displays captured patterns with goal, type, iterations, outcome
- [ ] Test suite passes with 18 test cases and 0 failures
- [ ] Full `npm test` passes with no regressions
- [ ] All bash code is Bash 3.2 compatible (no associative arrays, readarray, ${var,,})
- [ ] All file writes are atomic (tmp + mv)
- [ ] All jq calls use `--arg` for variable interpolation, never string interpolation

---

## Task Checklist

- [ ] Task 1: Create `scripts/lib/feature-patterns.sh` with module guard, constants, `featpat_init()`, `_featpat_file()` helper
- [ ] Task 2: Implement `featpat_classify_type()` — keyword-based feature type classification (Bash 3.2 safe)
- [ ] Task 3: Implement `featpat_capture()` — extract pattern from pipeline state + git diff, deduplicate, atomic write
- [ ] Task 4: Implement `featpat_match()` — score and rank stored patterns against a goal using jq
- [ ] Task 5: Implement `featpat_inject()` — format matched patterns as markdown for prompt injection (2K char cap)
- [ ] Task 6: Implement `featpat_show()` and `featpat_prune()` — CLI display and maintenance
- [ ] Task 7: Implement `featpat_record_helpfulness()` — effectiveness tracking
- [ ] Task 8: Integrate module sourcing and capture hook into `sw-memory.sh` (source lib, hook into `memory_capture_pipeline`, add CLI subcommand)
- [ ] Task 9: Integrate pattern injection into `lib/loop-iteration.sh` `compose_prompt()` — add `feature_patterns_section` variable and prompt heredoc section
- [ ] Task 10: Add feature patterns to `manage_context_window()` progressive trim order
- [ ] Task 11: Create `scripts/sw-feature-patterns-test.sh` with 18 test cases
- [ ] Task 12: Register test suite in `package.json`
- [ ] Task 13: Run full test suite — verify no regressions in existing tests
