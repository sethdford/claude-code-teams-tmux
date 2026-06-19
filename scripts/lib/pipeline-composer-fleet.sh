#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-composer-fleet — read-only fleet success-pattern advisory hook  ║
# ║  Consults the mined success-pattern library (issue #668) for a proven     ║
# ║  pipeline approach. STRICTLY read-only w.r.t. the library: on a hit it     ║
# ║  emits exactly one knowledge.pattern_recommended event and prints the      ║
# ║  recommended template; on a miss or ANY error it prints "" and the         ║
# ║  composer falls back to its current behavior. Never aborts composition.    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Resolve the knowledge CLI relative to this library (scripts/lib/ → scripts/).
_PCF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_BIN="${KNOWLEDGE_BIN:-${_PCF_DIR}/../sw-knowledge.sh}"

# composer_fleet_recommendation <issue_json>
# issue_json: an object with at least {title, complexity}. Prints the
# recommended pipeline template on a qualifying match, otherwise "".
composer_fleet_recommendation() {
    local issue_json="${1:-}"
    [[ -z "$issue_json" ]] && { echo ""; return 0; }
    command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
    [[ -x "$KNOWLEDGE_BIN" || -f "$KNOWLEDGE_BIN" ]] || { echo ""; return 0; }

    local title complexity
    title=$(jq -r '.title // ""' <<< "$issue_json" 2>/dev/null || echo "")
    complexity=$(jq -r '(.complexity // 5) | tostring' <<< "$issue_json" 2>/dev/null || echo "5")
    [[ "$complexity" =~ ^[0-9]+$ ]] || complexity=5
    [[ -z "$title" ]] && { echo ""; return 0; }

    # Pure read: recommend writes nothing to the library.
    local out
    out=$(bash "$KNOWLEDGE_BIN" recommend --json "$title" "$complexity" 1 2>/dev/null || echo "[]")

    local top_template top_sig
    top_template=$(jq -r '.[0].template // empty' <<< "$out" 2>/dev/null || echo "")
    top_sig=$(jq -r '.[0].signature // empty' <<< "$out" 2>/dev/null || echo "")

    if [[ -n "$top_template" ]]; then
        # Exactly one event per hit. mine-success reconciles total_reuses by
        # recounting these events — so emitting (not the library) is the
        # reuse-tracking signal.
        if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
            emit_event "knowledge.pattern_recommended" \
                "signature=${top_sig}" \
                "template=${top_template}" 2>/dev/null || true
        fi
        echo "$top_template"
        return 0
    fi

    echo ""
    return 0
}
