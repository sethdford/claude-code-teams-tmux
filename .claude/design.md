# Design: Project Type Auto-Detection and Template Recommendation Engine

## Context

Shipwright's pipeline system selects templates (fast, standard, full, etc.) based on task type (bug, feature, refactor), but has no awareness of **what kind of project** it's operating on. A Node.js CLI tool, a Django web app, and a Terraform infrastructure repo all get the same pipeline configuration despite having fundamentally different build/test/deploy characteristics.

The existing detection surface is split across two locations:

- `scripts/lib/pipeline-detection.sh` — detects language, test command, package manager, task type, and reviewers. Operates at the **language** level only (node/go/python/rust/ruby/java).
- `scripts/sw-prep.sh:214` `prep_detect_stack()` — detects language, framework, test framework, package manager, and build/lint/format commands. Richer but tightly coupled to the prep flow and writes to shell variables (not composable JSON).

Neither system classifies the **project type** (web app vs CLI tool vs library vs infrastructure) or recommends a pipeline template based on project characteristics. This means:

- Infrastructure repos get the same iteration count as simple CLIs
- Libraries don't get API surface review emphasis
- Web apps don't get deployment stage recommendations

**Constraints:**

- All scripts are bash, Bash 3.2 compatible (no associative arrays, no `readarray`, no `${var,,}`)
- Must work offline (no Claude API for basic detection)
- Must be idempotent and fast (<2s)
- Must not break existing `prep_detect_stack()` — additive only
- JSON output via `jq` (already a prerequisite)

## Decision

### Approach: New library module with multi-signal scoring

Create `scripts/lib/project-type-detection.sh` as a standalone library that scores project type from filesystem signals, then recommends a pipeline template. Expose via `shipwright detect` CLI and integrate as optional enrichment into `prep` and `setup`.

### Component Diagram

```
                        CLI Layer
  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
  │ sw-detect.sh │  │ sw-prep.sh   │  │ sw-setup.sh  │
  │   (new)      │  │ (modified)   │  │ (modified)   │
  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
         │                 │                  │
         └────────────┬────┴──────────────────┘
                      │ source
                      ▼
  ┌────────────────────────────────────────────────┐
  │   lib/project-type-detection.sh  (new)         │
  │                                                │
  │   detect_project_type()      → JSON stdout     │
  │   recommend_template()       → JSON stdout     │
  │   generate_project_config()  → writes files    │
  │                                                │
  │   _score_web_signals()       → integer (0-100) │
  │   _score_cli_signals()       → integer (0-100) │
  │   _score_library_signals()   → integer (0-100) │
  │   _score_infrastructure_signals() → int (0-100)│
  └──────────────────┬─────────────────────────────┘
                     │ source (reuse helpers)
                     ▼
  ┌────────────────────────────────────────────────┐
  │   lib/pipeline-detection.sh  (existing)        │
  │   detect_test_cmd(), detect_project_lang()     │
  └────────────────────────────────────────────────┘
                     │ reads
                     ▼
  ┌────────────────────────────────────────────────┐
  │   templates/project-types/*.json  (new)        │
  │   templates/pipelines/*.json      (existing)   │
  └────────────────────────────────────────────────┘
```

### Data Flow

```
1. Entry: detect_project_type(root_dir)
   │
   ├─ 2. Language detection (reuse detect_project_lang)
   │     → "node" | "go" | "python" | "rust" | "java" | "ruby" | "dotnet" | "unknown"
   │
   ├─ 3. Framework detection (grep manifest files)
   │     → "express" | "next.js" | "django" | "gin" | "actix-web" | ... | "none"
   │
   ├─ 4. Score all project types independently:
   │     ├─ _score_web_signals(lang, root)     → 0-100
   │     ├─ _score_cli_signals(lang, root)     → 0-100
   │     ├─ _score_library_signals(lang, root) → 0-100
   │     └─ _score_infrastructure_signals(lang, root) → 0-100
   │
   ├─ 5. Select winner:
   │     primary = max(scores)
   │     confidence = primary_score (normalized)
   │     if primary - runner_up < 15 → lower confidence (ambiguous)
   │     if primary < 40 → type = "unknown"
   │
   └─ 6. Output JSON to stdout
         {language, framework, project_type, confidence, signals[], ...}

7. recommend_template(detection_json)
   │
   ├─ Map (project_type, language) → template name
   ├─ Generate rationale string
   ├─ Suggest daemon_config overrides
   └─ Output JSON to stdout

8. generate_project_config(root, detection_json)
   │
   ├─ Write .claude/project-detection.json (atomic: tmp + mv)
   └─ Print suggested daemon-config snippet to stdout
```

### Interface Contracts

```bash
# ── detect_project_type ─────────────────────────────────────
# Input:  $1 = project root directory (default: $PROJECT_ROOT or pwd)
# Output: JSON to stdout
# Errors: Returns {"project_type":"unknown","confidence":0} on any failure
# Exit:   Always 0
#
# Output schema:
# {
#   "language":        "node|go|python|rust|java|ruby|dotnet|unknown",
#   "framework":       "express|next.js|django|gin|...|none",
#   "project_type":    "web|cli|library|infrastructure|unknown",
#   "confidence":      0-100,
#   "signals":         ["package.json has express dep", ...],
#   "package_manager": "npm|yarn|pnpm|bun|pip|cargo|go|mvn|gradle",
#   "test_framework":  "vitest|jest|pytest|cargo-test|go-test|...|unknown",
#   "test_cmd":        "npm test|...",
#   "build_cmd":       "npm run build|...|",
#   "secondary_types": [{"type":"library","confidence":30}]
# }

# ── recommend_template ──────────────────────────────────────
# Input:  $1 = JSON string from detect_project_type (or reads stdin)
# Output: JSON to stdout
# Errors: Returns {"template":"standard"} as safe default
# Exit:   Always 0
#
# Output schema:
# {
#   "template":           "standard|fast|full|deployed|...",
#   "confidence":         0-100,
#   "rationale":          "Go CLI with cobra — fast pipeline recommended",
#   "alternatives":       [{"template":"standard","rationale":"..."}],
#   "daemon_config":      { ... suggested overrides ... },
#   "recommended_agents": ["shell-script-specialist", ...]
# }

# ── generate_project_config ────────────────────────────────
# Input:  $1 = project root, $2 = detection JSON (optional, runs detect if missing)
# Output: Writes .claude/project-detection.json
#         Prints daemon-config suggestions to stdout
# Errors: Warns on stderr if write fails, does not exit
# Exit:   Always 0

# ── Scoring functions (private) ─────────────────────────────
# _score_web_signals(language, root_dir) → echoes integer 0-100
# _score_cli_signals(language, root_dir) → echoes integer 0-100
# _score_library_signals(language, root_dir) → echoes integer 0-100
# _score_infrastructure_signals(language, root_dir) → echoes integer 0-100
#
# Each scores independently. Signals are weighted:
#   +20  strong signal (framework dependency like express, cobra)
#   +10  medium signal (directory convention like cmd/, public/)
#   +5   weak signal (file existence like Dockerfile)
#   Capped at 100.
```

### Error Boundaries

| Component                   | Error Strategy                                                                  | Propagation                    |
| --------------------------- | ------------------------------------------------------------------------------- | ------------------------------ | ------------------------------------------------ | -------------------- |
| `_score_*_signals()`        | `                                                                               |                                | true` on every grep/jq; returns 0 on any failure | Score=0, never exits |
| `detect_project_type()`     | Catches all scoring errors; returns `{"project_type":"unknown","confidence":0}` | JSON with unknown, never exits |
| `recommend_template()`      | Returns `{"template":"standard"}` if input is malformed                         | Safe default, never exits      |
| `generate_project_config()` | Atomic write (tmp+mv); warns on stderr if directory missing                     | Warns only, never exits        |
| `sw-detect.sh`              | Validates jq availability; errors to stderr with exit 1                         | Only CLI exits non-zero        |
| `sw-prep.sh` integration    | Detection is optional enrichment; failure logged, prep continues                | No impact on existing flow     |
| `sw-setup.sh` integration   | Detection failure shows "unknown" in Phase 2 output                             | No impact on setup flow        |

### Signal Scoring Design

Each `_score_*` function accumulates points from independent signals. This avoids boolean logic problems where a single missing signal causes misclassification.

**Web signals** (per language):

- Server framework dep (express, fastify, django, flask, gin, actix-web, rails, spring-boot): +25
- `routes/`, `controllers/`, `views/` directory: +15
- `public/`, `static/`, `assets/` directory: +10
- Port/host config in env files or config: +10
- HTML/template files (_.html, _.ejs, \*.hbs): +10
- `src/server.*` or `src/app.*` file: +10

**CLI signals**:

- `bin` field in package.json / `[[bin]]` in Cargo.toml / `cmd/` in Go: +25
- CLI framework dep (commander, yargs, clap, cobra, click, argparse main): +20
- `#!/usr/bin/env` shebang in entry files: +15
- `src/cli.*` or `src/main.*` (non-web): +10
- No server framework present: +10

**Library signals**:

- `main`/`exports`/`types` in package.json / `[lib]` in Cargo.toml / `py_modules` in setup.py: +25
- `lib/` or `src/lib.*` directory/file: +15
- README with "install" or "usage" section: +10
- No bin field, no server framework: +10
- `typings`/`*.d.ts` files: +10

**Infrastructure signals**:

- `Dockerfile` or `docker-compose.yml`: +15
- `terraform/` or `*.tf` files: +25
- `k8s/`, `kubernetes/`, `helm/` directories: +20
- `.github/workflows/` with deploy jobs: +10
- CDK/Pulumi/CloudFormation files: +20
- `Makefile` with deploy/infra targets: +10

### Template Mapping

| Project Type         | Default Template | Rationale                                       |
| -------------------- | ---------------- | ----------------------------------------------- |
| web + deploy signals | `deployed`       | Web apps benefit from deploy+validate+monitor   |
| web (no deploy)      | `standard`       | Standard review cycle for web features          |
| cli                  | `fast`           | CLIs are typically simpler, fewer stages needed |
| library              | `standard`       | API surface review is important for libraries   |
| infrastructure       | `full`           | High-risk changes need maximum safety gates     |
| unknown              | `standard`       | Safe default when detection is uncertain        |

### Idempotency Strategy

- `detect_project_type()` is pure: same filesystem state = same JSON output, no side effects
- `generate_project_config()` writes `.claude/project-detection.json` atomically (tmp file + `mv`). Re-running overwrites with fresh detection — safe because the file is a cache, not user-edited config
- No deduplication needed — detection is deterministic from filesystem state

### Rollback Plan

- **Schema changes**: N/A — no database. Output is a JSON file that can be deleted
- **Code rollback**: Revert the 4 new files. Remove ~30 lines from prep/setup/sw-router. The integration points are guarded by `type detect_project_type >/dev/null 2>&1` checks, so removing the library degrades gracefully
- **Data rollback**: Delete `.claude/project-detection.json` from any repo where it was generated

## Alternatives Considered

1. **Monolithic detection in `sw-prep.sh`**
   - Pros: No new files, single source of truth
   - Cons: `sw-prep.sh` is already 1656 lines; detection logic not reusable from pipeline/daemon; testing requires sourcing the entire prep script with all its side effects; violates Single Responsibility
   - Rejected: Blast radius too high, not independently testable

2. **AI-only detection (Claude API)**
   - Pros: Handles edge cases perfectly (polyglot, unconventional layouts); no heuristic maintenance
   - Cons: Requires API key (breaks offline mode); adds ~2-5s latency; costs money per detection; non-deterministic (same repo could get different results)
   - Rejected as primary approach: Used as optional enrichment tier in `detect_project_lang()` already — extending that pattern for project type would add API dependency to a critical path. Heuristics cover >90% of cases.

3. **Static config file (user declares project type)**
   - Pros: 100% accurate; user controls behavior
   - Cons: Defeats the purpose of auto-detection; requires manual setup per repo; doesn't help new users or daemon-processed repos
   - Rejected: Auto-detection should be the default; user override via config is supported but not required

## Implementation Plan

### Files to create

- `scripts/lib/project-type-detection.sh` — Core detection library (~300 lines)
- `scripts/sw-detect.sh` — CLI subcommand for `shipwright detect` (~150 lines)
- `scripts/sw-detect-test.sh` — Test suite (~400 lines, 38 tests)
- `templates/project-types/` — Directory with 8 project type profile JSONs

### Files to modify

- `scripts/sw-prep.sh` — Source library, call after existing detection (~20 lines)
- `scripts/sw-setup.sh` — Display detection in Phase 2 (~10 lines)
- `scripts/sw` — Add `detect` case to router (~3 lines)
- `package.json` — Register `sw-detect-test.sh` in test scripts

### Dependencies

- No new external dependencies. Uses `jq` (already required), `grep`, `find`, file existence checks.

### Risk areas

- **Confidence calibration**: Initial signal weights are estimates. May need tuning after testing against real-world repos. Mitigation: threshold at 60% for "confident" and 40% for "low confidence vs unknown" provides safety margin.
- **Monorepo false positives**: A monorepo with `packages/web` and `packages/cli` may score highly on multiple types. Mitigation: `secondary_types` array reports all scores; primary is highest; ambiguous margin (<15 points) lowers confidence.
- **Prep integration regression**: New code in `prep_detect_stack()` path. Mitigation: Detection is wrapped in a function guard (`type detect_project_type >/dev/null 2>&1`); if the library isn't sourced, prep proceeds unchanged.

## Validation Criteria

- [ ] `detect_project_type()` correctly classifies 8+ project archetypes: node-web, node-cli, node-lib, go-web, go-cli, python-web, python-lib, rust-lib, java-web, infrastructure
- [ ] Confidence score >70 for unambiguous projects (single clear type with strong signals)
- [ ] Confidence score <40 returns `"unknown"` rather than guessing
- [ ] `recommend_template()` maps each project type to the correct pipeline template per the mapping table
- [ ] `shipwright detect` CLI prints human-readable output; `--json` prints machine-readable JSON
- [ ] `shipwright detect --generate` writes `.claude/project-detection.json` without corrupting existing `.claude/` files
- [ ] Integration with `sw-prep.sh` does not break any existing `sw-prep-test.sh` tests
- [ ] Integration with `sw-setup.sh` does not break any existing `sw-setup-test.sh` tests
- [ ] Detection completes in <2 seconds on a typical project (filesystem ops only, no network)
- [ ] Empty directory returns `{"project_type":"unknown","confidence":0}` without errors
- [ ] Monorepo with mixed signals reports primary + secondary types with appropriate confidence reduction
- [ ] All 38 tests in `sw-detect-test.sh` pass
- [ ] Full test suite (`npm test`) passes with no regressions
