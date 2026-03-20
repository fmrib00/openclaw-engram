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

# Check current memory search provider
if [ -n "$OPENCLAW" ]; then
    CURRENT_PROVIDER=$("$OPENCLAW" memory status 2>/dev/null | grep "Provider:" | awk '{print $2}' || echo "unknown")
    if [ "$CURRENT_PROVIDER" = "local" ]; then
        ok "Local embedding already configured"
    else
        info "Current memory search provider: ${CURRENT_PROVIDER:-none}"
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

# ── Local Embedding Configuration ───────────────────────────────────────────

info "Local Embedding Setup (for semantic search)"
echo ""
echo "  openclaw-engram recommends local embedding for zero-cost, private,"
echo "  offline-capable semantic search using embeddinggemma-300m (~600MB)."
echo ""

OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
NEED_RESTART=false

if [ -f "$OPENCLAW_CONFIG" ]; then
    # Check if memorySearch is already configured as local
    CURRENT=$(python3 -c "
import json
with open('$OPENCLAW_CONFIG') as f:
    c = json.load(f)
p = c.get('agents',{}).get('defaults',{}).get('memorySearch',{}).get('provider','')
print(p)
" 2>/dev/null || echo "")

    if [ "$CURRENT" = "local" ]; then
        ok "Local embedding already configured in openclaw.json"
    else
        read -rp "  Configure local embedding now? (recommended) [Y/n] " SETUP_EMBED
        if [[ ! "$SETUP_EMBED" =~ ^[Nn] ]]; then
            python3 -c "
import json
with open('$OPENCLAW_CONFIG') as f:
    config = json.load(f)

# Ensure path exists
config.setdefault('agents', {}).setdefault('defaults', {})

# Set memorySearch to local
config['agents']['defaults']['memorySearch'] = {
    'provider': 'local',
    'local': {
        'modelPath': 'hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf'
    }
}

with open('$OPENCLAW_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null

            if [ $? -eq 0 ]; then
                ok "Local embedding configured in openclaw.json"
                echo "    Model: embeddinggemma-300m (~600MB, auto-downloaded on first use)"
                echo "    No API key needed. Works offline."
                NEED_RESTART=true
            else
                warn "Failed to update config. Add manually:"
                echo '    "memorySearch": { "provider": "local", "local": { "modelPath": "hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf" } }'
            fi
        else
            info "Skipped local embedding setup"
            echo "    You can configure it later — see config-examples/local-embedding.json"
        fi
    fi
else
    warn "OpenClaw config not found at $OPENCLAW_CONFIG"
    echo "    Create it or set OPENCLAW_CONFIG to the correct path"
fi

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

# ── Restart Gateway ─────────────────────────────────────────────────────────

if [ "$NEED_RESTART" = true ] && [ -n "$OPENCLAW" ]; then
    echo ""
    warn "Gateway restart required for embedding changes to take effect."
    echo ""
    read -rp "  Restart OpenClaw gateway now? [Y/n] " DO_RESTART
    if [[ ! "$DO_RESTART" =~ ^[Nn] ]]; then
        info "Restarting gateway..."
        "$OPENCLAW" gateway restart 2>&1 | tail -3 || true
        ok "Gateway restarted. The embedding model (~600MB) will download on first search."
    else
        echo ""
        warn "Remember to restart the gateway manually:"
        echo "    openclaw gateway restart"
    fi
    echo ""
fi

echo "  Next steps:"
echo "    1. Edit $MEMORY_DIR/entities.conf to add your team/systems"
echo "    2. Set LLM_API_KEY environment variable"
echo "    3. Test: echo 'Alice deployed the API' > /tmp/test.md"
echo "            LLM_API_KEY=your-key bash $SCRIPTS_DIR/memorize.sh /tmp/test.md"
echo "    4. Search: bash $SCRIPTS_DIR/recall.sh \"Alice\""
echo ""
