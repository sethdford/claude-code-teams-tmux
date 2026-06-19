#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/memory-index — Persisted keyword→entry index (L2)          ║
# ║  Collapses 3×N per-entry `jq` spawns into a single indexed lookup.         ║
# ║  Strictly additive & fail-open: any error falls back to a full scan.       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Why this exists: each `sw memory` invocation is a fresh process, so an
# "in-memory" index cannot survive across calls — it MUST be persisted to disk.
# This module maintains `index.json` (sibling of the memory JSON files) mapping
# normalized keyword → [entry_ref,...] where entry_ref is "<source_type>:<idx>".
#
# Public interface (see design.md "Interface Contracts"):
#   memory_index_version  <dir>            -> stdout: mtime/size signature
#   memory_index_build    <dir>            -> exit 0|1 (writes index.json atomically)
#   memory_index_lookup   <dir> <keyword>  -> stdout: newline-separated entry refs
#   memory_index_validate <dir>            -> exit 0 (fresh) | 1 (stale/corrupt/missing)
#
# Contract: build is the only writer (atomic + flock); version/lookup/validate
# never write. No function exits non-zero on a *recoverable* condition except
# validate (whose "1" is a normal signal meaning "rebuild needed").

# Guard against double-sourcing.
[[ -n "${_MEMORY_INDEX_LOADED:-}" ]] && return 0 2>/dev/null || true
_MEMORY_INDEX_LOADED=1

# ─── Minimal fallbacks (when sourced without helpers.sh) ─────────────────────
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
    now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() { :; }  # no-op when canonical helper absent
fi
if [[ "$(type -t atomic_write 2>/dev/null)" != "function" ]]; then
    atomic_write() {
        local target="$1" data="$2" tmp
        [[ -z "$target" ]] && return 1
        tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
        printf '%s' "$data" > "$tmp" || { rm -f "$tmp"; return 1; }
        mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }
        return 0
    }
fi

# Schema version of the index format. Bump on incompatible structure changes
# so a stale on-disk index is treated as invalid and rebuilt.
_MEMORY_INDEX_SCHEMA=1

# Source files the index is built from (relative to the memory dir).
_memory_index_sources() {
    echo "failures.json"
    echo "decisions.json"
    echo "patterns.json"
}

# ─── Portable file mtime (epoch seconds) ─────────────────────────────────────
_memory_index_mtime() {
    local f="$1"
    # GNU stat, then BSD stat, then a best-effort fallback.
    stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0
}

# ─── Version signature: changes whenever any source file changes ─────────────
# Anchoring cache keys and validation on this signature makes invalidation
# automatic — any write to a memory file changes the signature.
memory_index_version() {
    local dir="$1"
    [[ -z "$dir" || ! -d "$dir" ]] && { echo "none"; return 0; }

    local sig="" f size mtime
    while IFS= read -r f; do
        local path="$dir/$f"
        if [[ -f "$path" ]]; then
            size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
            mtime=$(_memory_index_mtime "$path")
            sig="${sig}${f}:${size:-0}:${mtime:-0};"
        else
            sig="${sig}${f}:absent;"
        fi
    done < <(_memory_index_sources)

    # Hash for a compact, fixed-length signature. Fall back to raw on no shasum.
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$sig" | shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$sig" | sha256sum | cut -d' ' -f1
    else
        printf '%s' "$sig"
    fi
}

# ─── jq token-emit programs (one pass per file) ──────────────────────────────
# Each emits "<keyword>\t<source_type>:<idx>" lines. Tokenization mirrors the
# search path: lowercase, alphanumeric runs, drop length<=2 and stopwords.
_MEMORY_INDEX_STOPWORDS='["the","and","for","not","with","this","that","from"]'

_memory_index_jq_array() {
    # $1 = array key (failures/decisions), $2 = source_type, $3 = jq text expr
    local arr="$1" stype="$2" textexpr="$3"
    cat <<JQ
.${arr} // [] | to_entries[] | .key as \$i
| (${textexpr}) | ascii_downcase
| [ scan("[a-z0-9]+") ][]
| select(length > 2)
| select(. as \$t | ${_MEMORY_INDEX_STOPWORDS} | index(\$t) | not)
| "\(.)\t${stype}:\(\$i)"
JQ
}

_memory_index_jq_object() {
    # patterns.json is a flat object; treat all scalar values as one entry.
    cat <<JQ
( [ paths(scalars) as \$p | getpath(\$p) | tostring ] | join(" ") )
| ascii_downcase
| [ scan("[a-z0-9]+") ][]
| select(length > 2)
| select(. as \$t | ${_MEMORY_INDEX_STOPWORDS} | index(\$t) | not)
| "\(.)\tpattern:0"
JQ
}

# ─── Build the index ─────────────────────────────────────────────────────────
# Writes index.json atomically under an flock. Returns 1 (logged) on failure so
# the caller falls back to a full scan — never aborts the pipeline.
memory_index_build() {
    local dir="$1"
    [[ -z "$dir" ]] && return 1
    if ! command -v jq >/dev/null 2>&1; then
        emit_event "memory.index.skipped" "reason=no_jq"
        return 1
    fi
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 1

    local tokens index_json sig built
    tokens=$(mktemp) || return 1
    sig=$(memory_index_version "$dir")
    built=$(now_iso)

    # Collect tokens — failures + decisions (arrays), patterns (object).
    if [[ -f "$dir/failures.json" ]]; then
        jq -r "$(_memory_index_jq_array failures failure \
            '(.value.pattern // "") + " " + (.value.root_cause // "") + " " + (.value.fix // "")')" \
            "$dir/failures.json" 2>/dev/null >> "$tokens" || true
    fi
    if [[ -f "$dir/decisions.json" ]]; then
        jq -r "$(_memory_index_jq_array decisions decision \
            '(.value.summary // "") + " " + (.value.detail // "") + " " + (.value.type // "")')" \
            "$dir/decisions.json" 2>/dev/null >> "$tokens" || true
    fi
    if [[ -f "$dir/patterns.json" ]]; then
        jq -r "$(_memory_index_jq_object)" "$dir/patterns.json" 2>/dev/null >> "$tokens" || true
    fi

    # Aggregate "kw\tref" lines into {keywords:{kw:[refs]}} + metadata.
    index_json=$(jq -R -s \
        --arg ver "$sig" \
        --arg built "$built" \
        --argjson schema "$_MEMORY_INDEX_SCHEMA" '
        (split("\n") | map(select(length > 0) | split("\t"))
         | reduce .[] as $p ({}; .[$p[0]] += [$p[1]])
         | map_values(unique)) as $kw
        | {schema_version: $schema, version: $ver, built_at: $built, keywords: $kw}
    ' < "$tokens" 2>/dev/null) || { rm -f "$tokens"; emit_event "memory.index.error" "phase=aggregate"; return 1; }
    rm -f "$tokens" 2>/dev/null || true

    [[ -z "$index_json" ]] && { emit_event "memory.index.error" "phase=empty"; return 1; }

    # Atomic write under flock to serialize concurrent daemon workers.
    local target="$dir/index.json" lock="$dir/.index.lock" rc=0
    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 5 200 2>/dev/null || true
        fi
        atomic_write "$target" "$index_json"
    ) 200>"$lock" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        emit_event "memory.index.error" "phase=write"
        return 1
    fi

    local kw_count
    kw_count=$(jq -r '.keywords | length' "$target" 2>/dev/null || echo 0)
    emit_event "memory.index.built" "keywords=${kw_count}" "version=${sig:0:12}"
    return 0
}

# ─── Validate freshness/integrity ────────────────────────────────────────────
# Returns 0 when the on-disk index matches the current source signature and is
# structurally sound; 1 (a normal, expected signal) when a rebuild is needed.
memory_index_validate() {
    local dir="$1"
    [[ -z "$dir" ]] && return 1
    local idx="$dir/index.json"
    [[ -f "$idx" ]] || return 1

    # Structural soundness: parseable, correct schema, has a keywords object.
    local schema keywords_type
    schema=$(jq -r '.schema_version // empty' "$idx" 2>/dev/null) || return 1
    [[ "$schema" == "$_MEMORY_INDEX_SCHEMA" ]] || return 1
    keywords_type=$(jq -r '.keywords | type' "$idx" 2>/dev/null) || return 1
    [[ "$keywords_type" == "object" ]] || return 1

    # Freshness: stored version must equal the live source signature.
    local stored current
    stored=$(jq -r '.version // empty' "$idx" 2>/dev/null) || return 1
    current=$(memory_index_version "$dir")
    [[ -n "$stored" && "$stored" == "$current" ]] || return 1

    return 0
}

# ─── Lookup candidate entry refs for a keyword ───────────────────────────────
# Self-healing: a stale/corrupt index is rebuilt once before lookup. Output is
# a newline-separated list of "<source_type>:<idx>" refs (empty = no matches).
memory_index_lookup() {
    local dir="$1" keyword="$2"
    [[ -z "$dir" || -z "$keyword" ]] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    if ! memory_index_validate "$dir"; then
        memory_index_build "$dir" || return 0
        emit_event "memory.index.rebuilt" "trigger=lookup"
    fi

    local kw
    kw=$(printf '%s' "$keyword" | tr '[:upper:]' '[:lower:]')
    jq -r --arg kw "$kw" '.keywords[$kw][]? // empty' "$dir/index.json" 2>/dev/null || true
}
