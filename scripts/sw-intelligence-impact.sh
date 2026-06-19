#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright intelligence impact — Feature Impact Analyzer & A/B Framework ║
# ║  Controlled A/B comparison of pipeline runs (intelligence on vs off)     ║
# ║  Per-feature ROI scoring · monthly reports · gated config auto-disable    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
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
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# Color constants for tables (helpers may already define these)
: "${CYAN:=$'\033[38;2;0;212;255m'}"
: "${GREEN:=$'\033[38;2;74;222;128m'}"
: "${YELLOW:=$'\033[38;2;250;204;21m'}"
: "${RED:=$'\033[38;2;248;113;113m'}"
: "${DIM:=$'\033[2m'}"
: "${BOLD:=$'\033[1m'}"
: "${RESET:=$'\033[0m'}"

# ─── Storage & constants ─────────────────────────────────────────────────────
SHIPWRIGHT_HOME="${SHIPWRIGHT_HOME:-$HOME/.shipwright}"
IMPACT_FILE="${SW_IMPACT_FILE:-$SHIPWRIGHT_HOME/intelligence-impact.json}"
MAX_EXPERIMENTS=2000

# Significance & scoring constants (env-overridable)
MIN_SAMPLES="${SW_IMPACT_MIN_SAMPLES:-20}"
W_SUCCESS="${SW_IMPACT_W_SUCCESS:-0.6}"
W_COST="${SW_IMPACT_W_COST:-0.25}"
W_DURATION="${SW_IMPACT_W_DURATION:-0.15}"
VALUE_PER_SUCCESS="${SW_IMPACT_VALUE_PER_SUCCESS:-10}"
NOISE_BAND="${SW_IMPACT_NOISE_BAND:-0.01}"

# Feature → config-flag map (single source of truth). Features without a flag
# (convergence, adaptive_timeout, model_routing) are report-only — never disabled.
FEATURE_FLAGS="prediction:intelligence.prediction_enabled
adversarial:intelligence.adversarial_enabled
simulation:intelligence.simulation_enabled
architecture:intelligence.architecture_enabled
composer:intelligence.composer_enabled
optimization:intelligence.optimization_enabled
convergence:
adaptive_timeout:
model_routing:"

_feature_list() { echo "$FEATURE_FLAGS" | awk -F: '{print $1}'; }
_feature_flag() { echo "$FEATURE_FLAGS" | awk -F: -v f="$1" '$1==f{print $2}'; }

_json_error() {
  jq -cn --arg c "$1" --arg m "$2" '{error:{code:$c,message:$m}}'
}

# ─── Store management ────────────────────────────────────────────────────────
ensure_store() {
  mkdir -p "$(dirname "$IMPACT_FILE")"
  if [[ ! -f "$IMPACT_FILE" ]]; then
    local tmp; tmp="$(mktemp "${IMPACT_FILE}.XXXXXX")"
    jq -n --arg ts "$(now_iso)" '{version:"1",updated_at:$ts,experiments:[],report:{}}' > "$tmp"
    mv "$tmp" "$IMPACT_FILE"
  fi
  # Self-heal: if the file is not valid JSON, reinitialize.
  if ! jq -e . "$IMPACT_FILE" >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp "${IMPACT_FILE}.XXXXXX")"
    jq -n --arg ts "$(now_iso)" '{version:"1",updated_at:$ts,experiments:[],report:{}}' > "$tmp"
    mv "$tmp" "$IMPACT_FILE"
  fi
}

# ─── record ──────────────────────────────────────────────────────────────────
# Append one run record. Validates all input at the boundary; atomic write.
cmd_record() {
  local variant="" issue="" goal="" success="" duration="" cost="" iterations=""
  local failure_type="" features="" experiment_id="" json_mode=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --variant) variant="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --goal) goal="${2:-}"; shift 2 ;;
      --success) success="${2:-}"; shift 2 ;;
      --duration) duration="${2:-}"; shift 2 ;;
      --cost) cost="${2:-}"; shift 2 ;;
      --iterations) iterations="${2:-}"; shift 2 ;;
      --failure-type) failure_type="${2:-}"; shift 2 ;;
      --features) features="${2:-}"; shift 2 ;;
      --experiment-id) experiment_id="${2:-}"; shift 2 ;;
      --json) json_mode=1; shift ;;
      *) error "Unknown record option: $1"; return 2 ;;
    esac
  done

  # Validation (boundary)
  if [[ "$variant" != "intel_on" && "$variant" != "intel_off" ]]; then
    [[ $json_mode -eq 1 ]] && _json_error "BAD_INPUT" "--variant must be intel_on or intel_off" || error "--variant must be intel_on or intel_off (got: '$variant')"
    return 2
  fi
  if [[ "$success" != "true" && "$success" != "false" ]]; then
    [[ $json_mode -eq 1 ]] && _json_error "BAD_INPUT" "--success must be true or false" || error "--success must be true or false (got: '$success')"
    return 2
  fi
  : "${duration:=0}"; : "${cost:=0}"; : "${iterations:=0}"
  if ! [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    [[ $json_mode -eq 1 ]] && _json_error "BAD_INPUT" "--duration must be numeric" || error "--duration must be numeric (got: '$duration')"
    return 2
  fi
  if ! [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    [[ $json_mode -eq 1 ]] && _json_error "BAD_INPUT" "--cost must be numeric" || error "--cost must be numeric (got: '$cost')"
    return 2
  fi
  if ! [[ "$iterations" =~ ^[0-9]+$ ]]; then
    [[ $json_mode -eq 1 ]] && _json_error "BAD_INPUT" "--iterations must be an integer" || error "--iterations must be an integer (got: '$iterations')"
    return 2
  fi

  ensure_store
  local epoch; epoch="$(now_epoch)"
  [[ -z "$experiment_id" ]] && experiment_id="exp-${epoch}-${issue:-na}"

  # Build features JSON array from CSV (never eval).
  local features_json="[]"
  if [[ -n "$features" ]]; then
    features_json="$(echo "$features" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')"
  fi

  local tmp; tmp="$(mktemp "${IMPACT_FILE}.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  jq \
    --arg eid "$experiment_id" --arg issue "$issue" --arg goal "$goal" \
    --arg variant "$variant" --argjson features "$features_json" \
    --argjson success "$success" --argjson duration "$duration" \
    --argjson cost "$cost" --argjson iterations "$iterations" \
    --arg ftype "$failure_type" --argjson epoch "$epoch" \
    --arg ts "$(now_iso)" --argjson cap "$MAX_EXPERIMENTS" '
    .updated_at = $ts
    | .experiments += [{
        experiment_id:$eid, issue:$issue, goal:$goal, variant:$variant,
        features:$features, success:$success, duration_s:$duration,
        cost_usd:$cost, iterations:$iterations, failure_type:$ftype,
        ts_epoch:$epoch, ts:$ts
      }]
    | .experiments |= (if (length > $cap) then .[-($cap):] else . end)
  ' "$IMPACT_FILE" > "$tmp"
  # Validate parse before commit.
  jq -e . "$tmp" >/dev/null 2>&1 || { error "record: produced invalid JSON, aborting write"; return 1; }
  mv "$tmp" "$IMPACT_FILE"
  trap - RETURN

  emit_event "intelligence_impact_record" "variant=$variant" "issue=${issue:-na}" "success=$success" >/dev/null 2>&1 || true
  if [[ $json_mode -eq 1 ]]; then
    jq -cn --arg eid "$experiment_id" --arg v "$variant" '{ok:true,experiment_id:$eid,variant:$v}'
  else
    success "Recorded $variant run for issue ${issue:-na} (experiment $experiment_id)"
  fi
  return 0
}

# ─── Statistics ──────────────────────────────────────────────────────────────
# Reads a JSON array of experiment records on stdin, emits a stats object.
_stats_from_array() {
  jq -c '
    . as $c | ($c|length) as $n
    | { n:$n,
        success_rate: (if $n==0 then 0 else (($c|map(select(.success==true))|length)/$n) end),
        mean_duration: (if $n==0 then 0 else (($c|map(.duration_s)|add)/$n) end),
        mean_cost: (if $n==0 then 0 else (($c|map(.cost_usd)|add)/$n) end),
        mean_iterations: (if $n==0 then 0 else (($c|map(.iterations)|add)/$n) end),
        failure_types: ($c|map(select(.success==false)|.failure_type)
                          |map(select(. != "" and . != null))
                          |group_by(.)|map({key:.[0],value:length})|from_entries)
      }'
}

# Cohort stats for a variant across the (already filtered) experiment list file.
_cohort_variant() {
  local file="$1" variant="$2"
  jq -c --arg v "$variant" '[.experiments[]|select(.variant==$v)]' "$file" | _stats_from_array
}

# Feature A/B: runs WITH the feature vs runs WITHOUT it.
_cohort_feature() {
  local file="$1" feat="$2" mode="$3"  # mode: on|off
  if [[ "$mode" == "on" ]]; then
    jq -c --arg f "$feat" '[.experiments[]|select((.features//[])|index($f))]' "$file" | _stats_from_array
  else
    jq -c --arg f "$feat" '[.experiments[]|select(((.features//[])|index($f))|not)]' "$file" | _stats_from_array
  fi
}

# Score a single feature given on-stats and off-stats JSON.
_score_one() {
  local feat="$1" on="$2" off="$3" flag
  flag="$(_feature_flag "$feat")"
  jq -cn --arg feat "$feat" --arg flag "$flag" \
     --argjson on "$on" --argjson off "$off" \
     --argjson ws "$W_SUCCESS" --argjson wc "$W_COST" --argjson wd "$W_DURATION" \
     --argjson vps "$VALUE_PER_SUCCESS" --argjson noise "$NOISE_BAND" --argjson minN "$MIN_SAMPLES" '
    ($on.success_rate - $off.success_rate) as $dsucc
    | ($on.mean_cost - $off.mean_cost) as $dcost
    | ($on.mean_duration - $off.mean_duration) as $ddur
    | (if $off.mean_cost>0 then $dcost/$off.mean_cost else 0 end) as $dcost_n
    | (if $off.mean_duration>0 then $ddur/$off.mean_duration else 0 end) as $ddur_n
    | ($ws*$dsucc - $wc*$dcost_n - $wd*$ddur_n) as $impact
    | ($dsucc*$vps) as $vgain
    | (if $dcost>0 then ($vgain-$dcost)/$dcost elif $vgain>0 then 999 elif $vgain<0 then -999 else 0 end) as $roi
    | (($on.n>=$minN and $off.n>=$minN)) as $sig
    | (if (($on.n + $off.n)==0) then "INCONCLUSIVE"
        elif ($impact > $noise) then "KEEP"
        elif ($impact < (-$noise) and $roi<0 and $sig and ($flag != "")) then "DISABLE"
        else "INCONCLUSIVE" end) as $rec
    | { feature:$feat, flag:$flag, n_on:$on.n, n_off:$off.n,
        delta_success_rate:(($dsucc*10000|round)/10000),
        delta_cost:(($dcost*10000|round)/10000),
        delta_duration:(($ddur*100|round)/100),
        impact:(($impact*10000|round)/10000),
        roi:(($roi*100|round)/100),
        significant:$sig, recommendation:$rec }'
}

# Produce the full feature-score array (JSON) over the given store file.
score_features() {
  local file="$1" feat on off scores="[]"
  while IFS= read -r feat; do
    [[ -z "$feat" ]] && continue
    on="$(_cohort_feature "$file" "$feat" on)"
    off="$(_cohort_feature "$file" "$feat" off)"
    local one; one="$(_score_one "$feat" "$on" "$off")"
    scores="$(jq -c --argjson s "$one" '. + [$s]' <<<"$scores")"
  done < <(_feature_list)
  echo "$scores"
}

# ─── analyze ─────────────────────────────────────────────────────────────────
cmd_analyze() {
  local json_mode=0 since=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      --since) since="${2:-}"; shift 2 ;;
      *) error "Unknown analyze option: $1"; return 2 ;;
    esac
  done
  ensure_store

  # Optional time window: keep experiments newer than (now - since days).
  local work="$IMPACT_FILE"
  if [[ -n "$since" ]]; then
    if ! [[ "$since" =~ ^[0-9]+$ ]]; then error "--since must be an integer (days)"; return 2; fi
    local cutoff; cutoff=$(( $(now_epoch) - since*86400 ))
    work="$(mktemp "${TMPDIR:-/tmp}/sw-impact-window.XXXXXX")"
    jq --argjson c "$cutoff" '.experiments |= map(select(.ts_epoch >= $c))' "$IMPACT_FILE" > "$work"
  fi

  local total; total="$(jq '.experiments|length' "$work")"
  if [[ "$total" -eq 0 ]]; then
    [[ -n "$since" ]] && rm -f "$work"
    [[ $json_mode -eq 1 ]] && _json_error "NO_DATA" "no experiments recorded yet" || error "No experiments recorded yet. Run pipelines or 'intelligence impact record ...' first."
    return 3
  fi

  local on off scores
  on="$(_cohort_variant "$work" intel_on)"
  off="$(_cohort_variant "$work" intel_off)"
  scores="$(score_features "$work")"

  if [[ $json_mode -eq 1 ]]; then
    jq -cn --argjson on "$on" --argjson off "$off" --argjson feats "$scores" \
       --arg ts "$(now_iso)" --argjson total "$total" \
       '{generated_at:$ts, total_runs:$total, cohorts:{intel_on:$on, intel_off:$off}, features:$feats}'
  else
    _render_analysis "$on" "$off" "$scores" "$total"
  fi
  [[ -n "$since" ]] && rm -f "$work"
  return 0
}

_fmt_pct() { jq -rn --argjson v "$1" '(($v*1000|round)/10|tostring) + "%"'; }
_fmt_num() { jq -rn --argjson v "$1" '(($v*100|round)/100|tostring)'; }

_render_analysis() {
  local on="$1" off="$2" scores="$3" total="$4"
  echo ""
  echo -e "${CYAN}${BOLD}  Intelligence Feature Impact Analysis${RESET}"
  echo -e "${DIM}  ══════════════════════════════════════════════════════════${RESET}"
  echo ""
  local n_on n_off
  n_on="$(jq -r '.n' <<<"$on")"; n_off="$(jq -r '.n' <<<"$off")"
  echo -e "  ${BOLD}Cohorts${RESET} (total runs: $total)"
  printf "    %-12s %-8s %-10s %-10s %-10s\n" "variant" "n" "success" "mean_cost" "mean_dur"
  printf "    %-12s %-8s %-10s %-10s %-10s\n" "intel_on"  "$n_on"  "$(_fmt_pct "$(jq .success_rate <<<"$on")")"  "\$$(_fmt_num "$(jq .mean_cost <<<"$on")")"  "$(_fmt_num "$(jq .mean_duration <<<"$on")")s"
  printf "    %-12s %-8s %-10s %-10s %-10s\n" "intel_off" "$n_off" "$(_fmt_pct "$(jq .success_rate <<<"$off")")" "\$$(_fmt_num "$(jq .mean_cost <<<"$off")")" "$(_fmt_num "$(jq .mean_duration <<<"$off")")s"
  echo ""
  echo -e "  ${BOLD}Per-feature impact${RESET}"
  printf "    %-16s %-8s %-8s %-10s %-8s %-14s\n" "feature" "n_on" "n_off" "impact" "roi" "recommendation"
  local rows; rows="$(jq -r '.[] | [.feature,.n_on,.n_off,.impact,.roi,.recommendation] | @tsv' <<<"$scores")"
  local feature n_on_f n_off_f impact roi rec color
  while IFS=$'\t' read -r feature n_on_f n_off_f impact roi rec; do
    [[ -z "$feature" ]] && continue
    case "$rec" in
      KEEP) color="$GREEN" ;;
      DISABLE) color="$RED" ;;
      *) color="$YELLOW" ;;
    esac
    printf "    %-16s %-8s %-8s %-10s %-8s ${color}%-14s${RESET}\n" "$feature" "$n_on_f" "$n_off_f" "$impact" "$roi" "$rec"
  done <<<"$rows"
  echo ""
  if [[ "$n_on" -lt "$MIN_SAMPLES" || "$n_off" -lt "$MIN_SAMPLES" ]]; then
    warn "ADVISORY — insufficient data (intel_on=$n_on, intel_off=$n_off; need >=$MIN_SAMPLES per cohort for auto-disable)"
  fi
}

# ─── report ──────────────────────────────────────────────────────────────────
cmd_report() {
  local json_mode=0 month=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      --month) month="${2:-}"; shift 2 ;;
      *) error "Unknown report option: $1"; return 2 ;;
    esac
  done
  ensure_store
  [[ -z "$month" ]] && month="$(date -u +%Y-%m)"
  if ! [[ "$month" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then error "--month must be YYYY-MM"; return 2; fi

  # Filter experiments to the requested month (by ts prefix).
  local work; work="$(mktemp "${TMPDIR:-/tmp}/sw-impact-month.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$work'" RETURN
  jq --arg m "$month" '.experiments |= map(select((.ts // "") | startswith($m)))' "$IMPACT_FILE" > "$work"

  local total; total="$(jq '.experiments|length' "$work")"
  if [[ "$total" -eq 0 ]]; then
    [[ $json_mode -eq 1 ]] && _json_error "NO_DATA" "no experiments in $month" || error "No experiments recorded in $month."
    return 3
  fi

  local on off scores verdict
  on="$(_cohort_variant "$work" intel_on)"
  off="$(_cohort_variant "$work" intel_off)"
  scores="$(score_features "$work")"
  local n_on n_off
  n_on="$(jq -r '.n' <<<"$on")"; n_off="$(jq -r '.n' <<<"$off")"
  if [[ "$n_on" -ge "$MIN_SAMPLES" && "$n_off" -ge "$MIN_SAMPLES" ]]; then
    verdict="significant"
  else
    verdict="advisory"
  fi

  local report_json
  report_json="$(jq -cn --arg month "$month" --arg ts "$(now_iso)" --argjson total "$total" \
    --argjson on "$on" --argjson off "$off" --argjson feats "$scores" --arg verdict "$verdict" \
    '{month:$month, generated_at:$ts, total_runs:$total, verdict:$verdict,
      cohorts:{intel_on:$on,intel_off:$off}, features:$feats}')"

  # Cache the report into the persistent store (atomic).
  local tmp; tmp="$(mktemp "${IMPACT_FILE}.XXXXXX")"
  jq --argjson r "$report_json" '.report = $r' "$IMPACT_FILE" > "$tmp" && mv "$tmp" "$IMPACT_FILE" || rm -f "$tmp"

  emit_event "intelligence_impact_report" "month=$month" "verdict=$verdict" "runs=$total" >/dev/null 2>&1 || true

  if [[ $json_mode -eq 1 ]]; then
    echo "$report_json"
  else
    _render_analysis "$on" "$off" "$scores" "$total"
    echo -e "  ${BOLD}Monthly report${RESET}: $month — verdict: ${BOLD}$verdict${RESET}"
    local disables; disables="$(jq -r '[.[]|select(.recommendation=="DISABLE")|.feature]|join(", ")' <<<"$scores")"
    if [[ -n "$disables" ]]; then
      warn "Negative-ROI features eligible for auto-disable: $disables"
      echo -e "  ${DIM}Run 'shipwright intelligence impact apply' to disable (or --dry-run to preview).${RESET}"
    else
      success "No features recommended for disable this period."
    fi
    echo ""
  fi
  return 0
}

# ─── config discovery ────────────────────────────────────────────────────────
_find_daemon_config() {
  if [[ -n "${SW_DAEMON_CONFIG:-}" ]]; then echo "$SW_DAEMON_CONFIG"; return 0; fi
  local cfg
  for cfg in \
    "$(git rev-parse --show-toplevel 2>/dev/null)/.claude/daemon-config.json" \
    "$(pwd)/.claude/daemon-config.json" \
    "${REPO_DIR}/.claude/daemon-config.json"; do
    [[ -n "$cfg" && -f "$cfg" ]] && { echo "$cfg"; return 0; }
  done
  return 1
}

# ─── apply ───────────────────────────────────────────────────────────────────
# Auto-disable negative-ROI features in daemon-config.json. Gated on n>=MIN.
cmd_apply() {
  local dry_run=0 json_mode=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --json) json_mode=1; shift ;;
      *) error "Unknown apply option: $1"; return 2 ;;
    esac
  done
  ensure_store

  local on off n_on n_off scores
  on="$(_cohort_variant "$IMPACT_FILE" intel_on)"
  off="$(_cohort_variant "$IMPACT_FILE" intel_off)"
  n_on="$(jq -r '.n' <<<"$on")"; n_off="$(jq -r '.n' <<<"$off")"

  if [[ "$n_on" -lt "$MIN_SAMPLES" || "$n_off" -lt "$MIN_SAMPLES" ]]; then
    [[ $json_mode -eq 1 ]] && _json_error "INSUFFICIENT_DATA" "need >=$MIN_SAMPLES runs per cohort, have on=$n_on off=$n_off" \
      || error "Insufficient data: need >=$MIN_SAMPLES runs per cohort (have intel_on=$n_on, intel_off=$n_off). No changes made."
    return 3
  fi

  scores="$(score_features "$IMPACT_FILE")"
  local disable_feats; disable_feats="$(jq -r '[.[]|select(.recommendation=="DISABLE" and .flag!="")]' <<<"$scores")"
  local count; count="$(jq 'length' <<<"$disable_feats")"

  if [[ "$count" -eq 0 ]]; then
    [[ $json_mode -eq 1 ]] && jq -cn '{ok:true,disabled:[],message:"no negative-ROI features to disable"}' \
      || success "No negative-ROI features to disable — config unchanged."
    return 0
  fi

  local config; config="$(_find_daemon_config)" || { \
    [[ $json_mode -eq 1 ]] && _json_error "CONFIG_WRITE_FAILED" "daemon-config.json not found" || error "daemon-config.json not found."; return 3; }

  if [[ $dry_run -eq 1 ]]; then
    if [[ $json_mode -eq 1 ]]; then
      jq -cn --argjson d "$disable_feats" --arg cfg "$config" '{ok:true,dry_run:true,config:$cfg,would_disable:[$d[]|{feature:.feature,flag:.flag,impact:.impact,roi:.roi}]}'
    else
      warn "DRY RUN — no changes will be written to $config"
      jq -r '.[] | "  • \(.feature) (\(.flag)) — impact \(.impact), roi \(.roi)"' <<<"$disable_feats"
    fi
    return 0
  fi

  # Backup before first write.
  local backup="${config}.impact-bak"
  cp "$config" "$backup"

  # Build the jq program: set each flag to false + write an explanatory note.
  local tmp; tmp="$(mktemp "${config}.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  local feat flag impact roi
  cp "$config" "$tmp"
  while IFS=$'\t' read -r feat flag impact roi; do
    [[ -z "$feat" ]] && continue
    local parent="${flag%.*}" leaf="${flag##*.}"
    local out; out="$(mktemp "${config}.XXXXXX")"
    jq --arg parent "$parent" --arg leaf "$leaf" --arg feat "$feat" \
       --argjson impact "$impact" --argjson roi "$roi" --arg ts "$(now_iso)" \
       --argjson non "$n_on" --argjson noff "$n_off" '
       .[$parent] = ((.[$parent] // {}) | .[$leaf] = false)
       | .[$parent].intelligence_impact_notes = ((.[$parent].intelligence_impact_notes // {}) | .[$feat] = {
           disabled_at:$ts, reason:"negative ROI", impact:$impact, roi:$roi, n_on:$non, n_off:$noff
         })
    ' "$tmp" > "$out" && mv "$out" "$tmp" || { rm -f "$out"; error "apply: jq failed for $feat"; return 1; }
  done < <(jq -r '.[] | [.feature,.flag,.impact,.roi] | @tsv' <<<"$disable_feats")

  # Validate parse before commit.
  jq -e . "$tmp" >/dev/null 2>&1 || { error "apply: produced invalid config, aborting (backup at $backup)"; return 1; }
  mv "$tmp" "$config"
  trap - RETURN

  emit_event "intelligence_impact_apply" "disabled=$count" "n_on=$n_on" "n_off=$n_off" >/dev/null 2>&1 || true

  if [[ $json_mode -eq 1 ]]; then
    jq -cn --argjson d "$disable_feats" --arg cfg "$config" --arg bak "$backup" \
      '{ok:true,config:$cfg,backup:$bak,disabled:[$d[]|{feature:.feature,flag:.flag,impact:.impact,roi:.roi}]}'
  else
    success "Disabled $count negative-ROI feature(s) in $config"
    echo -e "  ${DIM}Backup written to $backup${RESET}"
    jq -r '.[] | "  • \(.feature): set \(.flag)=false (impact \(.impact), roi \(.roi))"' <<<"$disable_feats"
    echo -e "  ${DIM}Re-enable by editing the flag back to true; see intelligence_impact_notes for rationale.${RESET}"
  fi
  return 0
}

# ─── run-pair ────────────────────────────────────────────────────────────────
# Active A/B harness: run the same issue/goal twice (intel on, then off), with a
# shared experiment_id, and record both variants.
cmd_run_pair() {
  local issue="" goal="" local_flag="" json_mode=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue) issue="${2:-}"; shift 2 ;;
      --goal) goal="${2:-}"; shift 2 ;;
      --local) local_flag="--local"; shift ;;
      --json) json_mode=1; shift ;;
      *) error "Unknown run-pair option: $1"; return 2 ;;
    esac
  done
  if [[ -z "$issue" && -z "$goal" ]]; then
    error "run-pair requires --issue <id> or --goal \"...\""
    return 2
  fi

  local pipeline="$SCRIPT_DIR/sw-pipeline.sh"
  if [[ ! -x "$pipeline" && ! -f "$pipeline" ]]; then
    error "sw-pipeline.sh not found at $pipeline"
    return 1
  fi

  local experiment_id="exp-$(now_epoch)-${issue:-goal}"
  local rc=0 variant on_off
  for on_off in intel_on intel_off; do
    local intel_env="true"
    [[ "$on_off" == "intel_off" ]] && intel_env="false"
    info "run-pair: executing variant $on_off (experiment $experiment_id)"

    local start end dur run_rc=0
    start="$(now_epoch)"
    local args=(start)
    [[ -n "$issue" ]] && args+=(--issue "$issue")
    [[ -n "$goal" ]] && args+=(--goal "$goal")
    [[ -n "$local_flag" ]] && args+=("$local_flag")
    # Force intelligence on/off for this run via env override consumed by the pipeline.
    SW_INTELLIGENCE_ENABLED="$intel_env" INTELLIGENCE_ENABLED="$intel_env" \
      bash "$pipeline" "${args[@]}" >/dev/null 2>&1 || run_rc=$?
    end="$(now_epoch)"; dur=$((end - start))

    local succ="true"; [[ $run_rc -ne 0 ]] && succ="false"
    [[ $run_rc -ne 0 ]] && rc=1
    local ftype=""; [[ "$succ" == "false" ]] && ftype="pipeline_failure"

    cmd_record --variant "$on_off" --issue "$issue" --goal "$goal" \
      --success "$succ" --duration "$dur" --cost 0 --iterations 0 \
      --failure-type "$ftype" --experiment-id "$experiment_id" \
      --features "$([ "$on_off" = "intel_on" ] && echo "prediction,adversarial,simulation,architecture,composer,optimization,convergence,adaptive_timeout,model_routing" || echo "")" \
      >/dev/null 2>&1 || true
  done

  if [[ $json_mode -eq 1 ]]; then
    jq -cn --arg eid "$experiment_id" --argjson rc "$rc" '{ok:($rc==0),experiment_id:$eid}'
  else
    if [[ $rc -eq 0 ]]; then
      success "run-pair complete (experiment $experiment_id) — both variants recorded"
    else
      warn "run-pair complete with at least one pipeline failure (experiment $experiment_id)"
    fi
  fi
  return "$rc"
}

# ─── status ──────────────────────────────────────────────────────────────────
cmd_status() {
  local json_mode=0
  [[ "${1:-}" == "--json" ]] && json_mode=1
  ensure_store
  local total on_n off_n last_report
  total="$(jq '.experiments|length' "$IMPACT_FILE")"
  on_n="$(jq '[.experiments[]|select(.variant=="intel_on")]|length' "$IMPACT_FILE")"
  off_n="$(jq '[.experiments[]|select(.variant=="intel_off")]|length' "$IMPACT_FILE")"
  last_report="$(jq -r '.report.month // "none"' "$IMPACT_FILE")"
  if [[ $json_mode -eq 1 ]]; then
    jq -cn --arg file "$IMPACT_FILE" --argjson total "$total" --argjson on "$on_n" \
       --argjson off "$off_n" --arg lr "$last_report" --argjson minN "$MIN_SAMPLES" \
       '{store:$file,total_runs:$total,intel_on:$on,intel_off:$off,last_report_month:$lr,min_samples:$minN}'
  else
    echo ""
    echo -e "${CYAN}${BOLD}  Intelligence Impact — Store Status${RESET}"
    echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
    echo -e "  Store:        ${DIM}$IMPACT_FILE${RESET}"
    echo -e "  Total runs:   $total"
    echo -e "  intel_on:     $on_n"
    echo -e "  intel_off:    $off_n"
    echo -e "  Threshold:    >=$MIN_SAMPLES per cohort for auto-disable"
    echo -e "  Last report:  $last_report"
    echo ""
    if [[ "$on_n" -ge "$MIN_SAMPLES" && "$off_n" -ge "$MIN_SAMPLES" ]]; then
      success "Sufficient data for significant analysis."
    else
      warn "Below significance threshold — analysis is advisory only."
    fi
    echo ""
  fi
}

# ─── help ────────────────────────────────────────────────────────────────────
show_help() {
  echo ""
  echo -e "${CYAN}${BOLD}shipwright intelligence impact${RESET} — Feature Impact Analyzer & A/B Framework"
  echo ""
  echo -e "${BOLD}USAGE${RESET}"
  echo -e "  shipwright intelligence impact <subcommand> [options]"
  echo ""
  echo -e "${BOLD}SUBCOMMANDS${RESET}"
  echo -e "  ${CYAN}record${RESET}    --variant <intel_on|intel_off> --issue <id> --success <bool>"
  echo -e "            --duration <s> --cost <usd> --iterations <n> [--failure-type <t>]"
  echo -e "            [--features csv] [--experiment-id <id>]   Append one run record"
  echo -e "  ${CYAN}analyze${RESET}   [--since <days>] [--json]    Cohort comparison + per-feature impact"
  echo -e "  ${CYAN}report${RESET}    [--month <YYYY-MM>] [--json]  Monthly ROI report + recommendations"
  echo -e "  ${CYAN}run-pair${RESET}  --issue <id>|--goal <s> [--local]  Run an issue twice (on/off)"
  echo -e "  ${CYAN}apply${RESET}     [--dry-run] [--json]         Auto-disable negative-ROI features"
  echo -e "  ${CYAN}status${RESET}    [--json]                     Store stats & significance"
  echo -e "  ${CYAN}help${RESET}                                   Show this help"
  echo ""
  echo -e "${BOLD}METHODOLOGY${RESET}"
  echo -e "  Auto-disable requires >=${MIN_SAMPLES} runs per cohort. Features without a config"
  echo -e "  flag (convergence, adaptive_timeout, model_routing) are report-only."
  echo -e "  Full methodology: ${DIM}.claude/docs/intelligence-validation.md${RESET}"
  echo ""
  echo -e "${DIM}Version ${VERSION}${RESET}"
}

# ─── main ────────────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true
  case "$cmd" in
    record)   cmd_record "$@" ;;
    analyze)  cmd_analyze "$@" ;;
    report)   cmd_report "$@" ;;
    run-pair) cmd_run_pair "$@" ;;
    apply)    cmd_apply "$@" ;;
    status)   cmd_status "$@" ;;
    help|--help|-h) show_help ;;
    *) error "Unknown command: $cmd"; show_help; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
