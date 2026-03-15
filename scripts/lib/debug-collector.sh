#!/usr/bin/env bash
# Module: debug-collector
# Pipeline Failure Debug Artifact Auto-Collector
# Collects debug artifacts (logs, git state, environment, errors) into structured bundles
# when a pipeline stage fails, enabling faster failure diagnosis without manual artifact hunting.
#
set -euo pipefail

VERSION="2.0.0"

# ─── Module guard ─────────────────────────────────────────────────────
[[ -n "${_MODULE_DEBUG_COLLECTOR_LOADED:-}" ]] && return 0
_MODULE_DEBUG_COLLECTOR_LOADED=1

# ─── Defaults (needed if sourced independently) ────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/pipeline-state.md}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$STATE_DIR/pipeline-artifacts}"
EVENTS_FILE="${EVENTS_FILE:-$HOME/.shipwright/events.jsonl}"

# Global error context (set by pipeline-state.sh before calling collect_debug_bundle)
LAST_STAGE_ERROR="${LAST_STAGE_ERROR:-}"
LAST_STAGE_ERROR_CLASS="${LAST_STAGE_ERROR_CLASS:-}"

# ─── Ensure helpers are loaded ───────────────────────────────────────
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
[[ "$(type -t info 2>/dev/null)" == "function" ]] || info() { echo "$*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]] || warn() { echo "$*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]] || error() { echo "$*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }
[[ "$(type -t now_iso 2>/dev/null)" == "function" ]] || now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
[[ "$(type -t now_epoch 2>/dev/null)" == "function" ]] || now_epoch() { date +%s; }

# ═════════════════════════════════════════════════════════════════════════════
# collect_debug_bundle(stage_id) → string | ""
#
# Collect debug artifacts for a failed stage into a structured bundle.
#
# Input:
#   stage_id — Stage identifier (e.g., "build", "test")
#
# Output:
#   Bundle directory path (e.g., "/path/artifacts/debug-bundles/build-1710489600-12345/")
#   Empty string "" if collection fails (silently caught by caller)
#
# Artifacts Created:
#   - stage.log (last 500 lines of stage output)
#   - error-classification.json { stage, classification, canonical, error_snippet, timestamp }
#   - environment.json { bash_version, os, pwd, node_version, git_version, env_filtered }
#   - git-state.json { branch, sha, dirty_files, recent_commits_5, diff_stat }
#   - pipeline-state.md (copy of $STATE_FILE)
#   - recent-events.jsonl (last 20 lines of ~/.shipwright/events.jsonl)
#   - error-log-tail.jsonl (last 10 entries of $ARTIFACTS_DIR/error-log.jsonl)
#   - manifest.json { file_count, total_size_bytes, files: [{ name, size_bytes, sha256 }] }
#
# Error Handling:
#   All individual artifact collection wrapped in || true. Missing artifacts tolerated.
#   Returns "" on critical failure (dir creation or manifest write).
#
collect_debug_bundle() {
    local stage_id="${1:-}"
    [[ -z "$stage_id" ]] && return 1

    # Create bundle directory with epoch timestamp + PID (unique per invocation)
    local epoch
    epoch=$(now_epoch 2>/dev/null) || epoch=$(date +%s 2>/dev/null) || epoch="0"
    [[ -z "$epoch" ]] && epoch="0"
    local bundle_dir="${ARTIFACTS_DIR}/debug-bundles/${stage_id}-${epoch}-$$"

    # Clean up on error: ensure bundle dir is removed if we bail out
    _cleanup_bundle() {
        [[ -d "$bundle_dir" ]] && rm -rf "$bundle_dir" 2>/dev/null || true
    }
    trap _cleanup_bundle ERR

    # Create bundle directory
    mkdir -p "$bundle_dir" 2>/dev/null || { _cleanup_bundle; return 1; }

    # 1. Collect stage log (last 500 lines of stage output)
    _collect_stage_log "$stage_id" "$bundle_dir" || true

    # 2. Collect error classification
    _collect_error_classification "$bundle_dir" || true

    # 3. Collect environment snapshot (with secret filtering)
    _collect_environment "$bundle_dir" || true

    # 4. Collect git state (branch, SHA, dirty files, recent commits)
    _collect_git_state "$bundle_dir" || true

    # 5. Copy pipeline state at failure time
    _collect_pipeline_state "$bundle_dir" || true

    # 6. Collect recent events (last 20 lines of events.jsonl)
    _collect_recent_events "$bundle_dir" || true

    # 7. Collect error log tail (last 10 entries of error-log.jsonl)
    _collect_error_log_tail "$bundle_dir" || true

    # 8. Create manifest with checksums
    if ! _create_manifest "$bundle_dir"; then
        _cleanup_bundle
        return 1
    fi

    # Rotate old bundles (keep last 10)
    rotate_debug_bundles 10 || true

    # Emit observability event
    emit_event "debug.bundle_created" \
        "stage=$stage_id" \
        "bundle_path=$bundle_dir" \
        "timestamp=$(now_iso)" \
        2>/dev/null || true

    # Return bundle path (only if directory was successfully created)
    if [[ -d "$bundle_dir" ]]; then
        echo "$bundle_dir"
        return 0
    else
        return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# rotate_debug_bundles([max_bundles]) → void
#
# Remove old debug bundles, keeping only the most recent N.
#
rotate_debug_bundles() {
    local max_bundles="${1:-10}"
    local bundles_dir="${ARTIFACTS_DIR}/debug-bundles"

    [[ ! -d "$bundles_dir" ]] && return 0

    # List all bundle directories, sorted by name (contains epoch timestamp)
    local bundle_list
    bundle_list=$(find "$bundles_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2)

    local count=0
    while IFS= read -r bundle_dir; do
        [[ -z "$bundle_dir" ]] && continue
        count=$((count + 1))
        if [[ "$count" -gt "$max_bundles" ]]; then
            rm -rf "$bundle_dir" 2>/dev/null || true
        fi
    done <<< "$bundle_list"
}

# ═════════════════════════════════════════════════════════════════════════════
# list_debug_bundles() → void (outputs JSONL to stdout)
#
# List all debug bundles in a structured format.
#
# Output: JSONL stream of bundle entries
#
list_debug_bundles() {
    local bundles_dir="${ARTIFACTS_DIR}/debug-bundles"

    [[ ! -d "$bundles_dir" ]] && return 0

    # Find all bundle directories and emit JSONL
    find "$bundles_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r bundle_dir; do
        local manifest_file="${bundle_dir}/manifest.json"
        if [[ -f "$manifest_file" ]]; then
            local stage_id
            stage_id=$(basename "$bundle_dir" | cut -d'-' -f1)
            local total_size
            total_size=$(jq -r '.total_size_bytes // 0' "$manifest_file" 2>/dev/null || echo "0")
            local timestamp
            # Extract timestamp from bundle name: stage-epoch-pid → epoch is second component
            timestamp=$(basename "$bundle_dir" | cut -d'-' -f2)
            timestamp=$(date -u -d "@$timestamp" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

            # Output JSONL entry
            printf '{"stage":"%s","timestamp":"%s","size_bytes":%s,"path":"%s"}\n' \
                "$stage_id" "$timestamp" "$total_size" "$bundle_dir"
        fi
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# show_debug_bundle(bundle_path) → void (outputs formatted text to stdout)
#
# Display the contents of a debug bundle in human-readable format.
#
show_debug_bundle() {
    local bundle_path="${1:-}"
    [[ -z "$bundle_path" ]] && { error "Usage: show_debug_bundle <bundle-path>"; return 1; }
    [[ ! -d "$bundle_path" ]] && { error "Bundle not found: $bundle_path"; return 1; }

    local manifest_file="${bundle_path}/manifest.json"
    [[ ! -f "$manifest_file" ]] && { error "No manifest found in bundle"; return 1; }

    # Print header
    echo "═══════════════════════════════════════════════════════════════"
    echo "Debug Bundle: $(basename "$bundle_path")"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Print manifest summary
    echo "Manifest:"
    jq -r '.file_count as $fc | .total_size_bytes as $size |
        "  Files: \($fc)\n  Total Size: \($size) bytes"' "$manifest_file" 2>/dev/null || true
    echo ""

    # Print error classification if available
    local error_class_file="${bundle_path}/error-classification.json"
    if [[ -f "$error_class_file" ]]; then
        echo "Error Classification:"
        jq -r '"  Stage: \(.stage)\n  Classification: \(.classification)\n  Canonical: \(.canonical)"' \
            "$error_class_file" 2>/dev/null || true
        echo ""
    fi

    # Print git state if available
    local git_state_file="${bundle_path}/git-state.json"
    if [[ -f "$git_state_file" ]]; then
        echo "Git State:"
        jq -r '"  Branch: \(.branch)\n  SHA: \(.sha)\n  Dirty: \(.dirty_files | length)"' \
            "$git_state_file" 2>/dev/null || true
        echo ""
    fi

    # List all files in bundle
    echo "Contents:"
    ls -lh "$bundle_path" | tail -n +2 | awk '{printf "  %-30s %8s\n", $9, $5}'
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# export_debug_bundle(bundle_path, [output_file]) → void
#
# Create a tar.gz archive of a debug bundle for sharing.
#
export_debug_bundle() {
    local bundle_path="${1:-}"
    local output_file="${2:-./${bundle_path##*/}.tar.gz}"

    [[ -z "$bundle_path" ]] && { error "Usage: export_debug_bundle <bundle-path> [output-file]"; return 1; }
    [[ ! -d "$bundle_path" ]] && { error "Bundle not found: $bundle_path"; return 1; }

    # Create tar.gz with atomic write pattern
    local tmp_file="${output_file}.tmp.$$"
    if tar -czf "$tmp_file" -C "$(dirname "$bundle_path")" "$(basename "$bundle_path")" 2>/dev/null; then
        mv "$tmp_file" "$output_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
        success "Exported bundle to: $output_file"
        ls -lh "$output_file"
    else
        rm -f "$tmp_file"
        error "Failed to export bundle"
        return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# PRIVATE HELPER FUNCTIONS
# ═════════════════════════════════════════════════════════════════════════════

# Collect stage log (last 500 lines)
_collect_stage_log() {
    local stage_id="$1"
    local bundle_dir="$2"

    local log_file="${ARTIFACTS_DIR}/${stage_id}-results.log"
    [[ ! -f "$log_file" ]] && log_file="${ARTIFACTS_DIR}/test-results.log"
    [[ ! -f "$log_file" ]] && return 1

    # Copy last 500 lines to bundle
    tail -500 "$log_file" > "${bundle_dir}/stage.log" 2>/dev/null || return 1
}

# Collect error classification
_collect_error_classification() {
    local bundle_dir="$1"

    # Build JSON from globals set by pipeline-state.sh
    local json_file="${bundle_dir}/error-classification.json"
    local tmp_file="${json_file}.tmp.$$"

    {
        printf '{'
        printf '"stage":"%s",' "${CURRENT_STAGE_ID:-unknown}"
        printf '"classification":"%s",' "${LAST_STAGE_ERROR_CLASS:-unknown}"
        printf '"canonical":"%s",' "${LAST_STAGE_ERROR_CLASS:-unknown}"
        printf '"error_snippet":"%s",' "$(printf '%s' "${LAST_STAGE_ERROR:-}" | sed 's/"/\\"/g' | head -c 200)"
        printf '"timestamp":"%s"' "$(now_iso)"
        printf '}\n'
    } > "$tmp_file" 2>/dev/null || return 1
    mv "$tmp_file" "$json_file" 2>/dev/null || return 1
}

# Collect environment snapshot (with secret filtering)
_collect_environment() {
    local bundle_dir="$1"
    local json_file="${bundle_dir}/environment.json"
    local tmp_file="${json_file}.tmp.$$"

    {
        printf '{'
        printf '"bash_version":"%s",' "${BASH_VERSION:-}"
        printf '"os":"%s",' "$(uname -s)"
        printf '"pwd":"%s",' "$PWD"
        printf '"node_version":"%s",' "$(node -v 2>/dev/null || echo 'N/A')"
        printf '"git_version":"%s",' "$(git --version 2>/dev/null | cut -d' ' -f3 || echo 'N/A')"
        printf '"env_filtered":{'

        # Filter environment variables: skip TOKEN, SECRET, KEY, PASSWORD, CREDENTIAL, AUTH
        local first=1
        env | grep -v -iE "TOKEN|SECRET|KEY|PASSWORD|CREDENTIAL|AUTH" | while IFS='=' read -r key val; do
            [[ -z "$key" ]] && continue
            if [[ "$first" -eq 0 ]]; then
                printf ','
            fi
            first=0
            val=$(printf '%s' "$val" | sed 's/"/\\"/g' | head -c 100)
            printf '"%s":"%s"' "$key" "$val"
        done || true
        printf '}'
        printf '}\n'
    } > "$tmp_file" 2>/dev/null || return 1
    mv "$tmp_file" "$json_file" 2>/dev/null || return 1
}

# Collect git state (branch, SHA, dirty files, recent commits)
_collect_git_state() {
    local bundle_dir="$1"
    local json_file="${bundle_dir}/git-state.json"
    local tmp_file="${json_file}.tmp.$$"

    # Use timeout to prevent hangs on large repos
    {
        printf '{'
        printf '"branch":"%s",' "$(timeout 5 git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's/"/\\"/g' || echo 'unknown')"
        printf '"sha":"%s",' "$(timeout 5 git rev-parse HEAD 2>/dev/null | head -c 12 || echo 'unknown')"
        printf '"dirty_files":['
        timeout 5 git status --porcelain 2>/dev/null | head -20 | sed 's/^/  "/' | sed 's/$/",/' | tr '\n' ' ' || true
        printf '],'
        printf '"recent_commits_5":['
        timeout 5 git log --oneline -5 2>/dev/null | sed 's/^/  "/' | sed 's/$/",/' | tr '\n' ' ' || true
        printf '],'
        printf '"diff_stat":"%s"' "$(timeout 5 git diff --stat 2>/dev/null | head -10 | wc -l || echo '0')"
        printf '}\n'
    } > "$tmp_file" 2>/dev/null || return 1
    mv "$tmp_file" "$json_file" 2>/dev/null || return 1
}

# Copy pipeline state at failure time
_collect_pipeline_state() {
    local bundle_dir="$1"

    [[ ! -f "$STATE_FILE" ]] && return 1
    cp "$STATE_FILE" "${bundle_dir}/pipeline-state.md" 2>/dev/null || return 1
}

# Collect recent events (last 20 lines of events.jsonl)
_collect_recent_events() {
    local bundle_dir="$1"

    [[ ! -f "$EVENTS_FILE" ]] && return 0

    tail -20 "$EVENTS_FILE" > "${bundle_dir}/recent-events.jsonl" 2>/dev/null || return 1
}

# Collect error log tail (last 10 entries of error-log.jsonl)
_collect_error_log_tail() {
    local bundle_dir="$1"
    local error_log="${ARTIFACTS_DIR}/error-log.jsonl"

    [[ ! -f "$error_log" ]] && return 0

    tail -10 "$error_log" > "${bundle_dir}/error-log-tail.jsonl" 2>/dev/null || return 1
}

# Create manifest with file checksums
_create_manifest() {
    local bundle_dir="$1"
    local manifest_file="${bundle_dir}/manifest.json"
    local tmp_file="${manifest_file}.tmp.$$"

    # Build files array separately to avoid subshell issues
    local files_json="["
    local first=1

    # Count files (excluding manifest.json itself)
    local file_count=0
    file_count=$(find "$bundle_dir" -maxdepth 1 -type f ! -name "manifest.json" 2>/dev/null | wc -l || echo 0)

    # List files and build JSON (without subshell pipe to preserve variables)
    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue
        local filename
        filename=$(basename "$filepath")

        if [[ "$first" -eq 0 ]]; then
            files_json="${files_json},"
        fi
        first=0

        local size
        size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)
        local sha256
        sha256=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1 || echo "")

        files_json="${files_json}{\"name\":\"$(basename "$filepath")\",\"size_bytes\":${size},\"sha256\":\"${sha256}\"}"
    done < <(find "$bundle_dir" -maxdepth 1 -type f ! -name "manifest.json" 2>/dev/null || true)

    files_json="${files_json}]"

    local total_size
    total_size=$(du -sb "$bundle_dir" 2>/dev/null | cut -f1 || echo 0)

    # Write manifest
    {
        printf '{'
        printf '"file_count":%d,' "$file_count"
        printf '"total_size_bytes":%d,' "$total_size"
        printf '"files":%s' "$files_json"
        printf '}\n'
    } > "$tmp_file" 2>/dev/null || return 1
    mv "$tmp_file" "$manifest_file" 2>/dev/null || return 1
}
