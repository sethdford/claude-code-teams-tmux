#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  audit-trail — Structured pipeline audit logging                         ║
# ║                                                                         ║
# ║  Provides JSONL event emission, prompt archiving, and report generation  ║
# ║  for full pipeline lifecycle tracking and post-mortem analysis.          ║
# ║                                                                         ║
# ║  All functions are fail-open: risky operations wrapped with || return 0  ║
# ║  so audit never blocks the pipeline.                                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_AUDIT_TRAIL_LOADED:-}" ]] && return 0
_AUDIT_TRAIL_LOADED=1

# ─── Internal State ──────────────────────────────────────────────────────────
_AUDIT_JSONL=""  # Updated by audit_init from current ARTIFACTS_DIR

# ─── Helper: Build JSON with escaped values ──────────────────────────────────
_audit_escape_json_value() {
  local value="$1"
  # Escape backslashes first, then double quotes
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  echo "$value"
}

# ─── audit_init — Initialize audit trail ────────────────────────────────────
# Creates JSONL file and writes pipeline.start event with metadata.
# Updates _AUDIT_JSONL from current ARTIFACTS_DIR.
#
# Usage: audit_init --issue 42 --goal "..." --template standard --model gpt-4 --git-sha abc123
audit_init() {
  # Parse arguments
  local issue="" goal="" template="" model="" git_sha=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue) issue="$2"; shift 2 ;;
      --goal) goal="$2"; shift 2 ;;
      --template) template="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --git-sha) git_sha="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Update path from current ARTIFACTS_DIR
  _AUDIT_JSONL="${ARTIFACTS_DIR:-/tmp}/pipeline-audit.jsonl"

  # Create directory if needed
  mkdir -p "$(dirname "$_AUDIT_JSONL")" || return 0

  # Emit pipeline.start event
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 0

  # Build JSON with proper escaping
  local json="{\"ts\":\"$ts\",\"type\":\"pipeline.start\""
  [[ -n "$issue" ]] && json="${json},\"issue\":\"$issue\""
  [[ -n "$goal" ]] && {
    goal=$(_audit_escape_json_value "$goal")
    json="${json},\"goal\":\"$goal\""
  }
  [[ -n "$template" ]] && json="${json},\"template\":\"$template\""
  [[ -n "$model" ]] && json="${json},\"model\":\"$model\""
  [[ -n "$git_sha" ]] && json="${json},\"git_sha\":\"$git_sha\""
  json="${json}}"

  # Append to JSONL
  echo "$json" >> "$_AUDIT_JSONL" || return 0
}

# ─── audit_emit — Emit structured event to JSONL ────────────────────────────
# Appends one JSON line with timestamp and key=value pairs.
#
# Usage: audit_emit "stage.complete" "stage=plan" "duration_s=5"
audit_emit() {
  local event_type="$1"
  shift

  # Fail gracefully if JSONL not initialized
  _AUDIT_JSONL="${_AUDIT_JSONL:-${ARTIFACTS_DIR:-/tmp}/pipeline-audit.jsonl}"
  mkdir -p "$(dirname "$_AUDIT_JSONL")" || return 0

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 0

  # Build JSON with event type and timestamp
  local json="{\"ts\":\"$ts\",\"type\":\"$event_type\""

  # Add key=value pairs
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local val="${1#*=}"

    # Escape value
    val=$(_audit_escape_json_value "$val")

    json="${json},\"${key}\":\"${val}\""
    shift
  done

  json="${json}}"

  # Append to JSONL
  echo "$json" >> "$_AUDIT_JSONL" || return 0
}

# ─── audit_save_prompt — Archive prompt for iteration ────────────────────────
# Saves prompt text to $LOG_DIR/iteration-N.prompt.txt for analysis.
#
# Usage: audit_save_prompt "Full prompt text" 1
audit_save_prompt() {
  local prompt_text="$1"
  local iteration="$2"

  LOG_DIR="${LOG_DIR:-/tmp}"
  mkdir -p "$LOG_DIR" || return 0

  local prompt_file="$LOG_DIR/iteration-${iteration}.prompt.txt"
  echo "$prompt_text" > "$prompt_file" || return 0
}

# ─── Helper: Build JSON report from JSONL ───────────────────────────────────
_audit_build_json() {
  local jsonl_file="$1"
  local outcome="$2"

  # Read JSONL and build JSON structure
  # Try using jq if available
  if command -v jq &>/dev/null; then
    jq -s \
      --arg outcome "$outcome" \
      '{
        version: "1.0",
        pipeline_id: (.[0].git_sha // "unknown"),
        issue: (.[0].issue // "unknown"),
        goal: (.[0].goal // "unknown"),
        template: (.[0].template // "unknown"),
        model: (.[0].model // "unknown"),
        outcome: $outcome,
        duration_s: (if .[0].ts and .[-1].ts then
          ((.[-1].ts | fromdate) - (.[0].ts | fromdate))
        else 0 end),
        stages: [
          .[] | select(.type == "stage.complete") |
          {stage: .stage, duration_s: .duration_s}
        ],
        iterations: [
          .[] | select(.type | test("^loop\\.")) |
          {type: .type, iteration: .iteration}
        ]
      }' "$jsonl_file"
  else
    # Fallback without jq: build simpler JSON manually
    local first_line
    first_line=$(head -1 "$jsonl_file" 2>/dev/null)

    local issue goal template model git_sha
    issue=$(echo "$first_line" | grep -o '"issue":"[^"]*' | cut -d'"' -f4 || echo "unknown")
    goal=$(echo "$first_line" | grep -o '"goal":"[^"]*' | cut -d'"' -f4 || echo "unknown")
    template=$(echo "$first_line" | grep -o '"template":"[^"]*' | cut -d'"' -f4 || echo "unknown")
    model=$(echo "$first_line" | grep -o '"model":"[^"]*' | cut -d'"' -f4 || echo "unknown")
    git_sha=$(echo "$first_line" | grep -o '"git_sha":"[^"]*' | cut -d'"' -f4 || echo "unknown")

    # Count stages and iterations manually
    local stage_count iteration_count
    stage_count=$(grep -c '"type":"stage.complete"' "$jsonl_file" || echo "0")
    iteration_count=$(grep -c '"type":"loop.iteration_complete"' "$jsonl_file" || echo "0")

    cat <<EOF
{
  "version": "1.0",
  "pipeline_id": "$git_sha",
  "issue": "$issue",
  "goal": "$goal",
  "template": "$template",
  "model": "$model",
  "outcome": "$outcome",
  "duration_s": 0,
  "stages": $(grep '"type":"stage.complete"' "$jsonl_file" | wc -l),
  "iterations": $(grep '"type":"loop.iteration_complete"' "$jsonl_file" | wc -l)
}
EOF
  fi
}

# ─── Helper: Build markdown report from JSONL ────────────────────────────────
_audit_build_markdown() {
  local jsonl_file="$1"
  local outcome="$2"

  # Read first line for metadata
  local first_line
  first_line=$(head -1 "$jsonl_file" 2>/dev/null || echo "")

  local issue goal template model git_sha
  issue=$(echo "$first_line" | grep -o '"issue":"[^"]*' | cut -d'"' -f4 || echo "unknown")
  goal=$(echo "$first_line" | grep -o '"goal":"[^"]*' | cut -d'"' -f4 || echo "unknown")
  template=$(echo "$first_line" | grep -o '"template":"[^"]*' | cut -d'"' -f4 || echo "unknown")
  model=$(echo "$first_line" | grep -o '"model":"[^"]*' | cut -d'"' -f4 || echo "unknown")
  git_sha=$(echo "$first_line" | grep -o '"git_sha":"[^"]*' | cut -d'"' -f4 || echo "unknown")

  cat <<'EOF'
# Pipeline Audit Report

## Summary

EOF

  cat <<EOF
| Field | Value |
|-------|-------|
| Outcome | $outcome |
| Issue | $issue |
| Goal | $goal |
| Template | $template |
| Model | $model |
| Git SHA | $git_sha |

## Stages

EOF

  grep '"type":"stage.complete"' "$jsonl_file" | while IFS= read -r line; do
    local stage duration
    stage=$(echo "$line" | grep -o '"stage":"[^"]*' | cut -d'"' -f4)
    duration=$(echo "$line" | grep -o '"duration_s":"[^"]*' | cut -d'"' -f4)
    echo "- **$stage**: ${duration}s"
  done

  cat <<'EOF'

## Build Loop

EOF

  grep '"type":"loop.iteration_complete"' "$jsonl_file" | while IFS= read -r line; do
    local iteration
    iteration=$(echo "$line" | grep -o '"iteration":"[^"]*' | cut -d'"' -f4)
    echo "- Iteration $iteration completed"
  done

  # Compound audit findings section
  local compound_events
  compound_events=$(grep '"type":"compound.finding"' "$jsonl_file" 2>/dev/null || true)
  if [[ -n "$compound_events" ]]; then
    cat <<'EOF'

## Compound Audit Findings

EOF
    echo "$compound_events" | while IFS= read -r line; do
      local sev file desc
      sev=$(echo "$line" | grep -o '"severity":"[^"]*' | cut -d'"' -f4)
      file=$(echo "$line" | grep -o '"file":"[^"]*' | cut -d'"' -f4)
      desc=$(echo "$line" | grep -o '"description":"[^"]*' | cut -d'"' -f4)
      echo "- **[$sev]** \`$file\`: $desc"
    done

    # Convergence summary
    local converge_line
    converge_line=$(grep '"type":"compound.converged"' "$jsonl_file" 2>/dev/null | tail -1 || true)
    if [[ -n "$converge_line" ]]; then
      local reason cycles
      reason=$(echo "$converge_line" | grep -o '"reason":"[^"]*' | cut -d'"' -f4)
      cycles=$(echo "$converge_line" | grep -o '"total_cycles":"[^"]*' | cut -d'"' -f4)
      echo ""
      echo "**Converged** after ${cycles} cycle(s): ${reason}"
    fi
  fi

  cat <<'EOF'

---

*Report generated by audit-trail*
EOF
}

# ─── audit_finalize — Generate JSON and markdown reports ──────────────────────
# Reads JSONL file and generates structured reports for analysis.
#
# Outputs:
#  - $ARTIFACTS_DIR/pipeline-audit.json: Structured report
#  - $ARTIFACTS_DIR/pipeline-audit.md: Human-readable markdown
#
# Usage: audit_finalize "success" [or "failure"]
audit_finalize() {
  local outcome="${1:-unknown}"

  _AUDIT_JSONL="${_AUDIT_JSONL:-${ARTIFACTS_DIR:-/tmp}/pipeline-audit.jsonl}"

  # Fail gracefully if JSONL doesn't exist
  if [[ ! -f "$_AUDIT_JSONL" ]]; then
    return 0
  fi

  local artifacts_dir
  artifacts_dir=$(dirname "$_AUDIT_JSONL")
  mkdir -p "$artifacts_dir" || return 0

  # Generate JSON report
  _audit_build_json "$_AUDIT_JSONL" "$outcome" > "$artifacts_dir/pipeline-audit.json" 2>/dev/null || return 0

  # Generate markdown report
  _audit_build_markdown "$_AUDIT_JSONL" "$outcome" > "$artifacts_dir/pipeline-audit.md" 2>/dev/null || return 0

  return 0
}
