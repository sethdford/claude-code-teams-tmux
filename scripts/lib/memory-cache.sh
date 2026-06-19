#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/memory-cache — Query result cache (L1)                      ║
# ║  Memoizes whole `memory_ranked_search` outputs keyed by query + source     ║
# ║  version, so a repeated query skips the 3×N jq/grep scan entirely.         ║
# ║  Strictly additive & fail-open: any error behaves as a cache miss.         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Why this exists: each `sw memory` invocation is a fresh process, so the cache
# MUST be persisted to disk. A single SQLite file (`.query-cache.db`, sibling of
# the memory JSON files) holds (key → value) rows. The key embeds the index
# source-version signature (see memory-index.sh `memory_index_version`), so any
# write to a memory file changes every key prefix and old rows are pruned on the
# next put — invalidation is automatic and byte-identical correctness is kept
# because the exact prior output string is stored and returned verbatim.
#
# Public interface (see design.md "Interface Contracts"):
#   memory_cache_key   <dir> <query> <max>          -> stdout: cache key
#   memory_cache_get   <dir> <query> <max>          -> stdout: value; exit 0 hit / 1 miss
#   memory_cache_put   <dir> <query> <max> <value>  -> exit 0 stored / 1 skipped
#   memory_cache_clear <dir>                         -> exit 0 (drops all rows)
#
# Fail-open contract: when sqlite3 is unavailable, or the dir is missing, every
# function degrades to "miss" / "no-op" and returns without error so callers
# always fall back to a full scan.

# Guard against double-sourcing.
[[ -n "${_MEMORY_CACHE_LOADED:-}" ]] && return 0 2>/dev/null || true
_MEMORY_CACHE_LOADED=1

# Load the index module for `memory_index_version` (best-effort: a missing
# version just yields a less precise — but still correct — cache key).
if [[ "$(type -t memory_index_version 2>/dev/null)" != "function" ]]; then
    _MC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "$_MC_DIR/memory-index.sh" ]] && source "$_MC_DIR/memory-index.sh"
    unset _MC_DIR
fi

# Time-to-live (seconds) for a cached row regardless of version — a second
# safety bound under version-keyed invalidation. Evaluated per call (not cached
# at source time) so it stays tunable at runtime via SW_MEMORY_CACHE_TTL.
_memory_cache_ttl() {
    echo "${SW_MEMORY_CACHE_TTL:-86400}"
}

# ─── Availability ────────────────────────────────────────────────────────────
_memory_cache_available() {
    command -v sqlite3 >/dev/null 2>&1
}

# ─── DB path (sibling of the memory JSON files) ──────────────────────────────
_memory_cache_db() {
    printf '%s/.query-cache.db\n' "$1"
}

# ─── Short, fixed-length hash of an arbitrary string ─────────────────────────
_memory_cache_hash() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else
        # Last-resort: length-tagged raw (collisions only across same-length
        # strings, which only costs a cache miss — never a wrong result).
        printf 'raw%s-%s' "${#1}" "$1" | tr -c 'A-Za-z0-9-' '_'
    fi
}

# ─── Source-version prefix for keys (auto-invalidation anchor) ───────────────
_memory_cache_version() {
    if [[ "$(type -t memory_index_version 2>/dev/null)" == "function" ]]; then
        memory_index_version "$1" 2>/dev/null || echo "none"
    else
        echo "none"
    fi
}

# ─── Public: build the cache key for a query ─────────────────────────────────
# Format: "<version>|<hash(query)>|<max_results>" — version first so a prefix
# match identifies the current generation for pruning.
memory_cache_key() {
    local dir="$1" query="$2" max="${3:-5}"
    printf '%s|%s|%s\n' "$(_memory_cache_version "$dir")" "$(_memory_cache_hash "$query")" "$max"
}

# Maximum number of cached rows retained (LRU ceiling). Honors the acceptance
# criterion "cache the last 50 lookups"; eviction keys on last_used (see put).
_memory_cache_max_rows() {
    echo "${SW_MEMORY_CACHE_MAX:-50}"
}

# ─── Ensure the table exists (idempotent) ────────────────────────────────────
# The last_used column drives LRU eviction; a pre-existing table from before this
# column is migrated in-place (the ADD COLUMN is a no-op once present).
_memory_cache_init() {
    local db="$1"
    sqlite3 -cmd ".timeout 5000" "$db" \
        "CREATE TABLE IF NOT EXISTS query_cache (
            key        TEXT PRIMARY KEY,
            value      TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            last_used  INTEGER NOT NULL DEFAULT 0
        );" 2>/dev/null
    # Migrate legacy tables that predate last_used (ignore "duplicate column").
    sqlite3 -cmd ".timeout 5000" "$db" \
        "ALTER TABLE query_cache ADD COLUMN last_used INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
}

# ─── SQL string literal escaping (single-quote → doubled) ────────────────────
_memory_cache_sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

# ─── Public: look up a cached value ──────────────────────────────────────────
# Prints the stored value verbatim and returns 0 on a fresh hit; returns 1 on
# miss, expiry, missing dir, or no sqlite3.
memory_cache_get() {
    local dir="$1" query="$2" max="${3:-5}"
    [[ -n "$dir" && -d "$dir" ]] || return 1
    _memory_cache_available || return 1
    local db key now value
    db="$(_memory_cache_db "$dir")"
    [[ -f "$db" ]] || return 1
    key="$(memory_cache_key "$dir" "$query" "$max")"
    now="$(date +%s)"
    local ttl; ttl="$(_memory_cache_ttl)"
    # Fetch only if within TTL. sqlite list mode keeps the value byte-exact.
    value="$(sqlite3 -cmd ".timeout 5000" "$db" \
        "SELECT value FROM query_cache
         WHERE key='$(_memory_cache_sql_escape "$key")'
           AND created_at > $((now - ttl))
         LIMIT 1;" 2>/dev/null)" || return 1
    [[ -n "$value" ]] || return 1
    # Touch the row's recency so LRU eviction keeps actively-read entries. Fire
    # and forget — a failed touch only risks premature eviction, never wrong data.
    sqlite3 -cmd ".timeout 5000" "$db" \
        "UPDATE query_cache SET last_used=$now
         WHERE key='$(_memory_cache_sql_escape "$key")';" 2>/dev/null || true
    printf '%s\n' "$value"
    return 0
}

# ─── Public: store a value ───────────────────────────────────────────────────
# Also prunes rows from older source versions to bound growth. No-op (returns 1)
# when sqlite3 is unavailable or the dir is missing.
memory_cache_put() {
    local dir="$1" query="$2" max="${3:-5}" value="$4"
    [[ -n "$dir" && -d "$dir" ]] || return 1
    _memory_cache_available || return 1
    local db key ver now
    db="$(_memory_cache_db "$dir")"
    _memory_cache_init "$db" || return 1
    key="$(memory_cache_key "$dir" "$query" "$max")"
    ver="$(_memory_cache_version "$dir")"
    now="$(date +%s)"
    local ttl; ttl="$(_memory_cache_ttl)"
    local max; max="$(_memory_cache_max_rows)"
    sqlite3 -cmd ".timeout 5000" "$db" \
        "INSERT OR REPLACE INTO query_cache (key, value, created_at, last_used)
         VALUES ('$(_memory_cache_sql_escape "$key")',
                 '$(_memory_cache_sql_escape "$value")',
                 $now, $now);
         DELETE FROM query_cache
         WHERE key NOT LIKE '$(_memory_cache_sql_escape "$ver")|%'
            OR created_at <= $((now - ttl));
         DELETE FROM query_cache
         WHERE key NOT IN (
             SELECT key FROM query_cache ORDER BY last_used DESC, created_at DESC LIMIT $max
         );" 2>/dev/null || return 1
    return 0
}

# ─── Public: drop all cached rows for a memory dir ───────────────────────────
memory_cache_clear() {
    local dir="$1"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    _memory_cache_available || return 0
    local db
    db="$(_memory_cache_db "$dir")"
    [[ -f "$db" ]] || return 0
    sqlite3 -cmd ".timeout 5000" "$db" "DELETE FROM query_cache;" 2>/dev/null || true
    return 0
}
