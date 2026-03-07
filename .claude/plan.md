# Implementation Plan: Systematic Hardcoded Policy Discovery and Migration to Config

**Issue**: #202
**Branch**: `migrate/systematic-hardcoded-policy-discovery-an-202`
**Complexity**: Standard
**Template**: migration

---

## Brainstorming: Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A discovery script that scans all `scripts/*.sh` and `scripts/lib/*.sh` files for hardcoded numeric values and fallback patterns, generates a JSON report classifying each finding, produces a migration plan with priority rankings, and migrates the top 5 values as proof of concept.

**Implicit requirements**:

- Must not break any existing functionality — discovery is read-only, migrations use the existing `_config_get`/`policy_get` infrastructure
- Must integrate with the existing `config/policy.json` + `config/defaults.json` + `config/policy.schema.json` ecosystem
- The progress dashboard must be a CLI subcommand (consistent with all other shipwright commands)

**Acceptance criteria** (from issue):

1. Scan all scripts for hardcoded numeric values with context
2. Scan for fallback logic patterns
3. Generate migration plan with config structure and adaptive override strategy
4. Migration progress dashboard
5. Top 5 highest-priority value migrations as proof of concept
6. Integration with adaptive tuner

### Design Alternatives

**Alternative A: Standalone discovery script + migration tool**

- New `scripts/sw-policy-discovery.sh` script with `scan`, `report`, `migrate`, `dashboard` subcommands
- Regex-based scanning with context extraction
- JSON report output compatible with existing tooling
- **Pros**: Self-contained, testable, follows existing CLI patterns
- **Cons**: Another script to maintain

**Alternative B: Extend existing `sw-pipeline-vitals.sh` with hardcoded value tracking**

- Add hardcoded value counting to the vitals health scoring
- **Pros**: Integrates into existing health checks
- **Cons**: Vitals is already 1076 lines; mixing concerns; discovery needs its own subcommands

**Alternative C: Extend `sw-adaptive.sh` with discovery capabilities**

- **Pros**: Direct integration with tuning
- **Cons**: Adaptive is about runtime tuning from DORA data, not static analysis; mixing concerns

**Chosen approach**: **Alternative A** — standalone script. Minimizes blast radius, follows the project's one-script-per-command pattern, and keeps concerns separated. The adaptive integration is a hook, not a merge.

### Risk Assessment

| Risk                                     | Impact                      | Mitigation                                                                                                        |
| ---------------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Discovery regex produces false positives | Low — discovery is advisory | Confidence scoring + context extraction for human review                                                          |
| Migrating a value breaks a script        | Medium                      | Only migrate values already in `defaults.json` pattern; add tests first; use `_config_get` with existing fallback |
| Schema changes break validation          | Low                         | Additive schema changes only; existing tests validate                                                             |
| Too many findings overwhelm report       | Low                         | Priority ranking + dashboard filtering                                                                            |

### Dependency Analysis

**Depends on (all existing, stable)**:

- `scripts/lib/config.sh` — `_config_get()` precedence chain (env → daemon-config → policy → defaults)
- `scripts/lib/policy.sh` — `policy_get()` helper
- `config/policy.json` — existing policy values
- `config/defaults.json` — existing defaults
- `config/policy.schema.json` — JSON Schema validation
- `scripts/lib/helpers.sh` — output helpers (info, success, warn, error)
- `scripts/lib/test-helpers.sh` — test harness conventions

**Depended on by**: Nothing yet (new script). Future: `sw-adaptive.sh` will consume discovery output.

---

## Component Diagram

```
┌─────────────────────────────────────────────────────┐
│              sw-policy-discovery.sh                  │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐          │
│  │  Scanner  │  │ Reporter │  │ Dashboard │          │
│  │ (regex)   │→ │ (JSON)   │→ │  (CLI)    │          │
│  └──────────┘  └──────────┘  └───────────┘          │
│       │              │              ▲                 │
│       ▼              ▼              │                 │
│  ┌──────────┐  ┌──────────────┐    │                 │
│  │ Classifier│  │ Migration    │────┘                 │
│  │ (context) │  │ Plan Gen     │                      │
│  └──────────┘  └──────────────┘                      │
└───────────┬─────────────┬───────────────────────────┘
            │             │
            ▼             ▼
    ┌───────────┐  ┌──────────────┐
    │ defaults  │  │ policy.json  │
    │ .json     │  │ (+ schema)   │
    └───────────┘  └──────────────┘
            │
            ▼
    ┌───────────────┐
    │ sw-adaptive.sh│ (consumes discovery report)
    └───────────────┘
```

## Interface Contracts

```typescript
// Discovery report output (JSON)
interface DiscoveryReport {
  generated_at: string; // ISO 8601
  version: string; // "1"
  summary: {
    total_hardcoded: number;
    total_fallbacks: number;
    already_migrated: number;
    migration_candidates: number;
  };
  findings: Finding[];
}

interface Finding {
  file: string; // relative path
  line: number;
  value: string | number; // the hardcoded value
  context: string; // surrounding code (2 lines)
  type:
    | "timeout"
    | "limit"
    | "threshold"
    | "interval"
    | "retry"
    | "count"
    | "fallback";
  pattern:
    | "numeric_assignment"
    | "numeric_comparison"
    | "sleep"
    | "default_fallback"
    | "error_fallback"
    | "suppression";
  priority: 1 | 2 | 3 | 4 | 5; // 5 = highest ROI
  already_migrated: boolean; // true if value is read via _config_get/policy_get
  suggested_config_path: string; // e.g., "loop.convergence_threshold"
  adaptive_candidate: boolean; // true if adaptive tuner could optimize
}

// Dashboard output (CLI text)
// cmd_dashboard() -> stdout with colored progress bars

// Migration plan output (JSON)
interface MigrationPlan {
  candidates: MigrationCandidate[];
  schema_additions: object; // additions to policy.schema.json
  defaults_additions: object; // additions to defaults.json
}

interface MigrationCandidate {
  finding: Finding;
  config_key: string;
  default_value: number | string;
  migration_steps: string[];
}
```

## Data Flow

```
scan → grep scripts/*.sh for patterns → classify each match → score priority
  → compare against existing config/policy.json keys → mark already_migrated
  → generate JSON report → .claude/pipeline-artifacts/discovery-report.json
  → dashboard reads report → renders progress
  → migrate subcommand reads report → updates defaults.json + schema + script
```

## Error Boundaries

- Scanner: regex failures are non-fatal (skip and warn)
- Reporter: jq failures are fatal (malformed JSON is a bug)
- Dashboard: missing report file → prompt user to run `scan` first
- Migration: atomic file writes (tmp + mv); backup originals

---

## Files to Modify

### New Files

1. `scripts/sw-policy-discovery.sh` — Discovery engine with subcommands: `scan`, `report`, `plan`, `dashboard`, `migrate`
2. `scripts/sw-policy-discovery-test.sh` — Test suite

### Modified Files

3. `config/defaults.json` — Add new default values for top 5 migrated parameters
4. `config/policy.json` — Add new policy sections for migrated parameters
5. `config/policy.schema.json` — Add schema for new policy sections
6. `package.json` — Register test suite
7. `scripts/sw` — Register `policy-discovery` subcommand in CLI router
8. Up to 5 script files — Migrate top 5 hardcoded values to use `_config_get`

---

## Implementation Steps

### Step 1: Create discovery script skeleton

Create `scripts/sw-policy-discovery.sh` with standard boilerplate (VERSION, set -euo pipefail, helpers, subcommand routing). Subcommands: `scan`, `report`, `plan`, `dashboard`, `help`.

### Step 2: Implement scanner functions

Build regex-based scanner that greps across `scripts/*.sh` and `scripts/lib/*.sh` for:

- **Numeric assignments**: `VAR=<number>`, `local VAR=<number>`
- **Sleep/timeout**: `sleep <N>`, `timeout <N>`
- **Comparisons**: `-gt <N>`, `-lt <N>`, `-ge <N>`, `-le <N>`, `> <N>`, `< <N>`
- **Fallback patterns**: `${VAR:-<value>}`, `|| echo "<value>"`, `|| true`
- **Loop limits**: `for ((i=0; i<N;`

For each match, extract file, line number, value, and 2 lines of surrounding context.

### Step 3: Implement classifier and priority scorer

Classify each finding by type (timeout, limit, threshold, interval, retry, count, fallback). Cross-reference against existing `config/policy.json` and `config/defaults.json` keys to mark already-migrated values. Assign priority 1-5 based on the confidence scoring from the discovery skill (adaptive-tunable = 5, ambiguous = 2, security-critical = 1).

### Step 4: Implement report generator

Output findings as structured JSON to `.claude/pipeline-artifacts/discovery-report.json`. Include summary statistics.

### Step 5: Implement migration plan generator

For unmigrated findings with priority >= 4, generate:

- Suggested `config/defaults.json` key path
- Suggested `config/policy.schema.json` additions
- Code diff showing `_config_get` replacement

### Step 6: Implement progress dashboard

CLI dashboard showing:

- Total hardcoded values found
- Already migrated count (uses `_config_get`/`policy_get`)
- Migration candidates by priority tier
- Progress bar (migrated / total candidates)

### Step 7: Identify top 5 migration candidates

Based on scan results, select the 5 highest-priority unmigrated values. These will be values that:

- Are in hot-path scripts (pipeline, loop, daemon)
- Have clear semantics (timeouts, retry limits)
- Are good candidates for adaptive tuning
- Are NOT already read via `_config_get`

### Step 8: Migrate top 5 values

For each candidate:

1. Add default value to `config/defaults.json`
2. Add schema entry to `config/policy.schema.json`
3. Add override in `config/policy.json` (if different from default)
4. Replace hardcoded value in script with `_config_get` call
5. Source `lib/config.sh` if not already sourced

### Step 9: Add adaptive tuner integration hook

Add an `adaptive-candidates` subcommand that outputs the list of values suitable for `sw-adaptive.sh` auto-tuning. This provides a machine-readable list of config keys that the adaptive tuner can safely modify based on DORA metrics.

### Step 10: Register in CLI router and package.json

- Add `policy-discovery` case to `scripts/sw` CLI router
- Add test suite to `package.json` scripts

### Step 11: Write test suite

Create `scripts/sw-policy-discovery-test.sh` with tests for:

- Scanner finds known hardcoded values in test fixtures
- Classifier correctly categorizes findings
- Already-migrated values are marked correctly
- Dashboard renders without errors
- Report JSON is valid
- Priority scoring is consistent

### Step 12: Verify all existing tests still pass

Run `npm test` to ensure no regressions from migrations.

---

## Task Checklist

- [ ] Task 1: Create `sw-policy-discovery.sh` skeleton with subcommand routing
- [ ] Task 2: Implement scanner (regex patterns for hardcoded values and fallbacks)
- [ ] Task 3: Implement classifier and priority scorer
- [ ] Task 4: Implement JSON report generator (`scan` + `report` subcommands)
- [ ] Task 5: Implement migration plan generator (`plan` subcommand)
- [ ] Task 6: Implement progress dashboard (`dashboard` subcommand)
- [ ] Task 7: Implement adaptive-candidates output for tuner integration
- [ ] Task 8: Register CLI subcommand in `scripts/sw` router
- [ ] Task 9: Identify and migrate top 5 hardcoded values (update defaults.json, schema, policy, scripts)
- [ ] Task 10: Write test suite `sw-policy-discovery-test.sh`
- [ ] Task 11: Register test in `package.json` and run full test suite
- [ ] Task 12: Verify scan output and dashboard render correctly

---

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests** (~15 tests): Scanner regex matching, classifier categorization, priority scoring, already-migrated detection, report JSON structure
- **Integration tests** (~5 tests): Full scan of real codebase produces valid report, dashboard renders, plan generates valid schema additions
- **E2E tests** (~2 tests): CLI subcommands execute without error, migrated values are actually read from config

### Coverage Targets

- Scanner: 100% of pattern types tested (6 patterns)
- Classifier: All type categories verified
- Dashboard: Renders without errors on empty and populated reports
- Migrated values: Each of top 5 verified via `_config_get` integration

### Critical Test Cases

- **Happy path**: `scan` produces valid JSON with expected fields
- **Error case 1**: No scripts found in scan path → graceful empty report
- **Error case 2**: Malformed policy.json → scanner still completes (skips cross-reference)
- **Edge case 1**: Value appears in both hardcoded and config form → correctly marked
- **Edge case 2**: Nested fallback `${VAR:-${OTHER:-5}}` → innermost value extracted

---

## Definition of Done

- [ ] `shipwright policy-discovery scan` scans all scripts and produces JSON report
- [ ] Report includes hardcoded numeric values with file, line, value, context, type, priority
- [ ] Report includes fallback pattern detection (${VAR:-default}, || echo, || true)
- [ ] `shipwright policy-discovery plan` generates migration plan with config structure
- [ ] `shipwright policy-discovery dashboard` shows migration progress with counts
- [ ] Top 5 values migrated from hardcoded to `_config_get` with defaults.json + schema updates
- [ ] `shipwright policy-discovery adaptive-candidates` outputs machine-readable list for tuner
- [ ] All existing tests pass (`npm test`)
- [ ] New test suite passes with >= 15 PASS assertions
- [ ] No regression in any script that was migrated

---

## Alternatives Considered

| Approach                          | Complexity | Performance          | Maintainability                                 | Blast Radius            |
| --------------------------------- | ---------- | -------------------- | ----------------------------------------------- | ----------------------- |
| **A: Standalone script** (chosen) | Medium     | Good (one-time scan) | High (isolated)                                 | Low (new file only)     |
| B: Extend pipeline-vitals         | Low        | Good                 | Medium (adds to 1076-line file)                 | Medium (vitals changes) |
| C: Extend adaptive tuner          | Low        | Good                 | Low (mixes static analysis with runtime tuning) | Medium                  |

**Choice rationale**: Alternative A follows the project convention of one script per command, keeps discovery concerns separate from runtime tuning, and has the lowest blast radius since all new logic is in new files. The only existing file modifications are additive (new config keys, new CLI route, new test registration).

---

## Baseline Metrics

- **Current state**: `config/policy.json` has ~50 values across 10 sections. `config/defaults.json` has ~60 values across 12 sections. ~96 `_config_get`/`policy_get` calls across 23 scripts.
- **Estimated remaining**: ~44 hardcoded values + ~62 fallback blocks (per platform health report) not yet using the config system.
- **Target**: Migrate 5 values (proof of concept), document path for remaining ~39.

## Optimization Targets

- Scan should complete in < 5 seconds for the full script corpus (~100 files)
- Report JSON should be < 500KB
- Dashboard render should be instant (reads cached report)

## Profiling Strategy

- Not applicable (this is a development tooling script, not a hot path)

## Benchmark Plan

- Before: Count of `_config_get`/`policy_get` calls across codebase
- After: Same count + 5 (the migrated values)
- Verify with: `grep -r '_config_get\|policy_get' scripts/ | wc -l`

---

## Endpoint Specification

Not applicable — this is a CLI tool, not an API endpoint.

## Error Codes / Rate Limiting / Versioning

Not applicable — CLI tool with exit codes 0 (success) and 1 (error).
