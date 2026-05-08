#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  test-dep-map — Build cached test → source-file dependency maps          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Functions:
#   tdm_build_map <test_files_dir> <project_root>   Build/refresh the map
#   tdm_tests_for_changed <changed_file...>          Tests that depend on files
#   tdm_load_map [path]                              Load existing map
#
# Cache format (.claude/intelligence-cache/test-dep-map.json):
#   { "tests": { "<test_path>": ["<src_path>", ...] }, "built_at": "..." }
#
set -euo pipefail
[[ -n "${_TEST_DEP_MAP_LOADED:-}" ]] && return 0; _TEST_DEP_MAP_LOADED=1

TDM_CACHE_DIR="${TDM_CACHE_DIR:-.claude/intelligence-cache}"
TDM_CACHE_FILE="${TDM_CACHE_FILE:-$TDM_CACHE_DIR/test-dep-map.json}"

[[ "$(type -t info 2>/dev/null)" == "function" ]] || info() { echo -e "▸ $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]] || warn() { echo -e "⚠ $*" >&2; }

# Extract source/import dependency tokens from a test file.
# Looks for: bash `source X`, `. X`, JS `import ... from 'X'`, JS `require('X')`,
# Python `import X`, `from X import`.
_tdm_extract_deps() {
    local test_file="$1"
    [[ ! -f "$test_file" ]] && return 0

    # Bash sources
    grep -oE '(source|^\s*\.)\s+[^\s]+\.sh' "$test_file" 2>/dev/null \
        | awk '{print $NF}' | sed 's|^\./||'

    # JS/TS imports/requires (extract quoted path)
    grep -oE "(require|import\s+.*\s+from)\s*\(?\s*['\"][^'\"]+['\"]" "$test_file" 2>/dev/null \
        | grep -oE "['\"][^'\"]+['\"]" \
        | tr -d "'\""

    # Python imports — module names (best-effort)
    grep -oE "^(import|from)\s+[a-zA-Z_][a-zA-Z0-9_.]*" "$test_file" 2>/dev/null \
        | awk '{print $2}'
}

# Resolve a dependency token to a candidate file path within project_root.
_tdm_resolve_token() {
    local token="$1" project_root="$2"
    [[ -z "$token" ]] && return 0

    # Strip version specifiers / package prefixes
    token="${token%%/*.}"

    # Direct match
    if [[ -f "$project_root/$token" ]]; then
        echo "$token"; return 0
    fi

    # Basename match — find first file with this basename under project root
    local base
    base=$(basename "$token")
    [[ -z "$base" ]] && return 0
    find "$project_root" -name "$base" -type f 2>/dev/null | head -1 \
        | sed "s|^$project_root/||"
}

# Build dependency map for all test files. Atomic write.
# tdm_build_map <project_root> [test_glob_pattern]
tdm_build_map() {
    local project_root="${1:-.}"
    local pattern="${2:-*-test.sh}"

    [[ ! -d "$project_root" ]] && { warn "Project root missing: $project_root"; return 1; }

    mkdir -p "$TDM_CACHE_DIR"
    local tmp
    tmp=$(mktemp "${TDM_CACHE_FILE}.XXXXXX")
    # Cleanup tmp on any exit — must include error paths.
    trap "rm -f '$tmp'" RETURN

    local entries=""
    local first=1
    while IFS= read -r test_file; do
        [[ -z "$test_file" ]] && continue
        local rel="${test_file#$project_root/}"
        local deps_json="[]"
        local deps=()
        while IFS= read -r tok; do
            [[ -z "$tok" ]] && continue
            local resolved
            resolved=$(_tdm_resolve_token "$tok" "$project_root")
            [[ -n "$resolved" ]] && deps+=("$resolved")
        done < <(_tdm_extract_deps "$test_file")

        if [[ ${#deps[@]} -gt 0 ]] && command -v jq >/dev/null 2>&1; then
            deps_json=$(printf '%s\n' "${deps[@]}" | jq -R . | jq -s 'unique')
        fi

        if [[ $first -eq 1 ]]; then first=0; else entries+=","; fi
        entries+="$(printf '"%s":%s' "$rel" "$deps_json")"
    done < <(find "$project_root" -name "$pattern" -type f 2>/dev/null)

    local built_at
    built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"built_at":"%s","tests":{%s}}' "$built_at" "$entries" > "$tmp"

    # Validate JSON before atomic move
    if command -v jq >/dev/null 2>&1; then
        jq empty "$tmp" >/dev/null 2>&1 || { warn "Invalid dep-map JSON"; return 1; }
    fi
    mv "$tmp" "$TDM_CACHE_FILE"
}

# Return tests whose dep list intersects with given changed files.
# tdm_tests_for_changed <changed_file...>
tdm_tests_for_changed() {
    local -a changed=("$@")
    [[ ${#changed[@]} -eq 0 ]] && return 0
    [[ ! -f "$TDM_CACHE_FILE" ]] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    local changed_json
    changed_json=$(printf '%s\n' "${changed[@]}" | jq -R . | jq -s .)

    jq -r --argjson changed "$changed_json" '
        .tests | to_entries[]
        | select((.value // []) as $deps
                 | ($changed | any(. as $c | $deps | index($c))))
        | .key
    ' "$TDM_CACHE_FILE" 2>/dev/null
}

# Load and echo current map (for inspection / tests)
tdm_load_map() {
    local path="${1:-$TDM_CACHE_FILE}"
    [[ -f "$path" ]] && cat "$path" || echo '{}'
}
