#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/starter-kit — Framework-specific best practices library  ║
# ║  Pure functions: best practices, quality checks, pitfalls, issues        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   source "$SCRIPT_DIR/lib/starter-kit.sh"
#   starter_kit_best_practices "nodejs" "express"
#   starter_kit_quality_checks "python" "django" "/path/to/project"
#   starter_kit_pitfalls "golang" "gin"
#   starter_kit_example_issues "rust" "axum" "cargo test" "/path/to/project"

[[ -n "${_STARTER_KIT_LOADED:-}" ]] && return 0
_STARTER_KIT_LOADED=1

# ─── Validate type/framework combination ──────────────────────────────────
# Returns corrected "type framework" via stdout
_sk_validate_type_framework() {
    local type="${1:-unknown}" framework="${2:-unknown}"

    case "$type" in
        nodejs)
            case "$framework" in
                next|react|vue|angular|express|nestjs|fastify|hono) ;;
                *) framework="unknown" ;;
            esac
            ;;
        python)
            case "$framework" in
                django|fastapi|flask) ;;
                *) framework="unknown" ;;
            esac
            ;;
        golang)
            case "$framework" in
                gin|echo|chi|fiber) ;;
                *) framework="unknown" ;;
            esac
            ;;
        rust)
            case "$framework" in
                actix-web|axum|rocket) ;;
                *) framework="unknown" ;;
            esac
            ;;
        ruby)
            case "$framework" in
                rails) ;;
                *) framework="unknown" ;;
            esac
            ;;
        *)
            type="unknown"
            framework="unknown"
            ;;
    esac

    echo "$type $framework"
}

# ═══════════════════════════════════════════════════════════════════════════
# Best Practices — per (type, framework) combination
# ═══════════════════════════════════════════════════════════════════════════

_sk_nodejs_next_practices() {
    cat <<'PRACTICES'
### Next.js Conventions
- Use App Router (`app/`) over Pages Router for new projects
- Server Components by default; add `"use client"` only when needed
- Co-locate page components, loading states, and error boundaries
- Use `next/image` for all images; `next/link` for navigation
- API routes in `app/api/` follow REST conventions
- Environment variables: `NEXT_PUBLIC_` prefix for client-side access
- Prefer Server Actions over API routes for form mutations
- Use `generateMetadata()` for dynamic SEO; `metadata` export for static
PRACTICES
}

_sk_nodejs_express_practices() {
    cat <<'PRACTICES'
### Express.js Conventions
- Organize routes in `routes/` directory with dedicated router files
- Use middleware chain: cors → helmet → body-parser → auth → routes → error handler
- Error-handling middleware must have 4 parameters: `(err, req, res, next)`
- Use `express.Router()` for modular route groups
- Validate request bodies with a schema library (joi, zod, express-validator)
- Keep controllers thin — delegate business logic to service layer
- Use `async/await` with `express-async-errors` or wrap handlers
PRACTICES
}

_sk_nodejs_generic_practices() {
    cat <<'PRACTICES'
### Node.js Conventions
- Use ES modules (`"type": "module"` in package.json) for new projects
- Organize code: `src/` for source, `tests/` for tests, `config/` for configuration
- Handle all promise rejections — use `process.on('unhandledRejection', ...)`
- Use environment variables via `process.env` with validation at startup
- Prefer `const` over `let`; avoid `var`
- Use `npm run` scripts for all build/test/lint commands
- Lock dependencies: commit `package-lock.json` (or `yarn.lock`/`pnpm-lock.yaml`)
PRACTICES
}

_sk_python_django_practices() {
    cat <<'PRACTICES'
### Django Conventions
- Follow the Django project layout: `project/settings.py`, `app/models.py`, `app/views.py`
- Use class-based views (CBVs) for CRUD; function-based views for simple endpoints
- Always create and run migrations: `python manage.py makemigrations && migrate`
- Use Django ORM querysets — avoid raw SQL unless performance-critical
- Configure `ALLOWED_HOSTS`, `SECRET_KEY` via environment variables
- Use Django REST Framework (DRF) for API endpoints
- Write model-level validation in `clean()` methods
- Use `select_related()` / `prefetch_related()` to avoid N+1 queries
PRACTICES
}

_sk_python_fastapi_practices() {
    cat <<'PRACTICES'
### FastAPI Conventions
- Use Pydantic models for all request/response schemas
- Organize routers in `routers/` directory; include via `app.include_router()`
- Use dependency injection via `Depends()` for auth, DB sessions, config
- Define async endpoints (`async def`) for I/O-bound work
- Use `HTTPException` for error responses with proper status codes
- Configure CORS middleware for frontend integration
- Use `lifespan` context manager for startup/shutdown events
PRACTICES
}

_sk_python_generic_practices() {
    cat <<'PRACTICES'
### Python Conventions
- Follow PEP 8 style guide; use a formatter (black, ruff format)
- Use virtual environments (`venv`, `poetry`, or `pdm`)
- Type hints on all public function signatures
- Organize: `src/<package>/` for source, `tests/` for tests
- Use `pyproject.toml` as the single source of project metadata
- Prefer `pathlib.Path` over `os.path` for file operations
- Use `logging` module instead of `print()` for operational output
PRACTICES
}

_sk_golang_gin_practices() {
    cat <<'PRACTICES'
### Gin Framework Conventions
- Group routes with `router.Group()` for shared middleware
- Use `gin.Context` methods: `c.JSON()`, `c.Bind()`, `c.Param()`
- Register middleware with `router.Use()` — order matters
- Use `gin.H{}` for quick JSON responses; struct binding for complex ones
- Validate input with binding tags: `binding:"required"`
- Use `gin.Recovery()` middleware to catch panics
PRACTICES
}

_sk_golang_generic_practices() {
    cat <<'PRACTICES'
### Go Conventions
- Follow standard project layout: `cmd/` for entry points, `internal/` for private packages
- Use `error` return values — never panic in library code
- Wrap errors with `fmt.Errorf("context: %w", err)` for stack context
- Interfaces should be small (1-3 methods); define at the consumer, not provider
- Use `context.Context` as the first parameter for cancellation/timeout
- Run `go vet ./...` and `go test -race ./...` in CI
- Use `defer` for cleanup (file close, mutex unlock) immediately after acquisition
PRACTICES
}

_sk_rust_axum_practices() {
    cat <<'PRACTICES'
### Axum Framework Conventions
- Define routes with `Router::new().route("/path", get(handler))`
- Use extractors: `Path`, `Query`, `Json`, `State` for request data
- Share state via `Extension` or `State` with `Arc`
- Use tower middleware layers for cross-cutting concerns
- Return `impl IntoResponse` from handlers for flexible response types
- Use `axum::extract::rejection` for custom error responses
PRACTICES
}

_sk_rust_generic_practices() {
    cat <<'PRACTICES'
### Rust Conventions
- Use the module tree: `src/lib.rs` for library, `src/main.rs` for binary
- Propagate errors with `?` operator; use `thiserror` for custom error types
- Prefer `Result<T, E>` over `unwrap()`/`expect()` in library code
- Use `clippy` with `-D warnings` to enforce idiomatic code
- Organize with `mod.rs` or `module_name.rs` + `module_name/` directory
- Use `cargo fmt` for consistent formatting
- Keep `unsafe` blocks minimal and well-documented
PRACTICES
}

_sk_ruby_rails_practices() {
    cat <<'PRACTICES'
### Ruby on Rails Conventions
- Follow convention over configuration — use Rails generators
- MVC structure: models in `app/models/`, controllers in `app/controllers/`
- Use ActiveRecord associations (`has_many`, `belongs_to`) over manual joins
- Validate at the model level with ActiveRecord validations
- Use `before_action` callbacks sparingly — prefer explicit method calls
- Use `strong_parameters` (`params.require().permit()`) in controllers
- Run `bundle exec rails db:migrate` after any schema changes
- Use scopes for reusable query logic in models
PRACTICES
}

_sk_ruby_generic_practices() {
    cat <<'PRACTICES'
### Ruby Conventions
- Follow the Ruby Style Guide; use RuboCop for enforcement
- Use `Bundler` for dependency management; commit `Gemfile.lock`
- Organize: `lib/` for source, `spec/` or `test/` for tests
- Use blocks and iterators over manual loops
- Prefer symbols over strings for hash keys
- Use `frozen_string_literal: true` magic comment
PRACTICES
}

_sk_generic_practices() {
    cat <<'PRACTICES'
### General Coding Conventions
- Keep functions small and focused — single responsibility
- Write descriptive variable and function names
- Handle errors explicitly — never silently ignore failures
- Use version control best practices — small, focused commits
- Document public APIs and non-obvious logic
- Keep dependencies up to date; audit for security vulnerabilities
PRACTICES
}

starter_kit_best_practices() {
    local type="$1" framework="$2"
    local validated
    validated=$(_sk_validate_type_framework "$type" "$framework")
    type="${validated% *}"
    framework="${validated#* }"

    case "$type" in
        nodejs)
            case "$framework" in
                next)    _sk_nodejs_next_practices ;;
                express) _sk_nodejs_express_practices ;;
                *)       _sk_nodejs_generic_practices ;;
            esac
            ;;
        python)
            case "$framework" in
                django)  _sk_python_django_practices ;;
                fastapi) _sk_python_fastapi_practices ;;
                *)       _sk_python_generic_practices ;;
            esac
            ;;
        golang)
            case "$framework" in
                gin) _sk_golang_gin_practices ;;
                *)   _sk_golang_generic_practices ;;
            esac
            ;;
        rust)
            case "$framework" in
                axum) _sk_rust_axum_practices ;;
                *)    _sk_rust_generic_practices ;;
            esac
            ;;
        ruby)
            case "$framework" in
                rails) _sk_ruby_rails_practices ;;
                *)     _sk_ruby_generic_practices ;;
            esac
            ;;
        *)  _sk_generic_practices ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# Quality Checks — returns JSON array of commands per framework
# ═══════════════════════════════════════════════════════════════════════════

starter_kit_quality_checks() {
    local type="$1" framework="$2" root="${3:-.}"
    local validated
    validated=$(_sk_validate_type_framework "$type" "$framework")
    type="${validated% *}"
    framework="${validated#* }"

    local checks="[]"

    case "$type" in
        nodejs)
            checks='["npx tsc --noEmit", "npm run lint", "npx prettier --check .", "npm test"]'
            # If no tsconfig, remove tsc check
            if [[ ! -f "$root/tsconfig.json" ]]; then
                checks='["npm run lint", "npx prettier --check .", "npm test"]'
            fi
            ;;
        python)
            checks='["ruff check .", "mypy .", "python -m pytest"]'
            case "$framework" in
                django)
                    checks='["ruff check .", "mypy .", "python manage.py test", "python manage.py check --deploy"]'
                    ;;
            esac
            ;;
        golang)
            checks='["go vet ./...", "golangci-lint run", "go test ./...", "go build ./..."]'
            ;;
        rust)
            checks='["cargo clippy -- -D warnings", "cargo fmt --check", "cargo test"]'
            ;;
        ruby)
            checks='["bundle exec rubocop", "bundle exec rspec"]'
            case "$framework" in
                rails)
                    checks='["bundle exec rubocop", "bundle exec rspec", "bundle exec rails db:migrate:status"]'
                    ;;
            esac
            ;;
        *)
            checks='["echo No quality checks configured — add framework-specific checks"]'
            ;;
    esac

    echo "$checks"
}

# ═══════════════════════════════════════════════════════════════════════════
# Pitfalls — common gotchas per framework
# ═══════════════════════════════════════════════════════════════════════════

_sk_nodejs_pitfalls() {
    cat <<'PITFALLS'
### Common Pitfalls
- **Unhandled promise rejections** — Always `.catch()` or use `async/await` with try/catch
- **Memory leaks from event listeners** — Remove listeners when components unmount
- **Blocking the event loop** — Use `worker_threads` for CPU-intensive work
- **Missing error middleware** (Express) — Must be the last middleware in the chain
- **SSR hydration mismatches** (Next.js) — Ensure server and client render identical markup
- **Dependency confusion attacks** — Use `package-lock.json` and verify registry URLs
PITFALLS
}

_sk_python_pitfalls() {
    cat <<'PITFALLS'
### Common Pitfalls
- **Circular imports** — Use local imports or restructure module dependencies
- **Mutable default arguments** — Never use `def f(x=[]):`; use `def f(x=None):`
- **Missing migrations** (Django) — Always run `makemigrations` after model changes
- **Async context issues** (FastAPI) — Don't mix sync and async DB calls without care
- **Virtual environment not activated** — Verify `which python` points to venv
- **Silent type errors** — Run `mypy` in strict mode for critical modules
PITFALLS
}

_sk_golang_pitfalls() {
    cat <<'PITFALLS'
### Common Pitfalls
- **Goroutine leaks** — Always ensure goroutines can exit; use `context.Context` for cancellation
- **Nil pointer dereference** — Check interface values and pointer returns before use
- **Deferred close errors** — Use `defer func() { if err := f.Close(); err != nil { ... } }()`
- **Data races** — Run tests with `-race` flag; protect shared state with mutexes or channels
- **Error shadowing** — Don't use `:=` when you mean `=` in error handling blocks
- **Import cycle** — Keep packages small and interfaces at the consumer side
PITFALLS
}

_sk_rust_pitfalls() {
    cat <<'PITFALLS'
### Common Pitfalls
- **Lifetime complexity** — Start with owned types (`String`, `Vec`); optimize to borrows later
- **Async runtime conflicts** — Don't mix `tokio` and `async-std` in the same project
- **Feature flag combinatorics** — Test with `--all-features` and `--no-default-features`
- **Deadlocks with Mutex** — Avoid holding locks across `.await` points; use `tokio::sync::Mutex`
- **Orphan rule frustration** — Use newtype pattern to implement external traits on external types
- **Compile times** — Use `cargo check` for fast feedback; full build only when needed
PITFALLS
}

_sk_ruby_pitfalls() {
    cat <<'PITFALLS'
### Common Pitfalls
- **N+1 queries** — Use `includes()` or `eager_load()` for associations
- **Mass assignment** — Always use strong parameters; never `permit!` in production
- **Callback hell** — Prefer service objects over long callback chains in models
- **Gem version conflicts** — Pin major versions in Gemfile; use `bundle update --conservative`
- **Memory bloat** — Watch for large ActiveRecord result sets; use `find_each` for batches
- **Timezone confusion** — Always use `Time.zone.now` instead of `Time.now` in Rails
PITFALLS
}

_sk_generic_pitfalls() {
    cat <<'PITFALLS'
### Common Pitfalls
- **Ignoring error return values** — Always check and handle errors explicitly
- **Hard-coded configuration** — Use environment variables for all deployment-specific values
- **Missing input validation** — Validate at system boundaries (API inputs, file reads)
- **No CI pipeline** — Set up automated testing before the codebase grows
- **Outdated dependencies** — Schedule regular dependency updates and security audits
PITFALLS
}

starter_kit_pitfalls() {
    local type="$1" framework="$2"
    local validated
    validated=$(_sk_validate_type_framework "$type" "$framework")
    type="${validated% *}"

    case "$type" in
        nodejs) _sk_nodejs_pitfalls ;;
        python) _sk_python_pitfalls ;;
        golang) _sk_golang_pitfalls ;;
        rust)   _sk_rust_pitfalls ;;
        ruby)   _sk_ruby_pitfalls ;;
        *)      _sk_generic_pitfalls ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# Example Issue Templates — generates issue template file content
# ═══════════════════════════════════════════════════════════════════════════
# Output format: lines of "FILENAME" then content then "---SK_DELIM---"

_sk_issue_dependency_update() {
    local type="$1"
    local update_cmd="Update dependencies"
    case "$type" in
        nodejs) update_cmd="npm outdated && npm update" ;;
        python) update_cmd="pip list --outdated && pip install --upgrade <packages>" ;;
        golang) update_cmd="go get -u ./... && go mod tidy" ;;
        rust)   update_cmd="cargo update && cargo outdated" ;;
        ruby)   update_cmd="bundle outdated && bundle update" ;;
    esac

    cat <<EOF
dependency-update.md
---
name: Dependency Update
about: Update project dependencies to latest compatible versions
title: 'chore: update dependencies'
labels: dependencies, maintenance
assignees: ''
---

## Goal
Audit and update all project dependencies to their latest compatible versions.

## Steps
1. Run \`$update_cmd\` to check for outdated packages
2. Update dependencies one group at a time (dev deps, then prod deps)
3. Run the full test suite after each update group
4. Check for breaking changes in changelogs of major version bumps
5. Update lock file and commit

## Acceptance Criteria
- [ ] All dependencies at latest compatible versions
- [ ] No security vulnerabilities in dependency tree
- [ ] All tests pass after updates
---SK_DELIM---
EOF
}

_sk_issue_test_coverage() {
    local test_cmd="${1:-npm test}"
    cat <<EOF
test-coverage.md
---
name: Improve Test Coverage
about: Add tests for uncovered code paths
title: 'test: improve test coverage'
labels: testing, quality
assignees: ''
---

## Goal
Identify and test uncovered code paths to improve overall test coverage.

## Steps
1. Run tests with coverage: \`$test_cmd\` (with coverage flag)
2. Identify files/functions below 80% coverage
3. Write unit tests for uncovered branches and edge cases
4. Focus on critical paths: error handling, boundary conditions, integration points

## Acceptance Criteria
- [ ] Overall coverage above 80%
- [ ] All critical paths have test coverage
- [ ] No untested error handlers in production code
---SK_DELIM---
EOF
}

_sk_issue_bug_fix_template() {
    cat <<'EOF'
bug-fix.md
---
name: Bug Report
about: Report a bug for the autonomous agent to investigate and fix
title: 'fix: '
labels: bug
assignees: ''
---

## Bug Description
A clear description of what the bug is.

## Steps to Reproduce
1. Step one
2. Step two
3. Step three

## Expected Behavior
What should happen.

## Actual Behavior
What actually happens.

## Environment
- OS:
- Runtime version:
- Relevant dependency versions:

## Additional Context
Stack traces, screenshots, or logs.
---SK_DELIM---
EOF
}

_sk_issue_nodejs_specific() {
    cat <<'EOF'
typescript-strict.md
---
name: Enable TypeScript Strict Mode
about: Enable strict TypeScript checking for better type safety
title: 'chore: enable TypeScript strict mode'
labels: enhancement, typescript
assignees: ''
---

## Goal
Enable `"strict": true` in `tsconfig.json` and fix all resulting type errors.

## Steps
1. Set `"strict": true` in `tsconfig.json`
2. Run `npx tsc --noEmit` to see all type errors
3. Fix errors file by file, starting with the most-imported modules
4. Add explicit types where `any` was inferred
5. Ensure all tests still pass

## Acceptance Criteria
- [ ] `tsconfig.json` has `"strict": true`
- [ ] `npx tsc --noEmit` passes with zero errors
- [ ] All existing tests pass
---SK_DELIM---
EOF
}

_sk_issue_python_specific() {
    cat <<'EOF'
type-hints.md
---
name: Add Type Hints
about: Add type annotations to improve code quality and IDE support
title: 'chore: add comprehensive type hints'
labels: enhancement, typing
assignees: ''
---

## Goal
Add type hints to all public functions and configure mypy for type checking.

## Steps
1. Configure `mypy` in `pyproject.toml` with strict settings
2. Add type hints to all public function signatures
3. Add `py.typed` marker file for PEP 561 compliance
4. Fix all mypy errors
5. Add mypy to CI pipeline

## Acceptance Criteria
- [ ] All public functions have type annotations
- [ ] `mypy --strict` passes (or with documented exceptions)
- [ ] CI runs mypy on every PR
---SK_DELIM---
EOF
}

_sk_issue_golang_specific() {
    cat <<'EOF'
linter-setup.md
---
name: Configure golangci-lint
about: Set up comprehensive Go linting with golangci-lint
title: 'chore: configure golangci-lint'
labels: enhancement, tooling
assignees: ''
---

## Goal
Set up `golangci-lint` with a project-specific configuration for consistent code quality.

## Steps
1. Create `.golangci.yml` with enabled linters (govet, errcheck, staticcheck, gosimple, unused)
2. Run `golangci-lint run` and fix all findings
3. Add to CI pipeline
4. Document any intentional `nolint` directives

## Acceptance Criteria
- [ ] `.golangci.yml` configured with appropriate linters
- [ ] `golangci-lint run` passes with zero findings
- [ ] CI blocks PRs with lint violations
---SK_DELIM---
EOF
}

_sk_issue_rust_specific() {
    cat <<'EOF'
clippy-strict.md
---
name: Enable Strict Clippy Lints
about: Configure Clippy with strict linting rules
title: 'chore: enable strict Clippy lints'
labels: enhancement, tooling
assignees: ''
---

## Goal
Enable strict Clippy lints to enforce idiomatic Rust patterns.

## Steps
1. Add `#![warn(clippy::all, clippy::pedantic)]` to `src/lib.rs` or `src/main.rs`
2. Run `cargo clippy` and fix all warnings
3. Document any `#[allow(...)]` exceptions with justification
4. Add clippy to CI with `-D warnings`

## Acceptance Criteria
- [ ] Clippy pedantic lints enabled
- [ ] `cargo clippy -- -D warnings` passes
- [ ] All `#[allow]` directives have justification comments
---SK_DELIM---
EOF
}

_sk_issue_ruby_specific() {
    cat <<'EOF'
rubocop-setup.md
---
name: Configure RuboCop
about: Set up RuboCop for consistent Ruby/Rails code style
title: 'chore: configure RuboCop with project rules'
labels: enhancement, tooling
assignees: ''
---

## Goal
Configure RuboCop with project-specific rules and fix existing violations.

## Steps
1. Create `.rubocop.yml` with team-agreed rules
2. Run `bundle exec rubocop --auto-gen-config` for baseline
3. Fix violations incrementally (start with high-severity)
4. Add RuboCop to CI pipeline

## Acceptance Criteria
- [ ] `.rubocop.yml` configured with project rules
- [ ] `bundle exec rubocop` passes (or documented exceptions in `.rubocop_todo.yml`)
- [ ] CI runs RuboCop on every PR
---SK_DELIM---
EOF
}

starter_kit_example_issues() {
    local type="$1" framework="$2" test_cmd="${3:-}" root="${4:-.}"
    local validated
    validated=$(_sk_validate_type_framework "$type" "$framework")
    type="${validated% *}"
    framework="${validated#* }"

    # Universal issues
    _sk_issue_dependency_update "$type"
    _sk_issue_test_coverage "${test_cmd:-npm test}"
    _sk_issue_bug_fix_template

    # Framework-specific issue
    case "$type" in
        nodejs) _sk_issue_nodejs_specific ;;
        python) _sk_issue_python_specific ;;
        golang) _sk_issue_golang_specific ;;
        rust)   _sk_issue_rust_specific ;;
        ruby)   _sk_issue_ruby_specific ;;
    esac
}
