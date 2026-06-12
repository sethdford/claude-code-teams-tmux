#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/dependency-preflight — Pre-flight dependency check engine  ║
# ║  Detect manifests, check installed status, auto-install missing deps      ║
# ║  before the build loop runs. Best-effort & non-fatal by contract.         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Runs BEFORE the build loop (`sw loop`) inside stage_build(). Detects package
# manifests (Node/Python/Go/Ruby/Java), checks whether deps are installed, and
# auto-installs missing ones with the correct package manager.
#
# Contract: dep_preflight_run ALWAYS returns 0 — a failed/slow install must
# never abort the pipeline (the build loop is the safety net). Installs are
# wrapped in `timeout` and `( cd … )` subshells.
#
# Provides:
#   dep_detect_manifests(root)        — emits "manager<TAB>abs_manifest_path" lines
#   dep_manager_available(manager)    — 0 if package-manager binary present
#   dep_is_installed(manager, dir)    — 0 installed, 1 missing (fast heuristic)
#   dep_install(manager, dir)         — 0 success, 1 failure (non-fatal)
#   dep_preflight_run(root)           — orchestrator; always returns 0

[[ -n "${_DEPENDENCY_PREFLIGHT_LOADED:-}" ]] && return 0
_DEPENDENCY_PREFLIGHT_LOADED=1

VERSION="3.3.0"

# ─── Defensive sourcing of dependencies ──────────────────────────────────────
# These provide warn()/info()/emit_event()/atomic_write()/now_epoch(). When the
# engine is loaded standalone (e.g. unit tests), source them from the same dir.
_DEP_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! type emit_event >/dev/null 2>&1; then
    [[ -f "$_DEP_PREFLIGHT_DIR/helpers.sh" ]] && source "$_DEP_PREFLIGHT_DIR/helpers.sh" 2>/dev/null || true
fi
if ! type _smart_bool >/dev/null 2>&1; then
    [[ -f "$_DEP_PREFLIGHT_DIR/compat.sh" ]] && source "$_DEP_PREFLIGHT_DIR/compat.sh" 2>/dev/null || true
fi

# Fallback no-op shims so the module never crashes if helpers are absent.
type info  >/dev/null 2>&1 || info()  { echo "  $*"; }
type warn  >/dev/null 2>&1 || warn()  { echo "  ⚠ $*" >&2; }
type emit_event >/dev/null 2>&1 || emit_event() { :; }
type now_epoch  >/dev/null 2>&1 || now_epoch() { date +%s; }

# Manifest filename → package-manager mapping (bash 3.2: no associative arrays).
# _dep_manager_for_manifest <filename>
_dep_manager_for_manifest() {
    case "$1" in
        package.json)     echo "npm" ;;
        requirements.txt) echo "pip" ;;
        go.mod)           echo "go" ;;
        Gemfile)          echo "bundle" ;;
        pom.xml)          echo "maven" ;;
        *)                echo "" ;;
    esac
}

# ─── dep_detect_manifests(root) ───────────────────────────────────────────────
# Emit "manager<TAB>abs_manifest_path" lines for every supported manifest found
# up to a bounded depth. Excludes installed dependency trees (node_modules,
# vendor) so monorepos don't rescan installed packages.
dep_detect_manifests() {
    local root="${1:-.}"
    [[ -d "$root" ]] || return 0

    local max_depth="${SW_DEPS_MAX_DEPTH:-3}"
    [[ "$max_depth" =~ ^[0-9]+$ ]] || max_depth=3

    local manifest mgr base
    while IFS= read -r manifest; do
        [[ -z "$manifest" ]] && continue
        base="$(basename "$manifest")"
        mgr="$(_dep_manager_for_manifest "$base")"
        [[ -z "$mgr" ]] && continue
        printf '%s\t%s\n' "$mgr" "$manifest"
    done < <(
        find "$root" -maxdepth "$max_depth" \
            \( -name node_modules -o -name vendor -o -name .git \) -prune -o \
            -type f \( -name package.json -o -name requirements.txt \
                -o -name go.mod -o -name Gemfile -o -name pom.xml \) -print \
            2>/dev/null
    )
}

# ─── dep_manager_available(manager) ───────────────────────────────────────────
# 0 if the package-manager binary is present and runnable, else 1.
dep_manager_available() {
    local mgr="$1"
    case "$mgr" in
        npm)    command -v npm    >/dev/null 2>&1 ;;
        pip)    command -v pip    >/dev/null 2>&1 || command -v pip3 >/dev/null 2>&1 ;;
        go)     command -v go     >/dev/null 2>&1 ;;
        bundle) command -v bundle >/dev/null 2>&1 ;;
        maven)  command -v mvn    >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# ─── dep_is_installed(manager, manifest_dir) ──────────────────────────────────
# Fast, no-network heuristic: are deps already present? 0 installed, 1 missing.
dep_is_installed() {
    local mgr="$1" dir="$2"
    case "$mgr" in
        npm)
            [[ -d "$dir/node_modules" ]]
            ;;
        pip)
            # Installed only when an in-project virtualenv exists; a global
            # interpreter is ambiguous, so treat as missing to be safe.
            [[ -d "$dir/.venv" || -d "$dir/venv" ]]
            ;;
        go)
            # go.sum present AND module cache verifies cheaply.
            [[ -f "$dir/go.sum" ]] && ( cd "$dir" && go mod verify >/dev/null 2>&1 )
            ;;
        bundle)
            ( cd "$dir" && bundle check >/dev/null 2>&1 )
            ;;
        maven)
            [[ -d "$dir/target" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# ─── dep_install(manager, manifest_dir) ───────────────────────────────────────
# Install dependencies deterministically from lockfiles where possible.
# Wrapped in `timeout` + `( cd … )`. Returns 0 success, 1 failure (non-fatal).
dep_install() {
    local mgr="$1" dir="$2"
    local timeout_s="${SW_DEPS_TIMEOUT:-300}"
    [[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=300

    # Resolve a timeout wrapper (gtimeout on macOS); degrade to no wrapper.
    local timeout_bin=""
    if command -v timeout >/dev/null 2>&1; then
        timeout_bin="timeout ${timeout_s}s"
    elif command -v gtimeout >/dev/null 2>&1; then
        timeout_bin="gtimeout ${timeout_s}s"
    fi

    case "$mgr" in
        npm)
            if [[ -f "$dir/package-lock.json" ]]; then
                ( cd "$dir" && $timeout_bin npm ci >/dev/null 2>&1 ) && return 0
            fi
            ( cd "$dir" && $timeout_bin npm install >/dev/null 2>&1 )
            ;;
        pip)
            local pip_bin="pip"
            command -v pip >/dev/null 2>&1 || pip_bin="pip3"
            ( cd "$dir" && $timeout_bin "$pip_bin" install -r requirements.txt >/dev/null 2>&1 )
            ;;
        go)
            ( cd "$dir" && $timeout_bin go mod download >/dev/null 2>&1 )
            ;;
        bundle)
            ( cd "$dir" && $timeout_bin bundle install >/dev/null 2>&1 )
            ;;
        maven)
            ( cd "$dir" && $timeout_bin mvn -q -DskipTests dependency:resolve >/dev/null 2>&1 )
            ;;
        *)
            return 1
            ;;
    esac
}

# Count declared dependencies for observability (best-effort, 0 on any failure).
_dep_count() {
    local mgr="$1" dir="$2"
    case "$mgr" in
        npm)
            command -v jq >/dev/null 2>&1 || { echo 0; return; }
            jq -r '((.dependencies // {}) + (.devDependencies // {})) | length' \
                "$dir/package.json" 2>/dev/null || echo 0
            ;;
        pip)
            grep -cE '^[[:space:]]*[^#[:space:]]' "$dir/requirements.txt" 2>/dev/null || echo 0
            ;;
        *)
            echo 0
            ;;
    esac
}

# ─── dep_preflight_run(root) ──────────────────────────────────────────────────
# Orchestrator. Config-gated, best-effort, ALWAYS returns 0.
# Exports SW_DEPS_PREINSTALLED=1 when nothing needed installing, else 0.
dep_preflight_run() {
    local root="${1:-.}"
    export SW_DEPS_PREINSTALLED=1

    # Config gate (env → daemon-config.json → default true).
    local enabled="true"
    if type _smart_bool >/dev/null 2>&1; then
        enabled="$(_smart_bool dependency_preflight.auto_install true)"
    fi
    if [[ "$enabled" != "true" ]]; then
        emit_event "dependencies.installed" "manager=none" "count=0" "duration_ms=0" "status=disabled"
        return 0
    fi

    local manifests
    manifests="$(dep_detect_manifests "$root")"
    if [[ -z "$manifests" ]]; then
        return 0
    fi

    local mgr manifest dir start_e end_e dur_ms count
    while IFS=$'\t' read -r mgr manifest; do
        [[ -z "$mgr" ]] && continue
        dir="$(dirname "$manifest")"

        if ! dep_manager_available "$mgr"; then
            warn "dependency-preflight: $mgr not available — skipping $manifest"
            emit_event "dependencies.installed" "manager=$mgr" "count=0" \
                "duration_ms=0" "status=skipped" "reason=manager_missing"
            continue
        fi

        if dep_is_installed "$mgr" "$dir"; then
            emit_event "dependencies.installed" "manager=$mgr" "count=0" \
                "duration_ms=0" "status=present"
            continue
        fi

        # Missing deps → attempt install.
        SW_DEPS_PREINSTALLED=0
        count="$(_dep_count "$mgr" "$dir")"
        info "dependency-preflight: installing $mgr dependencies ($count) in $dir"
        start_e="$(now_epoch)"
        if dep_install "$mgr" "$dir"; then
            end_e="$(now_epoch)"
            dur_ms=$(( (end_e - start_e) * 1000 ))
            emit_event "dependencies.installed" "manager=$mgr" "count=$count" \
                "duration_ms=$dur_ms" "status=success"
        else
            end_e="$(now_epoch)"
            dur_ms=$(( (end_e - start_e) * 1000 ))
            warn "dependency-preflight: $mgr install failed in $dir (non-fatal — build loop will retry)"
            emit_event "dependencies.installed" "manager=$mgr" "count=$count" \
                "duration_ms=$dur_ms" "status=failed"
        fi
    done <<< "$manifests"

    export SW_DEPS_PREINSTALLED

    # Advisory marker for the build loop (best-effort).
    if [[ -n "${ARTIFACTS_DIR:-}" ]] && type atomic_write >/dev/null 2>&1; then
        local marker="${ARTIFACTS_DIR}/dep-preflight.json"
        local marker_json
        if command -v jq >/dev/null 2>&1; then
            marker_json="$(jq -n --arg pre "$SW_DEPS_PREINSTALLED" \
                '{preinstalled: ($pre == "1")}' 2>/dev/null || echo "{\"preinstalled\":false}")"
        else
            marker_json="{\"preinstalled\":$([[ "$SW_DEPS_PREINSTALLED" == "1" ]] && echo true || echo false)}"
        fi
        mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
        atomic_write "$marker" "$marker_json" 2>/dev/null || true
    fi

    return 0
}
