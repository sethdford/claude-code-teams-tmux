#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright sw-test-all — Run every test suite, report the FULL result   ║
# ║  Auto-discovers scripts/*-test.sh · isolates each suite · never aborts   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Why this exists:
#   `npm test` used to be a single `&&` chain of 142 `bash scripts/*-test.sh`
#   invocations. Two structural problems with that:
#     1. The first failing suite aborted the chain, so every suite after it
#        never ran — a green-to-red flip hid the state of ~96 other suites.
#     2. The chain was hand-maintained, so 20 test files on disk were never
#        referenced and therefore never executed at all.
#   This runner auto-discovers suites and runs each one independently, so the
#   summary reflects the whole repo instead of "everything up to the first
#   break".
#
# Usage:
#   bash scripts/sw-test-all.sh                 # all discovered suites
#   bash scripts/sw-test-all.sh --pattern lib   # only suites matching 'lib'
#   bash scripts/sw-test-all.sh --timeout 60    # per-suite limit (default 150s)
#   bash scripts/sw-test-all.sh --jobs 4        # run 4 suites concurrently
#   bash scripts/sw-test-all.sh --list          # print discovered suites, exit
#
# Exit codes: 0 = all suites passed · 1 = at least one failed or timed out

set -uo pipefail   # deliberately NOT -e: a failing suite is data, not a crash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (match shipwright theme; disabled when not a TTY) ───────────────
if [[ -t 1 ]]; then
    GREEN='\033[38;2;74;222;128m'; RED='\033[38;2;248;113;113m'
    YELLOW='\033[38;2;250;204;21m'; PURPLE='\033[38;2;168;85;247m'
    DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; PURPLE=''; DIM=''; BOLD=''; RESET=''
fi

# ─── Options ────────────────────────────────────────────────────────────────
TIMEOUT=150
PATTERN=''
JOBS=1
LIST_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
        --pattern) PATTERN="${2:?--pattern needs a value}"; shift 2 ;;
        --jobs)    JOBS="${2:?--jobs needs a value}"; shift 2 ;;
        --list)    LIST_ONLY=1; shift ;;
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

RESULTS_DIR="${TMPDIR:-/tmp}/sw-test-all.$$"
mkdir -p "$RESULTS_DIR/logs"
trap 'rm -rf "$RESULTS_DIR"' EXIT

# ─── Discover suites ────────────────────────────────────────────────────────
# Auto-discovery is the fix for orphaned tests: any scripts/*-test.sh is run,
# so adding a test file is enough to get it executed.
SUITES=()
while IFS= read -r f; do
    [[ -n "$PATTERN" && "$f" != *"$PATTERN"* ]] && continue
    SUITES+=("$f")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name '*-test.sh' -type f | sort)

if [[ ${#SUITES[@]} -eq 0 ]]; then
    echo "no test suites discovered under $SCRIPT_DIR" >&2
    exit 2
fi

if [[ $LIST_ONLY -eq 1 ]]; then
    for s in "${SUITES[@]}"; do echo "$(basename "$s")"; done
    exit 0
fi

# ─── Portable per-suite timeout ─────────────────────────────────────────────
# macOS ships no coreutils `timeout`, and a hung suite must not stall the run.
# A watchdog subshell SIGKILLs the suite if it outlives $TIMEOUT.
run_one() {
    local suite="$1"
    local name; name="$(basename "$suite" .sh)"
    local log="$RESULTS_DIR/logs/$name.log"
    local start end rc dur

    start=$(date +%s)
    bash "$suite" >"$log" 2>&1 &
    local pid=$!
    ( sleep "$TIMEOUT"; kill -9 "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    end=$(date +%s); dur=$((end - start))

    # 137 = SIGKILL. Attribute it to the watchdog only if we actually hit the
    # limit, so a genuine in-suite SIGKILL is still reported as a failure.
    local status
    if [[ $rc -eq 137 && $dur -ge $TIMEOUT ]]; then
        status=TIMEOUT
    elif [[ $rc -eq 0 ]]; then
        status=PASS
    else
        status="FAIL:$rc"
    fi

    printf '%s\t%s\t%s\n' "$name" "$status" "$dur" >>"$RESULTS_DIR/results.tsv"

    case "$status" in
        PASS)    printf "  ${GREEN}✓${RESET} %-46s ${DIM}%ss${RESET}\n" "$name" "$dur" ;;
        TIMEOUT) printf "  ${YELLOW}⧗${RESET} %-46s ${YELLOW}TIMEOUT after %ss${RESET}\n" "$name" "$dur" ;;
        *)       printf "  ${RED}✗${RESET} %-46s ${RED}exit %s${RESET} ${DIM}%ss${RESET}\n" "$name" "$rc" "$dur" ;;
    esac
}

# ─── Header ─────────────────────────────────────────────────────────────────
printf "\n${PURPLE}${BOLD}  SHIPWRIGHT TEST SUITE${RESET}\n"
printf "${DIM}  ──────────────────────────────────────────${RESET}\n"
printf "${DIM}  %s suites · %ss timeout · %s job(s)${RESET}\n\n" \
    "${#SUITES[@]}" "$TIMEOUT" "$JOBS"

: >"$RESULTS_DIR/results.tsv"
RUN_START=$(date +%s)

if [[ "$JOBS" -gt 1 ]]; then
    # Bounded concurrency: hold at most $JOBS suites in flight.
    for suite in "${SUITES[@]}"; do
        while [[ $(jobs -rp | wc -l) -ge $JOBS ]]; do wait -n 2>/dev/null || sleep 0.2; done
        run_one "$suite" &
    done
    wait
else
    for suite in "${SUITES[@]}"; do run_one "$suite"; done
fi

RUN_END=$(date +%s)

# ─── Summary ────────────────────────────────────────────────────────────────
passed=$(awk -F'\t' '$2=="PASS"'    "$RESULTS_DIR/results.tsv" | wc -l | tr -d ' ')
timedout=$(awk -F'\t' '$2=="TIMEOUT"' "$RESULTS_DIR/results.tsv" | wc -l | tr -d ' ')
failed=$(awk -F'\t' '$2 ~ /^FAIL/'  "$RESULTS_DIR/results.tsv" | wc -l | tr -d ' ')
total=$(wc -l < "$RESULTS_DIR/results.tsv" | tr -d ' ')

printf "\n${DIM}  ══════════════════════════════════════════${RESET}\n\n"
if [[ $failed -gt 0 || $timedout -gt 0 ]]; then
    printf "  ${RED}${BOLD}FAILING SUITES${RESET}\n"
    awk -F'\t' '$2!="PASS" {printf "    %-46s %s\n", $1, $2}' "$RESULTS_DIR/results.tsv"
    printf "\n"
fi
printf "  ${GREEN}${BOLD}%s${RESET} passed  ${RED}${BOLD}%s${RESET} failed  ${YELLOW}${BOLD}%s${RESET} timed out  ${DIM}(%s suites, %ss)${RESET}\n\n" \
    "$passed" "$failed" "$timedout" "$total" "$((RUN_END - RUN_START))"

# Persist the machine-readable result before the EXIT trap clears the temp dir.
if [[ -n "${SW_TEST_REPORT:-}" ]]; then
    cp "$RESULTS_DIR/results.tsv" "$SW_TEST_REPORT" && \
        printf "${DIM}  report: %s${RESET}\n\n" "$SW_TEST_REPORT"
fi

[[ $failed -eq 0 && $timedout -eq 0 ]] || exit 1
exit 0
