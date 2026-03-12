#!/usr/bin/env bash
# =============================================================================
#  generate-compose.sh — Docker Compose file generator (~900 lines)
#
#  SOURCE-ONLY: do not run this file directly.
#  Sourced by ai/setup.sh, which calls write_docker_compose().
#
#  Generates /opt/ai-stack/docker-compose.yml defining all 15 services in the
#  AI stack. Services communicate via the ai-net bridge network using container
#  name DNS. All persistent data lives in named Docker volumes.
# =============================================================================
set -euo pipefail

##
# Write the Docker Compose file defining all services in the AI stack.
#
# Services communicate via the  ai-net  bridge network using container
# name DNS (e.g. 'ollama', 'qdrant'). All persistent data is in named
# Docker volumes, so containers can be recreated without data loss.
#
# GPU ALLOCATION:
#   Ollama, Whisper, and nvidia-exporter receive full GPU access.
#   All other containers are CPU-only.
#
# TOOL SERVER PORTS:
#   8080  Open Terminal
#   8081  MCPO (MCP proxy)
#   8082  OpenAPI Filesystem server
#   8083  OpenAPI Memory/Knowledge Graph server
#   8084  OpenAPI Git server
#   8085  OpenAPI SQL server
#   8086  SearXNG
##
write_docker_compose() {
    section "Docker Compose"

    cat > /opt/ai-stack/docker-compose.yml <<COMPOSE
version: "3.9"

networks:
  ai-net:
    driver: bridge

volumes:
  ollama_data:
  openwebui_data:
  anythingllm_data:
  qdrant_data:
  whisper_cache:
  open_terminal_home:
  memory_data:

services:

  # ════════════════════════════════════════════════════════════════════════════
  #  CORE INFERENCE
  # ════════════════════════════════════════════════════════════════════════════

  # ── Ollama ──────────────────────────────────────────────────────────────────
  # LLM inference engine with OpenAI-compatible REST API.
  # OLLAMA_KEEP_ALIVE=24h keeps loaded models in VRAM between requests to avoid
  # the ~30s reload delay on every new conversation.
  # OLLAMA_MAX_LOADED_MODELS=2 allows one chat model + one embedding model.
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    environment:
      OLLAMA_HOST: 0.0.0.0
      OLLAMA_KEEP_ALIVE: 24h
      OLLAMA_MAX_LOADED_MODELS: "2"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    networks:
      - ai-net

  # ── Whisper ──────────────────────────────────────────────────────────────────
  # OpenAI-compatible speech-to-text API using faster-whisper on CUDA.
  # First start downloads the large-v3 model (~3 GB) — normal delay.
  # Model options: large-v3 (best), medium, small, base (fastest)
  # Open WebUI connects at: http://whisper:8000/v1
  whisper:
    image: fedirz/faster-whisper-server:latest-cuda
    container_name: whisper
    restart: unless-stopped
    ports:
      - "8000:8000"
    volumes:
      - whisper_cache:/root/.cache/huggingface
    environment:
      WHISPER__MODEL: large-v3
      WHISPER__INFERENCE_DEVICE: cuda
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  OPEN WEBUI ECOSYSTEM
  # ════════════════════════════════════════════════════════════════════════════

  # ── Open WebUI ───────────────────────────────────────────────────────────────
  # Primary AI chat interface. Pre-configured to connect to all local services.
  # TOOL_SERVER_CONNECTIONS pre-registers all OpenAPI/MCPO tool servers so
  # users don't need to configure them manually through the UI.
  # OPEN_TERMINAL_CONNECTIONS pre-registers the Open Terminal sandbox.
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "3000:8080"
    volumes:
      - openwebui_data:/app/backend/data
    environment:
      # ── Core ────────────────────────────────────────────────────────────────
      OLLAMA_BASE_URL: http://ollama:11434
      WEBUI_AUTH: "true"
      WEBUI_NAME: "Patwary AI"
      WEBUI_URL: http://chat.${BASE_DOMAIN}

      # ── Voice / STT ─────────────────────────────────────────────────────────
      # Routes microphone input through local Whisper rather than OpenAI's API
      AUDIO_STT_ENGINE: openai
      AUDIO_STT_OPENAI_API_BASE_URL: http://whisper:8000/v1
      AUDIO_STT_OPENAI_API_KEY: sk-placeholder

      # ── RAG Web Search ───────────────────────────────────────────────────────
      # SearXNG provides web search results injected into the context window
      ENABLE_RAG_WEB_SEARCH: "true"
      RAG_WEB_SEARCH_ENGINE: searxng
      SEARXNG_QUERY_URL: http://searxng:8080/search?q=<query>&format=json

      # ── Image Generation ──────────────────────────────────────────────────────
      # Disabled by default — enable if ComfyUI or AUTOMATIC1111 is added
      ENABLE_IMAGE_GENERATION: "false"

      # ── Tool Servers (OpenAPI + MCPO) ────────────────────────────────────────
      # Pre-registers all tool servers so they are available to models immediately.
      # Each entry follows the TOOL_SERVER_CONNECTIONS JSON schema.
      # Models must have Function Calling = Native to use these tools.
      TOOL_SERVER_CONNECTIONS: |
        [
          {
            "type": "openapi",
            "url": "http://mcpo:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "bearer",
            "key": "${MCPO_API_KEY}",
            "config": { "enable": true },
            "info": { "name": "MCP Tools (via MCPO)", "description": "Time, fetch, thinking, filesystem, memory, git, brave-search" }
          },
          {
            "type": "openapi",
            "url": "http://openapi-filesystem:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "none",
            "config": { "enable": true },
            "info": { "name": "Filesystem", "description": "Read, write, and list files in /workspace" }
          },
          {
            "type": "openapi",
            "url": "http://openapi-memory:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "none",
            "config": { "enable": true },
            "info": { "name": "Memory", "description": "Persistent knowledge graph across conversations" }
          },
          {
            "type": "openapi",
            "url": "http://openapi-git:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "none",
            "config": { "enable": true },
            "info": { "name": "Git", "description": "Git operations on /workspace repositories" }
          },
          {
            "type": "openapi",
            "url": "http://openapi-sql:8000",
            "spec_type": "url",
            "path": "openapi.json",
            "auth_type": "none",
            "config": { "enable": true },
            "info": { "name": "SQL", "description": "Natural language SQL queries against connected databases" }
          }
        ]

      # ── Open Terminal ─────────────────────────────────────────────────────────
      # Pre-registers the sandboxed terminal so AI can run shell commands.
      # Auth is via bearer token matched to OPEN_TERMINAL_API_KEY below.
      OPEN_TERMINAL_CONNECTIONS: |
        [
          {
            "name": "AI Sandbox",
            "url": "http://open-terminal:8000",
            "auth_type": "bearer",
            "key": "${MCPO_API_KEY}",
            "config": { "enable": true }
          }
        ]

    depends_on:
      - ollama
      - whisper
      - searxng
    networks:
      - ai-net

  # ── Open Terminal ─────────────────────────────────────────────────────────────
  # Sandboxed Linux environment the AI can control via shell commands.
  # The AI can: install packages, run scripts, process files, build things.
  # /home/user persists between restarts via named volume.
  # Docker socket is mounted so the AI can manage containers if needed.
  # OPEN_TERMINAL_MULTI_USER=true gives each Open WebUI user their own
  # isolated home directory within the container.
  open-terminal:
    image: ghcr.io/open-webui/open-terminal:latest
    container_name: open-terminal
    restart: unless-stopped
    ports:
      - "8080:8000"
    volumes:
      - open_terminal_home:/home/user
      # Share the workspace with OpenAPI filesystem and git servers
      - /opt/ai-stack/openapi-servers/workspace:/home/user/workspace
      # Docker socket: allows the AI to manage containers (trusted env only)
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      OPEN_TERMINAL_API_KEY: "${MCPO_API_KEY}"
      OPEN_TERMINAL_MULTI_USER: "true"
      # Extra pip packages available in the AI's Python environment
      OPEN_TERMINAL_PIP_PACKAGES: "httpx polars pandas numpy requests rich"
      # Extra apt packages available in the sandbox
      OPEN_TERMINAL_PACKAGES: "ffmpeg jq sqlite3 tree"
    networks:
      - ai-net

  # ── MCPO (MCP-to-OpenAPI Proxy) ───────────────────────────────────────────────
  # Reads mcpo/config.json, starts each MCP server as a subprocess, and
  # exposes every tool as an OpenAPI HTTP endpoint.
  # Each MCP server gets its own sub-path: http://mcpo:8000/<server-name>
  # API docs for all servers: http://<ai-vm-ip>:8081/docs
  # Hot-reload is enabled — editing config.json restarts affected servers
  # without downtime.
  # workspace is mounted so filesystem/git MCP servers can access shared files.
  mcpo:
    image: ghcr.io/open-webui/mcpo:main
    container_name: mcpo
    restart: unless-stopped
    ports:
      - "8081:8000"
    volumes:
      - /opt/ai-stack/mcpo/config.json:/app/config/config.json:ro
      - /opt/ai-stack/openapi-servers/workspace:/workspace
    command: >
      mcpo
        --host 0.0.0.0
        --port 8000
        --api-key "${MCPO_API_KEY}"
        --config /app/config/config.json
        --hot-reload
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  OPENAPI TOOL SERVERS (open-webui/openapi-servers)
  #  Native HTTP servers exposing structured tools via standard OpenAPI specs.
  #  Each server's schema is served at /openapi.json and viewable at /docs.
  # ════════════════════════════════════════════════════════════════════════════

  # ── OpenAPI Filesystem Server ─────────────────────────────────────────────────
  # Allows the AI to read, write, create, delete, and list files within /workspace.
  # The /workspace directory is shared with Open Terminal and the MCPO filesystem
  # MCP server, so files created by one tool are visible to the others.
  # Security: path traversal attacks are blocked by path normalization.
  # Destructive operations (delete) require a confirmation token.
  openapi-filesystem:
    image: ghcr.io/open-webui/openapi-servers:filesystem
    container_name: openapi-filesystem
    restart: unless-stopped
    ports:
      - "8082:8000"
    volumes:
      - /opt/ai-stack/openapi-servers/workspace:/workspace
    environment:
      ALLOWED_DIRECTORIES: /workspace
    networks:
      - ai-net

  # ── OpenAPI Memory / Knowledge Graph Server ───────────────────────────────────
  # Provides a persistent structured memory store that survives across
  # conversations. The AI can:
  #   - create_entities   (add named concepts)
  #   - add_observations  (store facts about entities)
  #   - create_relations  (link entities together)
  #   - query_knowledge   (search the graph semantically)
  # Data persists in /data/memory.json via named volume.
  openapi-memory:
    image: ghcr.io/open-webui/openapi-servers:memory
    container_name: openapi-memory
    restart: unless-stopped
    ports:
      - "8083:8000"
    volumes:
      - memory_data:/data
    networks:
      - ai-net

  # ── OpenAPI Git Server ────────────────────────────────────────────────────────
  # Exposes git operations as API endpoints. The AI can:
  #   - read commit history, diffs, branches, tags
  #   - search code within repos
  # Operates on git repos within /workspace (shared with filesystem server).
  openapi-git:
    image: ghcr.io/open-webui/openapi-servers:git
    container_name: openapi-git
    restart: unless-stopped
    ports:
      - "8084:8000"
    volumes:
      - /opt/ai-stack/openapi-servers/workspace:/workspace
    networks:
      - ai-net

  # ── OpenAPI SQL Server ────────────────────────────────────────────────────────
  # Accepts natural-language queries, generates SQL, executes against the
  # connected database, and returns formatted results.
  # Pointed at the Postgres instance on data-vm by default.
  # Change DATABASE_URL to point at a different database if needed.
  openapi-sql:
    image: ghcr.io/open-webui/openapi-servers:sql
    container_name: openapi-sql
    restart: unless-stopped
    ports:
      - "8085:8000"
    environment:
      DATABASE_URL: "postgresql://postgres:${POSTGRES_PASSWORD}@${DATA_VM_IP}:5432/app_db"
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  KNOWLEDGE AND SEARCH
  # ════════════════════════════════════════════════════════════════════════════

  # ── AnythingLLM ────────────────────────────────────────────────────────────────
  # Document-aware chat workspace. Upload PDFs, docs, code — ask questions.
  # Stores embeddings in Qdrant and metadata in Postgres on data-vm.
  anythingllm:
    image: mintplexlabs/anythingllm:latest
    container_name: anythingllm
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - anythingllm_data:/app/server/storage
    environment:
      STORAGE_DIR: /app/server/storage
      JWT_SECRET: ${ANYTHINGLLM_JWT_SECRET}
      LLM_PROVIDER: ollama
      OLLAMA_BASE_PATH: http://ollama:11434
      OLLAMA_MODEL_PREF: llama3.2
      EMBEDDING_ENGINE: ollama
      EMBEDDING_BASE_PATH: http://ollama:11434
      VECTOR_DB: qdrant
      QDRANT_ENDPOINT: http://qdrant:6333
      WHISPER_PROVIDER: local
    depends_on:
      - ollama
      - qdrant
    networks:
      - ai-net

  # ── Qdrant ────────────────────────────────────────────────────────────────────
  # High-performance vector database for embedding storage and similarity search.
  # Used by AnythingLLM. Port 6334 is the gRPC interface.
  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    restart: unless-stopped
    ports:
      - "6333:6333"
      - "6334:6334"
    volumes:
      - qdrant_data:/qdrant/storage
    networks:
      - ai-net

  # ── SearXNG ────────────────────────────────────────────────────────────────────
  # Self-hosted meta search engine. Aggregates Google, Bing, DuckDuckGo, and
  # others without sending personal data to any third party.
  # Open WebUI queries it at /search?q=<query>&format=json for RAG web search.
  # Port 8086 on the host; internally exposed as :8080 to Open WebUI.
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "8086:8080"
    volumes:
      - /opt/ai-stack/searxng:/etc/searxng:ro
    environment:
      SEARXNG_BASE_URL: http://searxng.${BASE_DOMAIN}/
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  REVERSE PROXY
  # ════════════════════════════════════════════════════════════════════════════

  # ── Nginx ──────────────────────────────────────────────────────────────────────
  # Routes subdomain requests to the appropriate containers.
  # Virtual host configs are in /opt/ai-stack/nginx/conf.d/ (one file per service).
  # Reload config without downtime: docker exec nginx nginx -s reload
  nginx:
    image: nginx:alpine
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/ai-stack/nginx/conf.d:/etc/nginx/conf.d:ro
      - /opt/ai-stack/nginx/certs:/etc/nginx/certs:ro
    depends_on:
      - open-webui
      - anythingllm
      - open-terminal
      - mcpo
    networks:
      - ai-net

  # ════════════════════════════════════════════════════════════════════════════
  #  OBSERVABILITY
  # ════════════════════════════════════════════════════════════════════════════

  # ── Prometheus Node Exporter ───────────────────────────────────────────────────
  # Exposes host system metrics (CPU, RAM, disk, network) at :9100/metrics.
  # Scraped by Prometheus on monitoring-vm every 15s.
  # pid: host is required for accurate per-process metrics.
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc)($$|/)'
    networks:
      - ai-net

  # ── NVIDIA GPU Exporter ────────────────────────────────────────────────────────
  # Exposes GPU metrics (utilisation, VRAM, temperature, power) at :9445/metrics.
  # Grafana dashboard ID 14574 visualises these. Requires GPU access.
  nvidia-exporter:
    image: mindprince/nvidia_gpu_prometheus_exporter:0.1
    container_name: nvidia-exporter
    restart: unless-stopped
    ports:
      - "9445:9445"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    networks:
      - ai-net

COMPOSE
    info "docker-compose.yml written ✓"
}
