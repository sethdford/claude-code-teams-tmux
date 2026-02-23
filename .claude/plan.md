# Plan: One-Command Demo Mode for Instant Onboarding

## Summary

Create `shipwright demo` — a single command that showcases Shipwright's full pipeline in a self-contained sandbox. No GitHub, no API keys, no prerequisites beyond bash and jq. The demo creates a temporary project with intentional bugs, runs a simulated pipeline through all 12 stages, and shows the user exactly what Shipwright does — in under 30 seconds.

## Files to Modify

| File                      | Action     | Purpose                                   |
| ------------------------- | ---------- | ----------------------------------------- |
| `scripts/sw-demo.sh`      | **Create** | Main demo command (~400 lines)            |
| `scripts/sw-demo-test.sh` | **Create** | Test suite (~250 lines)                   |
| `scripts/sw`              | **Edit**   | Register `demo` in CLI router + help text |
| `package.json`            | **Edit**   | Add test suite to `npm test` chain        |
| `.claude/CLAUDE.md`       | **Edit**   | Add demo to core-scripts AUTO section     |

## Architecture

### How It Works

```
shipwright demo
  → Creates temp sandbox (/tmp/sw-demo-XXXX/)
  → Scaffolds a mini Node.js project with a bug
  → Initializes git repo
  → Simulates 12 pipeline stages with realistic output
  → Shows: detection → planning → building → fixing → testing → PR
  → Prints "next steps" to get started for real
  → Cleans up temp directory
```

### Flags

| Flag      | Purpose                                  |
| --------- | ---------------------------------------- |
| `--keep`  | Don't clean up temp dir (for inspection) |
| `--fast`  | Skip animated delays (CI-friendly)       |
| `--quiet` | Minimal output                           |
| `--help`  | Usage info                               |

### No External Dependencies

- No `claude` CLI needed (simulated)
- No `gh` CLI needed (simulated)
- No GitHub API calls (`NO_GITHUB=true`)
- No tmux needed (runs in plain terminal)
- Only requires: bash, jq (both checked at startup)

## Implementation Steps

### 1. Create `scripts/sw-demo.sh`

The script has these sections:

**Header & Libraries** (~40 lines)

- Standard boilerplate: `set -euo pipefail`, `VERSION="3.1.0"`, script dir resolution
- Source `lib/compat.sh` and `lib/helpers.sh` with fallbacks
- Define `emit_event()` wrapper

**Help & Argument Parsing** (~30 lines)

- Parse `--keep`, `--fast`, `--quiet`, `--help`
- Show usage with examples

**Sandbox Setup** (`setup_sandbox()` ~60 lines)

- Create temp directory with `mktemp -d`
- Scaffold a mini project:
  - `package.json` (name, version, test script)
  - `src/auth.js` (auth function with intentional bug: returns `403` instead of `401`)
  - `tests/auth.test.js` (test that expects `401`, will fail)
  - `.gitignore`
- Initialize git repo, make initial commit

**Stage Simulation** (`run_demo_pipeline()` ~200 lines)

Each stage prints a boxed header, simulates work with brief delay (unless `--fast`), and shows a result. Stages:

1. **Intake** — Display the "issue": `Fix auth middleware returning wrong status code`
2. **Plan** — Show detected: Node.js project, 1 test file, 1 source file. Print a mini task checklist.
3. **Design** — Show architecture analysis: "Single-module fix, low risk, no dependencies affected"
4. **Build** — Show the fix: diff-style output changing `403` → `401` in `src/auth.js`. Actually apply the fix to the sandbox file.
5. **Test** — Run the actual test (`node tests/auth.test.js` — a self-contained assertion script, no jest needed). Show pass/fail.
6. **Review** — Show simulated code review output (clean code, no issues)
7. **Compound Quality** — Show quality score: 95/100
8. **PR** — Show simulated PR creation: title, body, files changed
9. **Merge** — Show simulated merge
10. **Deploy** — Show "deployment to staging" (simulated)
11. **Validate** — Show "health check passed" (simulated)
12. **Monitor** — Show "no regressions detected" (simulated)

Key design: stages 1-5 use the actual sandbox files (real git operations, real test execution). Stages 6-12 are purely visual simulation.

**Results Summary** (`show_results()` ~40 lines)

- Total time elapsed
- Stages completed (12/12)
- Files changed: 1
- Tests: 1 passing (was 0)
- Show the sandbox path if `--keep` was used

**Next Steps** (`show_next_steps()` ~30 lines)

- `shipwright init` — Set up your repo
- `shipwright pipeline start --issue N` — Run a real pipeline
- `shipwright daemon start` — Auto-process issues
- Link to docs

**Cleanup** — trap handler to remove temp dir (unless `--keep`)

### 2. Register in CLI Router (`scripts/sw`)

Add to `show_help()` in the GETTING STARTED section (after `doctor`):

```
  demo                  Try Shipwright instantly — no setup needed
```

Add to `main()` case statement (near `init`/`setup`):

```bash
demo)
    exec "$SCRIPT_DIR/sw-demo.sh" "$@"
    ;;
```

### 3. Create Test Suite (`scripts/sw-demo-test.sh`)

Using the standard test harness pattern with `lib/test-helpers.sh`:

**Tests (~15 cases):**

1. `--help` flag shows usage text
2. Script exits 0 on successful run with `--fast`
3. Sandbox directory is created during run
4. Sandbox is cleaned up after run (no `--keep`)
5. Sandbox is preserved with `--keep`
6. `src/auth.js` is created in sandbox
7. `tests/auth.test.js` is created in sandbox
8. Git repo is initialized in sandbox
9. Bug fix is applied (auth.js contains `401` after build stage)
10. Test passes after fix is applied
11. All 12 stage names appear in output
12. PR summary appears in output
13. Next steps section appears in output
14. `--quiet` flag reduces output
15. Script works without jq (graceful degradation or clear error)

### 4. Register Test in `package.json`

Add `&& bash scripts/sw-demo-test.sh` to the `"test"` script, placed alphabetically after the `sw-db-test.sh` entry.

### 5. Update CLAUDE.md

Add `sw-demo.sh` row to the `AUTO:core-scripts` table and `sw-demo-test.sh` to `AUTO:test-suites`.

## Task Checklist

- [ ] Task 1: Create `scripts/sw-demo.sh` with header, help, and argument parsing
- [ ] Task 2: Implement `setup_sandbox()` — temp dir, scaffold project, git init
- [ ] Task 3: Implement stage simulation functions (intake through monitor)
- [ ] Task 4: Implement results summary and next-steps output
- [ ] Task 5: Add cleanup trap and `--keep` flag support
- [ ] Task 6: Register `demo` command in `scripts/sw` (router + help text)
- [ ] Task 7: Create `scripts/sw-demo-test.sh` test suite
- [ ] Task 8: Register test in `package.json`
- [ ] Task 9: Run tests and fix any failures
- [ ] Task 10: Update CLAUDE.md documentation tables

## Testing Approach

1. **Unit tests** (`sw-demo-test.sh`): 15 tests covering flags, sandbox lifecycle, stage output, and cleanup
2. **Manual smoke test**: Run `shipwright demo --fast` and verify all 12 stages complete with exit 0
3. **Cleanup verification**: Confirm no temp files remain after normal run
4. **CI compatibility**: `--fast` flag skips delays, making it suitable for CI environments
5. **Cross-platform**: Use only Bash 3.2 features, test on Linux (CI) — compat.sh handles platform differences

## Definition of Done

- [ ] `shipwright demo` runs to completion with exit 0, showing all 12 stages
- [ ] `shipwright demo --fast` completes in under 10 seconds
- [ ] `shipwright demo --keep` preserves the sandbox for inspection
- [ ] `shipwright demo --help` shows usage
- [ ] No external dependencies (no claude CLI, no gh CLI, no GitHub API)
- [ ] Test suite passes with 0 failures
- [ ] `npm test` includes and passes the new test suite
- [ ] Demo uses only Bash 3.2 compatible constructs
- [ ] CLAUDE.md tables updated
