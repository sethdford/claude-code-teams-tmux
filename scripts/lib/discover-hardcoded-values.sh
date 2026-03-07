#!/usr/bin/env bash
# discover-hardcoded-values.sh — Scan scripts for hardcoded policy values
# Usage: bash scripts/lib/discover-hardcoded-values.sh scripts/
# Returns: JSON array of findings
set -euo pipefail

discover_hardcoded_values() {
    local search_dir="${1:-.}"
    local temp_json=$(mktemp)
    trap "rm -f '$temp_json'" EXIT

    echo '[]' > "$temp_json"

    # Find all shell scripts
    while IFS= read -r script_file; do
        discover_in_file "$script_file" "$temp_json"
    done < <(find "$search_dir" -name "*.sh" -type f 2>/dev/null | sort)

    cat "$temp_json"
}

discover_in_file() {
    local file="$1"
    local output_file="$2"
    local line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Pattern 1: Variable assignments with numeric values
        # Examples: TIMEOUT=120, INTERVAL=5, MAX_RETRIES=3
        if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_]+)=([0-9]+) ]]; then
            local var_name="${BASH_REMATCH[2]}"
            local value="${BASH_REMATCH[3]}"

            # Filter out obviously non-policy variables
            if ! [[ "$var_name" =~ ^(COUNT|INDEX|I|J|K|TEMP|TMP|PASS|FAIL|RC|EXIT)$ ]]; then
                local policy_key=$(var_to_policy_key "$var_name" "$file")
                local priority=$(estimate_priority "$var_name" "$file")

                jq \
                    --arg file "$(basename "$file")" \
                    --arg line "$line_num" \
                    --arg var "$var_name" \
                    --arg val "$value" \
                    --arg key "$policy_key" \
                    --arg priority "$priority" \
                    '. += [{"file": $file, "line": ($line | tonumber), "variable": $var, "value": ($val | tonumber), "type": "assignment", "policy_key": $key, "priority": ($priority | tonumber)}]' \
                    "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
            fi
        fi
    done < <(cat "$file" 2>/dev/null | grep -v '^\s*#' || true)
}

var_to_policy_key() {
    local var="$1"
    local file="$2"
    local file_prefix=$(basename "$file" .sh | sed 's/^sw-//')

    # Convert EXTENSION_SIZE to extension_size
    local key=$(echo "$var" | tr '[:upper:]' '[:lower:]')
    echo "${file_prefix}.${key}"
}

estimate_priority() {
    local var="$1"
    local file="$2"

    # High priority (5): adaptive-tunable values
    if echo "$var" | grep -qE 'TIMEOUT|INTERVAL|POLL|THRESHOLD|RETRIES|LIMIT|SIZE|MAX|MIN'; then
        echo "5"
    # Medium-high (4): loop and daemon control
    elif echo "$file" | grep -qE '(loop|daemon)'; then
        echo "4"
    # Medium (3): other config
    else
        echo "3"
    fi
}

# Run directly
discover_hardcoded_values "$@"
