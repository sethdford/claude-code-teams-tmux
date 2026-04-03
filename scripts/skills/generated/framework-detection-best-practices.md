## Framework Detection Best Practices

Framework detection is the foundation of zero-touch config generation. Poor detection means generated configs fail, destroying user trust at the critical onboarding moment.

### Detection Strategy

**Tier 1: Primary Markers (High Confidence)**
- Language-specific manifests: `go.mod`, `package.json`, `pyproject.toml`, `Cargo.toml`, `pom.xml`, `build.gradle`
- Parse and validate content (never assume format without verification)
- Single manifest = reliable detection

**Tier 2: Secondary Markers (Medium Confidence)**
- CI/CD configs: `.github/workflows/*.yml`, `.gitlab-ci.yml`, `azure-pipelines.yml` (reveal test frameworks, build patterns)
- Build scripts: `Makefile`, `build.sh`, `Justfile`, `tox.ini` (expose test tooling)
- Tool configs: `.eslintrc.json`, `.pylintrc`, `clippy.toml` (indicate linting/quality tools)

**Tier 3: Fallback (Low Confidence)**
- Source file extensions: `*.go`, `*.py`, `*.rs`, `*.ts` (only if no manifest found)
- Treat as "best guess" and include confidence in output

### Edge Cases & Handling

**Monorepos**
- Scan all directories for manifests, not just root
- Return structured result: `{root: Generic, workspaces: [{path: "api", framework: "Go"}, {path: "web", framework: "Node"}]}`
- Generate per-workspace configs or unified multi-workspace config

**Hybrid Stacks**
- Multiple manifests = prioritize by specificity (manifest > CI config > build script)
- Return primary + secondaries: primary used for config, secondaries inform cross-framework recommendations

**Minimal/Atypical Projects**
- No manifest found? Ask user or default to generic template
- Include confidence score in result: `{framework: "unknown", confidence: 0.0, detected: [], recommendation: "Please specify framework"}`

### Implementation Checklist

- [ ] Parse manifests correctly (Go mods are text, JSON must validate, Python requires ast, TOML is strict format)
- [ ] Fixture tests: 5+ real projects per framework (minimal, standard, monorepo, outdated versions, atypical layout)
- [ ] Integration tests: generate config for fixture → run setup → verify no errors
- [ ] Edge case tests: missing files, multi-framework, no CI, renamed manifests
- [ ] Confidence scoring: return `{framework, confidence: 0.0-1.0}` so caller can decide if prompting needed
- [ ] Document detection logic per framework (what files = what conclusion)

### Testing Framework Fixture Examples

**Go:** `go.mod` with `go` directive, `go.sum`, `cmd/main.go`
**Python:** `pyproject.toml` with `[project]` section, `requirements.txt`, `setup.py`
**Node:** `package.json` with `{"type": "module"}` or `{"engines": {"node"}}`, `npm-shrinkwrap.json`
**Rust:** `Cargo.toml` with `[package]`, `Cargo.lock`, `src/main.rs` or `src/lib.rs`

### Avoid

- Magic strings: don't hardcode "lodash" or "pytest" checks—parse dependency sections correctly
- Ignoring nested projects: monorepos have multiple manifests at different depths
- Assuming framework without validation: check that manifest actually parses
- Overconfidence: if detection is ambiguous, say so
