#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright bisect — Test Failure Git Bisection + Root Cause Identification║
# ║  Drives `git bisect run` to find the first bad commit, then classifies    ║
# ║  the failure via the shared root-cause engine and emits a JSON verdict.   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Root-cause classifier (reused, not reinvented) ────────────────────────
# shellcheck source=lib/root-cause.sh
[[ -f "$SCRIPT_DIR/lib/root-cause.sh" ]] && source "$SCRIPT_DIR/lib/root-cause.sh" 2>/dev/null || true

# ─── Config ─────────────────────────────────────────────────────────────────
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$STATE_DIR/pipeline-artifacts}"
RESULT_FILE="${RESULT_FILE:-$ARTIFACTS_DIR/bisect-result.json}"
DIFF_LINE_CAP="${DIFF_LINE_CAP:-200}"     # cap culprit diff fed to classifier
OUTPUT_LINE_CAP="${OUTPUT_LINE_CAP:-100}" # cap captured failure output

# ─── Runtime state (populated during the run; used by the cleanup trap) ─────
START_REF=""
WRAPPER=""
BISECT_ACTIVE=""

# ═══════════════════════════════════════════════════════════════════════════
# Usage
# ═══════════════════════════════════════════════════════════════════════════
show_usage() {
    cat <<'EOF'
shipwright bisect — Find the first commit that broke a test, then diagnose it.

USAGE
  shipwright bisect --good <ref> --test-cmd "<cmd>" [--bad <ref>] [options]

REQUIRED
  --good <ref>        A commit/ref where the test is known to PASS
  --test-cmd "<cmd>"  Command to run at each step (exit 0 = pass, non-zero = fail)

OPTIONS
  --bad <ref>         A commit/ref where the test FAILS (default: HEAD)
  --no-classify       Skip root-cause classification of the culprit
  --json              Emit only the JSON result (suppress the human report)
  -h, --help          Show this help

BEHAVIOR
  Drives `git bisect run` to locate the first bad commit in O(log n) checkouts,
  captures the culprit's metadata + diff, and classifies the failure using the
  shared root-cause engine. The working tree and branch are ALWAYS restored on
  success, failure, and interrupt. Refuses to run on a dirty tree.

OUTPUT
  Human-readable report + .claude/pipeline-artifacts/bisect-result.json

EXAMPLE
  shipwright bisect --good v1.2.0 --bad HEAD --test-cmd "npm test -- auth.test.js"
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# Cleanup — ALWAYS restore the repo to its starting state
# ═══════════════════════════════════════════════════════════════════════════
cleanup() {
    local rc=$?
    if [[ -n "$BISECT_ACTIVE" ]]; then
        git bisect reset >/dev/null 2>&1 || true
    fi
    # Safety net: bisect reset returns to the start ref, but restore explicitly
    # in case reset failed (e.g. interrupted mid-checkout).
    if [[ -n "$START_REF" ]]; then
        git checkout "$START_REF" >/dev/null 2>&1 || true
    fi
    [[ -n "$WRAPPER" && -f "$WRAPPER" ]] && rm -f "$WRAPPER"
    return $rc
}

# ═══════════════════════════════════════════════════════════════════════════
# Pre-flight guards
# ═══════════════════════════════════════════════════════════════════════════
preflight() {
    local good="$1" bad="$2"

    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        error "Not a git repository. Run bisect from inside a git repo."
        return 1
    fi
    # Refuse to run on a dirty tree — bisect checkouts would clobber changes.
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        error "Working tree is dirty. Commit or stash your changes before bisecting."
        return 1
    fi
    if ! git rev-parse --verify --quiet "$good^{commit}" >/dev/null 2>&1; then
        error "Good ref '$good' is not a valid commit."
        return 1
    fi
    if ! git rev-parse --verify --quiet "$bad^{commit}" >/dev/null 2>&1; then
        error "Bad ref '$bad' is not a valid commit."
        return 1
    fi
    # Good must be an ancestor of bad, otherwise the search range is invalid.
    if ! git merge-base --is-ancestor "$good" "$bad" 2>/dev/null; then
        error "Good ref '$good' must be an ancestor of bad ref '$bad'."
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Generate the exit-code-mapping wrapper `git bisect run` invokes per step
# ═══════════════════════════════════════════════════════════════════════════
write_wrapper() {
    local test_cmd="$1"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/sw-bisect-run.XXXXXX")"
    # Unquoted heredoc so $test_cmd expands; escape runtime vars with \$.
    cat > "$tmp" <<WRAP
#!/usr/bin/env bash
$test_cmd
rc=\$?
# git bisect run contract: 0=good, 125=skip, 1-124/126-127=bad, 128+=abort.
# Map any non-zero, non-skip result into the 'bad' range so the search never
# aborts on high signal exit codes (e.g. 137 from OOM-killed tests).
if [[ \$rc -eq 0 ]]; then exit 0; fi
if [[ \$rc -eq 125 ]]; then exit 125; fi
exit 1
WRAP
    chmod +x "$tmp"
    echo "$tmp"
}

# ═══════════════════════════════════════════════════════════════════════════
# Parse "<sha> is the first bad commit" from bisect run output
# ═══════════════════════════════════════════════════════════════════════════
parse_first_bad() {
    local log="$1"
    local sha
    sha="$(grep -oE '[0-9a-f]{7,40} is the first bad commit' "$log" 2>/dev/null | head -1 | awk '{print $1}')"
    if [[ -z "$sha" ]]; then
        # Fallback: ask git for the bisect verdict directly.
        sha="$(git bisect log 2>/dev/null | grep -oE 'first bad commit: \[[0-9a-f]{7,40}\]' | head -1 | grep -oE '[0-9a-f]{7,40}')"
    fi
    echo "$sha"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════
main() {
    local good="" bad="HEAD" test_cmd="" json_only="" no_classify=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --good)       good="${2:-}"; shift 2 ;;
            --bad)        bad="${2:-}"; shift 2 ;;
            --test-cmd)   test_cmd="${2:-}"; shift 2 ;;
            --json)       json_only=1; shift ;;
            --no-classify) no_classify=1; shift ;;
            -h|--help)    show_usage; return 0 ;;
            *)            error "Unknown option: $1"; show_usage; return 1 ;;
        esac
    done

    if [[ -z "$good" ]]; then
        error "Missing required --good <ref>."; show_usage; return 1
    fi
    if [[ -z "$test_cmd" ]]; then
        error "Missing required --test-cmd \"<cmd>\"."; show_usage; return 1
    fi

    preflight "$good" "$bad" || return 1

    # Capture the starting point for restoration.
    local start_branch start_sha
    start_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    start_sha="$(git rev-parse HEAD 2>/dev/null || echo '')"
    if [[ "$start_branch" == "HEAD" ]]; then
        START_REF="$start_sha"   # detached HEAD — restore by SHA
    else
        START_REF="$start_branch"
    fi

    trap cleanup EXIT INT TERM

    [[ -z "$json_only" ]] && info "Bisecting: good=$good bad=$bad"

    WRAPPER="$(write_wrapper "$test_cmd")"

    # ─── Drive the search ───────────────────────────────────────────────────
    local run_log
    run_log="$(mktemp "${TMPDIR:-/tmp}/sw-bisect-log.XXXXXX")"

    if ! git bisect start "$bad" "$good" >>"$run_log" 2>&1; then
        error "Failed to start git bisect."
        rm -f "$run_log"
        return 1
    fi
    BISECT_ACTIVE=1

    # `git bisect run` exits non-zero if no bad commit is isolated; capture it.
    git bisect run "$WRAPPER" >>"$run_log" 2>&1 || true

    local culprit
    culprit="$(parse_first_bad "$run_log")"

    if [[ -z "$culprit" ]]; then
        error "Bisection did not isolate a first bad commit."
        [[ -z "$json_only" ]] && tail -20 "$run_log" >&2
        rm -f "$run_log"
        return 1
    fi

    # ─── Collect culprit metadata (HEAD is at the culprit after bisect run) ──
    local full_sha short_sha author date subject files_changed
    full_sha="$(git rev-parse "$culprit" 2>/dev/null || echo "$culprit")"
    short_sha="$(git rev-parse --short "$culprit" 2>/dev/null || echo "${culprit:0:7}")"
    author="$(git show -s --format='%an' "$culprit" 2>/dev/null || echo unknown)"
    date="$(git show -s --format='%aI' "$culprit" 2>/dev/null || echo '')"
    subject="$(git show -s --format='%s' "$culprit" 2>/dev/null || echo '')"
    files_changed="$(git diff-tree --no-commit-id --name-only -r "$culprit" 2>/dev/null | grep -c . || true)"
    files_changed="${files_changed:-0}"

    # Capped diff for the classifier (protects the context budget).
    local culprit_diff
    culprit_diff="$(git show "$culprit" --format='' 2>/dev/null | head -n "$DIFF_LINE_CAP" || true)"

    # Capture real failure output at the culprit for classification.
    local fail_output=""
    if [[ -z "$no_classify" ]]; then
        fail_output="$(bash -c "$test_cmd" 2>&1 | head -n "$OUTPUT_LINE_CAP" || true)"
    fi

    # ─── Root-cause classification (reuse root-cause.sh) ────────────────────
    local category="skipped" confidence=0 evidence='[]' suggested_action=""
    if [[ -z "$no_classify" ]] && [[ "$(type -t rootcause_classify 2>/dev/null)" == "function" ]]; then
        local classify_input classification fix_json
        classify_input="$fail_output"$'\n'"culprit: $subject"$'\n'"$culprit_diff"
        classification="$(rootcause_classify "$classify_input" "bisect" 1 2>/dev/null || echo '{}')"
        category="$(echo "$classification" | jq -r '.category // "unknown"' 2>/dev/null || echo unknown)"
        confidence="$(echo "$classification" | jq -r '.confidence // 0' 2>/dev/null || echo 0)"
        evidence="$(echo "$classification" | jq -c '.evidence // []' 2>/dev/null || echo '[]')"
        if [[ "$(type -t rootcause_suggest_fix 2>/dev/null)" == "function" ]]; then
            fix_json="$(rootcause_suggest_fix "$category" "$fail_output" "bisect" 2>/dev/null || echo '{}')"
            suggested_action="$(echo "$fix_json" | jq -r '.suggestions // ""' 2>/dev/null || echo '')"
        fi
    fi

    # ─── Write the JSON artifact atomically ─────────────────────────────────
    mkdir -p "$ARTIFACTS_DIR"
    local tmp_json
    tmp_json="$(mktemp "${TMPDIR:-/tmp}/sw-bisect-json.XXXXXX")"
    jq -n \
        --arg good "$good" \
        --arg bad "$bad" \
        --arg sha "$full_sha" \
        --arg short "$short_sha" \
        --arg author "$author" \
        --arg date "$date" \
        --arg subject "$subject" \
        --argjson files "${files_changed:-0}" \
        --arg category "$category" \
        --argjson confidence "${confidence:-0}" \
        --argjson evidence "$evidence" \
        --arg action "$suggested_action" \
        --arg generated_at "$(now_iso)" \
        '{
            good: $good,
            bad: $bad,
            first_bad_commit: $sha,
            short_sha: $short,
            author: $author,
            date: $date,
            subject: $subject,
            files_changed: $files,
            root_cause: {
                category: $category,
                confidence: $confidence,
                evidence: $evidence,
                suggested_action: $action
            },
            generated_at: $generated_at
        }' > "$tmp_json" 2>/dev/null
    mv -f "$tmp_json" "$RESULT_FILE"

    rm -f "$run_log"

    emit_event "bisect_complete" "commit=$short_sha" "category=$category" "confidence=$confidence"

    # ─── Report ─────────────────────────────────────────────────────────────
    if [[ -n "$json_only" ]]; then
        cat "$RESULT_FILE"
    else
        echo ""
        echo -e "\033[38;2;0;212;255m\033[1m╔══════════════════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[38;2;0;212;255m\033[1m║  First Bad Commit Identified                                 ║\033[0m"
        echo -e "\033[38;2;0;212;255m\033[1m╚══════════════════════════════════════════════════════════════╝\033[0m"
        echo ""
        success "Culprit: $short_sha — $subject"
        info    "Author:  $author  ($date)"
        info    "Files:   $files_changed changed"
        if [[ -z "$no_classify" ]]; then
            echo ""
            info    "Root cause: $category (confidence ${confidence}%)"
            [[ -n "$suggested_action" ]] && warn "Suggested: $suggested_action"
        fi
        echo ""
        info "Full report: $RESULT_FILE"
    fi

    return 0
}

main "$@"
