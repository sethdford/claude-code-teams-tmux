# Implementation Plan: Hardcoded Policy Migration Engine with Adaptive Override Framework

**Goal**: Migrate hardcoded policy values across the codebase into a centralized, policy-driven system with an adaptive override framework that allows runtime-learned values to safely override static policies.

**Status**: Planning Phase  
**Target Completion**: 14 implementation tasks  
**Branch**: ci/issue-660

---

## Executive Summary

### What This Solves

The Shipwright codebase has critical policy values scattered as hardcoded constants across shell scripts (timeouts, escalation thresholds, model selection rules, etc.). This makes it:

1. **Hard to tune** — Changing a timeout requires script edits and testing
2. **Difficult to learn** — Adaptive values can't systematically override policy
3. **Fragile** — No schema validation for policy values
4. **Opaque** — No audit trail of which policy is active (hardcoded, static, or learned)

### Proposed Solution

A **Policy Migration Engine** that:

1. **Centralizes all hardcoded values** into `config/policy.json` with schema validation
2. **Establishes a precedence chain** for policy resolution (learned > user override > repo > hardcoded defaults)
3. **Provides an Adaptive Override Framework** that safely applies learned/optimized values at runtime
4. **Maintains backward compatibility** — scripts that don't use the policy system continue to work
5. **Audits policy decisions** — logs which policy was selected and why (hardcoded/repo/user/learned)

---

## Alternatives Considered

### Alternative 1: Full Bash Associative Array Rewrite (Rejected)

**Approach**: Rewrite all policy access to use bash 4.0+ associative arrays with a centralized registry.

**Pros**:

- Type-safe policy access
- Faster than jq-based lookups
- Single registry object in memory

**Cons**:

- **Breaks bash 3.2 compatibility** — violates CLAUDE.md requirement
- Requires rewriting adaptive-timeout.sh, adaptive-model.sh, and ~15 library functions
- Massive blast radius (tested, but fragile)
- No schema validation available
- **Verdict: REJECTED** — codebase explicitly supports bash 3.2

### Alternative 2: Environment Variable Only (Rejected)

**Approach**: Expose all policies via environment variables at startup (`export POLICY_TIMEOUT_BUILD=1800`).

**Pros**:

- Simple; no new infrastructure
- Fast O(1) lookups
- No file I/O overhead

**Cons**:

- **No runtime learning** — can't change an env var and have it take effect mid-pipeline
- **Poor auditability** — no way to know which env var came from which source
- Doesn't support user overrides (`~/.shipwright/policy.json`)
- Precedence chain becomes implicit and fragile
- **Verdict: REJECTED** — doesn't support adaptive overrides or user customization

### Alternative 3: Dynamic Policy Loader with Precedence Chain (Chosen)

**Approach**: Create a lightweight `policy_get()` helper that resolves a policy key through a precedence chain:

1. **Learned** — `~/.shipwright/learned-policy.json` (written by RL agent)
2. **User Override** — `~/.shipwright/policy.json` (user customization)
3. **Repo Policy** — `config/policy.json` (version controlled)
4. **Hardcoded Default** — fallback in the function itself

**Pros**:

- ✅ No bash 3.2 compatibility issues
- ✅ Runtime-safe learned overrides
- ✅ Supports user customization
- ✅ Auditability (can log which source was used)
- ✅ Schema validation via JSON Schema
- ✅ Backward compatible (scripts not using it continue to work)
- ✅ Minimal blast radius (new helper, optional adoption)

**Cons**:

- Slight performance cost (jq lookups in hot paths)
- Incremental adoption (scripts migrate gradually)

**Chosen**: This approach minimizes risk while meeting all requirements.

---

## Requirements Analysis

### Success Criteria (Definition of Done)

The implementation is complete when:

1. **Policy Schema Extended** ✓
   - [ ] `config/policy.schema.json` includes sections for timeout, model selection, and adaptive thresholds
   - [ ] Schema validates against all new hardcoded values being migrated
   - [ ] Schema allows additional properties for future extensibility

2. **Hardcoded Values Migrated** ✓
   - [ ] All `TIMEOUT_*` constants moved to `config/policy.json` under `adaptive.timeout`
   - [ ] All `ESCALATION_*` / `DOWNGRADE_*` constants moved under `adaptive.model_selection`
   - [ ] All other hardcoded thresholds (e.g., `AUTH_CHECK_INTERVAL`) migrated
   - [ ] At least 25 hardcoded values migrated to policy config

3. **Policy Resolution Helper** ✓
   - [ ] `scripts/lib/policy.sh` extended with `policy_get_with_precedence()` function
   - [ ] Precedence chain: learned > user override > repo > hardcoded
   - [ ] Supports nested JSON paths (e.g., `.adaptive.timeout.build`)
   - [ ] Returns default value if key not found at any level

4. **Adaptive Override Framework** ✓
   - [ ] `~/.shipwright/learned-policy.json` format documented
   - [ ] Policy learner writes valid policies to learned-policy.json
   - [ ] Runtime checks for learned policies and applies them safely
   - [ ] Audit log entry for each policy decision (optional but recommended)

5. **Script Integration** ✓
   - [ ] At least 3 key scripts refactored to use `policy_get_with_precedence()`:
     - `scripts/lib/adaptive-timeout.sh`
     - `scripts/lib/adaptive-model.sh`
     - `scripts/lib/daemon-state.sh`
   - [ ] Tests pass for refactored scripts
   - [ ] No functional changes (behavior identical to hardcoded values)

6. **Documentation & Validation** ✓
   - [ ] `docs/config-policy.md` updated with new sections and examples
   - [ ] Schema validation works: `jq empty config/policy.json` succeeds
   - [ ] Evidence collected (policy-validation.json captures test results)

7. **Testing** ✓
   - [ ] New test suite `sw-policy-migration-test.sh` covers:
     - Policy schema validation
     - Precedence chain resolution
     - Learned override application
     - Fallback to hardcoded defaults
   - [ ] All existing tests pass (no regressions)
   - [ ] At least 90% coverage of new functions

8. **Zero Breaking Changes** ✓
   - [ ] Scripts not migrated continue to work unchanged
   - [ ] If `policy_get_with_precedence()` fails, falls back to hardcoded
   - [ ] Backward-compatible API

---

## Task Decomposition (with Dependencies)

### Phase 1: Schema & Configuration (Tasks 1-3)

These are prerequisites for all other tasks.

**Task 1: Extend config/policy.schema.json**

- Add `adaptive.timeout` section with schema for timeout values
- Add `adaptive.model_selection` section for escalation/downgrade thresholds
- Add `adaptive.daemon` section for daemon-specific policies
- Document all new fields in schema comments
- Validate existing config/policy.json against new schema
- **Dependency**: None (standalone)
- **Estimate**: 2 iterations

**Task 2: Add hardcoded values to config/policy.json**

- Create `adaptive.timeout` section with values from adaptive-timeout.sh:
  - `buffer_percent`, `min_samples`, `history_lookback`, `rotation_entries`
  - Per-stage defaults (intake, plan, build, test, etc.)
- Create `adaptive.model_selection` section:
  - `escalation_error_threshold`, `downgrade_success_threshold`, etc.
- Create `adaptive.daemon` section:
  - `auth_check_interval_seconds`
- Validate schema: `jq empty config/policy.json`
- **Dependency**: Task 1
- **Estimate**: 1 iteration

**Task 3: Create learned-policy.json format & examples**

- Document schema for `~/.shipwright/learned-policy.json`
- Create example learned-policy.json showing adaptive overrides
- Add section to `docs/config-policy.md` explaining learned policies
- **Dependency**: Task 1
- **Estimate**: 1 iteration

### Phase 2: Policy Resolution Engine (Tasks 4-5)

These build the core infrastructure.

**Task 4: Implement policy_get_with_precedence() in policy.sh**

- Extend `scripts/lib/policy.sh` with new function:
  - Signature: `policy_get_with_precedence "key.path" "default_value" [verbose]`
  - Load from `~/.shipwright/learned-policy.json` (if exists)
  - Fall back to `~/.shipwright/policy.json` (if exists)
  - Fall back to `config/policy.json`
  - Fall back to default_value
  - Optionally log which source was used
- Implement efficient caching (cache loaded files to avoid repeated jq calls)
- Handle missing files gracefully
- **Dependency**: Tasks 1, 2, 3
- **Estimate**: 2 iterations

**Task 5: Create policy resolution utility functions**

- Implement `policy_timeout_get(stage)` wrapper
  - Calls `policy_get_with_precedence ".adaptive.timeout.${stage}"` with hardcoded fallback
- Implement `policy_model_threshold_get(key)` wrapper
  - Calls `policy_get_with_precedence ".adaptive.model_selection.${key}"`
- Implement `policy_validate()` function
  - Validates loaded policy against schema (requires jq + schema)
  - Returns exit code 0 if valid, 1 if invalid
- Add audit logging (optional): emit_event with policy source
- **Dependency**: Task 4
- **Estimate**: 2 iterations

### Phase 3: Script Migration (Tasks 6-8)

These migrate key scripts to use the new system. Done incrementally to reduce risk.

**Task 6: Refactor scripts/lib/adaptive-timeout.sh**

- Replace all `TIMEOUT_*` constants with calls to `policy_timeout_get()`
- Update `_timeout_default()` to read from policy:
  ```bash
  local timeout=$(policy_timeout_get "$stage")
  echo "${timeout:-300}"  # Default if policy lookup fails
  ```
- Remove hardcoded `TIMEOUT_MIN`, `TIMEOUT_MAX`, `TIMEOUT_BUFFER_PCT`, etc.
- Add fallback: if policy system fails, use old hardcoded values
- Update function comments to reference policy
- Run existing tests: `bash scripts/sw-adaptive-timeout-test.sh`
- **Dependency**: Tasks 4, 5
- **Estimate**: 2 iterations

**Task 7: Refactor scripts/lib/adaptive-model.sh**

- Replace `ESCALATION_ERROR_THRESHOLD`, `DOWNGRADE_SUCCESS_THRESHOLD`, etc. with policy lookups
- Refactor `adaptive_model_select()` to use policy values
- Add fallback to hardcoded values if policy fails
- Update comments
- Run existing tests: `bash scripts/sw-adaptive-model-test.sh`
- **Dependency**: Tasks 4, 5
- **Estimate**: 2 iterations

**Task 8: Refactor scripts/lib/daemon-state.sh**

- Migrate `AUTH_CHECK_INTERVAL` to policy lookup
- Update `_daemon_auth_check_needed()` to use `policy_get_with_precedence`
- Add fallback
- Run existing tests: grep for daemon-state tests and run them
- **Dependency**: Tasks 4, 5
- **Estimate**: 1 iteration

### Phase 4: Testing & Validation (Tasks 9-11)

These ensure correctness and prevent regressions.

**Task 9: Create sw-policy-migration-test.sh**

- Test schema validation (`jq empty config/policy.json`)
- Test `policy_get_with_precedence()` with all three sources (learned, user, repo)
- Test precedence chain (learned takes priority over user over repo)
- Test fallback to default_value
- Test missing files are handled gracefully
- Test nested paths (e.g., `.adaptive.timeout.build`)
- Test cache invalidation
- Target: 15-20 test cases
- **Dependency**: Tasks 4, 5, 6, 7, 8
- **Estimate**: 3 iterations

**Task 10: Run full regression test suite**

- Run `npm test` (all existing tests)
- Verify no regressions in:
  - `sw-adaptive-timeout-test.sh`
  - `sw-adaptive-model-test.sh`
  - `sw-pipeline-test.sh`
  - `sw-daemon-test.sh`
- Document any failures and fix
- **Dependency**: Tasks 6, 7, 8, 9
- **Estimate**: 2 iterations

**Task 11: Create evidence artifacts**

- Collect evidence that policy system works:
  - Policy validation output (`jq` on all three config files)
  - Policy resolution test results
  - Example learned policy application
  - Store in `.claude/evidence/policy-migration.json`
- **Dependency**: Tasks 9, 10
- **Estimate**: 1 iteration

### Phase 5: Documentation & Cleanup (Tasks 12-14)

These finalize the deliverable.

**Task 12: Update docs/config-policy.md**

- Add section on "Policy Resolution Precedence Chain"
- Document learned-policy.json format with examples
- Add section on "Using policy_get_with_precedence()" for script authors
- Document how to validate policies: `jq empty config/policy.json`
- Add examples showing learned override of timeout
- Update ROADMAP section to mark these as done
- **Dependency**: Tasks 1-11
- **Estimate**: 1 iteration

**Task 13: Create migration guide for remaining scripts**

- List all remaining hardcoded values not yet migrated
- Document how to migrate a script step-by-step
- Provide a checklist for future migration tasks
- Store in `docs/POLICY_MIGRATION_GUIDE.md`
- **Dependency**: Tasks 1-11
- **Estimate**: 1 iteration

**Task 14: Final review & merge**

- Code review for all changes
- Verify all tests pass
- Check for Bash 3.2 compatibility
- Verify schema validation passes
- Create PR with summary of changes
- **Dependency**: Tasks 1-13
- **Estimate**: 1 iteration

---

## Implementation Steps (Detailed)

### Step 1: Extend Schema (Task 1)

**File**: `config/policy.schema.json`

```json
{
  "adaptive": {
    "type": "object",
    "description": "Adaptive policy settings for timeouts, model selection, and daemon behavior",
    "properties": {
      "timeout": {
        "type": "object",
        "description": "Adaptive timeout configuration",
        "properties": {
          "buffer_percent": { "type": "integer", "minimum": 0, "maximum": 100 },
          "min_samples": { "type": "integer", "minimum": 1 },
          "history_lookback": { "type": "integer", "minimum": 10 },
          "rotation_entries": { "type": "integer", "minimum": 100 },
          "min": { "type": "integer", "minimum": 10 },
          "max": { "type": "integer", "minimum": 60 },
          "stages": {
            "type": "object",
            "additionalProperties": { "type": "integer", "minimum": 30 }
          }
        }
      },
      "model_selection": {
        "type": "object",
        "description": "Model selection and escalation thresholds",
        "properties": {
          "escalation_error_threshold": { "type": "integer", "minimum": 1 },
          "downgrade_success_threshold": { "type": "integer", "minimum": 1 },
          "convergence_drop_threshold": { "type": "integer", "minimum": 1 },
          "escalation_cooldown": { "type": "integer", "minimum": 1 },
          "rate_limit_backoff_seconds": { "type": "integer", "minimum": 1 }
        }
      },
      "daemon": {
        "type": "object",
        "description": "Daemon-specific adaptive policies",
        "properties": {
          "auth_check_interval_seconds": { "type": "integer", "minimum": 60 }
        }
      }
    }
  }
}
```

### Step 2: Update config/policy.json (Task 2)

Add under root:

```json
{
  "adaptive": {
    "timeout": {
      "buffer_percent": 20,
      "min_samples": 10,
      "history_lookback": 100,
      "rotation_entries": 10000,
      "min": 30,
      "max": 7200,
      "stages": {
        "intake": 60,
        "plan": 300,
        "design": 300,
        "build": 1800,
        "test": 600,
        "review": 600,
        "compound_quality": 900,
        "pr": 120,
        "merge": 120,
        "deploy": 300,
        "validate": 300,
        "monitor": 300
      }
    },
    "model_selection": {
      "escalation_error_threshold": 2,
      "downgrade_success_threshold": 3,
      "convergence_drop_threshold": 10,
      "escalation_cooldown": 2,
      "rate_limit_backoff_seconds": 60
    },
    "daemon": {
      "auth_check_interval_seconds": 300
    }
  }
}
```

### Step 3: Implement policy_get_with_precedence() (Task 4)

Add to `scripts/lib/policy.sh`:

```bash
# precedence_load_file(path) — Load and cache a policy file if it exists
# Returns 0 if loaded, 1 if not found
_precedence_load_file() {
    local path="$1"
    local cache_var="_policy_cache_$(echo "$path" | md5sum | awk '{print $1}')"

    # Check cache first
    [[ -n "${!cache_var}" ]] && return 0

    if [[ -f "$path" ]]; then
        local content
        content=$(jq '.' "$path" 2>/dev/null) || return 1
        eval "${cache_var}='${content}'"
        return 0
    fi
    return 1
}

# policy_get_with_precedence(path, default, [verbose])
# Resolve a policy key through the precedence chain:
# 1. ~/.shipwright/learned-policy.json
# 2. ~/.shipwright/policy.json
# 3. config/policy.json
# 4. default value
policy_get_with_precedence() {
    local path="$1"
    local default="${2:-}"
    local verbose="${3:-0}"

    local repo_dir="${REPO_DIR:-}"
    [[ -z "$repo_dir" ]] && repo_dir="$(git rev-parse --show-toplevel 2>/dev/null || true)"

    # Try learned policy first
    if _precedence_load_file "${HOME}/.shipwright/learned-policy.json"; then
        local val
        val=$(jq -r "${path} // \"\"" "${HOME}/.shipwright/learned-policy.json" 2>/dev/null)
        if [[ -n "$val" && "$val" != "null" ]]; then
            [[ "$verbose" == "1" ]] && emit_event "policy.resolved" "source=learned" "path=${path}" "value=${val}"
            echo "$val"
            return 0
        fi
    fi

    # Try user override
    if _precedence_load_file "${HOME}/.shipwright/policy.json"; then
        local val
        val=$(jq -r "${path} // \"\"" "${HOME}/.shipwright/policy.json" 2>/dev/null)
        if [[ -n "$val" && "$val" != "null" ]]; then
            [[ "$verbose" == "1" ]] && emit_event "policy.resolved" "source=user_override" "path=${path}" "value=${val}"
            echo "$val"
            return 0
        fi
    fi

    # Try repo policy
    if [[ -n "$repo_dir" && -f "$repo_dir/config/policy.json" ]]; then
        local val
        val=$(jq -r "${path} // \"\"" "$repo_dir/config/policy.json" 2>/dev/null)
        if [[ -n "$val" && "$val" != "null" ]]; then
            [[ "$verbose" == "1" ]] && emit_event "policy.resolved" "source=repo" "path=${path}" "value=${val}"
            echo "$val"
            return 0
        fi
    fi

    # Fall back to default
    [[ "$verbose" == "1" ]] && emit_event "policy.resolved" "source=default" "path=${path}" "value=${default}"
    echo "$default"
}
```

### Step 4: Create wrapper functions (Task 5)

Add to `scripts/lib/policy.sh`:

```bash
# policy_timeout_get(stage)
# Get timeout for a stage from policy, with hardcoded fallback
policy_timeout_get() {
    local stage="$1"
    local timeout
    timeout=$(policy_get_with_precedence ".adaptive.timeout.stages.${stage}")

    # Fallback to repo policy or hardcoded
    if [[ -z "$timeout" || "$timeout" == "null" ]]; then
        timeout=$(policy_get_with_precedence ".adaptive.timeout.stages.${stage}" "")
    fi

    # Final hardcoded fallback (for safety)
    case "$stage" in
        intake)         echo "${timeout:-60}" ;;
        plan|design)    echo "${timeout:-300}" ;;
        build)          echo "${timeout:-1800}" ;;
        test|review)    echo "${timeout:-600}" ;;
        *)              echo "${timeout:-300}" ;;
    esac
}

# policy_model_threshold_get(key)
# Get model selection threshold from policy
policy_model_threshold_get() {
    local key="$1"
    local val
    val=$(policy_get_with_precedence ".adaptive.model_selection.${key}")
    echo "${val:-}"
}
```

### Step 5-7: Migrate Scripts

**adaptive-timeout.sh** — Replace hardcoded TIMEOUT*\* with calls to policy_timeout_get()
**adaptive-model.sh** — Replace ESCALATION*\* with calls to policy_model_threshold_get()
**daemon-state.sh** — Replace AUTH_CHECK_INTERVAL with policy lookup

---

## Risk Analysis

### Risk 1: Policy Lookup Performance Degradation (Medium Risk)

**What could go wrong**: Each `policy_get_with_precedence()` call uses jq to parse JSON files. In hot loops (e.g., during timeout checks in sw-loop.sh iterations), this could add measurable latency.

**Mitigation**:

- Implement in-memory caching (cache_var pattern shown above)
- Only load policy files once per shell session
- Profile after implementation; if latency is >100ms, use lazy loading

**Failure mode**: Pipeline iterations take noticeably longer (e.g., 5-10% slowdown)

**Action if it fails**: Fall back to direct config reading or env var approach

---

### Risk 2: Precedence Chain Confusion (Low Risk)

**What could go wrong**: Users create `~/.shipwright/policy.json` expecting it to take priority over `config/policy.json`, but it doesn't (or vice versa). Or learned policy doesn't apply when expected.

**Mitigation**:

- Document precedence chain clearly in `docs/config-policy.md`
- Emit audit log entry for each policy resolution (which source was used)
- Add `policy_debug()` function to show policy resolution for a key
- Create examples showing all three cases

**Failure mode**: User confusion; incorrect policies applied; hard to debug

**Action if it fails**: Improve docs; add policy_debug() command to CLI

---

### Risk 3: Circular Dependencies or File Lock Issues (Low Risk)

**What could go wrong**: Multiple processes try to read/write learned-policy.json simultaneously. File gets corrupted or locked.

**Mitigation**:

- Never modify policy files in hot loops (policy learner is separate from pipeline runtime)
- Use atomic writes (write to temp file, then mv)
- Document that learned-policy.json is read-only during pipeline execution
- Add file existence check before each read

**Failure mode**: Occasional "file is locked" errors; policy file becomes malformed

**Action if it fails**: Add flock-based locking in policy_get_with_precedence() or skip learned policy if locked

---

### Risk 4: Schema Validation Drift (Low Risk)

**What could go wrong**: Someone edits `config/policy.json` and forgets to update the schema. Or schema is too permissive and allows invalid values.

**Mitigation**:

- Add CI check: `jq empty config/policy.json && ajv validate -s config/policy.schema.json -d config/policy.json`
- Schema requires specific types (integer with min/max bounds)
- Policy validation test in Task 9 catches schema mismatches

**Failure mode**: Invalid policy values pass through; unexpected behavior at runtime

**Action if it fails**: Add pre-commit hook to validate schema

---

### Risk 5: Backward Compatibility Breaking (Medium Risk)

**What could go wrong**: A script is refactored to use policy_get_with_precedence(), but someone hasn't updated their worktree or isolated environment. The old hardcoded value is used, but a learned policy overrides it, causing unexpected behavior.

**Mitigation**:

- Always include fallback to hardcoded values in refactored scripts
- Never remove hardcoded constants; just comment them as "deprecated"
- Test with hardcoded-only paths (scripts that don't have policy files at all)

**Failure mode**: Unexpected behavior in environments without policy files; scripts break in odd ways

**Action if it fails**: Revert policy_get_with_precedence() calls; use only hardcoded defaults

---

### Risk 6: Learned Policy Injection (High Risk — Security)

**What could go wrong**: A malicious actor or bug writes invalid policy to learned-policy.json. E.g., sets timeout to 1 second, causing all stages to timeout. Or sets model_selection threshold to invalid values.

**Mitigation**:

- Validate learned policy against schema before applying it
- Implement policy_validate() function (Task 5)
- Only apply learned values if they pass validation
- Add safeguards: policy values must be within safe ranges (e.g., timeout >= 30 seconds)
- Emit event + warning if learned policy is invalid
- **Never silently ignore bad learned policy; fail visibly**

**Failure mode**: Pipeline becomes unusable due to invalid learned policy

**Action if it fails**: Implement policy_validate() that rejects invalid learned policies; fall back to repo policy

---

### Risk 7: Audit Trail & Observability Loss (Low Risk)

**What could go wrong**: Without logging which policy source was used, it becomes hard to debug why a policy was applied. "Why did the timeout suddenly change?" → unknown.

**Mitigation**:

- Implement optional audit logging in policy_get_with_precedence() (verbose mode)
- Emit event with source information
- Store audit trail in `.claude/pipeline-artifacts/policy-audit.jsonl`

**Failure mode**: Difficult to debug policy-related issues; observability gap

**Action if it fails**: Add mandatory audit logging (not optional); every policy resolution is logged

---

## Definition of Done

The implementation is complete when **all** of the following are true:

### Functional Requirements

- [ ] `config/policy.schema.json` validates against all new policy sections
- [ ] `config/policy.json` contains all migrated hardcoded values
- [ ] `policy_get_with_precedence()` correctly resolves policies in precedence order
- [ ] At least 25 hardcoded values migrated to policy.json
- [ ] Fallback to hardcoded defaults works if all policy files are missing
- [ ] Learned policy override works (if learned-policy.json exists and valid)

### Script Migration

- [ ] `scripts/lib/adaptive-timeout.sh` refactored; uses policy system; all tests pass
- [ ] `scripts/lib/adaptive-model.sh` refactored; uses policy system; all tests pass
- [ ] `scripts/lib/daemon-state.sh` refactored; uses policy system; all tests pass
- [ ] No breaking changes; scripts behave identically before/after

### Testing & Validation

- [ ] `sw-policy-migration-test.sh` created with 15+ test cases
- [ ] All new tests pass
- [ ] Full regression test suite (`npm test`) passes
- [ ] No performance regression (timeout checks < 100ms)
- [ ] Policy validation works: `jq empty config/policy.json`

### Documentation

- [ ] `docs/config-policy.md` updated with precedence chain explanation
- [ ] Learned policy format documented with examples
- [ ] Migration guide created for remaining hardcoded values
- [ ] Policy resolution precedence chain clearly explained with diagrams

### Code Quality

- [ ] Bash 3.2 compatible (no associative arrays, no bash 4.0+ features)
- [ ] All scripts pass shellcheck
- [ ] No security vulnerabilities (policy validation prevents injection)
- [ ] Error handling for missing/invalid files

### Evidence & Verification

- [ ] `.claude/evidence/policy-migration.json` created with verification results
- [ ] Policy validation test results included
- [ ] Example learned policy override demonstrated
- [ ] Schema validation passes

---

## Failure Mode Analysis

### Failure Mode 1: jq Command Fails (High Severity)

**Trigger**: Policy files exist but are malformed JSON; jq returns error; policy_get_with_precedence() crashes.

**Impact**: Pipeline stalls; scripts using policy system fail; learned policy system breaks.

**Mitigation**:

- Wrap jq calls in error handling: `jq -r ... 2>/dev/null || true`
- Catch jq exit code; fall back to default if jq fails
- Validate policy files at startup with policy_validate()
- Test with malformed JSON in policy files

**Implementation**:

```bash
policy_get_with_precedence() {
    local val
    val=$(jq -r "${path} // empty" "$policy_file" 2>/dev/null) || {
        [[ "$verbose" == "1" ]] && warn "Policy file invalid: $policy_file"
        echo "$default"
        return 0
    }
}
```

---

### Failure Mode 2: Race Condition — Learned Policy Being Rewritten (Medium Severity)

**Trigger**: Policy learner rewrites learned-policy.json while a script reads it; file is partially written; jq parses incomplete JSON.

**Impact**: Intermittent pipeline failures with "malformed JSON" errors; learned policy is not applied; users can't rely on learned overrides.

**Mitigation**:

- Use atomic writes in policy learner: write to temp file, then mv
- Don't lock files; mv is atomic on POSIX systems
- If jq fails, fall back to default (see Failure Mode 1)
- Add safety: if learned-policy.json is older than 5 seconds and being modified, skip it

**Implementation**:

```bash
# In policy learner:
local tmp_file="${LEARNED_POLICY_FILE}.tmp.$$"
jq ... > "$tmp_file" || return 1
mv "$tmp_file" "$LEARNED_POLICY_FILE"  # Atomic on POSIX

# In policy_get_with_precedence:
if [[ -f "${HOME}/.shipwright/learned-policy.json" ]]; then
    local mtime=$(stat -c %Y "${HOME}/.shipwright/learned-policy.json" 2>/dev/null || echo 0)
    local now=$(date +%s)
    [[ $((now - mtime)) -lt 5 ]] && continue  # File being modified; skip
fi
```

---

### Failure Mode 3: Learned Policy Invalid (High Severity)

**Trigger**: Policy learner writes invalid policy (e.g., timeout=1, escalation_threshold=0); validation is skipped; invalid values are applied; pipeline breaks.

**Impact**: Pipeline becomes unusable; all subsequent builds timeout or fail; learned values override correct repo policy.

**Mitigation**:

- Implement policy_validate() function that checks:
  - JSON is valid
  - Required fields exist
  - Values are within safe ranges (timeout >= 30, thresholds >= 1)
  - Values match schema
- Policy learner must call policy_validate() before writing
- Runtime: reject learned policies that fail validation
- Emit warning + log event if learned policy is invalid

**Implementation**:

```bash
policy_validate() {
    local policy_file="$1"
    [[ ! -f "$policy_file" ]] && return 0  # Missing is OK

    # Check JSON validity
    jq empty "$policy_file" 2>/dev/null || return 1

    # Check timeout values are in safe range (30-7200 seconds)
    local timeouts
    timeouts=$(jq '.adaptive.timeout.stages[]? // empty' "$policy_file")
    while read -r timeout; do
        [[ "$timeout" -lt 30 || "$timeout" -gt 7200 ]] && return 1
    done <<< "$timeouts"

    return 0
}

policy_get_with_precedence() {
    # ... learned policy lookup ...
    if policy_validate "${HOME}/.shipwright/learned-policy.json"; then
        # Use learned policy
    else
        warn "Learned policy invalid; falling back to repo policy"
    fi
}
```

---

### Failure Mode 4: Config Directory Doesn't Exist (Low Severity)

**Trigger**: Script runs in environment where `config/policy.json` doesn't exist (e.g., CI environment with minimal checkout).

**Impact**: Policy resolution fails; falls back to hardcoded; pipeline continues (graceful fallback).

**Mitigation**:

- Check file existence before reading
- Fall back to hardcoded default if file missing
- This is expected behavior; not an error
- Log at debug level only

**Implementation**: Already handled by `[[ -f "$policy_file" ]] || return 1` checks.

---

### Failure Mode 5: Precedence Chain Ambiguity (Low Severity, UX Risk)

**Trigger**: User creates `~/.shipwright/policy.json` and `~/.shipwright/learned-policy.json` with conflicting values; unclear which takes precedence; user is confused.

**Impact**: User sets policy expecting one behavior; gets another due to precedence rules.

**Mitigation**:

- Document precedence chain in **bold** in docs: **Learned > User Override > Repo > Hardcoded**
- Add policy_debug() command to show which source was used:
  ```bash
  shipwright policy debug ".adaptive.timeout.build"
  # Output: source=learned value=1900
  ```
- Create examples showing all three sources
- Emit audit events showing source

**Implementation**:

```bash
policy_debug() {
    local path="$1"
    echo "Policy resolution for '$path':"
    [[ -f "${HOME}/.shipwright/learned-policy.json" ]] && \
        echo "  Learned: $(jq -r "${path}" "${HOME}/.shipwright/learned-policy.json" 2>/dev/null || echo 'N/A')"
    [[ -f "${HOME}/.shipwright/policy.json" ]] && \
        echo "  User: $(jq -r "${path}" "${HOME}/.shipwright/policy.json" 2>/dev/null || echo 'N/A')"
    [[ -f "config/policy.json" ]] && \
        echo "  Repo: $(jq -r "${path}" "config/policy.json" 2>/dev/null || echo 'N/A')"
    echo "  Result: $(policy_get_with_precedence "$path")"
}
```

---

## Files to Create/Modify

### Create

- [ ] `docs/POLICY_MIGRATION_GUIDE.md` — Migration guide for remaining hardcoded values

### Modify

- [ ] `config/policy.schema.json` — Add adaptive sections
- [ ] `config/policy.json` — Add adaptive timeout, model selection, daemon configs
- [ ] `scripts/lib/policy.sh` — Add policy_get_with_precedence(), policy_timeout_get(), policy_model_threshold_get(), policy_validate()
- [ ] `scripts/lib/adaptive-timeout.sh` — Use policy*timeout_get() instead of hardcoded TIMEOUT*\*
- [ ] `scripts/lib/adaptive-model.sh` — Use policy*model_threshold_get() instead of hardcoded ESCALATION*_, DOWNGRADE\__
- [ ] `scripts/lib/daemon-state.sh` — Use policy_get_with_precedence() for AUTH_CHECK_INTERVAL
- [ ] `scripts/sw-policy-migration-test.sh` — New comprehensive test suite
- [ ] `docs/config-policy.md` — Document precedence chain and learned policies
- [ ] `.claude/evidence/policy-validation.json` — Evidence artifacts

---

## Testing Approach

### Unit Tests (sw-policy-migration-test.sh)

1. **Schema Validation**
   - [ ] `jq empty config/policy.json` succeeds
   - [ ] Schema validates all policy sections

2. **Policy Resolution**
   - [ ] Load from learned-policy.json (if exists)
   - [ ] Load from ~/.shipwright/policy.json (if exists)
   - [ ] Load from config/policy.json
   - [ ] Fall back to default if all missing

3. **Precedence Chain**
   - [ ] Learned > User > Repo > Default
   - [ ] Create temp policy files; test each level

4. **Helper Functions**
   - [ ] policy_timeout_get(stage) returns correct timeout
   - [ ] policy_model_threshold_get(key) returns correct threshold
   - [ ] policy_validate() rejects invalid policies
   - [ ] policy_validate() accepts valid policies

5. **Fallback Behavior**
   - [ ] If policy system fails entirely, hardcoded defaults are used
   - [ ] No crashes or error messages

### Regression Tests

- [ ] `sw-adaptive-timeout-test.sh` still passes
- [ ] `sw-adaptive-model-test.sh` still passes
- [ ] `sw-daemon-test.sh` still passes
- [ ] `npm test` (all tests) pass

### Integration Tests

- [ ] Run a real pipeline; verify policies are applied correctly
- [ ] Create learned-policy.json; verify it overrides repo policy
- [ ] Create user ~/.shipwright/policy.json; verify it takes effect

---

## Summary

This implementation plan migrates hardcoded policies into a centralized, validated configuration system with an adaptive override framework. The key points:

1. **Minimal Risk** — Backward compatible; fallback to hardcoded values if policy system fails
2. **Incremental** — Scripts are migrated one at a time; can pause and roll back
3. **Auditable** — Policy resolution is logged; can debug which source was used
4. **Validated** — JSON Schema ensures policy values are valid
5. **Extensible** — New policies can be added to config/policy.json without code changes

The total effort is ~14 tasks across 5 phases, with clear dependencies and exit criteria.
