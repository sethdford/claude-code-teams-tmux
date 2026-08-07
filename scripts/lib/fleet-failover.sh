# fleet-failover.sh — Re-queue work from offline fleet machines
# When a machine goes offline, release its claimed issues so they can be picked up again.
# Source from daemon-poll or sw-fleet. Works standalone with gh + jq.
[[ -n "${_FLEET_FAILOVER_LOADED:-}" ]] && return 0
_FLEET_FAILOVER_LOADED=1

# Quarantine library, resolved relative to this file (callers set SCRIPT_DIR later).
_FLEET_FAILOVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./issue-quarantine.sh
source "${_FLEET_FAILOVER_LIB_DIR}/issue-quarantine.sh"

fleet_failover_check() {
    local health_file="$HOME/.shipwright/machine-health.json"
    [[ ! -f "$health_file" ]] && return 0

    [[ "${NO_GITHUB:-false}" == "true" ]] && return 0
    command -v gh >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0

    # Find offline machines (health file: .[machine_name] = {status, checked_at})
    local offline_machines
    offline_machines=$(jq -r 'to_entries[] | select(.value.status == "offline") | .key' "$health_file" 2>/dev/null)
    [[ -z "$offline_machines" ]] && return 0

    while IFS= read -r machine; do
        [[ -z "$machine" ]] && continue

        # Find issues claimed by this offline machine via GitHub label
        local orphaned_issues
        orphaned_issues=$(gh search issues \
            "label:claimed:${machine}" \
            is:open \
            --json number,repository,labels \
            --limit 100 2>/dev/null \
            | quarantine_filter_json "fleet-failover" \
            | jq -r '.[] | "\(.repository.nameWithOwner):\(.number)"' 2>/dev/null)
        [[ -z "$orphaned_issues" ]] && continue

        while IFS= read -r issue_key; do
            [[ -z "$issue_key" ]] && continue

            local issue_num="${issue_key##*:}"
            local repo="${issue_key%:*}"
            [[ "$repo" == "$issue_key" ]] && repo=""

            # Log and emit
            if [[ "$(type -t info 2>/dev/null)" == "function" ]]; then
                info "Failover: re-queuing issue #${issue_num} from offline machine ${machine}"
            fi
            if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
                emit_event "fleet.failover" "{\"issue\":\"$issue_num\",\"from_machine\":\"$machine\"}"
            fi

            # Release the claim (remove label) — idempotent
            if [[ -n "$repo" ]]; then
                gh issue edit "$issue_num" --repo "$repo" --remove-label "claimed:${machine}" 2>/dev/null || true
            else
                gh issue edit "$issue_num" --remove-label "claimed:${machine}" 2>/dev/null || true
            fi

            # When running in daemon context: enqueue so we pick it up if we watch this repo
            # In org mode WATCH_MODE=org, enqueue uses owner/repo:num; in repo mode just num
            if [[ -f "${STATE_FILE:-$HOME/.shipwright/daemon-state.json}" ]] && type enqueue_issue >/dev/null 2>&1; then
                local queue_key="$issue_num"
                [[ -n "$repo" ]] && queue_key="${repo}:${issue_num}"
                enqueue_issue "$queue_key" 2>/dev/null || true
            fi
        done <<< "$orphaned_issues"
    done <<< "$offline_machines"
}
