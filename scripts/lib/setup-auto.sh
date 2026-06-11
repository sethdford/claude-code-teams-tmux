#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/setup-auto — Intelligent defaults for zero-config setup    ║
# ║  Complexity scoring, config generation, and language-agent generation      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   source "$SCRIPT_DIR/lib/setup-auto.sh"
#   setup_auto_complexity_score "/path/to/project"   # JSON: score 0-100 + signals
#   setup_auto_generate_config  "/path/to/project"   # Tuned daemon-config.json
#   setup_auto_generate_agents  "/path/to/project"   # Language-specific agents
#
# Provides:
#   - setup_auto_complexity_score(root)          — Score project complexity (0-100)
#   - setup_auto_complexity_band(score)          — Map score to low|medium|high
#   - setup_auto_generate_config(root[, score])  — Generate tuned daemon-config.json
#   - setup_auto_generate_agents(root[, type])   — Generate language-specific agents
#
# All file writes are atomic (tmp + mv) and idempotent: existing user
# configuration is preserved, never overwritten.

[[ -n "${_SETUP_AUTO_LOADED:-}" ]] && return 0
_SETUP_AUTO_LOADED=1

_SETUP_AUTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse the canonical project detector for type/framework/test/build.
# shellcheck source=/dev/null
[[ -n "${_PROJECT_DETECT_LOADED:-}" ]] || source "$_SETUP_AUTO_DIR/project-detect.sh"

# ═══════════════════════════════════════════════════════════════════════════
# setup_auto_complexity_score(root)
# ─────────────────────────────────────────────────────────────────────────────
# Score project complexity on a 0-100 scale from structural signals:
#   - source file count   (volume of code to reason about)
#   - test file count     (existing test surface)
#   - lines of code        (depth of each file)
#   - infra presence       (Docker/k8s/CI raise operational complexity)
#
# Returns JSON: {
#   "score": 0-100,
#   "band": "low|medium|high",
#   "src_files": N, "test_files": N, "src_lines": N,
#   "has_deploy": bool, "has_ci": bool
# }
setup_auto_complexity_score() {
    local root="${1:-.}"
    [[ -d "$root" ]] || return 1

    local src_file_count test_file_count src_lines
    src_file_count=$(find "$root" \
        \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
           -o -name "*.py" -o -name "*.rb" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" \
        -not -path "*/target/*" 2>/dev/null | wc -l | tr -d ' ')
    src_file_count=${src_file_count:-0}

    test_file_count=$(find "$root" \
        \( -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" -o -name "test_*" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')
    test_file_count=${test_file_count:-0}

    src_lines=$(find "$root" \
        \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
           -o -name "*.py" -o -name "*.rb" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \) \
        -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/vendor/*" \
        -not -path "*/target/*" -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
    src_lines=${src_lines:-0}

    local has_deploy="false" has_ci="false"
    if [[ -f "$root/Dockerfile" || -f "$root/docker-compose.yml" || -f "$root/docker-compose.yaml" \
          || -f "$root/compose.yml" || -d "$root/k8s" || -d "$root/helm" || -f "$root/k8s.yaml" ]]; then
        has_deploy="true"
    fi
    if [[ -d "$root/.github/workflows" || -f "$root/.gitlab-ci.yml" || -f "$root/Jenkinsfile" ]]; then
        has_ci="true"
    fi

    # ── Weighted score (each component capped, summed to 0-100) ──
    # Files: up to 40 points (saturates at 200 files)
    local files_pts=$(( src_file_count / 5 ))
    [[ "$files_pts" -gt 40 ]] && files_pts=40
    # Lines: up to 30 points (saturates at 30k lines)
    local lines_pts=$(( src_lines / 1000 ))
    [[ "$lines_pts" -gt 30 ]] && lines_pts=30
    # Tests: up to 15 points (saturates at 75 test files)
    local test_pts=$(( test_file_count / 5 ))
    [[ "$test_pts" -gt 15 ]] && test_pts=15
    # Infra: deploy + CI each add operational complexity
    local infra_pts=0
    [[ "$has_deploy" == "true" ]] && infra_pts=$(( infra_pts + 10 ))
    [[ "$has_ci" == "true" ]] && infra_pts=$(( infra_pts + 5 ))

    local score=$(( files_pts + lines_pts + test_pts + infra_pts ))
    [[ "$score" -gt 100 ]] && score=100

    local band
    band=$(setup_auto_complexity_band "$score")

    jq -n \
        --argjson score "$score" \
        --arg band "$band" \
        --argjson src_files "$src_file_count" \
        --argjson test_files "$test_file_count" \
        --argjson src_lines "$src_lines" \
        --argjson has_deploy "$has_deploy" \
        --argjson has_ci "$has_ci" \
        '{score: $score, band: $band, src_files: $src_files,
          test_files: $test_files, src_lines: $src_lines,
          has_deploy: $has_deploy, has_ci: $has_ci}'
}

# ═══════════════════════════════════════════════════════════════════════════
# setup_auto_complexity_band(score) — map 0-100 score to a band
# ═══════════════════════════════════════════════════════════════════════════
setup_auto_complexity_band() {
    local score="${1:-0}"
    if [[ "$score" -lt 30 ]]; then
        echo "low"
    elif [[ "$score" -lt 70 ]]; then
        echo "medium"
    else
        echo "high"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# setup_auto_generate_config(root[, score])
# ─────────────────────────────────────────────────────────────────────────────
# Generate a daemon-config.json tuned to the project's complexity band.
# Idempotent: if a config already exists, generated defaults are merged
# UNDER the existing file so user settings always win. Atomic write.
#
# Tuning by band:
#   low    → fast template,     low parallelism, fewer restarts,  cheap models
#   medium → standard template, moderate everything
#   high   → full template,     high parallelism, more restarts,  opus routing
#
# Returns the path to the written config on stdout.
setup_auto_generate_config() {
    local root="${1:-.}"
    local score="${2:-}"
    [[ -d "$root" ]] || return 1

    if [[ -z "$score" ]]; then
        local cx
        cx=$(setup_auto_complexity_score "$root")
        score=$(echo "$cx" | jq -r '.score')
    fi

    local band
    band=$(setup_auto_complexity_band "$score")

    # ── Per-band tuning knobs ──
    local template max_parallel max_restarts max_extensions
    local effort_build effort_review default_model classification_model
    case "$band" in
        low)
            template="fast";     max_parallel=1; max_restarts=2; max_extensions=2
            effort_build="low";  effort_review="medium"
            default_model="sonnet"; classification_model="haiku" ;;
        high)
            template="full";     max_parallel=4; max_restarts=4; max_extensions=4
            effort_build="medium"; effort_review="high"
            default_model="opus"; classification_model="haiku" ;;
        *)  # medium
            template="standard"; max_parallel=2; max_restarts=3; max_extensions=3
            effort_build="medium"; effort_review="high"
            default_model="opus"; classification_model="haiku" ;;
    esac

    local generated
    generated=$(jq -n \
        --arg template "$template" \
        --argjson max_parallel "$max_parallel" \
        --argjson max_restarts "$max_restarts" \
        --argjson max_extensions "$max_extensions" \
        --arg effort_build "$effort_build" \
        --arg effort_review "$effort_review" \
        --arg default_model "$default_model" \
        --arg classification_model "$classification_model" \
        --argjson score "$score" \
        --arg band "$band" \
        '{
            pipeline_template: $template,
            max_parallel: $max_parallel,
            poll_interval: 60,
            auto_template: true,
            loop: {
                circuit_breaker_threshold: 4,
                min_progress_lines: 3,
                extension_size: 5,
                max_extensions: $max_extensions,
                context_restart_limit: 3,
                hard_restart_cap: 5,
                max_restarts: $max_restarts
            },
            effort_levels: {
                intake: "low",
                build: $effort_build,
                test: "medium",
                review: $effort_review,
                plan: "high",
                design: "high"
            },
            model_routing: {
                default: $default_model,
                classification: $classification_model,
                detection: "haiku",
                validation: "haiku",
                high_risk: "opus"
            },
            complexity: { score: $score, band: $band }
        }')

    local config_file="$root/.claude/daemon-config.json"
    mkdir -p "$root/.claude"

    local merged
    if [[ -f "$config_file" ]] && jq empty "$config_file" 2>/dev/null; then
        # Deep-merge: generated as base, existing on top (existing wins).
        merged=$(jq -s '.[0] * .[1]' <(echo "$generated") "$config_file")
    else
        merged="$generated"
    fi

    # Atomic write with restrictive permissions.
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/sw-daemon-config.XXXXXX") || return 1
    printf '%s\n' "$merged" > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$config_file"

    echo "$config_file"
}

# ═══════════════════════════════════════════════════════════════════════════
# setup_auto_generate_agents(root[, type])
# ─────────────────────────────────────────────────────────────────────────────
# Generate a language-specific specialist agent in .claude/agents/.
# Idempotent: never overwrites an existing agent file. Atomic write.
#
# Returns the path(s) to any newly created agent file on stdout (empty if
# the agent already existed or the type is unsupported).
setup_auto_generate_agents() {
    local root="${1:-.}"
    local type="${2:-}"
    [[ -d "$root" ]] || return 1

    if [[ -z "$type" ]]; then
        local type_info
        type_info=$(project_detect_type "$root" 2>/dev/null || echo '{}')
        type=$(echo "$type_info" | jq -r '.type // "unknown"')
    fi

    local lang slug body
    case "$type" in
        nodejs)
            slug="node-specialist"; lang="Node.js / JavaScript / TypeScript"
            body=$(_setup_auto_agent_node) ;;
        python)
            slug="python-specialist"; lang="Python"
            body=$(_setup_auto_agent_python) ;;
        golang)
            slug="go-specialist"; lang="Go"
            body=$(_setup_auto_agent_go) ;;
        rust)
            slug="rust-specialist"; lang="Rust"
            body=$(_setup_auto_agent_rust) ;;
        *)
            return 0 ;;  # No specialist template for this type — nothing to do.
    esac

    local agents_dir="$root/.claude/agents"
    local agent_file="$agents_dir/$slug.md"
    mkdir -p "$agents_dir"

    # Idempotent: preserve any existing (possibly user-edited) agent.
    [[ -f "$agent_file" ]] && return 0

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/sw-agent.XXXXXX") || return 1
    {
        printf -- '---\n'
        printf 'name: %s\n' "$slug"
        printf 'description: %s development specialist — idioms, testing, and tooling conventions\n' "$lang"
        printf -- '---\n\n'
        printf '%s\n' "$body"
    } > "$tmp"
    mv -f "$tmp" "$agent_file"

    echo "$agent_file"
}

# ─── Agent body templates (kept terse and language-focused) ──────────────────
_setup_auto_agent_node() {
    cat <<'EOF'
# Node.js / JavaScript / TypeScript Specialist

You are a specialist in Node.js, JavaScript, and TypeScript development.

## Conventions
- Match the project's module system (CommonJS vs ESM) — check `package.json` `"type"`.
- Use the detected package manager (npm/yarn/pnpm/bun) consistently.
- Prefer the project's existing test runner (vitest/jest/mocha). Co-locate or mirror tests per existing layout.

## Quality
- Type-check with `tsc --noEmit` for TypeScript before declaring done.
- Avoid floating promises; always handle async errors.
- Keep functions small and pure where practical; avoid hidden side effects.

## Testing
- Write tests for new functions and error/edge cases.
- Run the project's test command and ensure a green suite before committing.
EOF
}

_setup_auto_agent_python() {
    cat <<'EOF'
# Python Specialist

You are a specialist in Python development.

## Conventions
- Respect the project's dependency tooling (pip/poetry/uv) and virtualenv layout.
- Follow PEP 8; use type hints on public functions.
- Match the existing test runner (pytest/unittest) and test directory layout.

## Quality
- Run `ruff`/`flake8` and `mypy` if configured before declaring done.
- Prefer explicit exceptions over bare `except:`.
- Avoid mutable default arguments.

## Testing
- Add tests for new behavior and edge cases (empty input, boundaries, failures).
- Ensure the full suite passes before committing.
EOF
}

_setup_auto_agent_go() {
    cat <<'EOF'
# Go Specialist

You are a specialist in Go development.

## Conventions
- Run `gofmt`/`goimports`; keep the module path and package layout idiomatic.
- Handle every returned error explicitly — never discard with `_` unless justified.
- Prefer small interfaces defined at the consumer.

## Quality
- Run `go vet ./...` and `go build ./...` before declaring done.
- Avoid goroutine leaks; ensure contexts and channels are closed.

## Testing
- Use table-driven tests; cover error paths.
- Run `go test ./...` and ensure it passes before committing.
EOF
}

_setup_auto_agent_rust() {
    cat <<'EOF'
# Rust Specialist

You are a specialist in Rust development.

## Conventions
- Run `cargo fmt`; follow the existing crate/module structure.
- Prefer `Result` and `?` over panics in library code.
- Use ownership and borrowing idiomatically; avoid unnecessary `clone()`.

## Quality
- Run `cargo clippy --all-targets` and address warnings before declaring done.
- Run `cargo build` to confirm compilation.

## Testing
- Add `#[cfg(test)]` unit tests and cover error paths.
- Run `cargo test` and ensure it passes before committing.
EOF
}
