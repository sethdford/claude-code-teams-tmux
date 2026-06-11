## Project Detection Design

Detecting project type (language, framework, package manager, test runner) is the foundation for zero-config setup. Poor detection cascades into incorrect config and agent templates.

### Detection Strategy

**Layered Detection with Confidence Scoring:**
- Layer 1: Package manager indicators (package.json, requirements.txt, go.mod, Cargo.toml)
- Layer 2: Framework hints (imports, config files, lock files)
- Layer 3: Test runner detection (test scripts, fixture patterns, runner binaries)
- Layer 4: Project size/complexity (file count, test count, dependency count)

Each indicator contributes to a confidence score per language. Use highest-confidence language as primary, second-highest as fallback hint.

### Edge Cases & Handling

1. **Monorepos**: Multiple package.json or Cargo.toml files → detect primary language from root, flag as monorepo for config generation
2. **Missing primary indicators**: No package.json but has src/ + Makefile → apply heuristic scoring
3. **Polyglot projects**: Go backend + Node frontend → detect both, ask user or use Git history to pick primary
4. **Bare directories**: New project with just a few files → flag as "uncertain", suggest manual language selection
5. **Lock file without manifest**: lock.json without package.json → file corruption likely, require confirmation

### Implementation Checklist

- [ ] Read file system once (not per-detector)
- [ ] Assign numeric confidence 0-100 per language
- [ ] Return ranked list (primary, secondary, confidence scores)
- [ ] Provide reason text for each detection (e.g., "Node detected from package.json")
- [ ] Log detection process for debugging
- [ ] Handle permission errors gracefully
- [ ] Timeout directory traversal after 10k files
