## Dependency Installation Robustness

Implement a pre-flight dependency check that detects, parses, and safely installs packages across five package managers with clear error handling and observability.

### Core Challenges

**1. Manifest Detection & Parsing**
- Each language has different manifest formats: package.json (JSON), requirements.txt (plain text with comments), go.mod (TOML-like), Gemfile (Ruby DSL), pom.xml (XML).
- Parsing must be defensive—malformed manifests should report clear errors with line numbers, not crash silently.
- Support monorepo layouts where multiple manifests exist at different depths.
- Use language-native tools (node, python, go, ruby, mvn) to parse rather than regex, to handle format edge cases correctly.

**2. Package Manager Availability**
- The target package manager (npm, pip, go, bundle, maven) might not be installed.
- Failing with "command not found" is confusing—must detect upfront and provide actionable guidance (e.g., "pip not found—install Python 3").
- Verify manager version is compatible, not just present.
- This is the most common failure mode in CI environments.

**3. Installation Safety & Atomicity**
- Installing packages in the build directory can shadow system packages, cause version conflicts, or leak into production builds.
- Treat the entire install as atomic: all packages succeed, or the entire operation fails cleanly. Partial success leaves the build in an uncertain state.
- Use lockfiles (package-lock.json, poetry.lock, go.sum, Gemfile.lock) to ensure deterministic installs across environments.
- On failure, clean up any partially-installed packages so the build can retry cleanly.

**4. Error Recovery**
- Network failures during install must be distinguishable from package conflicts or broken manifests.
- Distinguish between "package manager crashed" (infrastructure issue, should retry) and "manifest is invalid" (code issue, should fail).
- Log root cause analysis: Was it a missing package manager? Malformed manifest? Version conflict? Network timeout?

**5. Observability for the Pipeline**
- The build loop needs to know what was installed, why it took time, and whether to skip iteration 1.
- Emit pipeline events: `type=dependencies_installed manager=npm count=42 duration_ms=5230 status=success`.
- Log individual install commands and their output so debugging is possible.
- Track which manifests were found and processed.

### Implementation Patterns

**Manifest Detection**
```bash
# Scan in order of priority (multiple manifests = multiple installs)
find . -maxdepth 3 -name 'package.json' -o -name 'requirements.txt' -o -name 'go.mod' -o -name 'Gemfile' -o -name 'pom.xml'
# Validate each manifest file exists and is readable
# Determine language from filename + content check (don't guess from extension alone)
```

**Defensive Parsing**
- For package.json: use `node -e "require('./package.json')"` to validate before parsing, catch SyntaxError with line number.
- For requirements.txt: parse line-by-line, skip comment lines, validate package@version format.
- For go.mod: use `go mod graph` to list dependencies instead of regex parsing.
- For Gemfile: use `bundler` commands to list without executing.
- For pom.xml: use `mvn dependency:list` or XML parser, not string matching.

**Package Manager Checks**
```bash
for manager in npm pip go bundle mvn; do
  if ! command -v "$manager" &>/dev/null; then
    warn "$manager not found—skipping $language deps"
    continue
  fi
  # Verify version
  version=$($manager --version 2>&1)
  if [[ $? -ne 0 ]]; then
    error "$manager exists but is broken: $version"
    exit 1
  fi
done
```

**Safe Installation**
- Use `npm ci` (clean install from lockfile) instead of `npm install` (allows upgrades).
- Use `pip install -r requirements.txt` with `--prefer-offline` to avoid unexpected changes.
- Use `go mod download` before `go mod verify` to validate checksums.
- Use `bundle install --no-deployment` (or `--deployment` if Gemfile.lock exists) for Ruby.
- Use `mvn dependency:resolve` to download without compiling.

**Atomic Installation**
```bash
# Create temp directory, install there, verify success, move to real location
temp_dir=$(mktemp -d)
trap "rm -rf '$temp_dir'" EXIT

if npm ci --prefix "$temp_dir" 2>&1 | tee "$temp_dir/install.log"; then
  mv "$temp_dir/node_modules" "./node_modules"
  success "Installed $(jq -r '.dependencies | keys | length' package.json) npm dependencies"
else
  error "npm install failed: $(tail -5 "$temp_dir/install.log")"
  exit 1
fi
```

**Logging & Observability**
```bash
# Log manifest detection
info "Found Node.js manifest: package.json ($(jq -r '.dependencies | keys | length' package.json) deps)"

# Log installation start
start=$(date +%s%N)

# Run install
npm ci 2>&1 | tee install.log

# Log completion
duration=$(( ($(date +%s%N) - start) / 1000000 ))
emit_event "dependencies_installed" \
  "manager=npm" "count=42" "duration_ms=$duration" "status=success"
```

### Edge Cases to Handle

1. **Monorepo with multiple manifests**: Should you install all, or only root? Design: install root first, then any other top-level manifests.
2. **Lockfile without manifest** (or vice versa): Warn but don't fail—let the build discover the real error.
3. **Broken package manager** (installed but crashes): Distinguish from missing manager. Both should skip gracefully.
4. **Network failure mid-install**: Retry up to 2 times with exponential backoff. If persistent, fail clearly.
5. **Dependency conflicts** (two manifests want incompatible versions): Log the conflict, let the build fail later with a clear error.
6. **Disk space exhaustion**: Check available disk before installing. Fail with "Disk full" rather than cryptic install errors.
7. **Pre-existing partial installations**: Clean up before installing to avoid version conflicts.

### Testing Strategy

**Unit Tests**
- Manifest parsing: valid, malformed, missing required fields, edge cases (empty files, BOM markers).
- Manager detection: installed, missing, broken (crashes on --version).
- Error message generation: clear, actionable, language-appropriate.

**Integration Tests**
- End-to-end with real npm, pip, go, bundle, mvn on test fixtures.
- Test fixtures with intentionally missing dependencies.
- Verify iteration 1 is skipped when all deps are pre-installed.
- Test monorepo scenarios with multiple manifests.
- Test network failure recovery (mock network timeouts).
- Test disk space handling (mock df to report low space).

**Fault Injection**
- Remove package managers mid-install (simulate uninstall during build).
- Truncate manifests to test parse error handling.
- Fill disk to test exhaustion scenarios.
- Introduce version conflicts in lock files.

### Configuration

Add to `daemon-config.json`:
```json
{
  "dependency_preflight": {
    "enabled": true,
    "managers": ["npm", "pip", "go", "bundle", "maven"],
    "skip_on_error": false,
    "max_install_time_seconds": 300
  }
}
```

Allow pipeline stage to override: `--dependency-install-timeout 600`.
