# Community Starter Kit Generator

The Community Starter Kit Generator (`shipwright prep --gen-starter-kit`) reduces initial project setup time from **10 minutes → 2 minutes** by auto-detecting your project framework and generating best-practice starter configurations.

## Overview

When you run `shipwright prep --gen-starter-kit`, Shipwright:

1. **Detects your project framework** — Parses language manifests (package.json, go.mod, pyproject.toml, etc.)
2. **Recommends a pipeline template** — Suggests `fast`, `standard`, or `full` based on repo size and complexity
3. **Generates CLAUDE-starter.md** — Framework-aware configuration with conventions and recommendations
4. **Creates starter GitHub issues** — 5 templated issues: dependency update, bug fix, feature, docs, test improvements
5. **Generates labels config** — Recommended GitHub labels for workflow automation

All artifacts are generated to `.claude/` for easy review and integration.

## Quick Start

```bash
# Auto-detect framework and generate starter kit
shipwright prep --gen-starter-kit

# Review the generated configuration
cat .claude/CLAUDE-starter.md

# (Optional) Import starter issues to GitHub
gh issue create -R org/repo < .claude/starter-issues.json
```

## Artifacts Generated

### 1. CLAUDE-starter.md
Framework-aware configuration scaffold with:
- Recommended pipeline template and stages
- Language-specific conventions (naming, imports, structure)
- Test strategy and coverage targets
- Monorepo guidance (if detected)
- Edge case handling recommendations

**When to use**: Review and integrate into your existing `.claude/CLAUDE.md` or use as-is if you're starting fresh.

### 2. starter-issues.json
Five GitHub issue templates covering:
- **Dependency Update** — Keep dependencies current
- **Bug Fix** — Report and fix production issues
- **Feature** — Implement new capabilities
- **Documentation** — Improve code comments and docs
- **Test Improvements** — Expand test coverage

**When to use**: Import with `gh issue create -B .claude/starter-issues.json` or manually copy issues into your tracker.

### 3. starter-labels.json
Recommended GitHub labels grouped by category:
- **Priority** — urgent, high, medium, low
- **Type** — bug, feature, documentation, test
- **Status** — in-progress, blocked, review-needed
- **Framework-specific** — depends on your tech stack

**When to use**: Create these labels in your GitHub repository settings.

## Framework Detection

The generator detects frameworks by looking for **primary markers** (high confidence):

| Framework     | Primary Marker      | Detected As              |
| ------------- | ------------------- | ----------------------- |
| Node.js       | `package.json`      | `nodejs` (specific if `next`, `nuxt`, `vue`, etc.) |
| Python        | `pyproject.toml`    | `python` (specific if `django`, `fastapi`, etc.)    |
| Go            | `go.mod`            | `golang`                |
| Rust          | `Cargo.toml`        | `rust`                  |
| Java          | `pom.xml`           | `java-maven`            |
| Ruby          | `Gemfile`           | `ruby-rails` or `ruby`  |

If multiple manifests exist (monorepo), Shipwright returns all detected workspaces and generates a unified config that handles all.

### Confidence Scoring

Each detection includes a confidence score (0.0–1.0):
- **1.0** — Manifest found and parsed successfully
- **0.9** — Manifest found but minimal content
- **0.7** — Detected from CI/build config
- **0.5** — Detected from file extensions only

If confidence is below 0.8, Shipwright recommends manual verification.

## Pipeline Template Recommendations

| Repo Size | Complexity | Recommended Template |
| --------- | ---------- | -------------------- |
| < 50 KB   | Simple     | `fast` — intake → build → test → PR |
| 50 KB–5 MB | Standard   | `standard` — full cycle with reviews |
| > 5 MB    | Complex    | `full` — all stages with deploy gate |

**Factors considered**:
- Number of source files
- Dependency manifest size
- Presence of CI/CD configs
- Monorepo structure
- Docker support

## Edge Cases

### Monorepos

If Shipwright detects multiple frameworks (e.g., API in Go, frontend in React):

```json
{
  "root": "generic",
  "workspaces": [
    { "path": "api", "framework": "golang" },
    { "path": "web", "framework": "next.js" }
  ]
}
```

The generated starter config handles both and suggests per-workspace test and build commands.

### Minimal Projects

If no manifest is found, Shipwright defaults to a generic template with sample commands. You can override:

```bash
# Explicitly specify framework
shipwright prep --framework golang --gen-starter-kit
```

### Monolith → Microservice Migrations

If your codebase has mixed patterns (e.g., legacy monolith with new microservices), Shipwright detects the primary framework and flags secondary patterns. Review the full detection output in `PROJECT_ROOT/.claude/framework-detection.json`.

## Customization

Generated files are **idempotent** — re-running `shipwright prep --gen-starter-kit` overwrites them. To preserve your custom changes:

1. **Move CLAUDE-starter.md to CLAUDE.md** and add your own sections
2. **Edit starter-issues.json** directly in your issue tracker
3. **Create labels manually** in GitHub UI (they're human-readable)

All generated files are marked with `<!-- sw:auto-start -->` and `<!-- sw:auto-end -->` comments. Edit outside these markers to preserve your changes across regenerations.

## Integration with Pipeline

Once you've reviewed the starter kit:

```bash
# Use the recommended pipeline template
shipwright pipeline start --issue 1 --template standard

# Or with full daemon automation
shipwright daemon start
```

The daemon uses your framework detection and starter configuration to intelligently route work.

## Troubleshooting

### "Framework not detected"
Run `shipwright prep --gen-starter-kit` with verbose output:
```bash
shipwright prep --gen-starter-kit --verbose
cat .claude/framework-detection.json  # See raw detection results
```

### "Wrong framework detected"
Override the detection:
```bash
shipwright prep --framework python --gen-starter-kit
```

### "Starter kit doesn't match my project"
The starter kit is a **template**, not a mandate. Review and customize:
- Edit `.claude/CLAUDE-starter.md` before importing
- Pick only the starter issues that matter for your project
- Adjust pipeline stages in `.claude/daemon-config.json`

## See Also

- `shipwright prep --help` — All preparation options
- `shipwright pipeline start --help` — Pipeline execution
- `.claude/CLAUDE.md` — Main configuration
- `.claude/daemon-config.json` — Daemon and intelligence settings
