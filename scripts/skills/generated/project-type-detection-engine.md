## Project Type Detection Engine

### Overview
Design and implement framework detection that identifies 10+ project types (Node.js, Rails, Django, Go, Rust, Python, Java/Maven, Next.js, React, Vue) by analyzing project structure and manifests. Output includes detected type, language, framework, and recommended pipeline template.

### Detection Strategy

**Priority-based manifest checks** (fail-safe ordering):
1. **Node.js ecosystem**: package.json → extract `name`, `type`, check for frameworks (Next.js, React, Vue via dependencies)
2. **Ruby**: Gemfile → check for Rails, Sinatra, or plain Ruby
3. **Python**: requirements.txt/pyproject.toml/setup.py → detect Django, Flask, FastAPI, or plain Python
4. **Go**: go.mod → always detected as Go
5. **Rust**: Cargo.toml → always detected as Rust
6. **Java**: pom.xml or build.gradle → detected as Java/Maven or Java/Gradle
7. **PHP**: composer.json → detect Laravel, Symfony, or plain PHP
8. **C#/.NET**: .csproj or .sln → detected as C#/.NET
9. **Other**: Fallback to language detection from file extensions

**Confidence scoring** (0.0–1.0):
- Primary manifest found: +0.8 (high confidence)
- Framework indicators in dependencies: +0.15 (e.g., `next`, `rails`, `django` in deps)
- Multiple confirming signals: +0.05 bonus
- Missing primary manifest: -0.3 (lower confidence, fallback to secondary detection)

### Edge Cases & Fallbacks

1. **Monorepos** (Lerna, Yarn workspaces, pnpm, Turborepo):
   - Detect `lerna.json`, root package.json with `workspaces` field, `pnpm-workspace.yaml`, or `turbo.json`
   - Tag as `monorepo` in output; recommend `standard` template regardless of single-project type
   - Scan first workspace for actual project type

2. **Missing primary manifest**:
   - Fall back to secondary detection: scan source files for import statements
   - If nothing found, default to language detected from file extensions

3. **Mixed frameworks** (e.g., Node backend + React frontend):
   - Detect both; recommend template based on primary (most impactful) framework
   - Flag in output: `"frameworks": ["node", "react"]`

4. **Non-standard setups** (custom scripts, no manifest):
   - Scan first 5 source files for shebang or language hint
   - If ambiguous, prompt user for confirmation

### Template Recommendation Logic

**Input**: detected type + complexity (LOC, test count, dependency count)

**Output**: recommended template name (fast/standard/full)

**Rules**:
- Small projects (<5K LOC, <20 dependencies, no tests): `fast`
- Medium projects (5K–50K LOC, 20–100 dependencies, basic tests): `standard`
- Large projects (>50K LOC, >100 dependencies, comprehensive tests): `full`
- New projects (no tests detected): `fast` → scale up after first run
- Enterprise frameworks (Java/Maven, .NET): skip `fast`, recommend `standard` minimum

### Implementation Checklist

- [ ] Bash functions for each manifest type (parse_node, parse_python, parse_go, etc.)
- [ ] Confidence scoring with weighted sum
- [ ] Monorepo detection and handling
- [ ] Fallback detection (source file scanning)
- [ ] Template recommendation based on type + complexity
- [ ] Safe file I/O (handle missing/malformed manifests without crashing)
- [ ] Test suite: one sample project per type (10+ total), validate detection accuracy
- [ ] Performance: complete detection in <2 seconds on typical projects
- [ ] Output: JSON with `type`, `language`, `framework`, `confidence`, `template`, `build_cmd`, `test_cmd`

### Security Considerations

- Parse JSON/YAML safely using `jq`/`yq` (not regex)
- Never execute manifest files (no `eval`, no dynamic sourcing)
- Validate file paths before reading (no path traversal)
- Handle large files gracefully (read first N lines only for source scanning)
