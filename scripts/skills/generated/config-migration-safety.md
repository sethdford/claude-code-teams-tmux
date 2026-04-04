## Config Migration Safety: Hardcoded Pattern → Validated Config

### Phase 1: Fallback Pattern Inventory
1. **Identify all 67 patterns** — Use grep/AST analysis to find all hardcoded fallback patterns (e.g., `|| default_value`, sentinel returns, if-empty checks)
2. **Categorize by impact** — Score by frequency of use, blast radius (how many code paths depend on it), and stability (how often does it fail?)
3. **Select top 20** — Choose patterns that are frequently used and represent distinct config categories (e.g., timeouts, retry counts, feature flags, environment defaults)
4. **Document rationale** — For each pattern: current code location, what it defaults to, why it exists, any known issues

### Phase 2: Schema Design with Validation
1. **Define config structure** — Group related fallbacks into logical sections (networking, retries, features, performance). Use nested JSON with clear naming.
2. **Write schema validation** — Use JSON Schema or domain-specific validation. For each field:
   - Mark as `required: true` if fallback is critical
   - Set realistic `min`, `max`, `enum` constraints
   - Provide `description` explaining what the setting controls
3. **Embed validation in startup** — Add a `validate_config()` function that runs before any service starts. Fail fast with stack trace showing exact missing/invalid fields.
4. **Default values documentation** — Every schema field must have an explicit default documented in code comment, not implicit in fallback logic.

### Phase 3: Operator Migration Path
1. **Generate migration guide** — For each top 20 pattern, show:
   - Old hardcoded value (e.g., `DEFAULT_TIMEOUT = 30`)
   - New config path (e.g., `config.networking.timeout_seconds`)
   - Migration command (e.g., `cp config.default.json config.json && edit config.json`)
   - Validation command (`./shipwright doctor --validate-config`)
2. **Provide config templates** — Ship `config.default.json` with all 20 patterns populated to sensible defaults. Minimal setup: `cp config.default.json config.json`.
3. **Version config schema** — Add `"schema_version": "1.0"` to config. On startup, check if schema version matches codebase; alert on mismatch.

### Phase 4: Testing & Validation
1. **Unit tests** — Each config field has tests for:
   - Valid values (from schema min/max/enum)
   - Invalid values (out of range, wrong type, unrecognized keys)
   - Missing required fields (clear error message)
2. **Integration tests** — System boots with default config, with custom config, with incomplete config (should fail at startup with actionable error).
3. **Operator smoke test** — New operators follow migration guide step-by-step; time to first success ≤ 5 minutes.

### Phase 5: Safety Guardrails
1. **Backward compatibility** — If old hardcoded fallbacks remain in code, startup validation should warn (not error) if config doesn't override them.
2. **Validation error clarity** — When startup validation fails, error message must include:
   - Exact config path that's missing/invalid
   - Example valid value (from schema or default)
   - Link to migration guide section
3. **Audit trail** — Log which config values were applied at startup. Post-deploy, verify operators' actual config matches migration guide expectations.
4. **Rollback path** — Document how to revert to old behavior if new config breaks production (e.g., restore `config.default.json`).

### Metrics
- **Fallback elimination**: Count patterns migrated (target: 20) and residual hardcoded fallbacks (target: <40).
- **Config validation**: Track startup validation failures (should drop after migration window).
- **Operator adoption**: Time from release to 90% of deployments using new config (target: <2 weeks).
