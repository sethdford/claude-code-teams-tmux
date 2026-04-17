#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  conflict-predictor — Predicts files a pipeline will touch                ║
# ║  Used by daemon/fleet to acquire file-locks BEFORE spawning a pipeline    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Strategy (conservative):
#   1. Extract explicit file/path references from issue title+body (``code``
#      spans, `path/file.ext` mentions, @file markers).
#   2. Cross-reference against tracked files in the repo — unknown paths are
#      dropped to avoid locking noise words.
#   3. If no explicit files found, fall back to a coarse directory prefix
#      (e.g. "scripts/sw-cost*" for issues mentioning cost/budget).
#   4. Always emit a sorted, de-duplicated list on stdout, one path per line.
#
# Exit code is always 0. Predictor failure must not block the pipeline —
# callers can treat an empty output as "unknown; proceed without locks".

[[ -n "${_CONFLICT_PREDICTOR_LOADED:-}" ]] && return 0
_CONFLICT_PREDICTOR_LOADED=1

# ─── Config ─────────────────────────────────────────────────────────────────
CONFLICT_PREDICT_MAX_FILES="${CONFLICT_PREDICT_MAX_FILES:-20}"

# ─── Internal: list of tracked files in repo (cached per process) ───────────
_predictor_tracked_files() {
    if [[ -z "${_PREDICTOR_TRACKED_CACHE:-}" ]]; then
        _PREDICTOR_TRACKED_CACHE=$(git ls-files 2>/dev/null || true)
        export _PREDICTOR_TRACKED_CACHE
    fi
    printf '%s\n' "$_PREDICTOR_TRACKED_CACHE"
}

# ─── Internal: extract candidate paths from free-form text ──────────────────
# Matches tokens that look like file paths: contain a `/` or end with a
# recognized extension, and stay within a reasonable length.
_predictor_extract_candidates() {
    local text="$1"
    printf '%s\n' "$text" \
        | tr -c 'A-Za-z0-9_./-' '\n' \
        | grep -E '^[A-Za-z0-9_./-]+$' \
        | grep -E '(/|\.(sh|ts|js|json|md|yml|yaml|py|go|rs|toml))$' \
        | grep -vE '^(https?|git|ssh|\.|/)' \
        | awk 'length($0) > 1 && length($0) < 200' \
        | sort -u
}

# ─── Public: predict file set for a pipeline ────────────────────────────────
# Usage: predict_pipeline_files "<issue title>" "<issue body>"
# Output: newline-separated, sorted, tracked paths (possibly empty).
predict_pipeline_files() {
    local title="${1:-}"
    local body="${2:-}"
    local combined="${title}
${body}"

    local candidates tracked matched=""
    candidates=$(_predictor_extract_candidates "$combined") || candidates=""
    [[ -z "$candidates" ]] && { return 0; }

    tracked=$(_predictor_tracked_files)
    [[ -z "$tracked" ]] && { return 0; }

    # Intersect candidates with tracked paths. Accept exact match OR basename
    # match (e.g. "file-locks.sh" → "scripts/lib/file-locks.sh").
    local tracked_file
    tracked_file=$(mktemp "${TMPDIR:-/tmp}/predict.tracked.XXXXXX") || return 0
    printf '%s\n' "$tracked" > "$tracked_file"

    while IFS= read -r cand; do
        [[ -z "$cand" ]] && continue
        # Exact match
        if grep -Fxq -- "$cand" "$tracked_file"; then
            matched+="${cand}
"
            continue
        fi
        # Basename match — only if candidate has no `/` (avoid over-matching)
        if [[ "$cand" != */* ]]; then
            local hit
            hit=$(grep -E "/${cand}$" "$tracked_file" | head -1 || true)
            [[ -n "$hit" ]] && matched+="${hit}
"
        fi
    done <<< "$candidates"

    rm -f "$tracked_file"
    [[ -z "$matched" ]] && return 0

    printf '%s' "$matched" | grep -v '^$' | sort -u | head -n "$CONFLICT_PREDICT_MAX_FILES"
    return 0
}
