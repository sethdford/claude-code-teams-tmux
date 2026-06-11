## Setup Config Generation

Generated daemon-config.json should have sensible defaults tuned to project characteristics, enabling first-time users to run `shipwright pipeline start --issue <N>` immediately without manual tuning.

### Tuning Factors

**Project Size** (file count, total LOC):
- Micro (<1k files): `max_parallel: 1`, `max_restarts: 1`
- Small (1k-10k): `max_parallel: 2`, `max_restarts: 2`
- Medium (10k-100k): `max_parallel: 3`, `max_restarts: 2`
- Large (>100k): `max_parallel: 4`, `max_restarts: 3`

**Test Runner** (vitest/jest/pytest/go test):
- Fast runners (vitest, go test): `fast_test_interval: 5`
- Slow runners (pytest): `fast_test_interval: 3`

**Language-Specific**:
- Python: Higher `loop.extension_size` (Python tests often need iteration)
- Go: Lower timeouts (go test fast, but builds can be slow)
- Node: Default timeouts, assume reasonable CI
- Rust: Higher build timeouts (cargo builds can be slow)

**Complexity Scoring**:
- Count test files, LOC per file, imports/dependencies
- Estimate test suite runtime (heuristic: 50ms per test file)
- If estimated runtime > 5 min: boost iteration count, enable `fast_test_mode`

### Generated Config Template

```json
{
  "max_parallel": <based on project size>,
  "loop": {
    "max_restarts": <based on project size>,
    "fast_test_interval": <based on test runner>,
    "circuit_breaker_threshold": 4,
    "min_progress_lines": 3
  },
  "model_routing": {
    "default": "opus",
    "classification": "haiku",
    "validation": "haiku"
  },
  "effort_levels": {
    "build": "medium",
    "review": "high"
  },
  "intelligence": {
    "enabled": true,
    "cache_ttl_seconds": 3600
  }
}
```

### Validation

- Ensure all required keys present
- Verify numeric values in valid ranges
- Test config with `shipwright doctor` before declaring success
- Offer user override opportunity (print config, ask "OK to use?")
