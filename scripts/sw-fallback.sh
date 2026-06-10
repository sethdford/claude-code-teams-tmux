#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-fallback.sh — Fallback Policy Migrator                               ║
# ║                                                                          ║
# ║  Audit static fallbacks, inspect the config-driven policy, resolve and   ║
# ║  validate values. Bridges into the existing sw-adaptive learning engine. ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Resolver library
# shellcheck source=lib/fallback-policy.sh
source "$SCRIPT_DIR/lib/fallback-policy.sh"

REPO_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo ".")"
POLICY_FILE="${SW_FALLBACK_POLICY_FILE:-${REPO_DIR}/config/fallback-policy.json}"
SCHEMA_FILE="${REPO_DIR}/config/fallback-policy.schema.json"

show_help() {
    cat <<EOF
USAGE
  shipwright fallback <subcommand> [options]

DESCRIPTION
  Convert static \${VAR:-default} fallbacks to a config-driven policy with
  adaptive override hooks. Resolution precedence:
    env SW_<KEY> > daemon-config .fallback_overrides > learned override
    > fallback-policy.json static > hardcoded call-site default

SUBCOMMANDS
  audit [dir]        Scan *.sh for ${VAR:-default} fallbacks; print summary
  inventory [dir]    Emit full fallback inventory as JSONL (file,line,variable,default,context)
  list               List declared policy keys with static value and bounds
  get <key> [dflt]   Resolve a policy key through the full precedence chain
  validate           Validate config/fallback-policy.json against its schema
  help               Show this help text

OPTIONS
  --help, -h         Show this help text
  --version, -v      Show version

EXAMPLES
  shipwright fallback list
  shipwright fallback get network.gh_timeout 30
  shipwright fallback inventory scripts > /tmp/fallbacks.jsonl
  shipwright fallback validate
EOF
}

cmd_inventory() {
    local dir="${1:-${REPO_DIR}/scripts}"
    _fallback_audit "$dir"
}

cmd_audit() {
    local dir="${1:-${REPO_DIR}/scripts}"
    local count
    count=$(_fallback_audit "$dir" | wc -l | tr -d ' ')
    info "Fallback audit of ${CYAN:-}${dir}${RESET:-}"
    echo "  Total \${VAR:-default} sites: ${count}"
    local declared
    declared=$(jq -r '.policies | keys | length' "$POLICY_FILE" 2>/dev/null || echo 0)
    echo "  Declared policy keys:      ${declared}"
    emit_event "fallback.audit" "sites=${count}" "declared=${declared}" 2>/dev/null || true
}

cmd_list() {
    if [[ ! -f "$POLICY_FILE" ]]; then
        error "Policy file not found: $POLICY_FILE"
        return 1
    fi
    info "Declared fallback policies (${POLICY_FILE})"
    jq -r '
        .policies | to_entries[] |
        "  \(.key)  static=\(.value.static)  range=[\(.value.adaptive_range[0]),\(.value.adaptive_range[1])]  learning=\(.value.learning_enabled)"
    ' "$POLICY_FILE" 2>/dev/null || { error "Failed to parse policy file"; return 1; }
}

cmd_get() {
    local key="${1:-}" default="${2:-}"
    if [[ -z "$key" ]]; then
        error "Usage: shipwright fallback get <key> [default]"
        return 1
    fi
    _smart_fallback "$key" "$default"
    echo
}

cmd_validate() {
    if [[ ! -f "$POLICY_FILE" ]]; then
        error "Policy file not found: $POLICY_FILE"
        return 1
    fi
    # 1. Must be valid JSON.
    if ! jq empty "$POLICY_FILE" 2>/dev/null; then
        error "Invalid JSON: $POLICY_FILE"
        return 1
    fi
    # 2. Required top-level fields.
    local version policies_count
    version=$(jq -r '.version // empty' "$POLICY_FILE" 2>/dev/null || echo "")
    policies_count=$(jq -r '.policies | length' "$POLICY_FILE" 2>/dev/null || echo 0)
    if [[ -z "$version" ]]; then
        error "Missing required field: version"
        return 1
    fi
    if [[ "$policies_count" -lt 1 ]]; then
        error "No policies declared"
        return 1
    fi
    # 3. Per-policy structural checks: required fields, range ordering, bounds.
    local bad
    bad=$(jq -r '
        .policies | to_entries[] |
        select(
            (.value.static == null) or
            (.value.learning_enabled == null) or
            ((.value.adaptive_range | type) != "array") or
            ((.value.adaptive_range | length) != 2) or
            (.value.adaptive_range[0] > .value.adaptive_range[1]) or
            (.value.static < .value.adaptive_range[0]) or
            (.value.static > .value.adaptive_range[1])
        ) | .key
    ' "$POLICY_FILE" 2>/dev/null || echo "")
    if [[ -n "$bad" ]]; then
        error "Invalid policy entries (bad bounds or missing fields):"
        echo "$bad" | sed 's/^/    /'
        return 1
    fi
    # 4. Schema presence (informational; jq has no native JSON Schema validator).
    [[ -f "$SCHEMA_FILE" ]] || warn "Schema file missing: $SCHEMA_FILE"
    success "fallback-policy.json valid — ${policies_count} policies, version ${version}"
    emit_event "fallback.validate" "policies=${policies_count}" "version=${version}" 2>/dev/null || true
}

main() {
    local cmd="${1:-help}"
    [[ $# -gt 0 ]] && shift || true
    case "$cmd" in
        audit)      cmd_audit "$@" ;;
        inventory)  cmd_inventory "$@" ;;
        list)       cmd_list "$@" ;;
        get)        cmd_get "$@" ;;
        validate)   cmd_validate "$@" ;;
        --version|-v) echo "sw-fallback v${VERSION}" ;;
        --help|-h|help) show_help ;;
        *) error "Unknown subcommand: $cmd"; echo; show_help; exit 1 ;;
    esac
}

main "$@"
