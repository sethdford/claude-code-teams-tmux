#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  error-actionability — Score and enhance error messages for clarity       ║
# ║                                                                         ║
# ║  Scores errors 0-100 based on actionability cues:                        ║
# ║  - File path present (25 pts)                                            ║
# ║  - Line number present (20 pts)                                          ║
# ║  - Specific error type (20 pts)                                          ║
# ║  - Actionable detail (20 pts)                                            ║
# ║  - Fix suggestion (15 pts)                                               ║
# ║                                                                         ║
# ║  Auto-enhances low-scoring errors (<70) with context.                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.2.4"

# Score an error message for actionability
# Input: error message (string)
# Output: JSON with score, breakdown, and suggestions
score_error_actionability() {
  local error_msg="$1"
  local score=0
  local has_filepath=0
  local has_line_number=0
  local has_error_type=0
  local has_actionable_detail=0
  local has_fix_suggestion=0

  # Check for file path (e.g., /path/to/file.sh, ./scripts/file.sh, scripts/file.sh)
  if [[ $error_msg =~ (/[a-zA-Z0-9._/-]+\.[a-zA-Z]+|\./(scripts|src|lib)/[a-zA-Z0-9._/-]+|scripts/[a-zA-Z0-9._/-]+) ]]; then
    has_filepath=1
    score=$((score + 25))
  fi

  # Check for line number (e.g., :123, line 123, at line 456)
  if [[ $error_msg =~ (:[0-9]+|line [0-9]+|at line [0-9]+) ]]; then
    has_line_number=1
    score=$((score + 20))
  fi

  # Check for specific error types (e.g., TypeError, SyntaxError, ENOENT, EACCES, etc.)
  if [[ $error_msg =~ (Error|Exception|ENOENT|EACCES|EAGAIN|EPERM|EEXIST|EISDIR|TypeError|SyntaxError|ReferenceError|RangeError|AssertionError) ]]; then
    has_error_type=1
    score=$((score + 20))
  fi

  # Check for actionable details (e.g., "cannot read property", "is not a function", "does not exist", "permission denied", "not found")
  if [[ $error_msg =~ (cannot|not found|does not exist|permission denied|not a function|is undefined|is null|unexpected token|invalid|failed to) ]]; then
    has_actionable_detail=1
    score=$((score + 20))
  fi

  # Check for fix suggestions (e.g., "try", "check", "ensure", "verify", "install", "add", "remove")
  if [[ $error_msg =~ (try |check |ensure |verify |install |add |remove |run |use |export |define ) ]]; then
    has_fix_suggestion=1
    score=$((score + 15))
  fi

  # Cap score at 100
  if [[ $score -gt 100 ]]; then
    score=100
  fi

  # Output as JSON
  local json="{
    \"score\": $score,
    \"breakdown\": {
      \"filepath\": $has_filepath,
      \"line_number\": $has_line_number,
      \"error_type\": $has_error_type,
      \"actionable_detail\": $has_actionable_detail,
      \"fix_suggestion\": $has_fix_suggestion
    },
    \"threshold_met\": $([ $score -lt 70 ] && echo "false" || echo "true")
  }"

  echo "$json"
}

# Enhance a low-scoring error with category labels and file context
# Input: error message, optionally the file path and line number
# Output: enhanced error message
enhance_error_message() {
  local error_msg="$1"
  local filepath="${2:-}"
  local line_number="${3:-}"
  local category=""

  # Determine error category
  if [[ $error_msg =~ (cannot read|cannot access|no such file|ENOENT|EACCES|permission denied) ]]; then
    category="FILE_ACCESS"
  elif [[ $error_msg =~ (is not a function|is undefined|cannot call|is not callable) ]]; then
    category="FUNCTION_ERROR"
  elif [[ $error_msg =~ (unexpected token|syntax error|parse error) ]]; then
    category="SYNTAX_ERROR"
  elif [[ $error_msg =~ (type error|is not|expected) ]]; then
    category="TYPE_ERROR"
  elif [[ $error_msg =~ (assertion|assert|expected|failed) ]]; then
    category="ASSERTION_FAILURE"
  elif [[ $error_msg =~ (timeout|timed out|hang|deadlock) ]]; then
    category="TIMEOUT"
  elif [[ $error_msg =~ (out of memory|OOM|memory|stack) ]]; then
    category="MEMORY_ERROR"
  elif [[ $error_msg =~ (network|socket|ECONNREFUSED|ECONNRESET|ETIMEDOUT) ]]; then
    category="NETWORK_ERROR"
  else
    category="UNKNOWN"
  fi

  # Extract file path and line number from error if not provided
  local extracted_filepath=""
  local extracted_line=""

  if [[ -z "$filepath" && $error_msg =~ (/[a-zA-Z0-9._/-]+\.[a-zA-Z]+|\./(scripts|src|lib)/[a-zA-Z0-9._/-]+) ]]; then
    extracted_filepath="${BASH_REMATCH[0]}"
  else
    extracted_filepath="$filepath"
  fi

  if [[ -z "$line_number" && $error_msg =~ (:[0-9]+) ]]; then
    extracted_line="${BASH_REMATCH[1]#:}"
  else
    extracted_line="$line_number"
  fi

  # Build enhanced message
  local enhanced="[${category}] ${error_msg}"

  # Add file context if available
  if [[ -n "$extracted_filepath" ]] && [[ -f "$extracted_filepath" ]]; then
    if [[ -n "$extracted_line" ]] && [[ $extracted_line =~ ^[0-9]+$ ]]; then
      # Show context around the line (2 lines before and after)
      local start_line=$((extracted_line - 2))
      local end_line=$((extracted_line + 2))
      [[ $start_line -lt 1 ]] && start_line=1

      enhanced+=$'\n  Context:  '
      if command -v sed &>/dev/null; then
        enhanced+=$(sed -n "${start_line},${end_line}p" "$extracted_filepath" 2>/dev/null | \
          awk -v target_line="$extracted_line" 'NR==target_line-start+1 {print "  > " $0; next} {print "    " $0}' \
          -v start="$start_line" || echo "")
      fi
    fi
  fi

  echo "$enhanced"
}

# Main entry point: Score and optionally enhance an error
# Usage: eval_error_message "error message" [filepath] [line_number]
eval_error_message() {
  local error_msg="$1"
  local filepath="${2:-}"
  local line_number="${3:-}"

  # Score the error
  local score_json
  score_json=$(score_error_actionability "$error_msg")
  local score
  score=$(echo "$score_json" | grep -o '"score": [0-9]*' | cut -d: -f2 | tr -d ' ')

  # Output score info
  echo "$score_json"

  # If score < 70, enhance the message
  if [[ $score -lt 70 ]]; then
    echo "---ENHANCEMENT---"
    enhance_error_message "$error_msg" "$filepath" "$line_number"
  fi
}

# For simple cases: just get the score
get_error_score() {
  local error_msg="$1"
  local score_json
  score_json=$(score_error_actionability "$error_msg")
  echo "$score_json" | grep -o '"score": [0-9]*' | cut -d: -f2 | tr -d ' '
}

# For testing: check if error needs enhancement
needs_enhancement() {
  local error_msg="$1"
  local score
  score=$(get_error_score "$error_msg")
  [[ $score -lt 70 ]] && return 0 || return 1
}
