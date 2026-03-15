## Configuration Extraction Safety Pattern

When extracting hardcoded values to configurable settings, follow these proven patterns to ensure safety, backward compatibility, and correctness:

### 1. Safe Extraction with Fallback
```bash
# Pattern: Read from config, fall back to original hardcoded value
POLL_INTERVAL=$(jq '.daemon_timeouts.poll_interval // empty' config/policy.json 2>/dev/null || echo '')
POLL_INTERVAL=${POLL_INTERVAL:-30}  # Original hardcoded value becomes fallback
```

This ensures:
- Users without policy.json changes see identical behavior
- Fallback value documents the current/original behavior
- No breaking changes if config section is missing
- Transparent migration path for existing deployments

### 2. Validation Before Use
```bash
# Always validate extracted values against safe ranges
validate_timeout() {
  local value=$1 min=$2 max=$3 name=$4
  if ! [[ $value =~ ^[0-9]+$ ]] || (( value < min || value > max )); then
    error "Invalid timeout '$name': $value (must be integer $min-$max seconds)"
    return 1
  fi
}

validate_timeout "$POLL_INTERVAL" 5 300 "poll_interval"
```

Validation prevents silent configuration errors and provides clear operator feedback.

### 3. Configuration Structure with Documentation
```json
{
  "daemon_timeouts": {
    "poll_interval": 30,
    "health_check_interval": 60,
    "cleanup_interval": 300,
    "retry_delay_base": 5,
    "_comment": "All times in seconds. Ranges: poll 5-300, health 10-600, cleanup 60-3600, retry 1-30"
  }
}
```

Inline documentation prevents users from setting invalid values.

### 4. Testing Matrix for Configuration Values

**Backward Compatibility** (config absent):
- Daemon starts and behaves identically to before extraction
- All timeouts match original hardcoded values
- No config file required for existing deployments

**Default Config Path** (config with recommended values):
- Daemon starts with config file present
- Behavior remains identical to original hardcoded behavior

**Custom Values** (within safe range):
- Test conservative values (larger timeouts - slower but safer)
- Test aggressive values (smaller timeouts within range - faster polling)
- Verify dependent timeouts work together (e.g., health_check < poll_interval)

**Invalid Values** (detect and reject):
- Non-numeric values → validation error, clear message
- Zero or negative → validation error with safe range
- Extreme values (9999999) → validation error with max range
- Missing optional fields → use fallback values
- Type mismatches (string vs number) → validation error

### 5. Common Pitfalls to Avoid

1. **No validation** → Invalid config silently breaks daemon behavior or causes hangs
2. **Missing fallback** → Removing or updating config breaks existing deployments
3. **Unrelated timeouts grouped** → Changes to poll_interval shouldn't require understanding health_check
4. **No interaction testing** → Cascading/dependent timeouts may deadlock under specific combinations
5. **Insufficient documentation** → Users don't understand safe ranges and cause production incidents
6. **Silent failures** → Warn clearly if fallback is used due to invalid config

### 6. Documentation Requirements for Each Extracted Value

For each timeout extracted to config:
- **Current value**: Original hardcoded value (reference/default)
- **Purpose**: When/why this timeout is used in the daemon lifecycle
- **Safe range**: Minimum and maximum recommended values
- **Impact of change**: What happens if too high (missed events?) or too low (high CPU?)
- **Dependencies**: Other timeouts that must be coordinated with this one

### 7. Verification Checklist

- [ ] All hardcoded timeout values identified and documented
- [ ] Fallback values match original hardcoded values exactly
- [ ] Validation enforces safe ranges with clear error messages
- [ ] Default config/policy.json section provided and documented
- [ ] Tested without config present (backward compatibility verified)
- [ ] Tested with custom values within safe range
- [ ] Tested with invalid values (proper error handling and messaging)
- [ ] Tested timeout interactions and cascading effects
- [ ] No behavior change when using default values
- [ ] Operator documentation covers safe ranges and rationale

### 8. Safe Rollout Strategy

1. **Stage 1**: Deploy with fallback defaults (no config changes required)
2. **Stage 2**: Provide optional config/policy.json with recommended values
3. **Stage 3**: Document use cases for custom timeouts (e.g., high-load environments)
4. **Stage 4**: Monitor for validation errors in logs (indicates invalid user config)
5. **Stage 5**: Gather feedback on timeout ranges from production deployments
