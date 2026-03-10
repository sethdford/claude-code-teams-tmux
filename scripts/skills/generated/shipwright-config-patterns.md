## Shipwright Config Pattern Guidance

When extracting hardcoded values into Shipwright config files, follow these patterns:

### Config Hierarchy
1. **Shipwright Defaults** (`scripts/config/build-loop-defaults.json`): Baseline for all installations
2. **Global Override** (`.claude/daemon-config.json`): Per-machine overrides, set once
3. **Per-Repo Override** (`.claude/build-loop-config.json`): Repository-specific tuning

Each level only needs to specify values that differ from the previous level. Merge at runtime, not at file edit time.

### Config Schema Design
- **Namespacing**: Group related tunables under a common key (e.g., `build_loop.max_iterations`, `build_loop.timeout_seconds`)
- **Validation**: Include JSON Schema validators inline or use `jq` to validate structure before use
- **Comments**: JSON doesn't support comments natively; use a `_notes` key for guidance or generate documentation from a schema file
- **Defaults**: Every config value should have a sensible default in the code (fallback if file missing)

### Backward Compatibility
- If code reads from missing config, always fall back to hardcoded default with a debug log
- Never error on missing config file—only error on unparseable JSON or invalid values
- Test that builds succeed with zero config files present (pure defaults)

### Per-Value Overridability
- Use environment variables (`BUILD_LOOP_MAX_ITERATIONS=100 shipwright loop`) for CI/automation
- Config file overrides env var (if both present, log which won)
- Flag overrides both (e.g., `--max-iterations 100`)

### Documentation Format
- Add a `--show-config` flag that prints active config with source (default/global/repo) labeled
- Generate a reference doc from schema showing all tunables, defaults, and tuning guidance
- Include examples of common overrides (e.g., "for resource-constrained agents", "for complex codebases")

### Testing Config System
- Test 1: No config files present → uses hardcoded defaults
- Test 2: Global config only → global values override defaults
- Test 3: Repo config only → repo values override defaults
- Test 4: Both global and repo config → repo overrides global, global overrides defaults
- Test 5: Malformed JSON → graceful fallback to defaults + error log
- Test 6: Missing keys in config → uses default for missing key
- Test 7: Environment variable + config file → config wins, log which is active
