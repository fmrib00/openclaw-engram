#!/bin/bash
# install.sh — One-click installer for openclaw-engram
# Usage: bash install.sh
# Or:    curl -fsSL https://raw.githubusercontent.com/user/openclaw-engram/main/install.sh | bash

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }
info() { echo -e "${CYAN}→${NC} $*"; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     openclaw-engram installer            ║${NC}"
echo -e "${CYAN}║     Local-first long-term memory         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Check dependencies ──────────────────────────────────────────────────────

info "Checking dependencies..."

MISSING=()
for cmd in bash curl jq python3 grep; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd found"
    else
        MISSING+=("$cmd")
        warn "$cmd NOT found"
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    fail "Missing dependencies: ${MISSING[*]}. Install them and retry."
fi

# Check for OpenClaw (optional but recommended)
OPENCLAW=$(command -v openclaw 2>/dev/null || echo "")
if [ -z "$OPENCLAW" ] && [ -x "$HOME/.nvm/versions/node/v22.22.1/bin/openclaw" ]; then
    OPENCLAW="$HOME/.nvm/versions/node/v22.22.1/bin/openclaw"
fi

if [ -n "$OPENCLAW" ]; then
    ok "OpenClaw found: $OPENCLAW"
else
    warn "OpenClaw not found — install it for semantic search (memory_search)"
fi

# Check for node-llama-cpp / local embedding capability
if [ -n "$OPENCLAW" ]; then
    if "$OPENCLAW" memory model-list 2>/dev/null | grep -qi "gemma\|embedding" 2>/dev/null; then
        ok "Local embedding model found"
    else
        warn "No local embedding model detected"
        echo "    Download one (free, ~600MB, one-time):"
        echo "    $OPENCLAW memory model-download embeddinggemma-300m"
        echo ""
    fi
fi

# ── Detect paths ────────────────────────────────────────────────────────────

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
MEMORY_DIR="$WORKSPACE/memory"
SCRIPTS_DIR="$WORKSPACE/scripts"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"

info "Workspace: $WORKSPACE"
info "Memory:    $MEMORY_DIR"
info "Scripts:   $SCRIPTS_DIR"
echo ""

# ── Create directory structure ──────────────────────────────────────────────

info "Creating memory directory structure..."

mkdir -p "$MEMORY_DIR"/{raw,calendar,entities/{people,systems,customers,vendors},decisions,issues}
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$WORKSPACE/logs"

ok "Directory structure created"

# ── Copy scripts ────────────────────────────────────────────────────────────

info "Installing scripts..."

for script in memorize.sh recall.sh daily-archive.sh; do
    if [ -f "$SOURCE_DIR/scripts/$script" ]; then
        cp "$SOURCE_DIR/scripts/$script" "$SCRIPTS_DIR/$script"
        chmod +x "$SCRIPTS_DIR/$script"
        ok "Installed $script"
    else
        warn "$script not found in source — skipping"
    fi
done

# ── Create initial files ────────────────────────────────────────────────────

info "Creating initial files..."

# index.md
if [ ! -f "$MEMORY_DIR/index.md" ]; then
    cat > "$MEMORY_DIR/index.md" <<'EOF'
# Memory Index
<!-- Auto-generated keyword-to-file mapping -->

| Keyword | Files | Last Updated |
|---------|-------|-------------|
EOF
    ok "Created index.md"
else
    ok "index.md already exists"
fi

# issues/open.md
if [ ! -f "$MEMORY_DIR/issues/open.md" ]; then
    cat > "$MEMORY_DIR/issues/open.md" <<'EOF'
# Open Issues

## 🔴 Critical

## ⚠️ Warning

## 💡 Low Priority
EOF
    ok "Created issues/open.md"
else
    ok "issues/open.md already exists"
fi

# entities.conf
if [ ! -f "$MEMORY_DIR/entities.conf" ]; then
    if [ -f "$SOURCE_DIR/config-examples/entities.conf.example" ]; then
        cp "$SOURCE_DIR/config-examples/entities.conf.example" "$MEMORY_DIR/entities.conf"
    else
        cat > "$MEMORY_DIR/entities.conf" <<'EOF'
# Entity Whitelist Configuration
# Format: entity_name = relative/path/to/file.md
# Customize for your team/project!

# ── People ──
# alice = entities/people/alice.md

# ── Systems ──
assistant = entities/systems/assistant.md
server = entities/systems/server.md
EOF
    fi
    ok "Created entities.conf — edit this to add your team members and systems!"
else
    ok "entities.conf already exists"
fi

echo ""

# ── LLM API Configuration ──────────────────────────────────────────────────

info "LLM API Configuration (for memory extraction)"
echo ""
echo "  memorize.sh needs a cheap LLM to extract memories from text."
echo "  Set these environment variables (add to ~/.bashrc or .env):"
echo ""
echo "    export LLM_API_KEY=\"your-api-key\""
echo "    export LLM_API_URL=\"https://api.openai.com/v1/chat/completions\""
echo "    export LLM_MODEL=\"gpt-4o-mini\"    # or glm-4-flash, llama3.2, etc."
echo ""

if [ -n "${LLM_API_KEY:-}" ]; then
    ok "LLM_API_KEY is already set"
else
    warn "LLM_API_KEY is not set — memorize.sh will not work until you set it"
fi

echo ""

# ── Local Embedding ─────────────────────────────────────────────────────────

info "Local Embedding (for semantic search)"
echo ""
echo "  openclaw-engram recommends local embedding for zero-cost, private,"
echo "  offline-capable semantic search."
echo ""
echo "  Download the model (~600MB, one-time):"
echo "    openclaw memory model-download embeddinggemma-300m"
echo ""
echo "  Once downloaded, OpenClaw's memory_search automatically uses it."
echo "  No API key, no billing, works offline."
echo ""

# ── Cron setup ──────────────────────────────────────────────────────────────

info "Cron Job (optional)"
echo ""
echo "  To auto-archive daily at 2:30 AM:"
echo ""
echo "    crontab -e"
echo "    # Add this line:"
echo "    30 2 * * * LLM_API_KEY=\"your-key\" bash $SCRIPTS_DIR/daily-archive.sh"
echo ""

read -rp "  Set up cron now? [y/N] " SETUP_CRON
if [[ "$SETUP_CRON" =~ ^[Yy] ]]; then
    if [ -z "${LLM_API_KEY:-}" ]; then
        warn "LLM_API_KEY not set — cron will fail. Set it first, then run:"
        echo "    (crontab -l 2>/dev/null; echo '30 2 * * * LLM_API_KEY=\"your-key\" bash $SCRIPTS_DIR/daily-archive.sh') | crontab -"
    else
        (crontab -l 2>/dev/null; echo "30 2 * * * LLM_API_KEY=\"$LLM_API_KEY\" LLM_API_URL=\"${LLM_API_URL:-}\" LLM_MODEL=\"${LLM_MODEL:-}\" bash $SCRIPTS_DIR/daily-archive.sh") | crontab -
        ok "Cron job installed"
    fi
else
    info "Skipped cron setup"
fi

echo ""

# ── MEMORY.md update ────────────────────────────────────────────────────────

MEMORY_MD="$WORKSPACE/MEMORY.md"
RECALL_SNIPPET="## File-Based Memory Retrieval (openclaw-engram)

\`\`\`
Step 1 — Direct path (fastest)
  By date  → read memory/calendar/YYYY-MM/MM-DD.md
  By entity → read memory/entities/<type>/<name>.md
  Open issues → read memory/issues/open.md

Step 2 — Keyword search
  bash scripts/recall.sh \"keyword\"

Step 3 — Full text search (fallback)
  grep -ri \"keyword\" memory/
\`\`\`"

if [ -f "$MEMORY_MD" ]; then
    if ! grep -q "openclaw-engram" "$MEMORY_MD" 2>/dev/null; then
        echo "" >> "$MEMORY_MD"
        echo "$RECALL_SNIPPET" >> "$MEMORY_MD"
        ok "Updated MEMORY.md with retrieval instructions"
    else
        ok "MEMORY.md already has engram instructions"
    fi
else
    echo "$RECALL_SNIPPET" > "$MEMORY_MD"
    ok "Created MEMORY.md with retrieval instructions"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     openclaw-engram installed! 🧠        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Next steps:"
echo "    1. Edit $MEMORY_DIR/entities.conf to add your team/systems"
echo "    2. Set LLM_API_KEY environment variable"
echo "    3. Download local embedding: openclaw memory model-download embeddinggemma-300m"
echo "    4. Test: echo 'Alice deployed the API' > /tmp/test.md"
echo "            LLM_API_KEY=your-key bash $SCRIPTS_DIR/memorize.sh /tmp/test.md"
echo "    5. Search: bash $SCRIPTS_DIR/recall.sh \"Alice\""
echo ""
