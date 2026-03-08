#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   Setup Telemetry & Checkpoint Library
#
#   Provides step-level timing, event emission, and checkpoint
#   save/restore for sw-init.sh, sw-setup.sh, and install.sh.
#
#   Usage:
#     source "$SCRIPT_DIR/lib/setup-telemetry.sh"
#     setup_telemetry_init "$@"          # after flag parsing
#     if setup_step_start "step_id" "description"; then
#       ... do work ...
#       setup_step_end "step_id"
#     fi
#     setup_telemetry_finish
# ═══════════════════════════════════════════════════════════════════

# Double-source guard
[[ -n "${_SW_SETUP_TELEMETRY_LOADED:-}" ]] && return 0
_SW_SETUP_TELEMETRY_LOADED=1

# ─── State ─────────────────────────────────────────────────────────
_SETUP_CHECKPOINT_FILE="${HOME}/.shipwright/setup-checkpoint.json"
_SETUP_RESUME=false
_SETUP_START_EPOCH=0
_SETUP_CURRENT_STEP=""
_SETUP_STEP_START=0
_SETUP_FLAGS=""
_SETUP_COMPLETED_STEPS=""   # newline-separated list of completed step IDs
_SETUP_STEPS_PASSED=0
_SETUP_STEPS_FAILED=0
_SETUP_STEPS_SKIPPED=0
_SETUP_CHECKPOINT_EXPIRY=86400  # 24 hours in seconds

# ─── Helpers (fallbacks if not already loaded) ─────────────────────
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
      local key="${1%%=*}" val="${1#*=}"
      payload="${payload},\"${key}\":\"${val}\""
      shift
    done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
if [[ "$(type -t now_epoch 2>/dev/null)" != "function" ]]; then
  now_epoch() { date +%s; }
fi

# ─── Checkpoint: atomic write ──────────────────────────────────────
_setup_checkpoint_save() {
  mkdir -p "${HOME}/.shipwright"
  local tmp
  tmp=$(mktemp "${HOME}/.shipwright/.setup-checkpoint.XXXXXX") || return 0

  local now_ts
  now_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local elapsed=0
  if [[ $_SETUP_START_EPOCH -gt 0 ]]; then
    elapsed=$(( $(now_epoch) - _SETUP_START_EPOCH ))
  fi

  # Build completed_steps JSON array
  local steps_json="[]"
  if [[ -n "$_SETUP_COMPLETED_STEPS" ]]; then
    steps_json="["
    local first=true
    local _line
    while IFS= read -r _line; do
      [[ -z "$_line" ]] && continue
      if [[ "$first" == "true" ]]; then
        steps_json="${steps_json}\"${_line}\""
        first=false
      else
        steps_json="${steps_json},\"${_line}\""
      fi
    done <<EOF
$_SETUP_COMPLETED_STEPS
EOF
    steps_json="${steps_json}]"
  fi

  local failed_step="${1:-}"
  local error_msg="${2:-}"

  # Use jq if available for proper JSON, otherwise printf
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --argjson version 1 \
      --arg started_at "${_SETUP_STARTED_AT:-$now_ts}" \
      --arg updated_at "$now_ts" \
      --arg flags "$_SETUP_FLAGS" \
      --argjson completed_steps "$steps_json" \
      --arg failed_step "$failed_step" \
      --arg error "$error_msg" \
      --argjson total_duration_s "$elapsed" \
      --argjson steps_passed "$_SETUP_STEPS_PASSED" \
      --argjson steps_failed "$_SETUP_STEPS_FAILED" \
      --argjson steps_skipped "$_SETUP_STEPS_SKIPPED" \
      '{
        version: $version,
        started_at: $started_at,
        updated_at: $updated_at,
        flags: $flags,
        completed_steps: $completed_steps,
        failed_step: (if $failed_step == "" then null else $failed_step end),
        error: (if $error == "" then null else $error end),
        total_duration_s: $total_duration_s,
        steps_passed: $steps_passed,
        steps_failed: $steps_failed,
        steps_skipped: $steps_skipped
      }' > "$tmp" 2>/dev/null
  else
    # printf fallback — valid JSON without jq
    local failed_json="null"
    local error_json="null"
    [[ -n "$failed_step" ]] && failed_json="\"$failed_step\""
    [[ -n "$error_msg" ]] && error_json="\"$error_msg\""
    printf '{"version":1,"started_at":"%s","updated_at":"%s","flags":"%s","completed_steps":%s,"failed_step":%s,"error":%s,"total_duration_s":%d,"steps_passed":%d,"steps_failed":%d,"steps_skipped":%d}\n' \
      "${_SETUP_STARTED_AT:-$now_ts}" "$now_ts" "$_SETUP_FLAGS" "$steps_json" \
      "$failed_json" "$error_json" "$elapsed" \
      "$_SETUP_STEPS_PASSED" "$_SETUP_STEPS_FAILED" "$_SETUP_STEPS_SKIPPED" > "$tmp"
  fi

  mv "$tmp" "$_SETUP_CHECKPOINT_FILE" 2>/dev/null || rm -f "$tmp"
}

# ─── Checkpoint: load ──────────────────────────────────────────────
_setup_checkpoint_load() {
  _SETUP_COMPLETED_STEPS=""

  if [[ ! -f "$_SETUP_CHECKPOINT_FILE" ]]; then
    return 1
  fi

  # Check expiry (24h)
  local file_epoch=0
  if command -v jq >/dev/null 2>&1; then
    local updated_at
    updated_at=$(jq -r '.updated_at // empty' "$_SETUP_CHECKPOINT_FILE" 2>/dev/null)
    if [[ -n "$updated_at" ]]; then
      # Parse ISO date to epoch — portable approach
      file_epoch=$(date -d "$updated_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null || echo "0")
    fi
  fi

  local now
  now=$(now_epoch)
  if [[ $file_epoch -gt 0 ]] && [[ $(( now - file_epoch )) -gt $_SETUP_CHECKPOINT_EXPIRY ]]; then
    return 1  # Expired
  fi

  # Load completed steps
  if command -v jq >/dev/null 2>&1; then
    _SETUP_COMPLETED_STEPS=$(jq -r '.completed_steps[]? // empty' "$_SETUP_CHECKPOINT_FILE" 2>/dev/null)
    _SETUP_STEPS_PASSED=$(jq -r '.steps_passed // 0' "$_SETUP_CHECKPOINT_FILE" 2>/dev/null)
    _SETUP_STEPS_FAILED=$(jq -r '.steps_failed // 0' "$_SETUP_CHECKPOINT_FILE" 2>/dev/null)
    _SETUP_STEPS_SKIPPED=$(jq -r '.steps_skipped // 0' "$_SETUP_CHECKPOINT_FILE" 2>/dev/null)
    _SETUP_STARTED_AT=$(jq -r '.started_at // empty' "$_SETUP_CHECKPOINT_FILE" 2>/dev/null)
  else
    # Basic grep fallback — extract step IDs from JSON array
    _SETUP_COMPLETED_STEPS=$(grep -oE '"[a-z_]+"' "$_SETUP_CHECKPOINT_FILE" 2>/dev/null | tr -d '"' || true)
  fi

  return 0
}

# ─── Check if step already completed ──────────────────────────────
_setup_step_completed() {
  local step_id="$1"
  if [[ -n "$_SETUP_COMPLETED_STEPS" ]]; then
    echo "$_SETUP_COMPLETED_STEPS" | grep -qxF "$step_id" 2>/dev/null
    return $?
  fi
  return 1
}

# ─── Public API ────────────────────────────────────────────────────

# Initialize telemetry session. Call after flag parsing.
# Args: all CLI flags as a string (for checkpoint preservation)
setup_telemetry_init() {
  local flags="$*"
  _SETUP_FLAGS="$flags"
  _SETUP_START_EPOCH=$(now_epoch)
  _SETUP_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  mkdir -p "${HOME}/.shipwright"

  # If --resume and checkpoint exists and not expired, load it
  if [[ "$_SETUP_RESUME" == "true" ]]; then
    if _setup_checkpoint_load; then
      local completed_count=0
      if [[ -n "$_SETUP_COMPLETED_STEPS" ]]; then
        completed_count=$(echo "$_SETUP_COMPLETED_STEPS" | grep -c . || true)
      fi
      emit_event "setup.resumed" "completed_count=$completed_count" || true
      return 0
    fi
    # No valid checkpoint — start fresh
    _SETUP_RESUME=false
  fi

  emit_event "setup.started" "flags=$flags" || true
  _setup_checkpoint_save || true
}

# Begin a setup step. Returns 1 (skip) if step already completed on resume.
# Usage: if setup_step_start "step_id" "description"; then ... fi
setup_step_start() {
  local step_id="$1"
  local description="${2:-$step_id}"

  # Resume mode: skip already-completed steps
  if [[ "$_SETUP_RESUME" == "true" ]] && _setup_step_completed "$step_id"; then
    _SETUP_STEPS_SKIPPED=$((_SETUP_STEPS_SKIPPED + 1))
    emit_event "setup.step" "step=$step_id" "status=skip" "description=$description" || true
    return 1  # Signal caller to skip
  fi

  _SETUP_CURRENT_STEP="$step_id"
  _SETUP_STEP_START=$(now_epoch)
  return 0  # Signal caller to execute
}

# Mark current step as completed successfully.
setup_step_end() {
  local step_id="${1:-$_SETUP_CURRENT_STEP}"
  local duration=0
  if [[ $_SETUP_STEP_START -gt 0 ]]; then
    duration=$(( $(now_epoch) - _SETUP_STEP_START ))
  fi

  # Add to completed list
  if [[ -n "$_SETUP_COMPLETED_STEPS" ]]; then
    _SETUP_COMPLETED_STEPS="${_SETUP_COMPLETED_STEPS}
${step_id}"
  else
    _SETUP_COMPLETED_STEPS="$step_id"
  fi

  _SETUP_STEPS_PASSED=$((_SETUP_STEPS_PASSED + 1))
  _SETUP_CURRENT_STEP=""
  _SETUP_STEP_START=0

  emit_event "setup.step" "step=$step_id" "status=pass" "duration_s=$duration" || true
  _setup_checkpoint_save || true
}

# Mark current step as failed.
setup_step_fail() {
  local step_id="${1:-$_SETUP_CURRENT_STEP}"
  local error_msg="${2:-unknown error}"
  local duration=0
  if [[ $_SETUP_STEP_START -gt 0 ]]; then
    duration=$(( $(now_epoch) - _SETUP_STEP_START ))
  fi

  _SETUP_STEPS_FAILED=$((_SETUP_STEPS_FAILED + 1))
  _SETUP_CURRENT_STEP=""
  _SETUP_STEP_START=0

  emit_event "setup.step" "step=$step_id" "status=fail" "duration_s=$duration" "error=$error_msg" || true
  _setup_checkpoint_save "$step_id" "$error_msg" || true
}

# Finalize telemetry — emit summary event and print timing.
setup_telemetry_finish() {
  local total_duration=0
  if [[ $_SETUP_START_EPOCH -gt 0 ]]; then
    total_duration=$(( $(now_epoch) - _SETUP_START_EPOCH ))
  fi

  emit_event "setup.completed" \
    "total_duration_s=$total_duration" \
    "steps_passed=$_SETUP_STEPS_PASSED" \
    "steps_failed=$_SETUP_STEPS_FAILED" \
    "steps_skipped=$_SETUP_STEPS_SKIPPED" || true

  _setup_checkpoint_save || true
}

# Get the checkpoint file path (for doctor integration)
setup_checkpoint_file() {
  echo "$_SETUP_CHECKPOINT_FILE"
}

# Set resume mode (called from flag parsing in consumer scripts)
setup_set_resume() {
  _SETUP_RESUME=true
}
