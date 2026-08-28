## Pipeline Template Recommendation Algorithm

Design and implement the recommendation logic that translates detected project signals into pipeline template suggestions with one-line rationale.

### Recommendation Heuristic

Build a weighted scoring system that considers:

**Primary Signals** (high weight):
- **Monorepo**: Presence of workspaces/lerna/rush → `standard` or `full` (complexity increases)
- **Existing CI**: GitHub Actions/.circleci/gitlab-ci → confidence +1 for template maturity
- **Test Framework Maturity**: vitest/jest/mocha with >80% coverage → `fast` viable, <20% coverage → `standard` minimum
- **Repository Size**: <1k commits → `fast`, 1k-50k → `standard`, >50k → `full`

**Secondary Signals** (modifier):
- **Activity Level**: Last commit < 30 days = active, > 6 months = inactive (inactive repos often have simpler needs)
- **Language**: Node/Python/Go → `fast` if all signals lean simple; Rust/C++ → `standard`+ (compile overhead)
- **Dependency Count**: >100 deps → `standard` minimum (more integration risk)

### Template Selection Logic

```
if monorepo AND ci_present AND large_repo:
  recommend: full (rationale: "complex monorepo with CI history needs full pipeline")
else if test_coverage >= 80 AND small_repo AND active:
  recommend: fast (rationale: "high-confidence small project can use fast template")
else if budget_constrained OR startup_detected:
  recommend: cost-aware (rationale: "cost optimization priority detected")
else:
  recommend: standard (rationale: "balanced pipeline for typical project")
```

### Rationale Format

For each recommendation, output a one-line rationale citing which signals drove the choice:
- "high-confidence small project can use fast template" (cites: test coverage, repo size, activity)
- "complex monorepo with CI history needs full pipeline" (cites: monorepo, CI presence, size)
- "cost optimization priority detected" (cites: budget constraints or resource limits)

### Edge Cases & Fallbacks

1. **New/Empty Repo**: No signals yet → default to `standard` with rationale "new project, standard template recommended"
2. **Detection Conflicts**: Monorepo but tiny repo → weigh by commit count, recommend `fast`; output rationale noting the conflict resolution
3. **Incomplete Detection**: If CLI/build system unknown → skip that signal, don't force a recommendation
4. **User Override**: If user has hand-configured template in daemon-config.json, don't override—note in output: "template already configured, skipping recommendation"

### Integration Points

- **sw-prep.sh**: Add `--recommend` flag; output JSON object: `{"template": "standard", "rationale": "...", "signals": {"monorepo": false, ...}}`
- **shipwright init**: Read recommendation from prep; present as default in interactive prompt: `Choose template [standard]:` with hint `(recommended for your project)`
- **daemon-config.json**: If no template set and recommendation available, use it as initial value

### Testing Checklist

1. **Single-package project** with full test coverage → expect `fast`
2. **Monorepo with CI/CD config** → expect `standard` or `full`
3. **New empty repo** → expect `standard` (safe fallback)
4. **Project with conflicting signals** (monorepo + tiny) → verify correct weighting
5. **Large project, low test coverage** → expect `full` (safety bias)

### Maintenance

If new signals are added (e.g., dependency scanning, security alerts), update the weighting table and re-test all 5 scenarios.
