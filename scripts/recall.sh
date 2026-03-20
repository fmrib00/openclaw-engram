#!/bin/bash
# recall.sh — Search long-term memory by keyword
# Usage: bash recall.sh "keyword or phrase"
# Dependencies: grep, bash
#
# Environment variables:
#   MEMORY_DIR — Path to memory directory (default: ~/.openclaw/workspace/memory)

set -euo pipefail

MEMORY_DIR="${MEMORY_DIR:-$HOME/.openclaw/workspace/memory}"
INDEX_FILE="$MEMORY_DIR/index.md"
QUERY="${1:-}"

[ -z "$QUERY" ] && { echo "Usage: recall.sh \"keyword\""; exit 1; }
[ -f "$INDEX_FILE" ] || { echo "ERROR: index.md not found at $INDEX_FILE"; exit 1; }

query_lower=$(echo "$QUERY" | tr '[:upper:]' '[:lower:]')

echo "🔍 Searching memory for: \"$QUERY\""
echo ""

# ── Step 1: Find matching files from index ──────────────────────────────────

MATCHED_FILES=$(grep -i "$query_lower" "$INDEX_FILE" 2>/dev/null | grep '^|' | \
    sed 's/^| *[^|]* | *//; s/ *|.*$//' | \
    tr ',' '\n' | sed 's/^ *//; s/ *$//' | \
    grep -v '^$' | sort -u) || true

# Also do a direct text search across all memory files for broader coverage
GREP_FILES=""
for subdir in calendar entities decisions issues; do
    [ -d "$MEMORY_DIR/$subdir" ] || continue
    GREP_FILES+=$(grep -rli "$QUERY" "$MEMORY_DIR/$subdir" 2>/dev/null || true)
    GREP_FILES+=$'\n'
done

# Merge both lists
ALL_FILES=$(printf '%s\n%s\n' "$MATCHED_FILES" "$GREP_FILES" | \
    sed "s|^entities/|$MEMORY_DIR/entities/|; s|^calendar/|$MEMORY_DIR/calendar/|; s|^decisions/|$MEMORY_DIR/decisions/|; s|^issues/|$MEMORY_DIR/issues/|" | \
    grep -v '^$' | sort -u)

if [ -z "$ALL_FILES" ]; then
    echo "❌ No memories found for \"$QUERY\""
    echo ""
    echo "Try:"
    echo "  - A more general keyword"
    echo "  - bash recall.sh \"$(echo "$QUERY" | awk '{print $1}')\"  (first word only)"
    exit 0
fi

FILE_COUNT=$(echo "$ALL_FILES" | wc -l)
echo "📂 Found in $FILE_COUNT file(s):"
echo ""

# ── Step 2: Show matching content from each file ─────────────────────────────

echo "$ALL_FILES" | while IFS= read -r filepath; do
    # Resolve relative paths
    if [ ! -f "$filepath" ]; then
        filepath="$MEMORY_DIR/$filepath"
    fi
    [ -f "$filepath" ] || continue

    # Get relative display path
    display_path="${filepath#$MEMORY_DIR/}"

    if grep -qi "$QUERY" "$filepath" 2>/dev/null; then
        echo "─── $display_path ───────────────────────────"
        grep -in "$QUERY" "$filepath" | head -10 | while IFS= read -r match_line; do
            echo "  $match_line"
        done
        echo ""
    else
        echo "─── $display_path (index match) ─────────────"
        head -5 "$filepath" | sed 's/^/  /'
        echo ""
    fi
done

# ── Step 3: Summary of entity files ─────────────────────────────────────────

echo "─────────────────────────────────────────────"
echo "📋 Quick entity lookup:"
HIT=0
for entity_file in "$MEMORY_DIR/entities"/**/*.md "$MEMORY_DIR/entities"/*/*.md; do
    [ -f "$entity_file" ] || continue
    if grep -qi "$QUERY" "$entity_file" 2>/dev/null; then
        display="${entity_file#$MEMORY_DIR/}"
        count=$(grep -ic "$QUERY" "$entity_file" 2>/dev/null || echo 0)
        echo "  $display ($count match(es))"
        HIT=1
    fi
done
[ "$HIT" -eq 0 ] && echo "  (no entity matches)"

echo ""
echo "💡 To read a full file: cat $MEMORY_DIR/<path>"
