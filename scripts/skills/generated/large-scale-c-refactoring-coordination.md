## Large-Scale C Refactoring Phase Coordination

When refactoring 30+ files across a C codebase with strict testing requirements (3849+ tests, ASan compliance), poor phase planning causes cascading test failures, leaked allocations detected late, and scope creep that undermines velocity.

### Phase Planning Discipline

1. **Identify minimal-dependency phases** — Group files by coupling:
   - Phase 1: New module + infrastructure (hu_data_loader, CMake xxd setup)
   - Phase 2: Static/non-behavioral changes (word lists, prompts)
   - Phase 3: Threshold configurations (no logic changes)
   - Phase 4: Integrations (callers updated)
   - Don't merge phases with circular dependencies or high rework risk

2. **Test stability checkpoints** — After each phase:
   - Run full suite: `./build/human_tests` (all 3849+)
   - Run ASan: `./build/human_tests --asan-report` (0 errors)
   - Diff test counts: ensure no tests skip or disappear
   - Single regression fails the phase

3. **Rollback points** — If a phase breaks tests:
   - Never push through red tests hoping later phases fix them
   - Revert the phase, fix root cause, re-test in isolation
   - Document why it failed in your memory for similar patterns

### One-Concern-Per-Commit Rule

Large refactors tempt you to batch changes. Resist:

```
❌ WRONG: "Externalize data + refactor loader API + add config"
✅ RIGHT: "Add hu_data_loader module with xxd embedding"
         "Update CMakeLists.txt for xxd generation"
         "Replace hardcoded word lists with hu_data_load() calls"
```

Each commit should pass tests independently. If a later commit breaks something, bisect pinpoints the exact change.

### ASan Leak Detection Between Phases

- After each phase, run: `ASAN_OPTIONS=detect_leaks=1 ./build/human_tests`
- New leaks in data loading must be fixed before moving forward
- Track ASan suppressions in `.claudeignore` or test config, document why
- Example: if xxd-embedded data needs special cleanup, add integration test to verify

### Scope Creep Prevention

- **Resist refactoring temptation** — If you find ugly code while phasing, note it in MEMORY but don't fix it now. Separate PR later.
- **Document phase boundaries** — Write them in your task list and stick to scope.
- **Review diffs carefully** — Large phases hide changes. Keep phase PRs under 400 lines if possible.

### Coordination Across Phases

- Use a shared checklist (`.claude/phase-checklist.md`) to track: data files created, config schema updated, tests passing, ASan clean
- If a later phase reveals earlier phase needs rework, update the phase and re-run its tests before continuing
- Don't hold uncommitted changes across phases—commit or stash between phases

### Common Pitfalls

1. **Building embedded defaults before measuring** — Measure original hardcoded values first (word count, threshold ranges, string encodings). Ensure embedded defaults match exactly.
2. **Forgetting cleanup paths** — New data loader functions must free allocations. ASan will catch this at phase end, but better to test per-function.
3. **CMake fragility** — xxd-based file generation can fail silently on some platforms. Test incremental rebuilds (`touch data/file.txt && cmake --build build`) on Linux + macOS.
4. **Config backward compatibility** — If adding new required fields (e.g., `data_dir`), don't break existing deployments. Provide sensible defaults or environment variable overrides.
5. **Mixing behaviors** — Don't change logic (e.g., "also apply new threshold") in the same phase as externalizing the threshold. Two phases: externalize first, change behavior second.

### Example Phase Sequence

```
Phase 0: Setup
  - Create src/data/loader.c with hu_data_load() skeleton
  - Create data/ directory structure
  - Add CMake xxd command (doesn't embed anything yet)
  - Tests: 3849 pass, ASan clean

Phase 1: Embedded Defaults
  - Add a single data file (e.g., data/prompts/safety_rules.txt)
  - Generate embedded_safety_rules.c via xxd
  - Implement hu_data_load() to return embedded data
  - Update one caller to use hu_data_load()
  - Tests: 3849 pass, ASan clean, verify embedded data loads correctly

Phase 2: File Override Path
  - Extend hu_data_load() to check ~/.human/data/ first
  - Add unit test: hu_data_load() returns file override if present
  - Tests: 3849 pass, ASan clean

Phase 3: Remaining Data Files
  - Add remaining data files (word lists, prompts, etc.)
  - Update all callers to hu_data_load()
  - Tests: 3849 pass, ASan clean

Phase 4: Config Integration
  - Add temp_dir, data_dir, threshold fields to config
  - Update callers to use config fields instead of hardcoded values
  - Tests: 3849 pass, ASan clean
```

Each phase is independently testable and deployable.
