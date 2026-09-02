## Shell Script Test Harness Patterns

### Test File Structure
Each `scripts/<name>-test.sh` follows this skeleton:

```bash
#!/bin/bash
set -euo pipefail

VERSION="1.0.0"  # Keep in sync with main script

# Counter setup
PASS=0
FAIL=0

# Mock binary directory
MOCK_BIN_DIR="$(mktemp -d)"
export PATH="${MOCK_BIN_DIR}:$PATH"

# ERR trap for failure capture
trap 'FAIL=$((FAIL + 1))' ERR

test_case() {
  local name="$1"
  echo "Testing: $name"
  # assertions here
  PASS=$((PASS + 1))
}

# Cleanup on exit
trap 'rm -rf "${MOCK_BIN_DIR}"' EXIT

# Output summary
echo "PASS: $PASS, FAIL: $FAIL"
exit "$FAIL"
```

### Mock Binary Patterns
- Place mock binaries in a temporary directory and prepend to `$PATH`
- Mock a command that the main script calls: e.g., if `sw-event-schema-sync.sh` calls `jq`, create `${MOCK_BIN_DIR}/jq` that returns test data
- Mock binaries are simple shell scripts with shebang; they can control exit codes and output
- Example: `echo '#!/bin/bash' > ${MOCK_BIN_DIR}/git && echo 'echo "main"' >> ${MOCK_BIN_DIR}/git && chmod +x ${MOCK_BIN_DIR}/git`

### PASS/FAIL Counting
- Increment `PASS` at the end of each successful test
- ERR trap (or explicit error handling) increments `FAIL`
- Exit with `$FAIL` so `npm test` aggregates failure counts across all suites

### Package.json Registration
Add to `package.json` test scripts section:
```json
"test:event-schema-sync": "bash scripts/sw-event-schema-sync-test.sh",
"test:test-all": "bash scripts/sw-test-all-test.sh"
```
Then add both to the main `test` script so `npm test` runs them.

### AUTO Documentation Sync
When adding new test suites, update the AUTO:test-suites table in `.claude/CLAUDE.md` with one row per test file (name, line count, purpose). Run `shipwright docs check` to validate consistency.

### Avoiding Common Pitfalls
- **Subshell state loss**: Use `while read; done < <(cmd)` not `cmd | while read` to preserve variables
- **Pipefail with mocks**: Ensure mock binaries exit 0 on success unless testing error cases
- **Cleanup order**: Set EXIT trap after creating mock directory so cleanup happens last
- **Assertion clarity**: Use descriptive assertion messages; prefix failures with "FAIL:" so they're searchable in logs
