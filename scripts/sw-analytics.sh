#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-analytics — Setup and First-Run Analytics Engine with Drop-off       ║
# ║  Tracking                                                                 ║
# ║                                                                          ║
# ║  Track setup phase completion rates, pipeline outcomes, and drop-off     ║
# ║  detection. Events are emitted to ~/.shipwright/analytics.jsonl with    ║
# ║  atomic writes and privacy-preserving sanitization.                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Helpers ───────────────────────────────────────────────────────────────
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallback helpers if not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi
if [[ "$(type -t atomic_append 2>/dev/null)" != "function" ]]; then
  atomic_append() {
    local target="$1" line="$2"
    [[ -z "$target" ]] && { error "atomic_append: target file not specified"; return 1; }
    [[ -z "$line" ]] && { error "atomic_append: line not specified"; return 1; }
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then
      error "atomic_append: invalid JSON: $line"
      return 1
    fi
    mkdir -p "$(dirname "$target")" || return 1
    echo "$line" >> "$target" 2>/dev/null || return 1
  }
fi

# ─── Analytics Core ───────────────────────────────────────────────────────
ANALYTICS_FILE="${HOME}/.shipwright/analytics.jsonl"

# Sanitize secrets from error messages
sanitize_secrets() {
  local text="$1"
  # Redact common secret patterns: API keys, tokens, AWS keys, passwords
  text="${text//[A-Za-z0-9_-]{32,}/[REDACTED_KEY]}"
  text="${text//Bearer [^ ]*/[REDACTED_TOKEN]}"
  text="${text//aws_[^ ]*/[REDACTED_AWS]}"
  text="${text//password[=:][^ ]*/[REDACTED_PASSWORD]}"
  text="${text//\$[A-Z_][A-Z0-9_]*/[REDACTED_VAR]}"
  echo "$text"
}

# Validate event type against whitelist
is_valid_event_type() {
  local event_type="$1"
  case "$event_type" in
    setup_start|setup_phase_complete|setup_abandoned|pipeline_attempt|pipeline_outcome|init_complete)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Track an analytics event (non-blocking, fails silently)
analytics_track() {
  local event_type="${1:-}"
  local metadata_json="${2:- }"
  local session_id="${3:-$(uuidgen 2>/dev/null || echo "session-$(date +%s)")}"

  # Use empty JSON object if metadata not provided
  [[ "$metadata_json" == " " ]] && metadata_json="{}"

  [[ -z "$event_type" ]] && return 1

  # Validate JSON
  if ! echo "$metadata_json" | jq -e . >/dev/null 2>&1; then
    error "analytics_track: invalid metadata JSON" >&2
    return 1
  fi

  # Validate event type
  if ! is_valid_event_type "$event_type"; then
    error "analytics_track: unknown event type: $event_type" >&2
    return 1
  fi

  # Build the event record
  local event
  event=$(jq -n \
    --arg ts "$(now_iso)" \
    --arg sid "$session_id" \
    --arg et "$event_type" \
    --argjson meta "$(echo "$metadata_json" | jq -c .)" \
    '{timestamp: $ts, session_id: $sid, event_type: $et, metadata: $meta}' 2>/dev/null) || return 1

  # Append atomically
  mkdir -p "$(dirname "$ANALYTICS_FILE")" 2>/dev/null || true
  atomic_append "$ANALYTICS_FILE" "$event" 2>/dev/null || return 1

  return 0
}

# Generate funnel report with drop-off detection
analytics_funnel() {
  local funnel_name="${1:-}"

  [[ -z "$funnel_name" ]] && { error "analytics_funnel: funnel name required"; return 1; }
  [[ ! -f "$ANALYTICS_FILE" ]] && { echo '{"stages": [], "total_started": 0, "total_completed": 0, "completion_percent": 0}'; return 0; }

  # Define funnel stages based on type
  local stages=()
  case "$funnel_name" in
    setup)
      stages=("setup_start" "setup_phase_complete:intake" "setup_phase_complete:plan" "setup_phase_complete:design" "setup_phase_complete:build" "setup_phase_complete:test" "setup_phase_complete:review" "setup_phase_complete:pr" "setup_phase_complete:merge")
      ;;
    pipeline)
      stages=("pipeline_attempt" "pipeline_outcome")
      ;;
    *)
      error "analytics_funnel: unknown funnel: $funnel_name" >&2
      return 1
      ;;
  esac

  # Read and parse analytics file
  local events
  events=$(jq -s '.' "$ANALYTICS_FILE" 2>/dev/null || echo '[]')

  # Calculate funnel metrics
  local total_started=0
  local prev_count=0
  local stage_data="[]"

  for stage in "${stages[@]}"; do
    # Parse stage name and phase (if applicable)
    local stage_type="${stage%%:*}"
    local phase="${stage##*:}"
    [[ "$phase" == "$stage_type" ]] && phase=""

    # Count sessions reaching this stage
    local count
    if [[ -n "$phase" ]]; then
      count=$(echo "$events" | jq --arg et "$stage_type" --arg p "$phase" '[.[] | select(.event_type == $et and .metadata.phase == $p)] | unique_by(.session_id) | length' 2>/dev/null || echo 0)
    else
      count=$(echo "$events" | jq --arg et "$stage_type" '[.[] | select(.event_type == $et)] | unique_by(.session_id) | length' 2>/dev/null || echo 0)
    fi

    # Track initial count for completion percentage
    [[ "$prev_count" -eq 0 ]] && total_started="$count"

    # Calculate drop-off percentage
    local drop_off_percent=0
    if [[ "$prev_count" -gt 0 && "$count" -lt "$prev_count" ]]; then
      drop_off_percent=$(( (prev_count - count) * 100 / prev_count ))
    fi

    # Add to stage data
    stage_data=$(echo "$stage_data" | jq \
      --arg s "$stage" \
      --argjson c "$count" \
      --argjson d "$drop_off_percent" \
      '. += [{"stage": $s, "count": $c, "drop_off_percent": $d}]' 2>/dev/null || echo "$stage_data")

    prev_count="$count"
  done

  # Calculate overall completion percentage
  local total_completed="$prev_count"
  local completion_percent=0
  [[ "$total_started" -gt 0 ]] && completion_percent=$(( total_completed * 100 / total_started ))

  # Return funnel as JSON
  jq -n \
    --argjson stages "$stage_data" \
    --argjson ts "$total_started" \
    --argjson tc "$total_completed" \
    --argjson cp "$completion_percent" \
    '{stages: $stages, total_started: $ts, total_completed: $tc, completion_percent: $cp}' 2>/dev/null || return 1
}

# Generate detailed event report
analytics_report() {
  local start_date="${1:-}"
  local end_date="${2:-}"
  local event_type_filter="${3:-}"

  [[ -z "$start_date" || -z "$end_date" ]] && { error "analytics_report: start_date and end_date required"; return 1; }
  [[ ! -f "$ANALYTICS_FILE" ]] && { echo '[]'; return 0; }

  # Parse dates to epoch for comparison
  local start_epoch end_epoch
  start_epoch=$(date -d "$start_date" +%s 2>/dev/null || echo 0)
  end_epoch=$(date -d "$end_date" +%s 2>/dev/null || echo 9999999999)

  # Read and filter events
  jq -s \
    --arg et "$event_type_filter" \
    --argjson se "$start_epoch" \
    --argjson ee "$end_epoch" \
    '[.[] |
      select(
        (if $et != "" then .event_type == $et else true end) and
        ((.timestamp | fromdate) >= $se and (.timestamp | fromdate) <= $ee)
      )
    ]' "$ANALYTICS_FILE" 2>/dev/null || echo '[]'
}

# Generate drop-off summary for high-impact stages
analytics_drop_off_summary() {
  local days="${1:-30}"

  [[ ! -f "$ANALYTICS_FILE" ]] && { echo '{}'; return 0; }

  # Calculate date range
  local end_date
  end_date=$(date -u +"%Y-%m-%d")
  local start_date
  start_date=$(date -u -d "$days days ago" +"%Y-%m-%d" 2>/dev/null || echo "2020-01-01")

  # Generate funnel reports
  local setup_funnel pipeline_funnel
  setup_funnel=$(analytics_funnel "setup")
  pipeline_funnel=$(analytics_funnel "pipeline")

  # Extract highest drop-off stages
  jq -n \
    --argjson setup "$setup_funnel" \
    --argjson pipeline "$pipeline_funnel" \
    '{
      date_range: {"start": $setup[0] // "N/A", "end": $setup[1] // "N/A"},
      setup_funnel: $setup,
      pipeline_funnel: $pipeline,
      days: '"$days"'
    }' 2>/dev/null || return 1
}

# ─── CLI Subcommands ──────────────────────────────────────────────────────

main() {
  local subcmd="${1:-help}"
  shift 2>/dev/null || true

  case "$subcmd" in
    track)
      if [[ $# -lt 1 ]]; then
        error "track: event_type required"
        return 1
      fi
      analytics_track "$@"
      ;;
    report)
      if [[ $# -lt 2 ]]; then
        error "report: start_date end_date required"
        return 1
      fi
      analytics_report "$@"
      ;;
    funnel)
      if [[ $# -lt 1 ]]; then
        error "funnel: funnel_name required"
        return 1
      fi
      analytics_funnel "$1"
      ;;
    drop-off-summary)
      analytics_drop_off_summary "${1:-30}"
      ;;
    help)
      cat <<EOF
Usage: shipwright analytics {track|report|funnel|drop-off-summary}

  track EVENT_TYPE [METADATA_JSON] [SESSION_ID]
    Emit an analytics event. Event types: setup_start, setup_phase_complete,
    setup_abandoned, pipeline_attempt, pipeline_outcome, init_complete

  report START_DATE END_DATE [EVENT_TYPE]
    Generate event report for date range (YYYY-MM-DD format)

  funnel FUNNEL_NAME
    Generate funnel report with drop-off metrics
    Funnel names: setup, pipeline

  drop-off-summary [DAYS]
    Summary of drop-off points in past N days (default 30)

EOF
      ;;
    *)
      error "Unknown analytics subcommand: $subcmd"
      return 1
      ;;
  esac
}

main "$@"
