# project-type-detection.sh — Project type auto-detection and template recommendation
# Source from sw-detect.sh, sw-prep.sh, sw-setup.sh. Requires jq.
[[ -n "${_PROJECT_TYPE_DETECTION_LOADED:-}" ]] && return 0
_PROJECT_TYPE_DETECTION_LOADED=1

# Source pipeline-detection for reuse of detect_project_lang, detect_test_cmd
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

# shellcheck source=pipeline-detection.sh
[[ -f "$(dirname "${BASH_SOURCE[0]}")/pipeline-detection.sh" ]] && source "$(dirname "${BASH_SOURCE[0]}")/pipeline-detection.sh"

# ─── Scoring Functions (private) ─────────────────────────────────────────────
# Each returns an integer 0-100 via echo. Signals are weighted:
#   +25  strong (framework dep)
#   +15  medium (directory convention)
#   +10  weak (file existence)
# Capped at 100.

_score_web_signals() {
    local lang="$1" root="$2"
    local score=0
    local signals=""

    # Server framework dependencies
    case "$lang" in
        node|nodejs|typescript|nextjs|react)
            if [[ -f "$root/package.json" ]]; then
                local deps
                deps=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$root/package.json" 2>/dev/null) || true
                local dep
                for dep in express fastify koa hapi nestjs next nuxt; do
                    if echo "$deps" | grep -qx "$dep" 2>/dev/null || echo "$deps" | grep -qx "@${dep}/core" 2>/dev/null; then
                        score=$((score + 25))
                        signals="${signals}package.json has ${dep} dependency;"
                        break
                    fi
                done
                # @nestjs/core variant
                if echo "$deps" | grep -q "@nestjs/" 2>/dev/null; then
                    if [[ $score -lt 25 ]]; then
                        score=$((score + 25))
                        signals="${signals}package.json has @nestjs dependency;"
                    fi
                fi
            fi
            ;;
        python)
            for f in "$root/requirements.txt" "$root/pyproject.toml" "$root/setup.py" "$root/Pipfile"; do
                if [[ -f "$f" ]]; then
                    if grep -qiE '(django|flask|fastapi|tornado|sanic|starlette)' "$f" 2>/dev/null; then
                        score=$((score + 25))
                        signals="${signals}${f##*/} has web framework dependency;"
                        break
                    fi
                fi
            done
            ;;
        go)
            if [[ -f "$root/go.mod" ]]; then
                if grep -qE '(gin-gonic|echo|fiber|chi|gorilla/mux|net/http)' "$root/go.mod" 2>/dev/null; then
                    score=$((score + 25))
                    signals="${signals}go.mod has web framework dependency;"
                fi
            fi
            ;;
        rust)
            if [[ -f "$root/Cargo.toml" ]]; then
                if grep -qiE '(actix-web|rocket|axum|warp|tide)' "$root/Cargo.toml" 2>/dev/null; then
                    score=$((score + 25))
                    signals="${signals}Cargo.toml has web framework dependency;"
                fi
            fi
            ;;
        java)
            if [[ -f "$root/pom.xml" ]]; then
                if grep -qiE '(spring-boot|spring-web|javax\.servlet|jakarta\.servlet)' "$root/pom.xml" 2>/dev/null; then
                    score=$((score + 25))
                    signals="${signals}pom.xml has web framework dependency;"
                fi
            elif [[ -f "$root/build.gradle" ]] || [[ -f "$root/build.gradle.kts" ]]; then
                local gf="$root/build.gradle"
                [[ -f "$root/build.gradle.kts" ]] && gf="$root/build.gradle.kts"
                if grep -qiE '(spring-boot|spring-web|servlet)' "$gf" 2>/dev/null; then
                    score=$((score + 25))
                    signals="${signals}build.gradle has web framework dependency;"
                fi
            fi
            ;;
        ruby)
            if [[ -f "$root/Gemfile" ]]; then
                if grep -qiE '(rails|sinatra|hanami|grape)' "$root/Gemfile" 2>/dev/null; then
                    score=$((score + 25))
                    signals="${signals}Gemfile has web framework dependency;"
                fi
            fi
            ;;
    esac

    # Directory signals
    for dir in routes controllers views; do
        if [[ -d "$root/$dir" ]] || [[ -d "$root/src/$dir" ]] || [[ -d "$root/app/$dir" ]]; then
            score=$((score + 15))
            signals="${signals}${dir}/ directory exists;"
            break
        fi
    done

    # Static asset directories
    for dir in public static assets; do
        if [[ -d "$root/$dir" ]]; then
            score=$((score + 10))
            signals="${signals}${dir}/ directory exists;"
            break
        fi
    done

    # HTML template files
    local html_count=0
    html_count=$(find "$root" -maxdepth 3 -type f \( -name "*.html" -o -name "*.ejs" -o -name "*.hbs" -o -name "*.pug" -o -name "*.erb" -o -name "*.jinja2" \) -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -5 | wc -l) || true
    if [[ "$html_count" -gt 0 ]]; then
        score=$((score + 10))
        signals="${signals}HTML template files found;"
    fi

    # Server entry files
    for f in "$root/src/server.ts" "$root/src/server.js" "$root/src/app.ts" "$root/src/app.js" "$root/server.ts" "$root/server.js" "$root/app.py" "$root/manage.py" "$root/main.go"; do
        if [[ -f "$f" ]]; then
            score=$((score + 10))
            signals="${signals}${f##*/} server entry file exists;"
            break
        fi
    done

    # Cap at 100
    [[ $score -gt 100 ]] && score=100
    echo "$score"
    # Store signals for later retrieval
    _WEB_SIGNALS="$signals"
}

_score_cli_signals() {
    local lang="$1" root="$2"
    local score=0
    local signals=""

    case "$lang" in
        node|nodejs|typescript)
            if [[ -f "$root/package.json" ]]; then
                # bin field
                local has_bin
                has_bin=$(jq -r '.bin // empty' "$root/package.json" 2>/dev/null) || true
                if [[ -n "$has_bin" ]]; then
                    score=$((score + 25))
                    signals="${signals}package.json has bin field;"
                fi
                # CLI framework deps
                local deps
                deps=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$root/package.json" 2>/dev/null) || true
                for dep in commander yargs oclif inquirer vorpal meow arg; do
                    if echo "$deps" | grep -qx "$dep" 2>/dev/null; then
                        score=$((score + 20))
                        signals="${signals}package.json has ${dep} CLI framework;"
                        break
                    fi
                done
            fi
            ;;
        go)
            # cmd/ directory (Go convention)
            if [[ -d "$root/cmd" ]]; then
                score=$((score + 25))
                signals="${signals}cmd/ directory exists (Go convention);"
            fi
            if [[ -f "$root/go.mod" ]]; then
                if grep -qE '(cobra|urfave/cli|kingpin|pflag)' "$root/go.mod" 2>/dev/null; then
                    score=$((score + 20))
                    signals="${signals}go.mod has CLI framework dependency;"
                fi
            fi
            ;;
        python)
            for f in "$root/requirements.txt" "$root/pyproject.toml" "$root/setup.py" "$root/Pipfile"; do
                if [[ -f "$f" ]]; then
                    if grep -qiE '(click|typer|argparse|fire)' "$f" 2>/dev/null; then
                        score=$((score + 20))
                        signals="${signals}${f##*/} has CLI framework dependency;"
                        break
                    fi
                fi
            done
            # Entry points / console_scripts
            if [[ -f "$root/pyproject.toml" ]] && grep -q "console_scripts" "$root/pyproject.toml" 2>/dev/null; then
                score=$((score + 25))
                signals="${signals}pyproject.toml has console_scripts;"
            elif [[ -f "$root/setup.py" ]] && grep -q "console_scripts" "$root/setup.py" 2>/dev/null; then
                score=$((score + 25))
                signals="${signals}setup.py has console_scripts;"
            fi
            ;;
        rust)
            if [[ -f "$root/Cargo.toml" ]]; then
                if grep -qiE '(clap|structopt|argh)' "$root/Cargo.toml" 2>/dev/null; then
                    score=$((score + 20))
                    signals="${signals}Cargo.toml has CLI framework dependency;"
                fi
                # [[bin]] section
                if grep -q '\[\[bin\]\]' "$root/Cargo.toml" 2>/dev/null; then
                    score=$((score + 25))
                    signals="${signals}Cargo.toml has [[bin]] section;"
                fi
            fi
            ;;
        java)
            # Main class with args parsing
            local main_count=0
            main_count=$(grep -rl "public static void main" "$root/src" 2>/dev/null | head -3 | wc -l) || true
            if [[ "$main_count" -gt 0 ]]; then
                score=$((score + 15))
                signals="${signals}Java main() method found;"
            fi
            ;;
    esac

    # CLI entry files
    for f in "$root/src/cli.ts" "$root/src/cli.js" "$root/src/cli.py" "$root/cli.py"; do
        if [[ -f "$f" ]]; then
            score=$((score + 10))
            signals="${signals}${f##*/} CLI entry file exists;"
            break
        fi
    done

    # Shebang in entry files
    for f in "$root/bin/"* "$root/src/index.js" "$root/src/index.ts"; do
        if [[ -f "$f" ]] && head -1 "$f" 2>/dev/null | grep -q "^#!" 2>/dev/null; then
            score=$((score + 15))
            signals="${signals}shebang found in entry file;"
            break
        fi
    done

    [[ $score -gt 100 ]] && score=100
    echo "$score"
    _CLI_SIGNALS="$signals"
}

_score_library_signals() {
    local lang="$1" root="$2"
    local score=0
    local signals=""

    case "$lang" in
        node|nodejs|typescript)
            if [[ -f "$root/package.json" ]]; then
                # exports / main / types fields
                local has_exports has_main has_types
                has_exports=$(jq -r '.exports // empty' "$root/package.json" 2>/dev/null) || true
                has_main=$(jq -r '.main // empty' "$root/package.json" 2>/dev/null) || true
                has_types=$(jq -r '.types // .typings // empty' "$root/package.json" 2>/dev/null) || true
                if [[ -n "$has_exports" ]] || [[ -n "$has_main" ]]; then
                    score=$((score + 15))
                    signals="${signals}package.json has main/exports field;"
                fi
                if [[ -n "$has_types" ]]; then
                    score=$((score + 10))
                    signals="${signals}package.json has types/typings field;"
                fi
                # No bin field (not a CLI)
                local has_bin
                has_bin=$(jq -r '.bin // empty' "$root/package.json" 2>/dev/null) || true
                if [[ -z "$has_bin" ]]; then
                    score=$((score + 10))
                    signals="${signals}no bin field (not a CLI);"
                fi
            fi
            ;;
        python)
            if [[ -f "$root/setup.py" ]] || [[ -f "$root/pyproject.toml" ]]; then
                score=$((score + 20))
                signals="${signals}setup.py or pyproject.toml exists (distributable package);"
            fi
            if [[ -f "$root/pyproject.toml" ]] && grep -qE '(py_modules|packages)' "$root/pyproject.toml" 2>/dev/null; then
                score=$((score + 15))
                signals="${signals}pyproject.toml declares packages;"
            fi
            ;;
        rust)
            if [[ -f "$root/Cargo.toml" ]] && grep -q '\[lib\]' "$root/Cargo.toml" 2>/dev/null; then
                score=$((score + 25))
                signals="${signals}Cargo.toml has [lib] section;"
            fi
            ;;
        go)
            # Go libraries typically don't have cmd/ or main package at root
            if [[ ! -d "$root/cmd" ]] && [[ ! -f "$root/main.go" ]]; then
                score=$((score + 15))
                signals="${signals}no cmd/ or main.go (likely library);"
            fi
            ;;
        java)
            if [[ -f "$root/pom.xml" ]] && grep -q "<packaging>jar</packaging>" "$root/pom.xml" 2>/dev/null; then
                score=$((score + 20))
                signals="${signals}pom.xml packaging is jar (library);"
            fi
            ;;
        ruby)
            if ls "$root"/*.gemspec 1>/dev/null 2>&1; then
                score=$((score + 25))
                signals="${signals}gemspec found (Ruby gem library);"
            fi
            ;;
    esac

    # lib/ directory
    if [[ -d "$root/lib" ]] || [[ -f "$root/src/lib.rs" ]] || [[ -f "$root/src/lib.ts" ]] || [[ -f "$root/src/lib.js" ]]; then
        score=$((score + 15))
        signals="${signals}lib/ directory or src/lib.* file exists;"
    fi

    # README with install/usage section
    if [[ -f "$root/README.md" ]]; then
        if grep -qiE '^#{1,3}\s*(install|usage|getting started|quick start)' "$root/README.md" 2>/dev/null; then
            score=$((score + 10))
            signals="${signals}README has install/usage section;"
        fi
    fi

    # TypeScript declaration files
    local dts_count=0
    dts_count=$(find "$root" -maxdepth 3 -name "*.d.ts" -not -path "*/node_modules/*" 2>/dev/null | head -3 | wc -l) || true
    if [[ "$dts_count" -gt 0 ]]; then
        score=$((score + 10))
        signals="${signals}TypeScript declaration files found;"
    fi

    [[ $score -gt 100 ]] && score=100
    echo "$score"
    _LIB_SIGNALS="$signals"
}

_score_infrastructure_signals() {
    local lang="$1" root="$2"
    local score=0
    local signals=""

    # Terraform
    local tf_count=0
    tf_count=$(find "$root" -maxdepth 2 -name "*.tf" 2>/dev/null | head -3 | wc -l) || true
    if [[ "$tf_count" -gt 0 ]] || [[ -d "$root/terraform" ]]; then
        score=$((score + 25))
        signals="${signals}Terraform files found;"
    fi

    # Kubernetes / Helm
    if [[ -d "$root/k8s" ]] || [[ -d "$root/kubernetes" ]] || [[ -d "$root/helm" ]]; then
        score=$((score + 20))
        signals="${signals}Kubernetes/Helm directory found;"
    fi

    # CDK / Pulumi / CloudFormation
    if [[ -f "$root/cdk.json" ]] || [[ -f "$root/Pulumi.yaml" ]]; then
        score=$((score + 20))
        signals="${signals}CDK/Pulumi config found;"
    fi
    local cfn_count=0
    cfn_count=$(find "$root" -maxdepth 2 -name "*.template.json" -o -name "*.template.yaml" -o -name "cloudformation*.yml" -o -name "cloudformation*.yaml" 2>/dev/null | head -3 | wc -l) || true
    if [[ "$cfn_count" -gt 0 ]]; then
        score=$((score + 20))
        signals="${signals}CloudFormation templates found;"
    fi

    # Docker
    if [[ -f "$root/Dockerfile" ]] || [[ -f "$root/docker-compose.yml" ]] || [[ -f "$root/docker-compose.yaml" ]]; then
        score=$((score + 15))
        signals="${signals}Docker configuration found;"
    fi

    # CI/CD with deploy jobs
    if [[ -d "$root/.github/workflows" ]]; then
        local deploy_wf=0
        deploy_wf=$(grep -rlE '(deploy|release|publish)' "$root/.github/workflows/" 2>/dev/null | head -3 | wc -l) || true
        if [[ "$deploy_wf" -gt 0 ]]; then
            score=$((score + 10))
            signals="${signals}GitHub workflows with deploy jobs found;"
        fi
    fi

    # Makefile with deploy/infra targets
    if [[ -f "$root/Makefile" ]]; then
        if grep -qE '^(deploy|infra|terraform|apply|plan):' "$root/Makefile" 2>/dev/null; then
            score=$((score + 10))
            signals="${signals}Makefile has deploy/infra targets;"
        fi
    fi

    [[ $score -gt 100 ]] && score=100
    echo "$score"
    _INFRA_SIGNALS="$signals"
}

# ─── Language Detection Helper ───────────────────────────────────────────────

_detect_language() {
    local root="$1"
    if [[ -f "$root/package.json" ]]; then
        echo "node"
    elif [[ -f "$root/go.mod" ]]; then
        echo "go"
    elif [[ -f "$root/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$root/pyproject.toml" ]] || [[ -f "$root/setup.py" ]] || [[ -f "$root/requirements.txt" ]]; then
        echo "python"
    elif [[ -f "$root/pom.xml" ]] || [[ -f "$root/build.gradle" ]] || [[ -f "$root/build.gradle.kts" ]]; then
        echo "java"
    elif [[ -f "$root/Gemfile" ]]; then
        echo "ruby"
    elif ls "$root"/*.sln 1>/dev/null 2>&1 || ls "$root"/*.csproj 1>/dev/null 2>&1; then
        echo "dotnet"
    else
        echo "unknown"
    fi
}

# ─── Framework Detection ─────────────────────────────────────────────────────

_detect_framework() {
    local lang="$1" root="$2"
    case "$lang" in
        node|nodejs|typescript)
            if [[ -f "$root/package.json" ]]; then
                local deps
                deps=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$root/package.json" 2>/dev/null) || true
                if echo "$deps" | grep -qx "next" 2>/dev/null; then echo "next.js"; return; fi
                if echo "$deps" | grep -qx "nuxt" 2>/dev/null; then echo "nuxt"; return; fi
                if echo "$deps" | grep -q "@nestjs/" 2>/dev/null; then echo "nestjs"; return; fi
                if echo "$deps" | grep -qx "express" 2>/dev/null; then echo "express"; return; fi
                if echo "$deps" | grep -qx "fastify" 2>/dev/null; then echo "fastify"; return; fi
                if echo "$deps" | grep -qx "koa" 2>/dev/null; then echo "koa"; return; fi
                if echo "$deps" | grep -qx "react" 2>/dev/null; then echo "react"; return; fi
                if echo "$deps" | grep -qx "vue" 2>/dev/null; then echo "vue"; return; fi
                if echo "$deps" | grep -qx "svelte" 2>/dev/null; then echo "svelte"; return; fi
                if echo "$deps" | grep -qx "angular" 2>/dev/null || echo "$deps" | grep -q "@angular/" 2>/dev/null; then echo "angular"; return; fi
            fi
            ;;
        python)
            for f in "$root/requirements.txt" "$root/pyproject.toml" "$root/setup.py"; do
                if [[ -f "$f" ]]; then
                    if grep -qiE 'django' "$f" 2>/dev/null; then echo "django"; return; fi
                    if grep -qiE 'flask' "$f" 2>/dev/null; then echo "flask"; return; fi
                    if grep -qiE 'fastapi' "$f" 2>/dev/null; then echo "fastapi"; return; fi
                fi
            done
            ;;
        go)
            if [[ -f "$root/go.mod" ]]; then
                if grep -q "gin-gonic" "$root/go.mod" 2>/dev/null; then echo "gin"; return; fi
                if grep -q "labstack/echo" "$root/go.mod" 2>/dev/null; then echo "echo"; return; fi
                if grep -q "gofiber/fiber" "$root/go.mod" 2>/dev/null; then echo "fiber"; return; fi
            fi
            ;;
        rust)
            if [[ -f "$root/Cargo.toml" ]]; then
                if grep -qi "actix-web" "$root/Cargo.toml" 2>/dev/null; then echo "actix-web"; return; fi
                if grep -qi "rocket" "$root/Cargo.toml" 2>/dev/null; then echo "rocket"; return; fi
                if grep -qi "axum" "$root/Cargo.toml" 2>/dev/null; then echo "axum"; return; fi
            fi
            ;;
        java)
            if [[ -f "$root/pom.xml" ]] && grep -qi "spring-boot" "$root/pom.xml" 2>/dev/null; then echo "spring-boot"; return; fi
            if [[ -f "$root/build.gradle" ]] && grep -qi "spring-boot" "$root/build.gradle" 2>/dev/null; then echo "spring-boot"; return; fi
            ;;
        ruby)
            if [[ -f "$root/Gemfile" ]] && grep -qi "rails" "$root/Gemfile" 2>/dev/null; then echo "rails"; return; fi
            if [[ -f "$root/Gemfile" ]] && grep -qi "sinatra" "$root/Gemfile" 2>/dev/null; then echo "sinatra"; return; fi
            ;;
    esac
    echo "none"
}

# ─── Package Manager Detection ───────────────────────────────────────────────

_detect_pkg_manager() {
    local lang="$1" root="$2"
    case "$lang" in
        node|nodejs|typescript)
            if [[ -f "$root/pnpm-lock.yaml" ]]; then echo "pnpm"
            elif [[ -f "$root/yarn.lock" ]]; then echo "yarn"
            elif [[ -f "$root/bun.lockb" ]]; then echo "bun"
            else echo "npm"; fi
            ;;
        python) echo "pip" ;;
        rust) echo "cargo" ;;
        go) echo "go" ;;
        java)
            if [[ -f "$root/pom.xml" ]]; then echo "mvn"
            else echo "gradle"; fi
            ;;
        ruby) echo "bundler" ;;
        *) echo "unknown" ;;
    esac
}

# ─── Test Framework Detection ────────────────────────────────────────────────

_detect_test_framework() {
    local lang="$1" root="$2"
    case "$lang" in
        node|nodejs|typescript)
            if [[ -f "$root/package.json" ]]; then
                local deps
                deps=$(jq -r '(.devDependencies // {}) + (.dependencies // {}) | keys[]' "$root/package.json" 2>/dev/null) || true
                if echo "$deps" | grep -qx "vitest" 2>/dev/null; then echo "vitest"; return; fi
                if echo "$deps" | grep -qx "jest" 2>/dev/null; then echo "jest"; return; fi
                if echo "$deps" | grep -qx "mocha" 2>/dev/null; then echo "mocha"; return; fi
                if echo "$deps" | grep -qx "ava" 2>/dev/null; then echo "ava"; return; fi
            fi
            ;;
        python) echo "pytest"; return ;;
        rust) echo "cargo-test"; return ;;
        go) echo "go-test"; return ;;
        java)
            if [[ -f "$root/pom.xml" ]] && grep -qi "junit" "$root/pom.xml" 2>/dev/null; then echo "junit"; return; fi
            echo "junit"; return
            ;;
        ruby)
            if [[ -f "$root/Gemfile" ]] && grep -qi "rspec" "$root/Gemfile" 2>/dev/null; then echo "rspec"; return; fi
            echo "minitest"; return
            ;;
    esac
    echo "unknown"
}

# ─── Build Command Detection ─────────────────────────────────────────────────

_detect_build_cmd() {
    local lang="$1" root="$2"
    case "$lang" in
        node|nodejs|typescript)
            if [[ -f "$root/package.json" ]]; then
                local has_build
                has_build=$(jq -r '.scripts.build // ""' "$root/package.json" 2>/dev/null) || true
                if [[ -n "$has_build" && "$has_build" != "null" ]]; then
                    local pm
                    pm=$(_detect_pkg_manager "$lang" "$root")
                    echo "${pm} run build"
                    return
                fi
            fi
            ;;
        rust) echo "cargo build"; return ;;
        go) echo "go build ./..."; return ;;
        java)
            if [[ -f "$root/pom.xml" ]]; then echo "mvn package"; return; fi
            echo "./gradlew build"; return
            ;;
    esac
    echo ""
}

# ─── Test Command Detection ──────────────────────────────────────────────────

_detect_test_cmd() {
    local lang="$1" root="$2"
    case "$lang" in
        node|nodejs|typescript)
            if [[ -f "$root/package.json" ]]; then
                local has_test
                has_test=$(jq -r '.scripts.test // ""' "$root/package.json" 2>/dev/null) || true
                if [[ -n "$has_test" && "$has_test" != "null" && "$has_test" != *"no test specified"* ]]; then
                    local pm
                    pm=$(_detect_pkg_manager "$lang" "$root")
                    echo "${pm} test"
                    return
                fi
            fi
            ;;
        python) echo "pytest"; return ;;
        rust) echo "cargo test"; return ;;
        go) echo "go test ./..."; return ;;
        java)
            if [[ -f "$root/pom.xml" ]]; then echo "mvn test"; return; fi
            echo "./gradlew test"; return
            ;;
        ruby)
            if [[ -f "$root/Gemfile" ]] && grep -qi "rspec" "$root/Gemfile" 2>/dev/null; then
                echo "bundle exec rspec"; return
            fi
            echo "bundle exec rake test"; return
            ;;
    esac
    echo ""
}

# ─── Main Detection Function ─────────────────────────────────────────────────

detect_project_type() {
    local root="${1:-${PROJECT_ROOT:-$(pwd)}}"

    # Initialize signal storage
    _WEB_SIGNALS=""
    _CLI_SIGNALS=""
    _LIB_SIGNALS=""
    _INFRA_SIGNALS=""

    # Detect language
    local lang
    lang=$(_detect_language "$root")

    # Detect framework
    local framework
    framework=$(_detect_framework "$lang" "$root")

    # Score all project types
    local web_score cli_score lib_score infra_score
    web_score=$(_score_web_signals "$lang" "$root")
    cli_score=$(_score_cli_signals "$lang" "$root")
    lib_score=$(_score_library_signals "$lang" "$root")
    infra_score=$(_score_infrastructure_signals "$lang" "$root")

    # Find primary type (highest score)
    local primary_type="unknown"
    local primary_score=0
    local second_score=0

    # Build sorted list (bash 3.2 compatible — no associative arrays)
    local types="web cli library infrastructure"
    local scores="$web_score $cli_score $lib_score $infra_score"

    # Find max
    local i=1
    local t s
    for t in $types; do
        s=$(echo "$scores" | cut -d' ' -f"$i")
        if [[ "$s" -gt "$primary_score" ]]; then
            second_score=$primary_score
            primary_score=$s
            primary_type=$t
        elif [[ "$s" -gt "$second_score" ]]; then
            second_score=$s
        fi
        i=$((i + 1))
    done

    # Calculate confidence
    local confidence=$primary_score
    # Reduce confidence if ambiguous (small margin between top two)
    local margin=$((primary_score - second_score))
    if [[ $margin -lt 15 ]] && [[ $primary_score -gt 0 ]] && [[ $second_score -gt 0 ]]; then
        confidence=$((confidence - 15 + margin))
    fi

    # If primary score is too low, mark as unknown
    if [[ $primary_score -lt 20 ]]; then
        primary_type="unknown"
        confidence=0
    fi

    # Cap confidence
    [[ $confidence -gt 100 ]] && confidence=100
    [[ $confidence -lt 0 ]] && confidence=0

    # Collect all signals
    local all_signals="${_WEB_SIGNALS}${_CLI_SIGNALS}${_LIB_SIGNALS}${_INFRA_SIGNALS}"

    # Build signals array for JSON
    local signals_json="[]"
    if [[ -n "$all_signals" ]]; then
        signals_json=$(echo "$all_signals" | tr ';' '\n' | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || signals_json="[]"
    fi

    # Build secondary types array
    local secondary_json="[]"
    local sec_types=""
    i=1
    for t in $types; do
        s=$(echo "$scores" | cut -d' ' -f"$i")
        if [[ "$t" != "$primary_type" ]] && [[ "$s" -gt 0 ]]; then
            sec_types="${sec_types}{\"type\":\"${t}\",\"confidence\":${s}},"
        fi
        i=$((i + 1))
    done
    if [[ -n "$sec_types" ]]; then
        sec_types="${sec_types%,}"
        secondary_json="[${sec_types}]"
    fi

    # Detect remaining metadata
    local pkg_manager test_framework test_cmd build_cmd
    pkg_manager=$(_detect_pkg_manager "$lang" "$root")
    test_framework=$(_detect_test_framework "$lang" "$root")
    test_cmd=$(_detect_test_cmd "$lang" "$root")
    build_cmd=$(_detect_build_cmd "$lang" "$root")

    # Output JSON
    jq -n \
        --arg language "$lang" \
        --arg framework "$framework" \
        --arg project_type "$primary_type" \
        --argjson confidence "$confidence" \
        --argjson signals "$signals_json" \
        --arg package_manager "$pkg_manager" \
        --arg test_framework "$test_framework" \
        --arg test_cmd "$test_cmd" \
        --arg build_cmd "$build_cmd" \
        --argjson secondary_types "$secondary_json" \
        '{
            language: $language,
            framework: $framework,
            project_type: $project_type,
            confidence: $confidence,
            signals: $signals,
            package_manager: $package_manager,
            test_framework: $test_framework,
            test_cmd: $test_cmd,
            build_cmd: $build_cmd,
            secondary_types: $secondary_types
        }'
}

# ─── Template Recommendation ─────────────────────────────────────────────────

recommend_template() {
    local detection_json="${1:-}"
    if [[ -z "$detection_json" ]]; then
        detection_json=$(cat)
    fi

    local project_type confidence lang
    project_type=$(echo "$detection_json" | jq -r '.project_type // "unknown"' 2>/dev/null) || project_type="unknown"
    confidence=$(echo "$detection_json" | jq -r '.confidence // 0' 2>/dev/null) || confidence=0
    lang=$(echo "$detection_json" | jq -r '.language // "unknown"' 2>/dev/null) || lang="unknown"

    local template="standard"
    local rationale=""
    local alt_template="" alt_rationale=""
    local agents="[]"

    case "$project_type" in
        web)
            template="standard"
            rationale="${lang} web application — standard pipeline with review stage"
            alt_template="deployed"
            alt_rationale="Use deployed template if deploying to production"
            agents='["code-reviewer","test-specialist","devops-engineer"]'
            ;;
        cli)
            template="fast"
            rationale="${lang} CLI tool — fast pipeline (fewer stages needed)"
            alt_template="standard"
            alt_rationale="Use standard if CLI has complex logic requiring review"
            agents='["shell-script-specialist","test-specialist"]'
            ;;
        library)
            template="standard"
            rationale="${lang} library — standard pipeline with API surface review"
            alt_template="full"
            alt_rationale="Use full template for public/published libraries"
            agents='["code-reviewer","test-specialist"]'
            ;;
        infrastructure)
            template="full"
            rationale="Infrastructure project — full pipeline with maximum safety gates"
            alt_template="enterprise"
            alt_rationale="Use enterprise for production infrastructure changes"
            agents='["devops-engineer","security-audit"]'
            ;;
        *)
            template="standard"
            rationale="Unknown project type — standard pipeline as safe default"
            alt_template="fast"
            alt_rationale="Use fast template for simple changes"
            agents='["code-reviewer"]'
            ;;
    esac

    local daemon_config
    daemon_config=$(jq -n \
        --arg template "$template" \
        '{
            pipeline_template: $template,
            intelligence: { enabled: true },
            max_parallel: 2
        }')

    jq -n \
        --arg template "$template" \
        --argjson confidence "$confidence" \
        --arg rationale "$rationale" \
        --arg alt_template "$alt_template" \
        --arg alt_rationale "$alt_rationale" \
        --argjson daemon_config "$daemon_config" \
        --argjson recommended_agents "$agents" \
        '{
            template: $template,
            confidence: $confidence,
            rationale: $rationale,
            alternatives: [{ template: $alt_template, rationale: $alt_rationale }],
            daemon_config: $daemon_config,
            recommended_agents: $recommended_agents
        }'
}

# ─── Config Generation ───────────────────────────────────────────────────────

generate_project_config() {
    local root="${1:-${PROJECT_ROOT:-$(pwd)}}"
    local detection_json="${2:-}"

    if [[ -z "$detection_json" ]]; then
        detection_json=$(detect_project_type "$root")
    fi

    # Write detection result atomically
    local claude_dir="$root/.claude"
    if [[ ! -d "$claude_dir" ]]; then
        mkdir -p "$claude_dir" 2>/dev/null || { echo "Warning: cannot create $claude_dir" >&2; return 0; }
    fi

    local tmp_file
    tmp_file=$(mktemp "${claude_dir}/project-detection.XXXXXX") || { echo "Warning: mktemp failed" >&2; return 0; }
    echo "$detection_json" > "$tmp_file"
    mv "$tmp_file" "$claude_dir/project-detection.json" 2>/dev/null || { rm -f "$tmp_file" 2>/dev/null; echo "Warning: could not write project-detection.json" >&2; return 0; }

    # Generate and print recommendation
    local recommendation
    recommendation=$(recommend_template "$detection_json")

    echo "$recommendation"
}
