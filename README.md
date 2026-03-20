# openclaw-engram

**Local-first long-term memory for OpenClaw agents.**

*Engram* (名词): 神经科学中的"记忆痕迹"——经验在大脑中留下的物理印记。

---

No cloud database. No embedding API fees. No rate limits. Your agent's memories live as Markdown files on your machine, indexed by a local vector model that runs on CPU in under a second.

不依赖云数据库、不需要 embedding API 费用、不受速率限制。Agent 的记忆以 Markdown 文件存储在本机，由本地向量模型在 CPU 上秒级完成索引。

## Why local vectors?

openclaw-engram uses **embeddinggemma-300m** (Google, ~600MB) running locally via **node-llama-cpp + sqlite-vec**. This is OpenClaw's built-in `memory_search` engine.

| | Cloud embedding (OpenAI/Gemini) | **openclaw-engram (local)** |
|---|---|---|
| **Cost** | ~$0.02/1M tokens, adds up | **$0 forever** |
| **Rate limits** | Yes — breaks batch operations | **None** |
| **Privacy** | Your data sent to third party | **Data never leaves your machine** |
| **Offline** | ✗ Needs internet | **✓ Works offline** |
| **Latency** | 100-500ms network round-trip | **<100ms on CPU** |
| **Setup** | API key + billing account | **One command download** |

### vs database-backed memory (pgvector, ChromaDB, memU)

| | Database solutions | **openclaw-engram** |
|---|---|---|
| **Storage** | PostgreSQL + pgvector / ChromaDB | **Plain Markdown files** |
| **Dependencies** | Docker, embedding model, vector DB | **bash, curl, jq** |
| **Write speed** | 30–200s (embed + store) | **3–6s** (LLM extract + file write) |
| **Search** | Vector similarity only | **Local vectors + BM25 + keyword index** |
| **Debugging** | SQL queries, opaque vectors | **Open a file, read it** |
| **Failure modes** | DB crash, model mismatch, stale embeddings | **Almost none** |

## Architecture

```
                                  openclaw-engram
┌──────────────────────────────────────────────────────────────────┐
│                                                                   │
│  session.jsonl ──→ daily-archive.sh ──→ raw/*.md                 │
│                                            │                      │
│                                       memorize.sh                 │
│                                       (LLM extract)              │
│                                            │                      │
│                    ┌───────────────────────┼──────────────┐       │
│                    ▼                       ▼              ▼       │
│              calendar/              entities/        decisions/   │
│            2026-03/03-16.md     systems/server.md   2026-03-*.md │
│            2026-03/03-17.md     people/alice.md      issues/     │
│                    │               │                              │
│                    └───────┬───────┘                              │
│                            ▼                                      │
│                        index.md  ◄── recall.sh (keyword grep)    │
│                            │                                      │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┼─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│                            ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  OpenClaw memory_search (local)                          │    │
│  │  embeddinggemma-300m → sqlite-vec → semantic search      │    │
│  │  + BM25 full-text search                                 │    │
│  │  All running on CPU, no API calls                        │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

### Dual-write principle

Every memory is written to **both** a calendar file (by date) and an entity file (by topic). You can find information either way.

### Storage structure

```
~/.openclaw/workspace/memory/
├── index.md                    # Keyword → file mapping (auto-generated)
├── entities.conf               # Entity whitelist (you customize this)
├── calendar/                   # What happened, by date
│   └── 2026-03/
│       ├── 03-16.md
│       └── 03-17.md
├── entities/                   # What we know, by topic
│   ├── people/
│   │   ├── alice.md
│   │   └── bob.md
│   ├── systems/
│   │   ├── myapp.md
│   │   └── server.md
│   ├── customers/
│   └── vendors/
├── decisions/                  # Important decisions with context
├── issues/
│   └── open.md                # Unresolved issues
└── raw/                        # Archived source documents
```

---

## Quick Start

### 1. Install

```bash
git clone https://github.com/user/openclaw-engram.git
cd openclaw-engram
bash install.sh
```

The installer checks dependencies, creates the directory structure, installs scripts, and optionally sets up a cron job.

### 2. Set up local embedding (recommended)

The installer automatically configures local embedding and prompts you to restart the gateway. If you skipped it, you can configure it manually:

```json
// Add to ~/.openclaw/openclaw.json under agents.defaults
"memorySearch": {
  "provider": "local",
  "local": {
    "modelPath": "hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf"
  }
}
```

Then restart the gateway and trigger indexing:

```bash
openclaw gateway restart
openclaw memory index --force
```

On first use, OpenClaw automatically downloads embeddinggemma-300m (~600MB) from HuggingFace. No API key needed, no billing, works offline.

> **Already using remote embedding?** That works too — see [Remote embedding](#remote-embedding-alternative) below.

### 3. Configure LLM for extraction

`memorize.sh` needs a cheap LLM to extract structured memories from raw text. Any OpenAI-compatible API works:

```bash
# GLM (cheapest, good for Chinese + English)
export LLM_API_KEY="your-zhipu-key"
export LLM_API_URL="https://open.bigmodel.cn/api/paas/v4/chat/completions"
export LLM_MODEL="glm-4-flash"

# Or OpenAI
export LLM_API_KEY="sk-..."
export LLM_API_URL="https://api.openai.com/v1/chat/completions"
export LLM_MODEL="gpt-4o-mini"

# Or local (Ollama)
export LLM_API_KEY="not-needed"
export LLM_API_URL="http://localhost:11434/v1/chat/completions"
export LLM_MODEL="llama3.2"
```

### 4. Configure entity whitelist

Edit `~/.openclaw/workspace/memory/entities.conf`:

```ini
# People
alice = entities/people/alice.md
bob = entities/people/bob.md

# Systems
myapp = entities/systems/myapp.md
server = entities/systems/server.md
```

Only whitelisted entities get their own files. This prevents the LLM from creating junk files for every noun.

### 5. Test

```bash
cat > /tmp/test-memory.md << 'EOF'
Alice deployed the new API to production at 3pm.
Bob reported a bug in the payment module.
Decision: Roll back to v2.3 until the fix is ready.
EOF

bash ~/.openclaw/workspace/scripts/memorize.sh /tmp/test-memory.md
bash ~/.openclaw/workspace/scripts/recall.sh "payment"
```

### 6. Automate

```bash
crontab -e
# Add:
30 2 * * * LLM_API_KEY="your-key" bash ~/.openclaw/workspace/scripts/daily-archive.sh
```

Runs nightly: exports session logs → extracts memories → re-indexes.

---

## How retrieval works

Three retrieval paths, from fastest to broadest:

### 1. Direct file access (instant)

When you know what you're looking for:

```
read memory/calendar/2026-03/03-16.md     # what happened on a date
read memory/entities/systems/server.md     # facts about the server
read memory/issues/open.md                 # current open issues
```

### 2. recall.sh — keyword search (<1s)

```bash
bash scripts/recall.sh "payment bug"
```

Searches `index.md` keywords + greps all memory files. Shows matched lines with context.

### 3. OpenClaw memory_search — semantic search (<1s)

OpenClaw's built-in tool uses local embedding vectors (embeddinggemma-300m) + BM25 to search all `.md` files in the workspace. Since engram stores everything as `.md` files, they're automatically indexed.

Best for fuzzy queries: "what issues did we have with deployments recently?"

---

## Scripts

### memorize.sh

Extracts memories from a document and distributes them to the right files.

```
Usage: bash memorize.sh <input-file.md>

Env:  LLM_API_KEY (required), LLM_API_URL, LLM_MODEL, MEMORY_DIR, ENTITY_CONFIG
```

Extracts: events → `calendar/`, entity facts → `entities/`, decisions → `decisions/`, issues → `issues/open.md`, keywords → `index.md`. All entity updates and decisions are **dual-written** to the calendar file too.

### recall.sh

```
Usage: bash recall.sh "keyword"
Env:   MEMORY_DIR
```

### daily-archive.sh

```
Usage: bash daily-archive.sh [YYYY-MM-DD]   (default: yesterday)
Env:   LLM_API_KEY (required), LLM_API_URL, LLM_MODEL
```

---

## Remote embedding (alternative)

If you prefer cloud embedding over local, configure OpenClaw's memory plugin:

**Gemini** (see `config-examples/gemini-embedding.json`):
```json
{"embedding": {"provider": "google", "model": "text-embedding-004", "apiKey": "YOUR_KEY"}}
```

**OpenAI** (see `config-examples/openai-embedding.json`):
```json
{"embedding": {"provider": "openai", "model": "text-embedding-3-small", "apiKey": "YOUR_KEY"}}
```

---

## FAQ

**Q: How much disk does it use?**
~3-5 KB/day for memories, ~1-2 MB/year. The embeddinggemma model is ~600MB (one-time download).

**Q: Can I use this without OpenClaw?**
Yes. The scripts work standalone. You lose `memory_search` (semantic search) but `recall.sh` (keyword search) still works.

**Q: What if I don't want to pay for any LLM API?**
Use a local model via Ollama for extraction too. Set `LLM_API_URL=http://localhost:11434/v1/chat/completions`. Then the entire system runs 100% offline with zero API costs.

**Q: How do I migrate from memU / pgvector?**

```bash
# Export
sudo docker exec memu-postgres psql -U memu -d memu -t -c \
  "SELECT memory_type || ': ' || summary FROM memory_items ORDER BY created_at;" \
  > memory/raw/memu-export.md

# Process
bash scripts/memorize.sh memory/raw/memu-export.md

# Stop memU
sudo docker stop memu-postgres
```

---

## Dependencies

- bash 4+, curl, jq, python3
- An OpenAI-compatible LLM API (for `memorize.sh` extraction)
- OpenClaw with `memory_search` plugin (for semantic search — optional but recommended)
- embeddinggemma-300m model (for local embedding — auto-downloaded on first use, ~600MB)

## License

MIT — see [LICENSE](LICENSE).
