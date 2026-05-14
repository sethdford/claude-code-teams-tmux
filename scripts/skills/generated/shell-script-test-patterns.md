## Shell Script Test Patterns & Harness Conventions

Shipwright test suites for shell scripts follow a specific pattern designed for parallelization, isolation, and clarity. This skill covers the conventions, mock patterns, and safety practices for writing test suites that integrate cleanly with `npm test`.

### Test File Structure

- **Naming**: `scripts/{script}-test.sh`
- **Registration**: Add entry to `package.json` scripts.test via `npm test` (runs via `npm test` with parallelization)
- **Shebang**: `#!/usr/bin/env bash` with `set -euo pipefail`
- **Version variable**: `VERSION=...` at top of file, matching script being tested

### Mock Binary Conventions

1. **Temp directory isolation**: Create `TMPDIR=$(mktemp -d)` per test, add cleanup trap
   ```bash
   trap 'rm -rf "$TMPDIR"' EXIT
   ```

2. **Mock binary structure**: Binaries go in `$TMPDIR/bin/` with predictable behavior
   - Mock returns exit code based on input (e.g., invalid arg → exit 1)
   - Mock outputs expected format (JSON, CSV, plain text)
   - Never call real binaries; replace in PATH: `export PATH="$TMPDIR/bin:$PATH"`

3. **Mock files**: Use `$TMPDIR` for all file I/O (configs, logs, state)
   - Never write to `/tmp` directly (other tests might collide)
   - Never rely on real files from repo (tests must be self-contained)

### Test Counting & Output

- **Global counters**: `PASS=0 FAIL=0` at top
- **Test function**: `test_name() { local result='...'; if [[ result == expected ]]; then ((PASS++)); else ((FAIL++)); echo "FAIL: $description"; fi; }`
- **Summary**: Print `✓ PASS: N, FAIL: M` and exit 0 if M==0, exit 1 if M>0
- **Colors**: Use `$green`, `$red`, `$cyan` (defined in test files) for readability

### Parallelization Safety

1. **No global state**: Each test uses its own `TMPDIR`; no shared files, env vars, or process state
2. **Process isolation**: Kill background processes in trap to prevent zombie processes affecting other tests
3. **Atomic writes**: Use `tmp_file=$(mktemp)` + `mv` pattern, never direct write
4. **Test ordering**: Tests must pass in any order; no dependencies between test functions
5. **Timeout protection**: Long-running operations should have timeouts (e.g., `timeout 5s mock_command`)

### Common Pitfalls

- **Forgetting cleanup trap**: Leftover files in shared /tmp cause race conditions
- **Mock command substitution**: Ensure `$(mock_cmd)` output is captured, not piped (loses exit code)
- **Hard-coded paths**: Use `$TMPDIR` for all files; never assume `/tmp` structure
- **Subshell variable loss**: Use `while read; done < <(cmd)` not `cmd | while read` to preserve outer variables
- **Color code validation**: Terminal colors in output need exact matching or regex; test for the pattern, not the literal escape code

### Edge Cases to Test

For every script being tested:
1. **Happy path**: Correct inputs → expected output
2. **Missing inputs**: Empty args, missing files → error or graceful default
3. **Invalid inputs**: Malformed JSON, invalid IDs, non-existent files → specific error code
4. **State transitions**: Before/after state (e.g., pane created → border color applied)
5. **Concurrent access**: Two tests accessing same mock simultaneously (shouldn't crash)
6. **Cleanup**: Temp resources freed even if test fails midway

### Integration with npm test

- Test suite is discovered and run by `npm test` automatically
- Test output should be parseable by CI (count PASS/FAIL, report failing test names)
- Exit code must be 0 for success, 1 for any failures
- Each test suite runs in its own process with isolated `TMPDIR` (no collisions)
