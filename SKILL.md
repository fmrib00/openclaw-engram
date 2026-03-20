# openclaw-engram

Local-first, file-based long-term memory for OpenClaw agents — with on-device vector search via embeddinggemma-300m.

## Description

Persistent, searchable agent memory using plain Markdown files. Memories are extracted by a cheap LLM, organized into calendar/entity/decision files, and indexed both by keyword (grep) and by local embedding vectors (embeddinggemma-300m via node-llama-cpp + sqlite-vec). Zero cloud embedding costs, zero rate limits, fully offline-capable.

### What it does
- **memorize.sh** — Extracts structured memories from raw text using an LLM, distributes to calendar + entity files (dual-write), updates keyword index
- **recall.sh** — Keyword search across index.md + all memory files
- **daily-archive.sh** — Nightly cron: export OpenClaw session JSONL → raw markdown → memorize → re-index

### Architecture
```
session.jsonl → daily-archive.sh → raw/*.md → memorize.sh → calendar/
                                                           → entities/
                                                           → decisions/
                                                           → issues/
                                                           → index.md
                                                                ↓
                                              OpenClaw memory_search
                                           (embeddinggemma-300m, local)
```

## Installation

```bash
git clone https://github.com/user/openclaw-engram.git
cd openclaw-engram
bash install.sh

# Download local embedding model (~600MB, one-time)
openclaw memory model-download embeddinggemma-300m
```

## Configuration

### Required
- `LLM_API_KEY` — API key for memory extraction LLM

### Optional
- `LLM_API_URL` — Chat completions endpoint (default: GLM)
- `LLM_MODEL` — Model name (default: glm-4-flash)
- `MEMORY_DIR` — Custom memory directory path
- `entities.conf` — Entity whitelist (customize for your team)

## Dependencies

- bash 4+, curl, jq, python3
- An OpenAI-compatible LLM API (for extraction)
- OpenClaw with memory plugin (for local vector search)
