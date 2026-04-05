#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  dependency-parser.sh — Extract source/. dependencies from bash scripts ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage: source this, then call parse_dependencies <file>
# Output: one dependency per line as "source_file|target_file"

# Parse a single bash script for source/. statements.
# Outputs lines of "source_file|resolved_target" to stdout.
# Unresolvable targets are output with [dynamic] prefix.
parse_dependencies() {
    local file="$1"
    local base_dir
    base_dir="$(cd "$(dirname "$file")" && pwd)"

    [[ -f "$file" ]] || return 0

    while IFS= read -r line; do
        # Skip pure comment lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip empty lines
        [[ -z "${line// /}" ]] && continue

        # Match: source "path" | source 'path' | source path
        #        . "path"      | . 'path'      | . path
        # The dot form requires whitespace after . to avoid matching ./script
        local target=""
        if [[ "$line" =~ ^[[:space:]]*(source|\.)[[:space:]]+(\"([^\"]+)\"|\'([^\']+)\'|([^[:space:]\;#]+)) ]]; then
            # Group 3: double-quoted, Group 4: single-quoted, Group 5: unquoted
            target="${BASH_REMATCH[3]:-${BASH_REMATCH[4]:-${BASH_REMATCH[5]}}}"
        fi

        [[ -z "$target" ]] && continue

        # Skip non-path targets (e.g., ". 2>/dev/null", redirections, numbers)
        [[ "$target" =~ ^[0-9] ]] && continue
        [[ "$target" == *">"* ]] && continue
        [[ "$target" == *"<"* ]] && continue
        # Must look like a path (contain / or . or end in .sh)
        if [[ "$target" != */* && "$target" != *".sh" && "$target" != '$'* ]]; then
            continue
        fi

        # Resolve common variables
        local resolved="$target"
        # Replace $SCRIPT_DIR or ${SCRIPT_DIR} with the file's directory
        resolved="${resolved/\$SCRIPT_DIR/$base_dir}"
        resolved="${resolved/\$\{SCRIPT_DIR\}/$base_dir}"

        # If target still contains $ (unresolved variable), mark as dynamic
        if [[ "$resolved" == *'$'* ]]; then
            echo "$file|[dynamic]:$target"
            continue
        fi

        # Normalize the path
        if [[ "$resolved" != /* ]]; then
            resolved="$base_dir/$resolved"
        fi

        # Canonicalize (resolve .., remove //)
        if [[ -f "$resolved" ]]; then
            resolved="$(cd "$(dirname "$resolved")" && pwd)/$(basename "$resolved")"
        fi

        echo "$file|$resolved"
    done < "$file"
}

# Parse all .sh files in a directory tree.
# Args: root_dir [file_pattern]
# Output: dependency pairs, one per line
parse_directory() {
    local root_dir="$1"
    local pattern="${2:-*.sh}"

    while IFS= read -r -d '' file; do
        parse_dependencies "$file"
    done < <(find "$root_dir" -name "$pattern" -type f -print0 2>/dev/null | sort -z)
}
