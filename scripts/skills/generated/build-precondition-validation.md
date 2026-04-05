## Build Precondition Validation Patterns

### Ecosystem Detection

1. **Hierarchy**: Check in order (most specific to least specific)
   - Lockfile presence (`package-lock.json`, `yarn.lock`, `go.mod`, `Cargo.lock`)
   - Package manager config (`package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`)
   - Language detection from file extensions as fallback

2. **Multi-lockfile handling**: Error if both `package-lock.json` AND `yarn.lock` exist (ambiguous)

### Safe Dry-Run Execution

- **npm**: `npm install --dry-run` or parse `package.json` without installing
- **go**: `go build -n ./...` (prints commands without executing)
- **cargo**: `cargo check --dry-run` or `cargo metadata --format-version=1`
- **python**: Parse `requirements.txt`, `pyproject.toml`, or `setup.py` without installing
- **Never execute arbitrary commands**; whitelist safe introspection tools

### Test Discovery Dry-Run

1. Look for test config/discovery artifacts:
   - `jest.config.js`, `vitest.config.ts`, `.mocharc.json` (JS)
   - `pytest.ini`, `tox.ini` (Python)
   - `go test ./...` with `-list` flag to enumerate tests without running
   - `cargo test --no-run` to compile tests but skip execution

2. If discovery fails, report which test framework is expected vs. what was found

3. For dry-run, prefer metadata queries over test execution (faster, safer)

### Tool Presence Validation

```bash
# Validate tool is in PATH and works
if ! command -v prettier &>/dev/null; then
  MISSING_TOOLS+=("prettier")
fi

# Alternatively, check for local install
if [[ ! -f node_modules/.bin/eslint ]]; then
  MISSING_TOOLS+=("eslint")
fi
```

Prefer local install in `node_modules/`, `.cargo/bin/`, etc. over global PATH lookup for reproducibility.

### Validation Report Schema

```json
{
  "timestamp": "2026-04-05T06:47:13Z",
  "status": "pass|fail|warn",
  "ecosystem": "node|python|go|rust",
  "checks": {
    "package_manager": { "status": "pass", "version": "20.11.0" },
    "lockfile": { "status": "pass", "path": "package-lock.json" },
    "test_framework": { "status": "warn", "message": "Jest config found but no tests/ directory" },
    "build_command": { "status": "pass", "exit_code": 0 },
    "tools": {
      "prettier": { "status": "pass", "path": "node_modules/.bin/prettier" },
      "eslint": { "status": "fail", "message": "Not found in node_modules" }
    }
  },
  "errors": [
    "eslint not installed; run 'npm install --save-dev eslint'"
  ],
  "warnings": [],
  "duration_ms": 234
}
```

### Error Messaging

- **Actionable**: Include fix command (e.g., `npm install --save-dev eslint`)
- **Specific**: Name the exact missing tool, path, or command
- **Grouped**: Separate errors from warnings; list all failures before asking for fixes
- **Early exit**: If any error-level check fails, exit build stage before loop iterations

### Edge Cases to Handle

1. **Monorepos**: Detect workspace roots and validate per-workspace
2. **Optional dependencies**: Mark as `warn` instead of `fail` if configured as optional
3. **Multiple test frameworks**: If `jest.config.js` AND `vitest.config.ts` both exist, ask user to clarify
4. **Missing ecosystems**: Don't assume Node just because `package.json` exists; check for `go.mod`, `Cargo.toml` first
5. **Lockfile out of date**: Warn if lockfile timestamp is older than package manager config
6. **Tool version conflicts**: Validate tool versions if critical (e.g., Node 16+ for certain eslint plugins)

### Performance Considerations

- **Parallel checks**: Run ecosystem detection, lockfile checks, and tool validation in parallel
- **Cache results**: Store validation report; skip re-validation within same session if source files unchanged
- **Fast path**: If all checks pass, complete validation in <1s; complex monorepos may take 3-5s
- **Timeout**: Set 30s overall timeout; report `timeout` status if validation takes too long
