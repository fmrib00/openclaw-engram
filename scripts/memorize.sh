#!/bin/bash
# memorize.sh — Extract structured memories from a raw .md file and distribute
# Usage: bash memorize.sh /path/to/raw-log.md
# Dependencies: curl, jq, bash 4+
#
# Environment variables:
#   MEMORY_DIR        — Path to memory directory (default: ~/.openclaw/workspace/memory)
#   LLM_API_URL       — OpenAI-compatible chat completions endpoint
#   LLM_API_KEY       — API key for the LLM provider
#   LLM_MODEL         — Model name (default: glm-4-flash)
#   ENTITY_CONFIG     — Path to entity whitelist file (default: $MEMORY_DIR/entities.conf)

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

MEMORY_DIR="${MEMORY_DIR:-$HOME/.openclaw/workspace/memory}"
API_URL="${LLM_API_URL:-https://open.bigmodel.cn/api/paas/v4/chat/completions}"
API_KEY="${LLM_API_KEY:-}"
MODEL="${LLM_MODEL:-glm-4-flash}"
MAX_RETRIES=3
RETRY_DELAY=3

[ -z "$API_KEY" ] && { echo "[memorize] ERROR: LLM_API_KEY not set. Export it or add to .env" >&2; exit 1; }

# ── Entity whitelist ────────────────────────────────────────────────────────
# Default whitelist. Override by creating $MEMORY_DIR/entities.conf
# Format: entity_name=relative/path.md (one per line)
#
# Users should customize this for their own team/project.

declare -A ENTITY_MAP=()
ENTITY_NAMES_FOR_PROMPT=""

load_entity_whitelist() {
    local config_file="${ENTITY_CONFIG:-$MEMORY_DIR/entities.conf}"

    if [ -f "$config_file" ]; then
        while IFS='=' read -r name path; do
            # Skip comments and empty lines
            [[ "$name" =~ ^#.*$ ]] && continue
            [ -z "$name" ] && continue
            name=$(echo "$name" | tr -d ' ')
            path=$(echo "$path" | tr -d ' ')
            ENTITY_MAP["$name"]="$path"
        done < "$config_file"
    fi

    # If no config file or empty, use a sensible default
    if [ ${#ENTITY_MAP[@]} -eq 0 ]; then
        ENTITY_MAP=(
            [assistant]="entities/systems/assistant.md"
            [server]="entities/systems/server.md"
        )
    fi

    # Build entity name list for prompt
    ENTITY_NAMES_FOR_PROMPT=""
    for name in "${!ENTITY_MAP[@]}"; do
        local path="${ENTITY_MAP[$name]}"
        local dir
        dir=$(dirname "$path")
        local category="${dir##*/}"  # people, systems, customers, vendors
        ENTITY_NAMES_FOR_PROMPT+="  - \"$name\" ($category)\n"
    done
}

load_entity_whitelist

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[memorize] $(date '+%H:%M:%S') $*"; }
die() { echo "[memorize] ERROR: $*" >&2; exit 1; }

call_llm() {
    local prompt="$1"
    local attempt=0

    # Truncate very long inputs to ~12000 chars to stay within token limits
    if [ ${#prompt} -gt 12000 ]; then
        prompt="${prompt:0:12000}...(truncated)"
    fi

    local json_prompt
    json_prompt=$(jq -Rs '.' <<< "$prompt")

    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))
        local response
        response=$(curl -s --max-time 60 "$API_URL" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": $json_prompt}],
                \"max_tokens\": 2000,
                \"temperature\": 0.1
            }" 2>/dev/null) || true

        local content
        content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || true
        if [ -n "$content" ]; then
            echo "$content"
            return 0
        fi

        local err
        err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null) || true
        log "API attempt $attempt failed: ${err:-no response}. Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
    done

    die "API failed after $MAX_RETRIES attempts"
}

extract_json_block() {
    # Strip markdown fences, then grab the first JSON object
    sed 's/^```json//;s/^```//' | sed -n '/^[[:space:]]*{/,/^[[:space:]]*}/p' | head -200
}

append_if_new() {
    local file="$1"
    local line="$2"
    local check="${line:0:60}"
    if ! grep -qF "$check" "$file" 2>/dev/null; then
        echo "$line" >> "$file"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

INPUT_FILE="${1:-}"
[ -z "$INPUT_FILE" ] && die "Usage: memorize.sh <input-file.md>"
[ -f "$INPUT_FILE" ] || die "File not found: $INPUT_FILE"

BASENAME=$(basename "$INPUT_FILE" .md)
log "Processing: $BASENAME"

# Detect date from filename
FILE_DATE=""
if [[ "$BASENAME" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    FILE_DATE="${BASH_REMATCH[1]}"
fi
DATE_FOR_CALENDAR="${FILE_DATE:-$(date '+%Y-%m-%d')}"
YEAR_MONTH="${DATE_FOR_CALENDAR:0:7}"
MONTH_DAY="${DATE_FOR_CALENDAR:5}"

log "Date: $DATE_FOR_CALENDAR"

CONTENT=$(cat "$INPUT_FILE")
[ -z "$CONTENT" ] && { log "Empty file, skipping."; exit 0; }

# ── Step 1: LLM Extraction ──────────────────────────────────────────────────

ENTITY_LIST=$(echo -e "$ENTITY_NAMES_FOR_PROMPT")

EXTRACTION_PROMPT="You are a memory extraction assistant. Extract important facts from the document below.

CRITICAL RULES FOR ENTITY NAMES:
You may ONLY use these exact entity names in entity_updates:
${ENTITY_LIST}

DO NOT create new entity names. Map everything to the closest whitelist entity above.

Output ONLY valid JSON (no markdown fences, no explanation):

{
  \"events\": [
    {\"time\": \"HH:MM or empty string\", \"summary\": \"One-line what happened\"}
  ],
  \"entity_updates\": [
    {\"entity\": \"exact_whitelist_name\", \"fact\": \"New information\"}
  ],
  \"decisions\": [
    {\"title\": \"Short title\", \"summary\": \"One-line description\"}
  ],
  \"issues_opened\": [
    {\"severity\": \"critical|warning|low\", \"summary\": \"Issue description\"}
  ],
  \"issues_resolved\": [\"Description of resolved issue\"],
  \"keywords\": [\"specific_keyword1\", \"specific_keyword2\"]
}

Rules:
- Only extract important facts, skip chatter and process details
- Events: concrete happenings with outcomes
- Keywords: specific and searchable (not generic words like \"update\", \"fix\", \"issue\")
- Empty arrays [] for categories with nothing to report
- Output ONLY the JSON object

Document:
$CONTENT"

log "Calling LLM for extraction..."
RAW_RESPONSE=$(call_llm "$EXTRACTION_PROMPT")
sleep 3  # Rate limit

# Parse JSON
JSON_DATA=$(echo "$RAW_RESPONSE" | extract_json_block)
if ! echo "$JSON_DATA" | jq empty 2>/dev/null; then
    log "WARNING: JSON parse failed. Raw saved to /tmp/memorize_debug.txt"
    echo "$RAW_RESPONSE" > /tmp/memorize_debug.txt
    die "JSON parse failed"
fi

log "Extraction successful."

# ── Step 2: Distribute to files (dual-write) ────────────────────────────────

N_EVENTS=$(echo "$JSON_DATA" | jq '.events | length')
N_ENTITIES=$(echo "$JSON_DATA" | jq '.entity_updates | length')
N_DECISIONS=$(echo "$JSON_DATA" | jq '.decisions | length')
N_OPENED=$(echo "$JSON_DATA" | jq '.issues_opened | length')
N_RESOLVED=$(echo "$JSON_DATA" | jq '.issues_resolved | length')
N_KEYWORDS=$(echo "$JSON_DATA" | jq '.keywords | length')

TOTAL=$((N_EVENTS + N_ENTITIES + N_DECISIONS + N_OPENED + N_RESOLVED))
log "Extracted: ${N_EVENTS} events, ${N_ENTITIES} entities, ${N_DECISIONS} decisions, ${N_OPENED}/${N_RESOLVED} issues, ${N_KEYWORDS} keywords"

# ── 2a: Calendar file ───────────────────────────────────────────────────────

CALENDAR_DIR="$MEMORY_DIR/calendar/$YEAR_MONTH"
CALENDAR_FILE="$CALENDAR_DIR/$MONTH_DAY.md"
mkdir -p "$CALENDAR_DIR"
[ -f "$CALENDAR_FILE" ] || echo "# $DATE_FOR_CALENDAR" > "$CALENDAR_FILE"

if [ "$N_EVENTS" -gt 0 ]; then
    grep -q "^## Events" "$CALENDAR_FILE" 2>/dev/null || echo -e "\n## Events" >> "$CALENDAR_FILE"
    echo "$JSON_DATA" | jq -r '.events[] | "- " + (if .time != "" then "**" + .time + "** " else "" end) + .summary' | while IFS= read -r line; do
        append_if_new "$CALENDAR_FILE" "$line"
    done
fi

# Dual-write entity updates to calendar
if [ "$N_ENTITIES" -gt 0 ]; then
    grep -q "^## Notes" "$CALENDAR_FILE" 2>/dev/null || echo -e "\n## Notes" >> "$CALENDAR_FILE"
    echo "$JSON_DATA" | jq -r '.entity_updates[] | "- [" + .entity + "] " + .fact' | while IFS= read -r line; do
        append_if_new "$CALENDAR_FILE" "$line"
    done
fi

# Dual-write decisions to calendar
if [ "$N_DECISIONS" -gt 0 ]; then
    grep -q "^## Decisions" "$CALENDAR_FILE" 2>/dev/null || echo -e "\n## Decisions" >> "$CALENDAR_FILE"
    echo "$JSON_DATA" | jq -r '.decisions[] | "- **" + .title + ":** " + .summary' | while IFS= read -r line; do
        append_if_new "$CALENDAR_FILE" "$line"
    done
fi

# Tags
if [ "$N_KEYWORDS" -gt 0 ]; then
    TAGS=$(echo "$JSON_DATA" | jq -r '.keywords | join(", ")')
    if grep -q "^## Tags" "$CALENDAR_FILE" 2>/dev/null; then
        EXISTING_TAGS=$(grep -A1 "^## Tags" "$CALENDAR_FILE" | tail -1)
        MERGED=$(echo "$EXISTING_TAGS, $TAGS" | tr ',' '\n' | sed 's/^ *//' | sort -uf | paste -sd', ')
        TMPF=$(mktemp)
        awk -v merged="$MERGED" '/^## Tags/{print; getline; print merged; next}1' "$CALENDAR_FILE" > "$TMPF" && mv "$TMPF" "$CALENDAR_FILE"
    else
        echo -e "\n## Tags\n$TAGS" >> "$CALENDAR_FILE"
    fi
fi

log "  Calendar: $CALENDAR_FILE"

# ── 2b: Entity files (whitelist-constrained) ────────────────────────────────

if [ "$N_ENTITIES" -gt 0 ]; then
    echo "$JSON_DATA" | jq -c '.entity_updates[]' | while IFS= read -r entity_json; do
        ENTITY_NAME=$(echo "$entity_json" | jq -r '.entity' | tr '[:upper:]' '[:lower:]')
        ENTITY_FACT=$(echo "$entity_json" | jq -r '.fact')

        # Look up in whitelist
        ENTITY_FILE="${ENTITY_MAP[$ENTITY_NAME]:-}"

        if [ -z "$ENTITY_FILE" ]; then
            # Check if it's a customer-style ID (letter + digits)
            if [[ "$ENTITY_NAME" =~ ^[a-z][0-9]+$ ]]; then
                ENTITY_FILE="entities/customers/${ENTITY_NAME}.md"
                FULL_PATH="$MEMORY_DIR/$ENTITY_FILE"
                mkdir -p "$(dirname "$FULL_PATH")"
                [ -f "$FULL_PATH" ] || echo "# Customer ${ENTITY_NAME^^}" > "$FULL_PATH"
            else
                # Not in whitelist — pick first system entity as fallback
                local fallback_key
                fallback_key=$(echo "${!ENTITY_MAP[@]}" | tr ' ' '\n' | head -1)
                ENTITY_FILE="${ENTITY_MAP[$fallback_key]}"
                log "  SKIP entity '$ENTITY_NAME' (not in whitelist), appending to $ENTITY_FILE"
            fi
        fi

        FULL_PATH="$MEMORY_DIR/$ENTITY_FILE"
        mkdir -p "$(dirname "$FULL_PATH")"
        [ -f "$FULL_PATH" ] || echo "# ${ENTITY_NAME}" > "$FULL_PATH"
        append_if_new "$FULL_PATH" "- [$DATE_FOR_CALENDAR] $ENTITY_FACT"
        log "  Entity: $ENTITY_FILE <- $ENTITY_NAME"
    done
fi

# ── 2c: Decisions ────────────────────────────────────────────────────────────

if [ "$N_DECISIONS" -gt 0 ]; then
    echo "$JSON_DATA" | jq -c '.decisions[]' | while IFS= read -r decision_json; do
        TITLE=$(echo "$decision_json" | jq -r '.title')
        SUMMARY=$(echo "$decision_json" | jq -r '.summary')
        DECISION_FILENAME=$(echo "$DATE_FOR_CALENDAR-$TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
        DECISION_FILE="$MEMORY_DIR/decisions/${DECISION_FILENAME}.md"

        if [ ! -f "$DECISION_FILE" ]; then
            mkdir -p "$MEMORY_DIR/decisions"
            cat > "$DECISION_FILE" <<EOF
# $TITLE — $DATE_FOR_CALENDAR

## Summary
$SUMMARY

## Source
$BASENAME
EOF
            log "  Decision: decisions/${DECISION_FILENAME}.md"
        fi
    done
fi

# ── 2d: Issues ───────────────────────────────────────────────────────────────

ISSUES_FILE="$MEMORY_DIR/issues/open.md"
mkdir -p "$MEMORY_DIR/issues"
if [ ! -f "$ISSUES_FILE" ]; then
    cat > "$ISSUES_FILE" <<'EOF'
# Open Issues

## 🔴 Critical

## ⚠️ Warning

## 💡 Low Priority
EOF
fi

if [ "$N_OPENED" -gt 0 ]; then
    echo "$JSON_DATA" | jq -c '.issues_opened[]' | while IFS= read -r issue_json; do
        ISSUE_SUMMARY=$(echo "$issue_json" | jq -r '.summary')
        append_if_new "$ISSUES_FILE" "- [$DATE_FOR_CALENDAR] $ISSUE_SUMMARY"
        log "  Issue opened: $ISSUE_SUMMARY"
    done
fi

if [ "$N_RESOLVED" -gt 0 ]; then
    echo "$JSON_DATA" | jq -r '.issues_resolved[]' | while IFS= read -r resolved; do
        log "  Issue resolved: $resolved"
    done
fi

# ── Step 3: Update index.md ─────────────────────────────────────────────────

INDEX_FILE="$MEMORY_DIR/index.md"

if [ ! -f "$INDEX_FILE" ]; then
    cat > "$INDEX_FILE" <<'EOF'
# Memory Index
<!-- Auto-generated keyword-to-file mapping -->

| Keyword | Files | Last Updated |
|---------|-------|-------------|
EOF
fi

# Build file list: calendar + entity files touched
FILES_STR="calendar/$YEAR_MONTH/$MONTH_DAY.md"
if [ "$N_ENTITIES" -gt 0 ]; then
    EPATHS=$(echo "$JSON_DATA" | jq -r '.entity_updates[].entity' | tr '[:upper:]' '[:lower:]' | sort -u | while IFS= read -r ename; do
        efile="${ENTITY_MAP[$ename]:-}"
        if [ -n "$efile" ]; then
            echo "$efile"
        elif [[ "$ename" =~ ^[a-z][0-9]+$ ]]; then
            echo "entities/customers/${ename}.md"
        fi
    done | sort -u | paste -sd', ')
    [ -n "${EPATHS:-}" ] && FILES_STR="$FILES_STR, $EPATHS"
fi

# Add keywords to index
if [ "$N_KEYWORDS" -gt 0 ]; then
    echo "$JSON_DATA" | jq -r '.keywords[]' | while IFS= read -r keyword; do
        kw_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
        if ! grep -qi "| ${kw_lower} |" "$INDEX_FILE" 2>/dev/null; then
            echo "| $kw_lower | $FILES_STR | $DATE_FOR_CALENDAR |" >> "$INDEX_FILE"
        fi
    done
fi

log "  Index updated ($N_KEYWORDS keywords)"
log "Done: $BASENAME ($TOTAL memories)"
