# Implementation Plan: Project Type Auto-Detection and Template Recommendation Engine

## Brainstorming & Design Decisions

### Requirements Clarity

**Minimum viable change**: A new bash library (`scripts/lib/project-type-detection.sh`) that detects project type (web/cli/library/infrastructure) and category (node/go/python/rust/java/ruby) from file system signals, produces a confidence score, and recommends a pipeline template. Integrated into `shipwright prep` and `shipwright setup`.

**Implicit requirements**:

- Must work offline (no Claude API dependency for basic detection)
- Must be fast (<2s for detection)
- Must be idempotent (re-running doesn't corrupt state)
- Must handle monorepos and ambiguous projects gracefully

**Acceptance criteria** (from issue):

1. Detection logic for 8+ project types (node/go/python/rust/java × web/cli/library)
2. Template recommendation with confidence score and rationale
3. Example config generation (daemon-config.json, recommended agents, test commands)
4. Integration with `shipwright prep` and `shipwright setup`
5. Test coverage for detection accuracy across sample repos
6. Documentation with examples for each project type

### Alternatives Considered

**Approach A: Single monolithic detection function in `sw-prep.sh`**

- Pros: Minimal file changes, simple
- Cons: Not reusable from pipeline, hard to test in isolation, makes prep.sh even larger (already 1656 lines)
- Blast radius: High (modifying large critical script)

**Approach B: New library module + CLI subcommand** (CHOSEN)

- Pros: Reusable from prep/setup/pipeline, independently testable, follows existing `scripts/lib/` pattern, clean separation of concerns
- Cons: New files to maintain
- Blast radius: Low (new files + small integration points in existing scripts)

**Approach C: AI-only detection (Claude API)**

- Pros: Most accurate for edge cases
- Cons: Requires API key, slow, expensive, not offline-capable
- Rejected: Use as enhancement tier on top of heuristic detection

**Decision**: Approach B — a new `scripts/lib/project-type-detection.sh` library sourced by existing scripts, with a `shipwright detect` CLI subcommand for standalone use. Heuristic-first with optional AI enrichment.

### Risk Analysis

| Risk                                                          | Impact                          | Mitigation                                                                                     |
| ------------------------------------------------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------- |
| False positive detection (e.g., node CLI detected as web app) | Wrong template selected         | Multi-signal scoring with confidence thresholds; require ≥60% confidence                       |
| Breaking existing `prep_detect_stack()`                       | Prep command fails              | New module is additive; existing detection untouched; new functions called after existing ones |
| Monorepo confusion (multiple project types)                   | Incorrect single classification | Detect multiple project types, report primary + secondary                                      |
| Minimal projects with few signals                             | Low confidence, wrong guess     | Return "unknown" with confidence <40%; let user override                                       |
| Performance regression in pipeline startup                    | Slower intake stage             | File-existence checks are O(1); grep scans limited to manifest files                           |

### Definition of Done

- [ ] `detect_project_type()` returns JSON with type, category, confidence, rationale for 8+ project types
- [ ] `recommend_template()` maps detected type to pipeline template with confidence score
- [ ] `generate_project_config()` outputs tailored daemon-config.json and agent recommendations
- [ ] `shipwright detect` CLI command works standalone
- [ ] Integration with `shipwright prep` shows detection results and uses them for config generation
- [ ] Integration with `shipwright setup` shows detection results during Phase 2
- [ ] Test suite covers all 8+ project types with mock projects
- [ ] Tests verify edge cases: empty project, monorepo, minimal project, ambiguous signals
- [ ] All existing tests pass (no regressions)

---

## Architecture

### Component Diagram

```
┌──────────────────────────────────────────────────────┐
│                  CLI Layer                            │
│  sw-detect.sh (new)  sw-prep.sh  sw-setup.sh        │
│        │                │              │              │
│        └────────────────┼──────────────┘              │
│                         │                             │
│                         ▼                             │
│  ┌─────────────────────────────────────────────┐     │
│  │   lib/project-type-detection.sh (new)       │     │
│  │                                             │     │
│  │   detect_project_type()                     │     │
│  │   detect_project_category()                 │     │
│  │   recommend_template()                      │     │
│  │   generate_project_config()                 │     │
│  │   _score_web_signals()                      │     │
│  │   _score_cli_signals()                      │     │
│  │   _score_library_signals()                  │     │
│  │   _score_infrastructure_signals()           │     │
│  └──────────────┬──────────────────────────────┘     │
│                 │                                     │
│                 ▼                                     │
│  ┌─────────────────────────────────────────────┐     │
│  │   lib/pipeline-detection.sh (existing)      │     │
│  │                                             │     │
│  │   detect_test_cmd()                         │     │
│  │   detect_project_lang()                     │     │
│  │   detect_task_type()                        │     │
│  │   template_for_type()                       │     │
│  └─────────────────────────────────────────────┘     │
│                                                       │
│  ┌─────────────────────────────────────────────┐     │
│  │   templates/pipelines/*.json (existing)     │     │
│  │   + templates/project-types/*.json (new)    │     │
│  └─────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────┘
```

### Interface Contracts

```bash
# ── Core Detection Function ──────────────────────────────
# Input: PROJECT_ROOT (env var, defaults to pwd)
# Output: JSON to stdout
# Errors: Returns empty JSON {} on failure
detect_project_type() → {
  "language": "node|go|python|rust|java|ruby|dotnet|unknown",
  "framework": "next.js|express|django|gin|...|none",
  "project_type": "web|cli|library|infrastructure|unknown",
  "confidence": 0-100,
  "signals": ["package.json has express", "src/server.ts exists", ...],
  "package_manager": "npm|yarn|pnpm|...",
  "test_framework": "vitest|jest|pytest|...",
  "test_cmd": "npm test|...",
  "build_cmd": "npm run build|...",
  "secondary_types": [{"type": "library", "confidence": 30}]
}

# ── Template Recommendation ──────────────────────────────
# Input: JSON from detect_project_type (stdin or arg)
# Output: JSON to stdout
recommend_template() → {
  "template": "standard|fast|full|...",
  "confidence": 0-100,
  "rationale": "Node.js web app with Express — standard pipeline recommended",
  "alternatives": [
    {"template": "deployed", "rationale": "If deploying to production"}
  ],
  "daemon_config": {
    "pipeline_template": "standard",
    "intelligence": {"enabled": true, ...},
    "max_parallel": 2
  },
  "recommended_agents": ["shell-script-specialist", "test-specialist"],
  "test_cmd": "npm test",
  "build_cmd": "npm run build"
}

# ── Config Generation ────────────────────────────────────
# Input: PROJECT_ROOT, detection JSON
# Output: writes files to .claude/ directory
# Side effects: creates daemon-config.json, agent configs
generate_project_config() → void (writes files)
```

### Data Flow

```
User runs: shipwright detect (or prep/setup)
  │
  ├─ 1. Scan manifest files (package.json, go.mod, Cargo.toml, etc.)
  │     → language, framework, package_manager, test_framework
  │
  ├─ 2. Score project type signals
  │     ├─ _score_web_signals()     → web score (0-100)
  │     ├─ _score_cli_signals()     → cli score (0-100)
  │     ├─ _score_library_signals() → library score (0-100)
  │     └─ _score_infrastructure_signals() → infra score (0-100)
  │
  ├─ 3. Select highest-scoring type with confidence
  │     → project_type, confidence, signals[]
  │
  ├─ 4. recommend_template() maps type → template
  │     → template name, rationale, daemon_config
  │
  └─ 5. generate_project_config() writes tailored configs
        → .claude/project-detection.json
        → .claude/daemon-config.json (example)
```

### Error Boundaries

- **Detection library**: Never exits; returns empty/default JSON on any error. Uses `|| true` guards.
- **CLI command (`sw-detect.sh`)**: Handles missing jq, missing PROJECT_ROOT gracefully with user-facing error messages.
- **Integration points**: `sw-prep.sh` and `sw-setup.sh` treat detection as optional enrichment — failure doesn't block their core flow.

---

## Files to Modify

### New Files

1. **`scripts/lib/project-type-detection.sh`** — Core detection library (~300 lines)
2. **`scripts/sw-detect.sh`** — CLI subcommand for `shipwright detect` (~150 lines)
3. **`scripts/sw-detect-test.sh`** — Test suite for detection accuracy (~400 lines)
4. **`templates/project-types/`** — Directory with project type profile JSONs (~8 files, ~30 lines each)

### Modified Files

5. **`scripts/sw-prep.sh`** — Source new library, call `detect_project_type()` in `prep_detect_stack()`, use results for config generation (~20 lines added)
6. **`scripts/sw-setup.sh`** — Display detection results during Phase 2 (~10 lines added)
7. **`scripts/sw`** — Add `detect` subcommand routing (~3 lines added)
8. **`package.json`** — Register test suite (~1 line added)

---

## Implementation Steps

### Step 1: Create project type signal scoring library

Create `scripts/lib/project-type-detection.sh` with:

- Guard header (`_PROJECT_TYPE_DETECTION_LOADED`)
- Source `pipeline-detection.sh` for existing helpers
- `_score_web_signals(lang, root)` — scores indicators: server framework deps (express, fastify, django, gin, actix-web, rails), `src/server.*` or `src/app.*` files, `public/` or `static/` dirs, port/host config, routes/controllers dirs, HTML templates
- `_score_cli_signals(lang, root)` — scores: `bin` field in package.json, `src/cli.*` or `src/main.*`, `commander`/`yargs`/`clap`/`cobra`/`click` deps, `#!` shebangs, no server framework, `cmd/` directory (Go)
- `_score_library_signals(lang, root)` — scores: `main`/`exports`/`types` fields in package.json, `lib/` directory, no server/CLI deps, `[lib]` in Cargo.toml, `py_modules`/`packages` in setup.py, README with "install" section
- `_score_infrastructure_signals(lang, root)` — scores: `Dockerfile`, `docker-compose.yml`, `terraform/`, `.github/workflows/`, `Makefile` with deploy targets, `k8s/` or `kubernetes/` dirs, Helm charts, CDK/Pulumi files

### Step 2: Implement detect_project_type()

Main orchestrator function that:

1. Calls existing `prep_detect_stack()` logic to get language/framework (or reimplements lightweight version)
2. Calls all four `_score_*_signals()` functions
3. Selects highest score as primary type
4. Calculates confidence = (highest_score - second_highest_score) + highest_score/2
5. Collects signal descriptions for rationale
6. Outputs JSON to stdout via `jq`

### Step 3: Implement recommend_template()

Maps project type + language to optimal template:

- web + any language → `standard` (or `deployed` if deploy signals present)
- cli + any → `fast` (CLIs are usually simpler)
- library + any → `standard` (need review for API surface)
- infrastructure + any → `full` (high-risk changes)
- unknown → `standard` (safe default)
  Also generates recommended daemon-config.json fields and agent list.

### Step 4: Implement generate_project_config()

Writes:

- `.claude/project-detection.json` — full detection output
- Suggested daemon-config.json snippet (printed to stdout, not overwritten)
- Recommended agent roles based on project type

### Step 5: Create sw-detect.sh CLI command

Standalone command with subcommands:

- `shipwright detect` — run detection and print results
- `shipwright detect --json` — machine-readable output
- `shipwright detect --generate` — generate config files

### Step 6: Integrate with sw-prep.sh

In `prep_detect_stack()`, after existing detection:

1. Source `lib/project-type-detection.sh`
2. Call `detect_project_type()` to get project type
3. Store result for use in config generation
4. Display project type and confidence to user

### Step 7: Integrate with sw-setup.sh

In Phase 2 (Repo Analysis):

1. Source detection library
2. Show detected project type alongside language/framework
3. Show recommended template

### Step 8: Add CLI routing

Add `detect` case to `scripts/sw` router.

### Step 9: Create test suite

`scripts/sw-detect-test.sh` with:

- Mock project directories for each type (node-web, node-cli, node-lib, go-web, go-cli, python-web, python-cli, rust-lib, java-web, infrastructure)
- Verify correct type detection for each
- Verify confidence scores are reasonable (>60 for clear cases)
- Edge cases: empty dir, ambiguous project, monorepo
- Template recommendation tests

### Step 10: Register test and verify

Add test to `package.json`, run full suite, ensure no regressions.

---

## Task Checklist

- [ ] Task 1: Create `scripts/lib/project-type-detection.sh` with signal scoring functions (`_score_web_signals`, `_score_cli_signals`, `_score_library_signals`, `_score_infrastructure_signals`)
- [ ] Task 2: Implement `detect_project_type()` orchestrator that scores all signals and returns JSON
- [ ] Task 3: Implement `recommend_template()` that maps detected type to pipeline template with confidence and rationale
- [ ] Task 4: Implement `generate_project_config()` that writes tailored daemon-config and agent recommendations
- [ ] Task 5: Create `scripts/sw-detect.sh` CLI command with `--json` and `--generate` flags
- [ ] Task 6: Add `detect` routing to `scripts/sw` CLI router
- [ ] Task 7: Integrate detection into `scripts/sw-prep.sh` (`prep_detect_stack()`)
- [ ] Task 8: Integrate detection into `scripts/sw-setup.sh` (Phase 2)
- [ ] Task 9: Create `scripts/sw-detect-test.sh` test suite with mock projects for all 8+ types
- [ ] Task 10: Add edge case tests (empty project, monorepo, ambiguous signals, minimal files)
- [ ] Task 11: Register test in `package.json` and run full test suite
- [ ] Task 12: Create `templates/project-types/` directory with project type profile JSONs

---

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests (25 tests)**: Each `_score_*_signals()` function tested in isolation with mock file structures. Each project type × language combination verified.
- **Integration tests (8 tests)**: Full `detect_project_type()` called on realistic mock project directories. Template recommendation end-to-end.
- **Edge case tests (5 tests)**: Empty directory, monorepo with multiple types, single-file project, conflicting signals, infrastructure-only repo.

**Total: ~38 tests**

### Coverage Targets

- 100% of supported project types (node/go/python/rust/java × web/cli/library + infrastructure)
- 100% of template recommendation paths
- Edge cases for confidence thresholds (<40 unknown, 40-60 low confidence, >60 confident)

### Critical Paths to Test

**Happy paths:**

- Node.js Express web app → type=web, template=standard, confidence>70
- Go CLI with cobra → type=cli, template=fast, confidence>70
- Python library with setup.py → type=library, template=standard, confidence>70
- Rust actix-web server → type=web, template=standard, confidence>70

**Error cases:**

- Empty directory → type=unknown, confidence=0
- Directory with only README.md → type=unknown, confidence<40

**Edge cases:**

- Node.js project with both CLI (bin field) and web (express) → reports both, primary=web
- Go project with cmd/ and internal/ → type=cli (Go convention)
- Monorepo with packages/ containing web and lib subprojects → detect primary type

---

## Task Decomposition with Dependencies

1. **Task 1**: Create detection library with scoring functions — **no dependencies**
2. **Task 2**: Implement `detect_project_type()` — **depends on Task 1**
3. **Task 3**: Implement `recommend_template()` — **depends on Task 2**
4. **Task 4**: Implement `generate_project_config()` — **depends on Task 3**
5. **Task 5**: Create CLI command — **depends on Tasks 2, 3, 4**
6. **Task 6**: Add CLI routing — **depends on Task 5**
7. **Task 7**: Integrate with prep — **depends on Task 2**
8. **Task 8**: Integrate with setup — **depends on Task 2**
9. **Task 9**: Create test suite — **depends on Tasks 1-4** (but can start mock scaffolding in parallel)
10. **Task 10**: Edge case tests — **depends on Task 9**
11. **Task 11**: Register and run tests — **depends on Tasks 9, 10**
12. **Task 12**: Project type profiles — **no dependencies** (can be done in parallel with Task 1)

**Critical path**: 1 → 2 → 3 → 4 → 5 → 6 (then 9 → 10 → 11 for tests)
**Parallel work**: Tasks 7, 8, 12 can proceed once Task 2 is complete.

---

## Endpoint Specification

_N/A — This is a CLI tool, not an API. The "endpoints" are bash functions with JSON stdout contracts defined in the Interface Contracts section above._

## Error Codes

| Scenario                   | Exit Code | Behavior                                   |
| -------------------------- | --------- | ------------------------------------------ |
| Detection succeeds         | 0         | JSON output to stdout                      |
| No project files found     | 0         | JSON with type=unknown, confidence=0       |
| jq not available           | 1         | Error message to stderr                    |
| Invalid PROJECT_ROOT       | 1         | Error message to stderr                    |
| Permission denied on files | 0         | Skips unreadable files, reduces confidence |

## Rate Limiting

_N/A — local file system operations only._

## Versioning

_Follows Shipwright versioning. VERSION variable at top of new scripts._
