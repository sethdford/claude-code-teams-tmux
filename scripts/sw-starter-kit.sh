#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-starter-kit.sh — Community Starter Kit Generator                     ║
# ║  Framework detection → best practices → quality checks → issue templates ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Source libraries ───────────────────────────────────────────────────────
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=lib/project-detect.sh
[[ -f "$SCRIPT_DIR/lib/project-detect.sh" ]] && source "$SCRIPT_DIR/lib/project-detect.sh"
# shellcheck source=lib/starter-kit.sh
[[ -f "$SCRIPT_DIR/lib/starter-kit.sh" ]] && source "$SCRIPT_DIR/lib/starter-kit.sh"

# Fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# ─── Markers for idempotent CLAUDE.md sections ─────────────────────────────
SK_MARKER_START="<!-- sw:starter-kit-start -->"
SK_MARKER_END="<!-- sw:starter-kit-end -->"

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright starter-kit <command> [OPTIONS]

COMMANDS
  generate          Auto-detect framework and generate starter kit (default)
  issues            Generate example issue templates only
  check             Audit existing starter kit setup
  help              Show this help text

OPTIONS
  --force           Overwrite existing starter kit content
  --framework <fw>  Override auto-detection (e.g., --framework express)
  --no-issues       Skip example issue generation
  --dry-run         Show what would be generated without writing files
  --root <path>     Project root (default: current directory)
  --help, -h        Show this help text
  --version, -v     Show version

ALIASES
  shipwright sk     Same as shipwright starter-kit

EXAMPLES
  shipwright starter-kit generate              Auto-detect and generate
  shipwright sk generate --framework django    Override framework
  shipwright sk issues                         Generate issue templates only
  shipwright sk check                          Audit existing setup
  shipwright sk generate --dry-run             Preview without writing

EOF
}

# ─── Update CLAUDE.md section between markers ──────────────────────────────
_update_starter_kit_section() {
    local filepath="$1" content="$2"

    if [[ ! -f "$filepath" ]]; then
        # Create file with markers
        printf '%s\n%s\n%s\n' "$SK_MARKER_START" "$content" "$SK_MARKER_END" > "$filepath"
        return 0
    fi

    if grep -q "$SK_MARKER_START" "$filepath"; then
        # Replace content between markers
        local tmp_file="${filepath}.tmp.$$"
        local in_section=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"$SK_MARKER_START"* ]]; then
                echo "$line"
                echo "$content"
                in_section=1
            elif [[ "$line" == *"$SK_MARKER_END"* ]]; then
                echo "$line"
                in_section=0
            elif [[ "$in_section" -eq 0 ]]; then
                echo "$line"
            fi
        done < "$filepath" > "$tmp_file"
        mv "$tmp_file" "$filepath"
    else
        # Append markers + content at end of file
        printf '\n%s\n%s\n%s\n' "$SK_MARKER_START" "$content" "$SK_MARKER_END" >> "$filepath"
    fi
}

# ─── Write issue template files ────────────────────────────────────────────
_write_issue_templates() {
    local root="$1" type="$2" framework="$3" test_cmd="$4" dry_run="$5" force="$6"
    local template_dir="${root}/.github/ISSUE_TEMPLATE"
    local issues_output filename content written=0

    issues_output=$(starter_kit_example_issues "$type" "$framework" "$test_cmd" "$root")

    # Parse delimited output into files
    local current_file="" current_content=""
    local first_line=1

    while IFS= read -r line; do
        if [[ "$line" == "---SK_DELIM---" ]]; then
            if [[ -n "$current_file" ]]; then
                if [[ "$dry_run" == "true" ]]; then
                    info "Would create: $template_dir/$current_file"
                else
                    if [[ ! -f "$template_dir/$current_file" ]] || [[ "$force" == "true" ]]; then
                        mkdir -p "$template_dir"
                        local tmp_file="${template_dir}/${current_file}.tmp.$$"
                        printf '%s\n' "$current_content" > "$tmp_file"
                        mv "$tmp_file" "$template_dir/$current_file"
                        written=$((written + 1))
                    fi
                fi
            fi
            current_file=""
            current_content=""
            first_line=1
        elif [[ "$first_line" -eq 1 ]]; then
            current_file="$line"
            first_line=0
        else
            if [[ -z "$current_content" ]]; then
                current_content="$line"
            else
                current_content="${current_content}
${line}"
            fi
        fi
    done <<< "$issues_output"

    echo "$written"
}

# ─── Subcommand: generate ──────────────────────────────────────────────────
cmd_generate() {
    local root="." force="false" framework_override="" no_issues="false" dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force="true"; shift ;;
            --framework) framework_override="${2:-}"; shift 2 ;;
            --no-issues) no_issues="true"; shift ;;
            --dry-run) dry_run="true"; shift ;;
            --root) root="${2:-.}"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Ensure .claude/ exists
    if [[ ! -d "$root/.claude" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            info "Would run: shipwright prep (no .claude/ directory)"
        else
            info "No .claude/ directory found — running prep first..."
            if [[ -f "$SCRIPT_DIR/sw-prep.sh" ]]; then
                bash "$SCRIPT_DIR/sw-prep.sh" "$root" 2>/dev/null || true
            else
                mkdir -p "$root/.claude"
            fi
        fi
    fi

    # Detect project type
    local type="unknown" framework="unknown" test_cmd="" build_tool=""

    if [[ "$(type -t project_detect_type 2>/dev/null)" == "function" ]]; then
        local detection
        if detection=$(project_detect_type "$root" 2>/dev/null); then
            type=$(echo "$detection" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")
            framework=$(echo "$detection" | jq -r '.framework // "unknown"' 2>/dev/null || echo "unknown")
            build_tool=$(echo "$detection" | jq -r '.build_tool // "unknown"' 2>/dev/null || echo "unknown")
        fi

        if [[ "$(type -t project_detect_test_cmd 2>/dev/null)" == "function" ]]; then
            test_cmd=$(project_detect_test_cmd "$root" "$type" 2>/dev/null || echo "")
        fi
    fi

    # Apply framework override
    if [[ -n "$framework_override" ]]; then
        framework="$framework_override"
    fi

    info "Detected: type=$type, framework=$framework, build_tool=${build_tool:-unknown}"

    # Generate best practices
    local practices pitfalls quality_json
    practices=$(starter_kit_best_practices "$type" "$framework")
    pitfalls=$(starter_kit_pitfalls "$type" "$framework")
    quality_json=$(starter_kit_quality_checks "$type" "$framework" "$root")

    # Build CLAUDE.md content
    local sk_content
    sk_content=$(cat <<CONTENT
## Starter Kit — Framework Best Practices

**Detected Stack:** ${type}${framework:+ / $framework}

${practices}

${pitfalls}

### Quality Checks
Run these commands to verify code quality:
$(echo "$quality_json" | jq -r '.[]' 2>/dev/null | while read -r cmd; do echo "- \`$cmd\`"; done)
CONTENT
)

    # Write to CLAUDE.md
    local claude_md="$root/.claude/CLAUDE.md"
    if [[ "$dry_run" == "true" ]]; then
        info "Would update: $claude_md (starter kit section)"
        echo ""
        echo "$sk_content"
        echo ""
    else
        if [[ ! -f "$claude_md" ]] || grep -q "$SK_MARKER_START" "$claude_md" || [[ "$force" == "true" ]]; then
            _update_starter_kit_section "$claude_md" "$sk_content"
            success "Updated $claude_md with framework best practices"
        else
            # First run on existing file — append
            _update_starter_kit_section "$claude_md" "$sk_content"
            success "Added starter kit section to $claude_md"
        fi
    fi

    # Write quality checks JSON
    local quality_file="$root/.claude/quality-checks.json"
    if [[ "$dry_run" == "true" ]]; then
        info "Would write: $quality_file"
    else
        local tmp_quality="${quality_file}.tmp.$$"
        mkdir -p "$(dirname "$quality_file")"
        echo "$quality_json" | jq '.' > "$tmp_quality" 2>/dev/null || echo "$quality_json" > "$tmp_quality"
        mv "$tmp_quality" "$quality_file"
        success "Wrote quality checks to $quality_file"
    fi

    # Generate issue templates
    local issues_written=0
    if [[ "$no_issues" != "true" ]]; then
        issues_written=$(_write_issue_templates "$root" "$type" "$framework" "${test_cmd:-npm test}" "$dry_run" "$force")
        if [[ "$dry_run" != "true" ]]; then
            success "Generated $issues_written issue templates in .github/ISSUE_TEMPLATE/"
        fi
    fi

    # Emit event
    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]] && [[ "$dry_run" != "true" ]]; then
        emit_event "starter_kit.generated" "type=$type" "framework=$framework" "issues=$issues_written"
    fi

    # Summary
    echo ""
    info "Starter Kit Summary:"
    echo "  Type:       $type"
    echo "  Framework:  $framework"
    echo "  CLAUDE.md:  updated with best practices & pitfalls"
    echo "  Quality:    $quality_file"
    if [[ "$no_issues" != "true" ]]; then
        echo "  Issues:     ${issues_written:-0} templates in .github/ISSUE_TEMPLATE/"
    fi
    if [[ "$dry_run" == "true" ]]; then
        echo ""
        warn "Dry run — no files were written"
    fi
}

# ─── Subcommand: issues ────────────────────────────────────────────────────
cmd_issues() {
    local root="." force="false" dry_run="false" framework_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force="true"; shift ;;
            --framework) framework_override="${2:-}"; shift 2 ;;
            --dry-run) dry_run="true"; shift ;;
            --root) root="${2:-.}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local type="unknown" framework="unknown" test_cmd=""

    if [[ "$(type -t project_detect_type 2>/dev/null)" == "function" ]]; then
        local detection
        if detection=$(project_detect_type "$root" 2>/dev/null); then
            type=$(echo "$detection" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")
            framework=$(echo "$detection" | jq -r '.framework // "unknown"' 2>/dev/null || echo "unknown")
        fi
        if [[ "$(type -t project_detect_test_cmd 2>/dev/null)" == "function" ]]; then
            test_cmd=$(project_detect_test_cmd "$root" "$type" 2>/dev/null || echo "")
        fi
    fi

    if [[ -n "$framework_override" ]]; then
        framework="$framework_override"
    fi

    info "Generating issue templates for $type / $framework..."
    local written
    written=$(_write_issue_templates "$root" "$type" "$framework" "${test_cmd:-npm test}" "$dry_run" "$force")

    if [[ "$dry_run" != "true" ]]; then
        success "Generated $written issue templates in .github/ISSUE_TEMPLATE/"
    else
        warn "Dry run — no files were written"
    fi
}

# ─── Subcommand: check ─────────────────────────────────────────────────────
cmd_check() {
    local root="."
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root) root="${2:-.}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local score=0 total=0 gaps=""

    # Check CLAUDE.md exists
    ((total++))
    if [[ -f "$root/.claude/CLAUDE.md" ]]; then
        ((score++))
        success "CLAUDE.md exists"
    else
        gaps="${gaps}\n  - Missing .claude/CLAUDE.md"
        warn "Missing .claude/CLAUDE.md"
    fi

    # Check starter kit section in CLAUDE.md
    ((total++))
    if [[ -f "$root/.claude/CLAUDE.md" ]] && grep -q "$SK_MARKER_START" "$root/.claude/CLAUDE.md"; then
        ((score++))
        success "Starter kit section present in CLAUDE.md"
    else
        gaps="${gaps}\n  - No starter kit section in CLAUDE.md"
        warn "No starter kit section in CLAUDE.md — run 'shipwright sk generate'"
    fi

    # Check quality checks
    ((total++))
    if [[ -f "$root/.claude/quality-checks.json" ]]; then
        ((score++))
        success "Quality checks configured"
    else
        gaps="${gaps}\n  - Missing .claude/quality-checks.json"
        warn "Missing quality checks — run 'shipwright sk generate'"
    fi

    # Check issue templates
    ((total++))
    local template_count=0
    if [[ -d "$root/.github/ISSUE_TEMPLATE" ]]; then
        template_count=$(find "$root/.github/ISSUE_TEMPLATE" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [[ "$template_count" -ge 3 ]]; then
        ((score++))
        success "Issue templates present ($template_count found)"
    else
        gaps="${gaps}\n  - Fewer than 3 issue templates (found $template_count)"
        warn "Fewer than 3 issue templates — run 'shipwright sk issues'"
    fi

    # Check project detection
    ((total++))
    if [[ -f "$root/.claude/project-detection.json" ]]; then
        ((score++))
        success "Project detection cached"
    else
        gaps="${gaps}\n  - No cached project detection"
        warn "No cached project detection — run 'shipwright prep' or 'shipwright sk generate'"
    fi

    # Summary
    echo ""
    info "Starter Kit Score: $score/$total"

    if [[ "$score" -eq "$total" ]]; then
        success "Starter kit is fully configured!"
        return 0
    else
        echo -e "  Gaps:$gaps"
        return 2
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-generate}"

    case "$cmd" in
        --help|-h|help)
            show_help
            exit 0
            ;;
        --version|-v)
            echo "$VERSION"
            exit 0
            ;;
        generate)
            shift
            cmd_generate "$@"
            ;;
        issues)
            shift
            cmd_issues "$@"
            ;;
        check)
            shift
            cmd_check "$@" || exit $?
            ;;
        *)
            # Treat unknown as generate with flags
            cmd_generate "$@"
            ;;
    esac
}

main "$@"
