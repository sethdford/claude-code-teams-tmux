# Ping Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `shipwright ping` command that prints `pong` to stdout and exits 0.

**Architecture:** Single standalone bash script (`sw-ping.sh`) following the identical pattern as `sw-hello.sh`. Registered in the CLI router (`scripts/sw`) and in the `npm test` suite (`package.json`).

**Tech Stack:** Bash 3.2, existing Shipwright conventions (set -euo pipefail, ERR trap, VERSION constant, fallback helpers).

---

## Design Analysis

### Requirements Clarity

- **Minimum viable change:** `shipwright ping` → prints `pong` → exits 0. Nothing else.
- **Implicit requirements:** Must follow Shipwright shell conventions (VERSION, set -euo pipefail, ERR trap, helpers fallback). Must be testable. Must appear in `npm test`.
- **Acceptance criteria:**
  1. `shipwright ping` outputs exactly `pong` on stdout
  2. Exit code is 0
  3. `shipwright ping --help` / `-h` outputs help text
  4. `shipwright ping --invalid` exits 1
  5. Test suite passes (FAIL: 0)

### Alternatives Considered

**Option A: Standalone script (chosen)**

- New file `scripts/sw-ping.sh` + `scripts/sw-ping-test.sh` + router entry + package.json entry
- Trade-offs: +4 lines in router, +1 line in package.json, 2 new files
- Blast radius: minimal — only adds new files and small modifications
- Matches 100% of existing commands; fully testable in isolation

**Option B: Inline in router**

- Add a `ping)` case in `scripts/sw` that `echo`s `pong` directly without a separate script
- Trade-offs: Untestable in isolation, inconsistent with all other commands, no --help/--version support
- Rejected: architectural debt, no test coverage possible

### Risk Assessment

| Risk                                 | What breaks                        | Mitigation                                                                             |
| ------------------------------------ | ---------------------------------- | -------------------------------------------------------------------------------------- |
| Wrong router position                | Could shadow another command       | Insert before `*)` (wildcard), after `hello)`                                          |
| Package.json test order              | Test fails before others           | Insert after `sw-hello-test.sh` — no ordering dependency                               |
| Output format mismatch               | Test expects `pong`, gets `pong\n` | Shell echo adds newline; test captures with `$()` which strips trailing newline — fine |
| CLAUDE.md AUTO sections become stale | Docs check fails in CI             | Run `shipwright docs sync` after implementation (optional — pipeline handles this)     |

---

## Files to Modify

| Action     | Path                                                                        |
| ---------- | --------------------------------------------------------------------------- |
| **Create** | `scripts/sw-ping.sh`                                                        |
| **Create** | `scripts/sw-ping-test.sh`                                                   |
| **Modify** | `scripts/sw` (lines 605–607: insert `ping)` case after `hello)`)            |
| **Modify** | `package.json` (line 39: insert `sw-ping-test.sh` after `sw-hello-test.sh`) |

---

## Implementation Steps

### Task 1: Create `scripts/sw-ping.sh`

**Files:**

- Create: `scripts/sw-ping.sh`

**Step 1: Write the file**

```bash
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-ping.sh — Ping Command                                               ║
# ║                                                                          ║
# ║  A simple connectivity check command. Prints "pong" to stdout.           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright ping [OPTIONS]

DESCRIPTION
  A simple connectivity check command. Prints "pong" to stdout.

OPTIONS
  --help, -h      Show this help text
  --version, -v   Show version

EXAMPLES
  shipwright ping                  Print "pong"
  shipwright ping --help           Show this help text

EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            echo "$VERSION"
            exit 0
            ;;
        "")
            echo "pong"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
```

**Step 2: Make executable**

```bash
chmod +x scripts/sw-ping.sh
```

**Step 3: Verify basic output**

```bash
bash scripts/sw-ping.sh
```

Expected output: `pong`

**Step 4: Commit**

```bash
git add scripts/sw-ping.sh
git commit -m "feat: add sw-ping.sh command — prints pong to stdout"
```

---

### Task 2: Create `scripts/sw-ping-test.sh`

**Files:**

- Create: `scripts/sw-ping-test.sh`

**Step 1: Write the test file**

```bash
#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-ping-test.sh — Ping Command Test Suite                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code:   $actual"
    fi
}

# ─── Test: ping command outputs "pong" ──────────────────────────────────────
test_ping_output() {
    local output
    output=$("$SCRIPT_DIR/sw-ping.sh")
    assert_equals "pong" "$output" "ping command outputs 'pong'"
}

# ─── Test: ping command exits with 0 ────────────────────────────────────────
test_ping_exit_code() {
    "$SCRIPT_DIR/sw-ping.sh" > /dev/null 2>&1
    assert_exit_code 0 $? "ping command exits with code 0"
}

# ─── Test: ping --help shows help text ──────────────────────────────────────
test_ping_help() {
    local output
    output=$("$SCRIPT_DIR/sw-ping.sh" --help)
    if [[ "$output" =~ "USAGE" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m ping --help displays help text"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m ping --help displays help text"
    fi
}

# ─── Test: ping -h shows help text ───────────────────────────────────────────
test_ping_short_help() {
    local output
    output=$("$SCRIPT_DIR/sw-ping.sh" -h)
    if [[ "$output" =~ "USAGE" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m ping -h displays help text"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m ping -h displays help text"
    fi
}

# ─── Test: ping --version shows version ─────────────────────────────────────
test_ping_version() {
    local output
    output=$("$SCRIPT_DIR/sw-ping.sh" --version)
    if [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m ping --version displays version"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m ping --version displays version"
    fi
}

# ─── Test: ping with invalid option exits non-zero ──────────────────────────
test_ping_invalid_option() {
    "$SCRIPT_DIR/sw-ping.sh" --invalid > /dev/null 2>&1 || local exit_code=$?
    assert_exit_code 1 "${exit_code:-1}" "ping with invalid option exits with code 1"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-ping-test.sh"
test_ping_output
test_ping_exit_code
test_ping_help
test_ping_short_help
test_ping_version
test_ping_invalid_option

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
```

**Step 2: Run the test (should pass since sw-ping.sh already exists)**

```bash
bash scripts/sw-ping-test.sh
```

Expected: `PASS: 6  FAIL: 0`

**Step 3: Commit**

```bash
git add scripts/sw-ping-test.sh
git commit -m "test: add sw-ping-test.sh — 6 tests for ping command"
```

---

### Task 3: Register `ping` in the CLI router (`scripts/sw`)

**Files:**

- Modify: `scripts/sw` (after line 606, before `*)`)

**Step 1: Insert the router entry**

In `scripts/sw`, find the `hello)` case block (currently lines 605–607):

```bash
        hello)
            exec "$SCRIPT_DIR/sw-hello.sh" "$@"
            ;;
```

Insert `ping)` immediately after it, before the `*)` wildcard:

```bash
        hello)
            exec "$SCRIPT_DIR/sw-hello.sh" "$@"
            ;;
        ping)
            exec "$SCRIPT_DIR/sw-ping.sh" "$@"
            ;;
        *)
```

**Step 2: Verify routing works**

```bash
bash scripts/sw ping
```

Expected output: `pong`

```bash
bash scripts/sw ping --help
```

Expected: shows USAGE block

**Step 3: Commit**

```bash
git add scripts/sw
git commit -m "feat: register ping command in CLI router"
```

---

### Task 4: Add `sw-ping-test.sh` to `npm test` in `package.json`

**Files:**

- Modify: `package.json` (line 39, the `"test"` script)

**Step 1: Insert after `sw-hello-test.sh`**

In the `"test"` script string, find the substring:

```
bash scripts/sw-hello-test.sh &&
```

Insert immediately after it:

```
bash scripts/sw-hello-test.sh && bash scripts/sw-ping-test.sh &&
```

**Step 2: Verify the test script runs**

```bash
bash scripts/sw-ping-test.sh
```

Expected: `PASS: 6  FAIL: 0`

**Step 3: Commit**

```bash
git add package.json
git commit -m "test: add sw-ping-test.sh to npm test suite"
```

---

## Task Checklist

- [ ] Task 1: Create `scripts/sw-ping.sh` with `echo "pong"` as default action
- [ ] Task 2: Make `scripts/sw-ping.sh` executable (`chmod +x`)
- [ ] Task 3: Verify `bash scripts/sw-ping.sh` outputs `pong` and exits 0
- [ ] Task 4: Create `scripts/sw-ping-test.sh` with 6 tests matching hello-test pattern
- [ ] Task 5: Run `bash scripts/sw-ping-test.sh` — confirm `PASS: 6 FAIL: 0`
- [ ] Task 6: Add `ping)` case to `scripts/sw` router after `hello)` block
- [ ] Task 7: Verify `bash scripts/sw ping` outputs `pong`
- [ ] Task 8: Insert `bash scripts/sw-ping-test.sh &&` into `package.json` test script after `sw-hello-test.sh`
- [ ] Task 9: Run `bash scripts/sw-ping-test.sh` one final time to confirm all pass
- [ ] Task 10: Commit all changes (4 commits, one per logical unit)

---

## Testing Approach

**Unit test (isolated):**

```bash
bash scripts/sw-ping-test.sh
# Expected: PASS: 6  FAIL: 0
```

**Integration test (via router):**

```bash
bash scripts/sw ping
# Expected: pong
```

**Full suite (confirm no regressions):**

```bash
npm test
# Expected: all suites pass (sw-ping-test.sh included)
```

---

## Definition of Done

- [ ] `bash scripts/sw-ping.sh` outputs exactly `pong` on stdout, exits 0
- [ ] `bash scripts/sw ping` outputs exactly `pong` on stdout, exits 0 (router works)
- [ ] `bash scripts/sw-ping-test.sh` reports `PASS: 6  FAIL: 0`
- [ ] `sw-ping-test.sh` is present in the `"test"` script in `package.json`
- [ ] No existing tests broken (run `bash scripts/sw-hello-test.sh` as a quick sanity check)
- [ ] All 4 files committed with descriptive messages
