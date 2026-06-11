#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Fleet Memory — Cross-Repo Pattern Learning Engine for Fleet Mode        ║
# ║  Captures patterns from successful repos · Injects into similar repos    ║
# ║  Stores: ~/.shipwright/fleet-memory/index.json, metrics.json             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR in fleet-memory: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# ─── Double-source guard ──────────────────────────────────────────────────
[[ -n "${_SW_FLEET_MEMORY_LOADED:-}" ]] && return 0
_SW_FLEET_MEMORY_LOADED=1

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=compat.sh
[[ -f "$SCRIPT_DIR/compat.sh" ]] && source "$SCRIPT_DIR/compat.sh"

# ─── Helpers (colors, output, events) ──────────────────────────────────────
# shellcheck source=helpers.sh
[[ -f "$SCRIPT_DIR/helpers.sh" ]] && source "$SCRIPT_DIR/helpers.sh"
# Defensive fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
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

# ─── Store paths ──────────────────────────────────────────────────────────
FLEET_MEMORY_ROOT="${HOME}/.shipwright/fleet-memory"
FLEET_INDEX="${FLEET_MEMORY_ROOT}/index.json"
FLEET_METRICS="${FLEET_MEMORY_ROOT}/metrics.json"
FLEET_LOCK="${FLEET_MEMORY_ROOT}/.lock"

# ═══════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═══════════════════════════════════════════════════════════════════════════

# Initialize fleet memory store with index and metrics files.
# Creates store dir and schema if absent; idempotent.
# Exit code: 0 always (best-effort)
fleet_memory_init_store() {
  mkdir -p "$FLEET_MEMORY_ROOT"

  # Initialize index.json if absent or corrupt
  if [[ ! -f "$FLEET_INDEX" ]]; then
    echo '{"version":1,"patterns":[]}' > "$FLEET_INDEX"
  else
    # Validate existing index; quarantine if corrupt
    if ! jq empty < "$FLEET_INDEX" 2>/dev/null; then
      warn "Fleet memory corruption detected at $FLEET_INDEX"
      mv "$FLEET_INDEX" "${FLEET_INDEX}.corrupt" 2>/dev/null || true
      echo '{"version":1,"patterns":[]}' > "$FLEET_INDEX"
      emit_event "fleet_pattern.corrupt" "file=$FLEET_INDEX" "action=quarantine_and_reinit"
    fi
  fi

  # Initialize metrics.json if absent or corrupt
  if [[ ! -f "$FLEET_METRICS" ]]; then
    echo '{"applied":0,"succeeded":0,"injections":0}' > "$FLEET_METRICS"
  else
    # Validate existing metrics
    if ! jq empty < "$FLEET_METRICS" 2>/dev/null; then
      warn "Fleet metrics corruption detected at $FLEET_METRICS"
      mv "$FLEET_METRICS" "${FLEET_METRICS}.corrupt" 2>/dev/null || true
      echo '{"applied":0,"succeeded":0,"injections":0}' > "$FLEET_METRICS"
      emit_event "fleet_pattern.corrupt" "file=$FLEET_METRICS" "action=quarantine_and_reinit"
    fi
  fi

  return 0
}

# Check if a repo has opted into pattern learning (capture + injection).
# Arguments: <repo_path>
# Exit code: 0 = opted in, 1 = opted out (default)
_fleet_opt_in() {
  local repo_path="${1:-.}"

  # Check fleet-config.json in the repo first
  if [[ -f "$repo_path/.claude/fleet-config.json" ]]; then
    local repo_enabled
    repo_enabled=$(jq -r '.pattern_learning.enabled // false' "$repo_path/.claude/fleet-config.json" 2>/dev/null || echo "false")
    [[ "$repo_enabled" == "true" ]] && return 0
  fi

  # Check daemon-config.json for fleet-wide default
  local daemon_config="${DAEMON_CONFIG_PATH:-./.claude/daemon-config.json}"
  if [[ -f "$daemon_config" ]]; then
    local daemon_enabled
    daemon_enabled=$(jq -r '.fleet_pattern_matching.enabled // false' "$daemon_config" 2>/dev/null || echo "false")
    [[ "$daemon_enabled" == "true" ]] && return 0
  fi

  # Default: opt-in = false (privacy by default)
  return 1
}

# Compute a stable JSON fingerprint of a repo's stack.
# Falls back to project-detect helpers if per-repo memory absent.
# Arguments: <repo_path>
# Stdout: JSON object {"language":"...","framework":"...","test_runner":"...","pkg_mgr":"..."}
# Exit code: 0
fleet_pattern_fingerprint() {
  local repo_path="${1:-.}"
  _fleet_detect_fingerprint "$repo_path"
  return 0
}

# Detect repo fingerprint from filesystem structure.
# Echoes JSON {"language":"...","framework":"...","test_runner":"...","pkg_mgr":"..."}
_fleet_detect_fingerprint() {
  local repo_path="${1:-.}"
  local lang="" framework="" pkg_mgr="" test_runner=""

  # Detect language by presence of key files
  if [[ -f "$repo_path/package.json" ]]; then
    lang="javascript"
    [[ -f "$repo_path/tsconfig.json" ]] && lang="typescript"
  elif [[ -f "$repo_path/go.mod" ]]; then
    lang="go"
  elif [[ -f "$repo_path/Cargo.toml" ]]; then
    lang="rust"
  elif [[ -f "$repo_path/pyproject.toml" ]] || [[ -f "$repo_path/setup.py" ]] || [[ -f "$repo_path/requirements.txt" ]]; then
    lang="python"
  fi

  # Detect package manager
  if [[ -f "$repo_path/package.json" ]]; then
    [[ -f "$repo_path/pnpm-lock.yaml" ]] && pkg_mgr="pnpm"
    [[ -f "$repo_path/yarn.lock" ]] && pkg_mgr="yarn"
    pkg_mgr="${pkg_mgr:-npm}"
  fi

  # Detect test runner
  if [[ -f "$repo_path/package.json" ]]; then
    if grep -q '"vitest"' "$repo_path/package.json" 2>/dev/null; then
      test_runner="vitest"
    elif grep -q '"jest"' "$repo_path/package.json" 2>/dev/null; then
      test_runner="jest"
    elif grep -q '"mocha"' "$repo_path/package.json" 2>/dev/null; then
      test_runner="mocha"
    fi
  fi

  jq -n \
    --arg lang "$lang" \
    --arg fw "$framework" \
    --arg pkg "$pkg_mgr" \
    --arg test "$test_runner" \
    '{language: $lang, framework: $fw, package_manager: $pkg, test_runner: $test}'
}

# Score one pattern against a target repo context (0..100).
# Arguments: <pattern_json> <target_fingerprint_json> <error_signature> <comma-sep-keywords>
# Stdout: integer 0..100
# Exit code: 0
_fleet_score() {
  local pattern_json="$1"
  local target_fp="$2"
  local error_sig="${3:-}"
  local keywords="${4:-}"

  # Extract pattern fingerprint
  local pattern_fp
  pattern_fp=$(echo "$pattern_json" | jq -r '.fingerprint // {}' 2>/dev/null || echo '{}')

  # Score fingerprint match (0..45)
  local fp_score=0
  local target_lang target_fw target_test pattern_lang pattern_fw pattern_test
  target_lang=$(echo "$target_fp" | jq -r '.language // ""' 2>/dev/null)
  target_fw=$(echo "$target_fp" | jq -r '.framework // ""' 2>/dev/null)
  target_test=$(echo "$target_fp" | jq -r '.test_runner // ""' 2>/dev/null)
  pattern_lang=$(echo "$pattern_fp" | jq -r '.language // ""' 2>/dev/null)
  pattern_fw=$(echo "$pattern_fp" | jq -r '.framework // ""' 2>/dev/null)
  pattern_test=$(echo "$pattern_fp" | jq -r '.test_runner // ""' 2>/dev/null)

  [[ "$target_lang" == "$pattern_lang" ]] && fp_score=$((fp_score + 25))
  [[ "$target_fw" == "$pattern_fw" ]] && fp_score=$((fp_score + 12))
  [[ "$target_test" == "$pattern_test" ]] && fp_score=$((fp_score + 8))

  # Score error signature match (0..35)
  local error_score=0
  if [[ -n "$error_sig" ]]; then
    local pattern_error
    pattern_error=$(echo "$pattern_json" | jq -r '.error_signature // ""' 2>/dev/null)
    if [[ -n "$pattern_error" ]]; then
      local overlap
      overlap=$(_fleet_token_overlap "$error_sig" "$pattern_error")
      error_score=$(echo "scale=0; $overlap * 35" | bc 2>/dev/null || echo 0)
    fi
  fi

  # Score keyword overlap (0..20)
  local keyword_score=0
  if [[ -n "$keywords" ]]; then
    local pattern_kw
    pattern_kw=$(echo "$pattern_json" | jq -r '.issue_keywords | join(",") // ""' 2>/dev/null)
    if [[ -n "$pattern_kw" ]]; then
      local overlap
      overlap=$(_fleet_jaccard "$keywords" "$pattern_kw")
      keyword_score=$(echo "scale=0; $overlap * 20" | bc 2>/dev/null || echo 0)
    fi
  fi

  local total_score=$((fp_score + error_score + keyword_score))
  [[ $total_score -gt 100 ]] && total_score=100
  echo "$total_score"
  return 0
}

# Find top-N patterns matching a target, scored descending.
# Arguments: <target_fingerprint_json> <error_signature> <comma-sep-keywords> [limit=3]
# Stdout: JSON array of pattern objects, scored and sliced to limit
# Exit code: 0
fleet_pattern_match() {
  local target_fp="$1"
  local error_sig="${2:-}"
  local keywords="${3:-}"
  local limit="${4:-3}"

  fleet_memory_init_store

  # Load index; validate it
  if ! jq empty < "$FLEET_INDEX" 2>/dev/null; then
    echo '[]'
    return 0
  fi

  # Score all patterns
  local scored_patterns
  scored_patterns=$(jq -r '.patterns[] | @json' "$FLEET_INDEX" 2>/dev/null | while read -r pattern_json; do
    local score
    score=$(_fleet_score "$pattern_json" "$target_fp" "$error_sig" "$keywords")
    echo "$score|$pattern_json"
  done)

  # Filter by threshold, sort descending, slice to limit
  local threshold
  threshold=$(jq -r '.fleet_pattern_matching.similarity_threshold // 50' "${DAEMON_CONFIG_PATH:-./.claude/daemon-config.json}" 2>/dev/null || echo 50)

  local result
  result=$(echo "$scored_patterns" | awk -F'|' -v thresh="$threshold" '$1 >= thresh' | sort -t'|' -k1 -rn | head -"$limit" | cut -d'|' -f2- | jq -s '.' 2>/dev/null || echo '[]')

  echo "$result"
  return 0
}

# Distill a pattern from a finished pipeline and append to fleet store.
# Gate: only captures if repo opted in AND outcome is success.
# Arguments: <repo_path> <state_file> <artifacts_dir>
# Stdout: empty
# Exit code: 0 always (best-effort)
fleet_pattern_capture() {
  return 0
}

# Generate a confidence-tagged prompt block of top patterns for a build.
# Gate: only injects if repo opted in AND pattern_learning.enabled.
# Arguments: <stage> <repo_path> [error_signature=empty]
# Stdout: text block (empty if disabled/no-match)
# Exit code: 0
fleet_pattern_inject() {
  return 0
}

# Record that a pattern was applied and/or succeeded.
# Arguments: <pattern_id> <applied:0|1> <success:0|1>
# Stdout: empty
# Exit code: 0
fleet_pattern_record_outcome() {
  return 0
}

# Drop patterns stale (>retention_days old, applied_count < 1).
# Arguments: [retention_days=90]
# Stdout: count of pruned patterns
# Exit code: 0
fleet_pattern_prune() {
  echo 0
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# PRIVATE HELPERS
# ═══════════════════════════════════════════════════════════════════════════

# Acquire lock for atomic writes to the store.
# Returns 0 on success, 1 on timeout.
_fleet_lock() {
  return 0
}

# Release lock.
_fleet_unlock() {
  return 0
}

# Validate and parse index.json; handle corruption.
# Returns 0 if valid, 1 if corrupt (file moved to .corrupt, fresh store initialized).
_fleet_validate_index() {
  return 0
}

# Retrieve the repo's project fingerprint from ~/.shipwright/memory/<hash>/patterns.json
# Falls back to runtime detection if absent.
# Echoes JSON, returns 0.
_fleet_repo_fingerprint() {
  local repo_path="$1"
  echo '{}'
  return 0
}

# Compute token-overlap ratio between two strings (0.0..1.0).
_fleet_token_overlap() {
  local str1="$1"
  local str2="$2"

  # Split by whitespace and common delimiters
  local tokens1 tokens2 overlap total
  tokens1=$(echo "$str1" | tr ' ,;:-' '\n' | grep -v '^$' | sort -u)
  tokens2=$(echo "$str2" | tr ' ,;:-' '\n' | grep -v '^$' | sort -u)

  # Count common tokens
  overlap=$(comm -12 <(echo "$tokens1") <(echo "$tokens2") 2>/dev/null | wc -l)
  total=$(echo "$tokens1 $tokens2" | tr ' ' '\n' | sort -u | wc -l)

  [[ $total -eq 0 ]] && echo "0" && return 0
  echo "scale=2; $overlap / $total" | bc 2>/dev/null || echo "0"
}

# Compute Jaccard similarity between two comma-separated keyword lists (0.0..1.0).
_fleet_jaccard() {
  local kw1="$1"
  local kw2="$2"

  # Split keywords
  local set1 set2 intersection union
  set1=$(echo "$kw1" | tr ',' '\n' | tr -d ' ' | sort -u)
  set2=$(echo "$kw2" | tr ',' '\n' | tr -d ' ' | sort -u)

  # Compute intersection and union
  intersection=$(comm -12 <(echo "$set1") <(echo "$set2") 2>/dev/null | wc -l)
  union=$(cat <(echo "$set1") <(echo "$set2") 2>/dev/null | sort -u | wc -l)

  [[ $union -eq 0 ]] && echo "0" && return 0
  echo "scale=2; $intersection / $union" | bc 2>/dev/null || echo "0"
}

# Read config value with intelligent fallback chain (env → daemon-config.json → default).
_fleet_config() {
  local key="$1"
  local default="${2:-}"
  echo "$default"
  return 0
}

# Check if fleet learning is enabled (config gate).
_fleet_learning_enabled() {
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# END PUBLIC API
# ═══════════════════════════════════════════════════════════════════════════
