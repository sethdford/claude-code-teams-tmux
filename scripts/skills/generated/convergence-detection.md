## Convergence Detection & Build Loop Abort Logic

### Error Signature Extraction

Extract a stable hash from test output to detect repeated failures:

1. **Parse test output** for error lines (stack traces, assertion failures, syntax errors)
2. **Normalize**: Strip line numbers and timestamps; preserve file path and error category
3. **Hash**: `sha256(error_message + file_path + error_category)` ensures consistency
4. **Collision risk**: Test that similar but distinct errors (e.g., different assertion messages on same line) produce different hashes

### Convergence Detection Algorithm

- Track signatures in a circular buffer of the last N iterations (N = 5 recommended)
- On each test failure, extract signature and compare against buffer
- **Abort condition**: 3+ **consecutive identical signatures** = unrecoverable error
- **Don't abort on**: Single failures, transient errors (flaky tests), or signature variation
- **State location**: Write signatures to `error-summary.json` with timestamps; read on loop resume

### Configuration Schema

```json
{
  "convergence_detection": {
    "enabled": true,
    "repetition_threshold": 3,
    "signature_buffer_size": 5,
    "ignore_flaky_patterns": ["timeout", "network", "connection_reset"]
  }
}
```

### Abort Reason Format

When aborting, write to `.claude/error-summary.json`:

```json
{
  "abort_reason": "Convergence detected: identical error signature across 3 consecutive iterations",
  "error_signature": "<sha256_hash>",
  "error_category": "SyntaxError",
  "first_occurrence_iteration": 2,
  "final_occurrence_iteration": 4,
  "sample_error_message": "...",
  "sample_file": "src/component.tsx:42"
}
```

### Testing Convergence Logic

- Mock test failures with identical signatures on iterations 2, 3, 4 → abort on iteration 4
- Mock failures with changing signatures → don't abort
- Mock failures with only 2 repetitions → don't abort
- Verify signature extraction handles multiline stack traces correctly
- Test that `--max-iterations` is honored even if convergence would allow continuation
