#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-template-validate.sh — Pipeline Template Schema Validator            ║
# ║                                                                          ║
# ║  Validates pipeline template JSON files against the schema before        ║
# ║  execution. Catches misconfigurations early with clear error messages.   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# shellcheck source=lib/pipeline-validation.sh
source "$SCRIPT_DIR/lib/pipeline-validation.sh"

# ─── Help text ────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright template validate <file|name> [OPTIONS]
  shipwright template validate --all

DESCRIPTION
  Validates pipeline template JSON against the schema. Reports all errors
  at once so you can fix everything in a single pass.

  Checks:
    • Required fields (name, description, defaults, stages)
    • Valid stage IDs (intake, plan, design, build, test, etc.)
    • Valid gate values (auto, approve)
    • Boolean/numeric type constraints
    • Stage ordering (intake→build→test→pr, etc.)
    • No duplicate stage IDs
    • Positive numeric config values

ARGUMENTS
  <file>        Path to a pipeline template JSON file
  <name>        Template name (e.g., "standard", "fast") — searches known locations

OPTIONS
  --all         Validate all built-in templates
  --quiet, -q   Suppress output on success
  --help, -h    Show this help text
  --version, -v Show version

EXAMPLES
  shipwright template validate standard
  shipwright template validate templates/pipelines/custom.json
  shipwright template validate --all

EXIT CODES
  0  All templates valid
  1  Validation errors found

EOF
}

# ─── Find template by name ────────────────────────────────────────────────
find_template() {
    local name="$1"
    local repo_dir
    repo_dir="$(cd "$SCRIPT_DIR/.." && pwd)"

    local locations=(
        "$repo_dir/templates/pipelines/${name}.json"
        "$HOME/.shipwright/pipelines/${name}.json"
    )
    for loc in "${locations[@]}"; do
        if [[ -f "$loc" ]]; then
            echo "$loc"
            return 0
        fi
    done
    return 1
}

# ─── Validate a single template ──────────────────────────────────────────
validate_one() {
    local target="$1"
    local quiet="${2:-false}"
    local file=""

    # If it's a file path, use directly; otherwise look up by name
    if [[ -f "$target" ]]; then
        file="$target"
    else
        file=$(find_template "$target") || {
            error "Template not found: $target"
            return 1
        }
    fi

    if validate_pipeline_template "$file"; then
        [[ "$quiet" != "true" ]] && success "Valid: $(basename "$file")"
        return 0
    else
        return 1
    fi
}

# ─── Validate all built-in templates ──────────────────────────────────────
validate_all() {
    local quiet="${1:-false}"
    local repo_dir
    repo_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    local template_dir="$repo_dir/templates/pipelines"

    if [[ ! -d "$template_dir" ]]; then
        error "Template directory not found: $template_dir"
        return 1
    fi

    local total=0
    local passed=0
    local failed=0

    for f in "$template_dir"/*.json; do
        [[ ! -f "$f" ]] && continue
        total=$((total + 1))
        if validate_pipeline_template "$f"; then
            passed=$((passed + 1))
            [[ "$quiet" != "true" ]] && success "Valid: $(basename "$f")"
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    if [[ "$failed" -eq 0 ]]; then
        success "All $total templates valid"
        return 0
    else
        error "$failed/$total templates failed validation"
        return 1
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────
main() {
    local quiet=false
    local all=false
    local targets=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                echo "$VERSION"
                exit 0
                ;;
            --quiet|-q)
                quiet=true
                shift
                ;;
            --all)
                all=true
                shift
                ;;
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                targets+=("$1")
                shift
                ;;
        esac
    done

    if [[ "$all" == "true" ]]; then
        validate_all "$quiet"
        exit $?
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        error "No template specified. Use --all or provide a template name/path."
        echo ""
        show_help
        exit 1
    fi

    local exit_code=0
    for target in "${targets[@]}"; do
        validate_one "$target" "$quiet" || exit_code=1
    done
    exit $exit_code
}

main "$@"
