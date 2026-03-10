# Pipeline Quality Revolution — Design Spec

**Date**: 2026-03-10
**Status**: Approved
**Goal**: Close 6 quality gaps + AI-readiness foundation so autonomous agents deliver better than humans

## Problem

Shipwright's pipeline infrastructure works — it polls issues, spawns agents, runs builds, creates PRs. But the _quality_ of output is mediocre because:

1. Plans are optimistic checklists without adversarial thinking
2. Definition of Done is written by the same agent that implements (fox/henhouse)
3. Agents don't understand _why_ they're building something
4. No feedback loop from PR review quality or post-merge outcomes
5. Code review is advisory, not adversarial — agents rubber-stamp
6. No scope discipline — PRs balloon to 16K+ lines

And underneath all of this: repos aren't "AI-ready." The daemon has no project-specific quality standards.

## Architecture

```
PREP (AI-Readiness Foundation) ──────────────────────
  │  Interactive quality profile dialogue
  │  → .claude/quality-profile.json
  │  → enriched CLAUDE.md
  ▼
INTAKE ──────────────────────────────────────────────
  │  Intent analysis: WHO/WHAT/WHY/HOW/NOT
  │  → .claude/pipeline-artifacts/acceptance-criteria.json
  ▼
PLAN ────────────────────────────────────────────────
  │  Constrained by external acceptance criteria
  │  Mandatory failure mode analysis section
  │  → plan.md (with "Files to Modify" for scope tracking)
  ▼
BUILD ───────────────────────────────────────────────
  │  "never_ship" rules injected every iteration
  │  Scope tracking: planned vs actual files
  │  Quality rules from learned patterns
  ▼
REVIEW ──────────────────────────────────────────────
  │  Adversarial-by-default, must find 3+ issues
  │  Bugs block (not just criticals)
  │  Scope creep flagged from plan diff
  ▼
COMPOUND_QUALITY ────────────────────────────────────
  │  Machine-verifiable DoD scorecard
  │  Each acceptance criterion: PASS/FAIL with evidence
  ▼
PR ──────────────────────────────────────────────────
  │  PR size gate (configurable, default 500 lines)
  ▼
POST-MERGE ──────────────────────────────────────────
     Review comment capture → memory
     Merge quality score tracking
     Auto-generated quality rules from patterns
```

## Component Designs

### Component 1: Quality Profile (`quality-profile.json`)

The keystone. Every pipeline stage reads this to calibrate behavior to the project.

**Schema:**

```json
{
  "version": 1,
  "project_name": "string",
  "generated_at": "ISO-8601",
  "architecture": {
    "pattern": "monolith|modular_monolith|microservices|serverless|library",
    "layers": ["string"],
    "dependency_direction": "inward|none",
    "rules": ["string — architectural constraints"]
  },
  "testing": {
    "philosophy": "tdd|test_after|coverage_target|manual",
    "min_coverage_delta": 0,
    "required_test_types": ["unit", "integration", "e2e"],
    "test_cmd": "string",
    "fast_test_cmd": "string"
  },
  "quality": {
    "max_pr_lines": 500,
    "max_files_per_pr": 15,
    "never_ship": ["string — absolute rules"],
    "always_require": ["string — positive requirements"],
    "learned_rules": [
      {
        "rule": "string",
        "source": "string — how this was learned",
        "confidence": 0.0-1.0,
        "created_at": "ISO-8601",
        "inject_at": ["plan", "build", "review"]
      }
    ]
  },
  "review": {
    "focus_areas": ["string"],
    "blocking_severities": ["critical", "bug", "security"],
    "min_issues_to_find": 3
  },
  "scope": {
    "unplanned_files_block": false,
    "decomposition_threshold_lines": 500
  },
  "deployment": {
    "strategy": "direct|preview_then_production|staged_rollout",
    "rollback_plan": "revert_commit|feature_flag|manual",
    "monitoring_window_minutes": 30
  }
}
```

**Generation**: `shipwright prep --interactive` runs a guided dialogue analyzing repo structure, configs, tests, CI, and asking 5-7 targeted questions. `shipwright prep --auto` infers from repo analysis with confidence scores.

**Location**: `.claude/quality-profile.json` (checked into repo, grows over time)

### Component 2: Intent Analysis (Intake Stage Enhancement)

**Trigger**: Runs in `stage_intake()` after issue metadata is fetched, before plan stage.

**Prompt template**:

```
Analyze this issue deeply before any implementation planning.

Issue: {title}
Body: {body}
Labels: {labels}

Project architecture: {quality_profile.architecture}

Produce a structured analysis:

1. WHO benefits? (end user / developer / ops / CI)
2. WHAT changes? (concrete before→after behavior, with examples)
3. WHY does this matter? (pain solved / capability unlocked)
4. HOW will we know it worked? (observable signals — specific, testable)
5. WHAT SHOULD WE NOT DO? (explicit out-of-scope boundaries)
6. ACCEPTANCE CRITERIA: 3-7 machine-verifiable criteria

Output JSON to acceptance-criteria.json matching this schema:
{schema}
```

**Output**: `acceptance-criteria.json` saved to pipeline artifacts. Passed to plan stage as input constraint.

**Key design decision**: Intent analysis runs as a _separate Claude session_ from planning. The analyst defines "what success looks like." The planner figures out "how to get there."

### Component 3: Adversarial Plan Validation (Plan Stage Enhancement)

**Trigger**: After plan is generated, before plan validation gate.

**Injected into plan prompt**:

```
After your implementation plan, include a MANDATORY section:

## Failure Mode Analysis
For each major component or decision:
1. Runtime failures: What happens when dependencies are unavailable?
2. Concurrency risks: Race conditions, stale state, duplicate processing?
3. Scale risks: 10x data, slow external deps, memory pressure?
4. Rollback story: Can we revert safely without data loss?

Project architecture rules to consider:
{quality_profile.architecture.rules}

You MUST identify at least 3 concrete failure modes.
Address the most critical one in your implementation plan.
```

**Validation gate addition**: New rejection reason `missing_failure_analysis` — plan is rejected if the failure mode section is empty, has fewer than 3 items, or contains only generic platitudes (detected by checking for project-specific references).

### Component 4: Scope Enforcement (Build + PR Stage Enhancement)

**A. Planned files tracking (build stage)**:
Extract "Files to Modify" from `plan.md` at build start. After each iteration, compare `git diff --name-only` against planned files. Log unplanned files to `scope-report.json`.

**B. PR size gate (PR stage)**:

```bash
total_lines=$(git diff --stat origin/main...HEAD | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
max_lines=$(jq -r '.quality.max_pr_lines // 500' "$QUALITY_PROFILE")
if [[ "$total_lines" -gt "$max_lines" ]]; then
    error "PR is ${total_lines} lines (max: ${max_lines}). Decompose into smaller PRs."
    exit 1
fi
```

**C. Scope report injection into review**:
The review stage receives `scope-report.json` listing unplanned files. Reviewer must justify or flag each.

### Component 5: Adversarial Review (Review Stage Enhancement)

**New review prompt** (replaces current generic prompt):

```
You are a SKEPTICAL senior engineer reviewing code for production.
Your job is to FIND PROBLEMS, not confirm quality.

Project standards (from quality-profile.json):
- Never ship: {quality_profile.quality.never_ship}
- Always require: {quality_profile.quality.always_require}
- Focus areas: {quality_profile.review.focus_areas}
- Learned rules: {quality_profile.quality.learned_rules}

Definition of Done (from acceptance-criteria.json):
{acceptance_criteria}

Scope report (planned vs actual files):
{scope_report}

Rules:
1. Find at least {min_issues_to_find} issues. If truly zero issues exist,
   write a paragraph explaining why this code is exceptional.
2. Rate each: Critical / Bug / Security / Warning / Suggestion
3. Check EVERY acceptance criterion — mark PASS/FAIL with evidence.
4. Flag every unplanned file — justify or mark as scope creep.
5. Check every "never_ship" rule — cite violations with line numbers.
```

**Blocking change**: Gate condition becomes `critical_count + bug_count + security_count > 0` (bugs now block).

### Component 6: Machine-Verifiable DoD Scorecard (Compound Quality Enhancement)

**Computed checks** (no LLM needed):

```json
{
  "scorecard": {
    "pr_size": { "status": "pass", "value": 247, "limit": 500 },
    "test_count_delta": { "status": "pass", "value": 12, "baseline": 0 },
    "coverage_delta": { "status": "pass", "value": 2.1, "min": 0 },
    "lint_warnings_delta": { "status": "pass", "value": 0, "max": 0 },
    "planned_files_coverage": {
      "status": "pass",
      "planned": 5,
      "touched": 5,
      "unplanned": 1
    },
    "never_ship_violations": { "status": "pass", "violations": [] },
    "acceptance_criteria": [
      {
        "id": "ac-1",
        "status": "pass",
        "evidence": "GET /api/users returns 200 in test output"
      },
      {
        "id": "ac-2",
        "status": "fail",
        "evidence": "No test for 401 response on invalid token"
      }
    ]
  },
  "overall": "fail",
  "blocking_failures": ["ac-2"]
}
```

Machine checks run first. LLM-based checks (adversarial, negative testing) run only if machine checks pass. This is faster and cheaper.

### Component 7: Outcome Feedback Loop (Post-Merge Enhancement)

**A. PR Review Capture** (new function in `sw-feedback.sh`):

```bash
capture_review_feedback() {
    local pr_number="$1"
    local reviews=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" --jq '.[].body')
    local comments=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" --jq '.[].body')
    # Store in memory with type "review_feedback"
    # Extract patterns for quality rule generation
}
```

**B. Merge Quality Score** (new function in `sw-feedback.sh`):
Track per-PR: `clean_merge` (+1), `changes_requested` (-1), `reverted` (-3), `regression` (-2). Rolling average → pipeline quality score in DORA dashboard.

**C. Quality Rule Auto-Generation** (new function in `sw-memory.sh`):
When same review pattern appears 3+ times, generate a quality rule and add to `quality-profile.json`'s `learned_rules` array. Rules are injected into plan, build, and review stages.

## Data Flow

```
quality-profile.json ──→ ALL STAGES (standards calibration)
         │
         ├──→ intake: intent analysis prompt
         ├──→ plan: failure mode analysis prompt + acceptance criteria constraints
         ├──→ build: never_ship rules + learned quality rules
         ├──→ review: focus areas + blocking rules + scope report
         ├──→ compound_quality: machine check thresholds
         └──→ pr: size limits

acceptance-criteria.json ──→ plan (constraints) → review (checklist) → compound_quality (scorecard)
scope-report.json ──→ review (scope creep detection) → pr (size gate)
dod-scorecard.json ──→ compound_quality output → pr gate
merge-quality.jsonl ──→ feedback → quality-profile.json (learned_rules)
```

## Testing Strategy

Each component has a corresponding test:

- `sw-quality-profile-test.sh` — profile generation, schema validation, merge with learned rules
- `sw-intent-analysis-test.sh` — acceptance criteria extraction, JSON schema compliance
- `sw-scope-enforcement-test.sh` — planned vs actual file tracking, PR size gate
- `sw-adversarial-review-test.sh` — minimum issue finding, blocking behavior, scope creep detection
- `sw-dod-scorecard-test.sh` — machine check computation, pass/fail logic
- `sw-outcome-feedback-test.sh` — review capture, quality score, rule auto-generation

Integration: `sw-pipeline-test.sh` gains tests for quality profile flow through all stages.

## Files to Create

| File                               | Purpose                                               |
| ---------------------------------- | ----------------------------------------------------- |
| `scripts/lib/quality-profile.sh`   | Profile loading, validation, merge with learned rules |
| `scripts/lib/intent-analysis.sh`   | Issue intent analysis, acceptance criteria generation |
| `scripts/lib/scope-enforcement.sh` | Planned vs actual file tracking, PR size gate         |
| `scripts/lib/dod-scorecard.sh`     | Machine-verifiable DoD computation                    |
| `scripts/lib/outcome-feedback.sh`  | Review capture, quality score, rule generation        |

## Files to Modify

| File                                                       | Changes                                                     |
| ---------------------------------------------------------- | ----------------------------------------------------------- |
| `scripts/lib/pipeline-stages-intake.sh`                    | Add intent analysis step, generate acceptance-criteria.json |
| `scripts/lib/pipeline-stages-intake.sh` (plan section)     | Inject failure mode analysis, consume acceptance criteria   |
| `scripts/lib/pipeline-stages-build.sh`                     | Inject never_ship rules, scope tracking                     |
| `scripts/lib/pipeline-stages-review.sh`                    | New adversarial review prompt, bug-blocking, scope report   |
| `scripts/lib/pipeline-stages-review.sh` (compound_quality) | Machine DoD scorecard before LLM checks                     |
| `scripts/lib/pipeline-stages-delivery.sh`                  | PR size gate                                                |
| `scripts/sw-prep.sh`                                       | Interactive quality profile generation                      |
| `scripts/sw-feedback.sh`                                   | PR review capture, merge quality score                      |
| `scripts/sw-memory.sh`                                     | Quality rule auto-generation from patterns                  |
| `scripts/sw-pipeline-test.sh`                              | Integration tests for quality profile flow                  |
