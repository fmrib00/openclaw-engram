#!/bin/bash
# daily-archive.sh — Nightly auto-archive: export session JSONL → raw .md → memorize
# Usage: bash daily-archive.sh [YYYY-MM-DD]   (default: yesterday)
# Cron:  30 2 * * * bash ~/.openclaw/workspace/scripts/daily-archive.sh
#
# Environment variables:
#   MEMORY_DIR    — Path to memory directory (default: ~/.openclaw/workspace/memory)
#   LLM_API_KEY   — Required by memorize.sh
#   LLM_API_URL   — Optional, passed through to memorize.sh
#   LLM_MODEL     — Optional, passed through to memorize.sh

set -euo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
MEMORY_DIR="${MEMORY_DIR:-$WORKSPACE/memory}"
RAW_DIR="$MEMORY_DIR/raw"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$WORKSPACE/logs"
AGENTS_DIR="$HOME/.openclaw/agents"

export MEMORY_DIR  # Pass to memorize.sh

mkdir -p "$RAW_DIR" "$LOG_DIR"

# Target date (default: yesterday)
if date -d 'yesterday' '+%Y-%m-%d' >/dev/null 2>&1; then
    # GNU date
    TARGET_DATE="${1:-$(date -d 'yesterday' '+%Y-%m-%d')}"
else
    # macOS date
    TARGET_DATE="${1:-$(date -v-1d '+%Y-%m-%d')}"
fi

LOG_FILE="$LOG_DIR/daily-archive-${TARGET_DATE}.log"

log() { echo "[archive] $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }

log "=== Daily Archive Start: $TARGET_DATE ==="

# ── Step 1: Export sessions to raw .md ──────────────────────────────────────

EXPORTED=0

if [ ! -d "$AGENTS_DIR" ]; then
    log "No agents directory found at $AGENTS_DIR — skipping session export"
else
    for agent_dir in "$AGENTS_DIR"/*/; do
        AGENT_NAME=$(basename "$agent_dir")
        SESSION_DIR="$agent_dir/sessions"
        [ -d "$SESSION_DIR" ] || continue

        while IFS= read -r jsonl_file; do
            [ -f "$jsonl_file" ] || continue

            # Check if file was modified on target date
            if stat --version >/dev/null 2>&1; then
                FILE_DATE=$(date -r "$jsonl_file" '+%Y-%m-%d')
            else
                FILE_DATE=$(stat -f '%Sm' -t '%Y-%m-%d' "$jsonl_file" 2>/dev/null || date -r "$jsonl_file" '+%Y-%m-%d')
            fi
            [ "$FILE_DATE" = "$TARGET_DATE" ] || continue

            SESSION_ID=$(basename "$jsonl_file" .jsonl)
            RAW_FILE="$RAW_DIR/${TARGET_DATE}-${AGENT_NAME}-${SESSION_ID:0:8}.md"

            # Skip if already exported
            [ -f "$RAW_FILE" ] && { log "  SKIP (exists): $(basename "$RAW_FILE")"; continue; }

            log "  Exporting: $AGENT_NAME/$SESSION_ID"

            {
                echo "# Session: $TARGET_DATE ($AGENT_NAME)"
                echo ""
                echo "- **Agent**: $AGENT_NAME"
                echo "- **Session ID**: $SESSION_ID"
                echo "- **Date**: $TARGET_DATE"
                echo ""
                echo "## Conversation"
                echo ""

                python3 -c "
import json, sys

seen = set()
for line in open('$jsonl_file'):
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except:
        continue

    role = entry.get('role', '')
    content = entry.get('content', '')

    if not role and 'message' in entry:
        msg = entry['message']
        if isinstance(msg, dict):
            role = msg.get('role', '')
            content = msg.get('content', '')

    if not role or not content:
        continue
    if not isinstance(content, str):
        if isinstance(content, list):
            text_parts = []
            for part in content:
                if isinstance(part, dict) and part.get('type') == 'text':
                    text_parts.append(part.get('text', ''))
            content = '\n'.join(text_parts)
        else:
            continue

    if not content.strip():
        continue

    h = hash(role + content[:200])
    if h in seen:
        continue
    seen.add(h)

    if len(content) > 3000:
        content = content[:3000] + '...(truncated)'

    if role in ('user', 'assistant', 'system'):
        print(f'**{role}**: {content}')
        print()
" 2>/dev/null || true
            } > "$RAW_FILE"

            # Only keep if file has meaningful content (> 500 bytes)
            if [ "$(wc -c < "$RAW_FILE")" -lt 500 ]; then
                rm "$RAW_FILE"
                log "  SKIP (too short): $AGENT_NAME/$SESSION_ID"
            else
                EXPORTED=$((EXPORTED + 1))
                log "  OK: $(basename "$RAW_FILE")"
            fi

        done < <(find "$SESSION_DIR" -maxdepth 1 -name "*.jsonl" -not -name "*.deleted.*" -not -name "*.reset.*" 2>/dev/null)
    done
fi

log "Exported $EXPORTED session(s) to raw files"

# ── Step 2: Run memorize.sh on each new raw file ───────────────────────────

MEMORIZED=0

for raw_file in "$RAW_DIR"/${TARGET_DATE}*.md; do
    [ -f "$raw_file" ] || continue

    log "Processing: $(basename "$raw_file")"

    if bash "$SCRIPTS_DIR/memorize.sh" "$raw_file" >> "$LOG_FILE" 2>&1; then
        MEMORIZED=$((MEMORIZED + 1))
        log "  OK: memorized"
    else
        log "  WARN: memorize.sh failed for $(basename "$raw_file")"
    fi

    sleep 3  # Rate limit between API calls
done

log "Memorized $MEMORIZED file(s)"

# ── Step 3: Trigger memory re-index (if OpenClaw is available) ──────────────

OPENCLAW=$(command -v openclaw 2>/dev/null || echo "")
if [ -z "$OPENCLAW" ] && [ -x "$HOME/.nvm/versions/node/v22.22.1/bin/openclaw" ]; then
    OPENCLAW="$HOME/.nvm/versions/node/v22.22.1/bin/openclaw"
fi

if [ -n "$OPENCLAW" ]; then
    log "Triggering memory re-index..."
    timeout 300 "$OPENCLAW" memory index 2>&1 | tail -3 | tee -a "$LOG_FILE" || true
    log "Re-index done"
else
    log "OpenClaw CLI not found — skipping re-index (run 'openclaw memory index' manually)"
fi

# ── Summary ────────────────────────────────────────────────────────────────

log "=== Daily Archive Complete ==="
log "  Date: $TARGET_DATE"
log "  Sessions exported: $EXPORTED"
log "  Files memorized: $MEMORIZED"
log "  Log: $LOG_FILE"
